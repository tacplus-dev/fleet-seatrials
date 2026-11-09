#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/cert.sh, the cert job, against stub gcloud (Secret Manager in a
# directory) and lego (it writes a certificate, or nothing, or fails), with the
# real ci/cert-check.sh under a test CA:
#   - lego obtains a new certificate (nothing of the old one given to it) only when the
#     check says missing, expired, wrong-hostname or invalid;
#   - on valid or due, lego gets the current certificate and its own renewal decides (ARI,
#     falling back to the last third): it renews, or it writes nothing and the version stays;
#   - a new version is added only for a certificate lego wrote that passes the check;
#   - a supplied certificate is checked the same way and never obtained;
#   - the ACME account is kept in its own secret, a version added only when it changed;
#   - the job passes the secret and version on (CERT_ENV_OUT), prints nothing secret, and
#     leaves no working directory.
# Needs bash, jq, yq and openssl.
#
#   ci/cert_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
mkdir -p "$work/bin" "$work/pki"

cat > "$work/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
# Secret Manager in $STUB_SM/<project>/<secret>/<n>: list, access, add.
echo "gcloud $*" >> "$STUB_LOG"
args=() project="" secret="" out="" data=""
for a in "$@"; do
  case "$a" in
    --project=*) project=${a#*=} ;; --secret=*) secret=${a#*=} ;; --out-file=*) out=${a#*=} ;;
    --data-file=*) data=${a#*=} ;; --*) ;; *) args+=("$a") ;;
  esac
done
case "${args[*]:0:3}" in
  "secrets versions list")
    d=$STUB_SM/$project/${args[3]}
    [ -d "$d" ] || { echo "ERROR: NOT_FOUND: secret ${args[3]}" >&2; exit 1; }
    n=$(ls "$d" | sort -n | tail -1); [ -z "$n" ] || echo "projects/$project/secrets/${args[3]}/versions/$n" ;;
  "secrets versions access")
    f=$STUB_SM/$project/$secret/${args[3]}
    [ -f "$f" ] || { echo "ERROR: NOT_FOUND: version" >&2; exit 1; }
    cp "$f" "$out" ;;
  "secrets versions add")
    d=$STUB_SM/$project/${args[3]}
    [ -d "$d" ] || { echo "ERROR: NOT_FOUND: secret ${args[3]}" >&2; exit 1; }
    n=$(( $(ls "$d" | sort -n | tail -1) + 1 ))
    cp "$data" "$d/$n" && echo "projects/$project/secrets/${args[3]}/versions/$n" ;;
  *) echo "unexpected gcloud $*" >&2; exit 3 ;;
esac
EOF
cat > "$work/bin/lego" <<'EOF'
#!/usr/bin/env bash
# Records how it was run (fresh: no certificate given to it; renew: the current one) and,
# as STUB_LEGO says, writes $STUB_ISSUE as the certificate (issue), writes nothing (noop)
# or fails (fail). It registers the account when it has none.
path="" name=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in --path) j=$((i + 1)); path=${!j} ;; --cert.name) j=$((i + 1)); name=${!j} ;; esac
done
how=fresh
[ -f "$path/certificates/$name.json" ] && [ -f "$path/certificates/$name.crt" ] && [ -f "$path/certificates/$name.key" ] && how=renew
echo "lego $how $*" >> "$STUB_LOG"
echo "$path" > "$STUB_LEGO_PATH"
echo "GCE_PROJECT=${GCE_PROJECT:-} GCE_ZONE_ID=${GCE_ZONE_ID:-}" >> "$STUB_LOG"
if [ ! -d "$path/accounts" ]; then
  mkdir -p "$path/accounts/acme-v02.api.letsencrypt.org/seatrials/keys"
  echo '{"id":"seatrials"}' > "$path/accounts/acme-v02.api.letsencrypt.org/seatrials/account.json"
  echo "ACCOUNT KEY" > "$path/accounts/acme-v02.api.letsencrypt.org/seatrials/keys/seatrials.key"
fi
case "${STUB_LEGO:-noop}" in
  issue) mkdir -p "$path/certificates"
    sed '/PRIVATE KEY-----$/,$d' "$STUB_ISSUE" > "$path/certificates/$name.crt"
    sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "$STUB_ISSUE" > "$path/certificates/$name.key"
    echo '{}' > "$path/certificates/$name.json" ;;
  fail) echo "lego: acme: error: 429 :: urn:ietf:params:acme:error:rateLimited" >&2; exit 1 ;;
esac
EOF
chmod +x "$work/bin/"*

# The test PKI: a root (the trust anchor), an intermediate, and payloads (leaf, chain, key).
cd "$work/pki"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout root.key -out root.crt -days 3650 -subj /CN=root 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout inter.key -out inter.csr -subj /CN=inter 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n' > inter.ext
openssl x509 -req -in inter.csr -CA root.crt -CAkey root.key -CAcreateserial -days 3650 -extfile inter.ext -out inter.crt 2>/dev/null
leaf() { # NAME DAYS SAN...
  local name=$1 days=$2 san; shift 2
  san=$(printf 'DNS:%s,' "$@")
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$1" 2>/dev/null
  printf 'subjectAltName=%s\n' "${san%,}" > "$name.ext"
  openssl x509 -req -in "$name.csr" -CA inter.crt -CAkey inter.key -CAcreateserial -days "$days" -extfile "$name.ext" -out "$name.crt" 2>/dev/null
  cat "$name.crt" inter.crt "$name.key" > "$name.pem"
}
# renewed is what lego writes; long enough to be valid at the times the tests check the
# current one at (CERT_CHECK_NOW holds for both).
leaf current 90 tacplus.dev '*.tacplus.dev'
leaf renewed 400 tacplus.dev '*.tacplus.dev'
leaf narrow 400 seatrials.tacplus.dev
cat current.crt inter.crt narrow.key > badkey.pem
cd "$here/.."
printf 'fqdn: seatrials.tacplus.dev\n' > "$work/operator.yaml"
now=$(date +%s) day=86400

# run NAME [VAR=VALUE...]: ci/cert.sh in a fresh state ($work/$NAME), its output in
# $work/$NAME/out, its exit status in $rc, CERT_ENV_OUT in $work/$NAME/cert.env.
run() {
  local name=$1; shift
  s=$work/$name; rm -rf "$s"; mkdir -p "$s/sm/tacplus-dev/tls-seatrials" "$s/sm/tacplus-dev/acme-account-seatrials" \
    "$s/sm/tacplus-dev/tls-supplied"
  for d in ${SECRETS:-}; do mkdir -p "$s/sm/tacplus-dev/$d"; done
  : > "$s/log"
  [ -z "${CURRENT:-}" ] || cp "$work/pki/$CURRENT" "$s/sm/tacplus-dev/tls-seatrials/4"
  [ -z "${ACCOUNT:-}" ] || { mkdir -p "$s/acct/accounts/x/seatrials"; echo '{"id":"seatrials"}' > "$s/acct/accounts/x/seatrials/account.json"
    tar -C "$s/acct" -czf "$s/sm/tacplus-dev/acme-account-seatrials/1" accounts; }
  [ -z "${SUPPLIED:-}" ] || cp "$work/pki/$SUPPLIED" "$s/sm/tacplus-dev/tls-supplied/2"
  rc=0
  env PATH="$work/bin:$PATH" STUB_SM="$s/sm" STUB_LOG="$s/log" STUB_LEGO_PATH="$s/lego-path" \
    STUB_ISSUE="$work/pki/${ISSUE:-renewed.pem}" CERT_CHECK_CAFILE="$work/pki/root.crt" \
    CERT_PROJECT=tacplus-dev CERT_SECRET=tls-seatrials ACME_ACCOUNT_SECRET=acme-account-seatrials \
    CERT_DOMAINS='tacplus.dev,*.tacplus.dev' CERT_DNS_ZONE=acme-challenge-tacplus-dev \
    OPERATOR_YAML="$work/operator.yaml" CERT_ENV_OUT="$s/cert.env" "$@" \
    "$here/cert.sh" > "$s/out" 2>&1 || rc=$?
}
versions() { ls "$s/sm/tacplus-dev/$1" | sort -n | tr '\n' ' ' | sed 's/ $//'; }
lego_runs() { grep -c '^lego ' "$s/log"; }
expect() { # NAME CONDITION...: ok when the condition (a command) holds
  local name=$1; shift
  if "$@"; then ok "$name"; else fail "$name: $(tail -5 "$s/out" | tr '\n' '|')"; fi
}
env_is() { [ "$(cat "$s/cert.env" 2>/dev/null)" = "$(printf 'CERT_SECRET=%s\nCERT_VERSION=%s' "$1" "$2")" ]; }
no_secret_printed() {
  ! grep -q 'PRIVATE KEY\|ACCOUNT KEY' "$s/out" && ! grep -qF "$(sed -n 2p "$work/pki/renewed.key")" "$s/out" &&
    ! grep -qF "$(sed -n 2p "$work/pki/current.key")" "$s/out"
}
no_workdir_left() { [ -s "$s/lego-path" ] && [ ! -e "$(cat "$s/lego-path")" ]; }

# Missing: the first run, no version and no account. lego obtains, the account is kept.
CURRENT= ACCOUNT= run missing STUB_LEGO=issue
expect "missing: the job succeeds" [ "$rc" = 0 ]
expect "missing: lego obtains a new certificate" grep -q '^lego fresh run ' "$s/log"
expect "missing: lego asks for apex and wildcard" grep -q -- "--domains tacplus.dev --domains \*.tacplus.dev" "$s/log"
expect "missing: lego answers DNS-01 in Cloud DNS" grep -q -- "--dns gcloud" "$s/log"
expect "missing: lego writes the challenge in the project's challenge zone" \
  grep -qx 'GCE_PROJECT=tacplus-dev GCE_ZONE_ID=acme-challenge-tacplus-dev' "$s/log"
expect "missing: lego uses ARI (it is never disabled)" bash -c "! grep -q -- --ari-disable '$s/log'"
expect "missing: its certificate is the new version 1" [ "$(versions tls-seatrials)" = 1 ]
expect "missing: the version holds the chain and the key" \
  cmp -s <(grep -v '^$' "$s/sm/tacplus-dev/tls-seatrials/1") <(grep -v '^$' "$work/pki/renewed.pem")
expect "missing: the new ACME account is kept in its own secret" [ "$(versions acme-account-seatrials)" = 1 ]
expect "missing: it passes tls-seatrials version 1 on" env_is tls-seatrials 1
expect "missing: nothing secret on its output" no_secret_printed
expect "missing: no working directory left" no_workdir_left

# Valid: lego gets the current certificate and decides; it writes nothing, nothing changes.
CURRENT=current.pem ACCOUNT=1 run valid STUB_LEGO=noop
expect "valid: the job succeeds" [ "$rc" = 0 ]
expect "valid: lego renews by its own decision (ARI, then the last third), not a new order" \
  grep -q '^lego renew run ' "$s/log"
expect "valid: lego is not forced" bash -c "! grep -q -- --renew-force '$s/log'"
expect "valid: no new version" [ "$(versions tls-seatrials)" = 4 ]
expect "valid: no new account version" [ "$(versions acme-account-seatrials)" = 1 ]
expect "valid: it passes the current version 4 on" env_is tls-seatrials 4
expect "valid: nothing secret on its output" no_secret_printed
expect "valid: no working directory left" no_workdir_left

# Due: inside the last third. lego renews, and its certificate is the new version.
CURRENT=current.pem ACCOUNT=1 run due STUB_LEGO=issue CERT_CHECK_NOW=$((now + 61 * day))
expect "due: the job succeeds" [ "$rc" = 0 ]
expect "due: lego renews the current certificate" grep -q '^lego renew run ' "$s/log"
expect "due: the renewed certificate is the new version 5" [ "$(versions tls-seatrials)" = "4 5" ]
expect "due: it passes version 5 on" env_is tls-seatrials 5
expect "due: nothing secret on its output" no_secret_printed

# Expired, wrong hostname, invalid: lego obtains anew.
CURRENT=current.pem ACCOUNT=1 run expired STUB_LEGO=issue CERT_CHECK_NOW=$((now + 91 * day))
expect "expired: lego obtains a new certificate" grep -q '^lego fresh run ' "$s/log"
expect "expired: it is the new version 5" [ "$(versions tls-seatrials)" = "4 5" ]
CURRENT=narrow.pem ACCOUNT=1 run wronghost STUB_LEGO=issue
expect "wrong-hostname: lego obtains a new certificate" grep -q '^lego fresh run ' "$s/log"
expect "wrong-hostname: it is the new version 5" [ "$(versions tls-seatrials)" = "4 5" ]
expect "wrong-hostname: it passes version 5 on" env_is tls-seatrials 5
CURRENT=badkey.pem ACCOUNT=1 run invalid STUB_LEGO=issue
expect "invalid: lego obtains a new certificate" grep -q '^lego fresh run ' "$s/log"
expect "invalid: it is the new version 5" [ "$(versions tls-seatrials)" = "4 5" ]
expect "invalid: nothing secret on its output" no_secret_printed

# What lego wrote is checked first: one that does not cover the hostnames is never a version.
CURRENT= ACCOUNT=1 ISSUE=narrow.pem run badissue STUB_LEGO=issue
expect "a certificate lego wrote that fails the check fails the job" [ "$rc" != 0 ]
expect "and is not added as a version" [ -z "$(versions tls-seatrials)" ]
expect "and the job says why" grep -q 'wrong-hostname' "$s/out"
expect "and no working directory is left" no_workdir_left

# lego fails: the job fails, no version, lego's error shown.
CURRENT=current.pem ACCOUNT=1 run legofails STUB_LEGO=fail CERT_CHECK_NOW=$((now + 61 * day))
expect "lego failing fails the job" [ "$rc" != 0 ]
expect "lego failing adds no version" [ "$(versions tls-seatrials)" = 4 ]
expect "lego failing shows lego's error" grep -q 'rateLimited' "$s/out"

# Lets Encrypt's staging, for a test run.
CURRENT= ACCOUNT=1 run staging STUB_LEGO=issue ACME_SERVER=letsencrypt-staging
expect "ACME_SERVER chooses the CA (staging for a test run)" grep -q -- '--server letsencrypt-staging' "$s/log"

# Supplied: checked, never obtained.
CURRENT=current.pem SUPPLIED=current.pem ACCOUNT=1 run supplied CERT_SUPPLIED_SECRET=tls-supplied STUB_LEGO=issue
expect "supplied valid: the job succeeds" [ "$rc" = 0 ]
expect "supplied valid: lego never runs" [ "$(lego_runs)" = 0 ]
expect "supplied valid: it passes the supplied secret's version on" env_is tls-supplied 2
expect "supplied valid: nothing is written" bash -c "[ '$(versions tls-supplied)' = 2 ] && [ '$(versions tls-seatrials)' = 4 ]"
CURRENT= SUPPLIED=current.pem ACCOUNT= run supplieddue CERT_SUPPLIED_SECRET=tls-supplied CERT_CHECK_NOW=$((now + 61 * day))
expect "supplied due: a warning, not a failure" bash -c "[ $rc = 0 ] && grep -q 'warning' '$s/out'"
expect "supplied due: lego never runs" [ "$(lego_runs)" = 0 ]
for st in expired:$((now + 91 * day)) wronghost: invalid:; do
  case $st in wronghost:*) p=narrow.pem ;; invalid:*) p=badkey.pem ;; *) p=current.pem ;; esac
  at=${st#*:}
  CURRENT= SUPPLIED=$p ACCOUNT= run "supplied-${st%%:*}" CERT_SUPPLIED_SECRET=tls-supplied ${at:+CERT_CHECK_NOW=$at}
  expect "supplied ${st%%:*}: the job fails, naming the secret to update" bash -c "[ $rc != 0 ] && grep -q 'tls-supplied' '$s/out'"
  expect "supplied ${st%%:*}: lego never runs" [ "$(lego_runs)" = 0 ]
done
CURRENT= SUPPLIED= ACCOUNT= run suppliedmissing CERT_SUPPLIED_SECRET=tls-supplied
expect "supplied missing: the job fails, naming the secret" bash -c "[ $rc != 0 ] && grep -q 'tls-supplied' '$s/out'"
expect "supplied missing: lego never runs" [ "$(lego_runs)" = 0 ]

# A secret that does not exist (or cannot be read) is an error, not a missing certificate.
CURRENT= ACCOUNT= run nosecret STUB_LEGO=issue CERT_SECRET=tls-nowhere
expect "an unreadable secret fails the job, and lego never runs" bash -c "[ $rc != 0 ] && [ $(lego_runs) = 0 ]"

# The test IdP's own certificate (test-idp/apply.sh, #27): its secrets, its one name and its
# challenge zone, checked for CERT_FQDN, not the fleet's fqdn, with no operator.yaml read.
(cd "$work/pki" && leaf idp 400 idp.test.tacplus.dev)
CURRENT= ACCOUNT= ISSUE=idp.pem SECRETS="tls-test-idp acme-account-test-idp" run testidp STUB_LEGO=issue CERT_SECRET=tls-test-idp \
  ACME_ACCOUNT_SECRET=acme-account-test-idp CERT_DOMAINS=idp.test.tacplus.dev CERT_FQDN=idp.test.tacplus.dev \
  CERT_DNS_ZONE=acme-challenge-idp-test-tacplus-dev OPERATOR_YAML="$work/nowhere.yaml"
expect "test IdP: the job succeeds" [ "$rc" = 0 ]
expect "test IdP: lego asks for its one name" bash -c "grep -q -- '--domains idp.test.tacplus.dev' '$s/log' && ! grep -q -- '--domains tacplus.dev' '$s/log'"
expect "test IdP: lego writes the challenge in its own zone" \
  grep -qx 'GCE_PROJECT=tacplus-dev GCE_ZONE_ID=acme-challenge-idp-test-tacplus-dev' "$s/log"
expect "test IdP: its certificate is version 1 of tls-test-idp, its account in acme-account-test-idp" \
  bash -c "[ '$(versions tls-test-idp)' = 1 ] && [ '$(versions acme-account-test-idp)' = 1 ] && [ -z '$(versions tls-seatrials)' ]"
expect "test IdP: it passes tls-test-idp version 1 on" env_is tls-test-idp 1
CURRENT= ACCOUNT= SECRETS="tls-test-idp acme-account-test-idp" run testidp-wrongname STUB_LEGO=issue CERT_SECRET=tls-test-idp \
  ACME_ACCOUNT_SECRET=acme-account-test-idp CERT_DOMAINS=idp.test.tacplus.dev CERT_FQDN=idp.test.tacplus.dev \
  CERT_DNS_ZONE=acme-challenge-idp-test-tacplus-dev OPERATOR_YAML="$work/nowhere.yaml"
expect "test IdP: a certificate without its name is never added" \
  bash -c "[ $rc != 0 ] && [ -z '$(versions tls-test-idp)' ]"

[ "$failed" = 0 ] && echo "all passed" || { echo "cert tests failed"; exit 1; }
