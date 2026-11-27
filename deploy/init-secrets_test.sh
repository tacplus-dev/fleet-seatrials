#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/init-secrets.sh against a fake Secret Manager (a stub gcloud)
# and a stub schematic-operator (#44): a first run generates the pair and adds
# one version to each of fleet-crypto-seatrials (crypto.yaml as it is) and
# fleet-ca-seatrials (ca.pem); a second run adds nothing and runs no operator;
# a half pair (one secret with a version, the other without) is refused,
# adding nothing; a secret that does not exist, a refused read and a refused
# add fail, saying which; no generated value reaches the output or a command
# line.
#
#   deploy/init-secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"

# Secret Manager: a secret is the directory $STUB_SM/PROJECT/SECRET, its
# versions the files 1, 2, ... in it; a file N.disabled is a disabled version.
#   versions list SECRET --project=P --filter=state:enabled ...  the latest enabled version's number, or nothing
#   versions add SECRET --project=P --data-file=F               F as the next version
# A secret that is not there answers NOT_FOUND; STUB_REFUSE=list or
# STUB_REFUSE=add:SECRET answers PERMISSION_DENIED. Every call's arguments go
# to $STUB_CALLS.
cat > "$work/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
echo "gcloud $*" >> "$STUB_CALLS"
[ "$1 $2" = "secrets versions" ] || { echo "unexpected gcloud $*" >&2; exit 3; }
op=$3 secret=$4 project="" file="" filter=""
for a in "${@:5}"; do
  case "$a" in
    --project=*) project=${a#*=} ;;
    --data-file=*) file=${a#*=} ;;
    --filter=*) filter=${a#*=} ;;
  esac
done
dir=$STUB_SM/$project/$secret
[ -d "$dir" ] || { echo "ERROR: (gcloud.secrets.versions.$op) NOT_FOUND: Secret [projects/$project/secrets/$secret] not found." >&2; exit 1; }
case "$op" in
  list)
    [ "${STUB_REFUSE:-}" != list ] || { echo "ERROR: (gcloud.secrets.versions.list) PERMISSION_DENIED: Permission 'secretmanager.versions.list' denied" >&2; exit 1; }
    [ "$filter" = state:enabled ] || { echo "unexpected filter [$filter]" >&2; exit 3; }
    ls "$dir" | grep -x '[0-9]*' | sort -n | tail -1 ;;
  add)
    [ "${STUB_REFUSE:-}" != "add:$secret" ] || { echo "ERROR: (gcloud.secrets.versions.add) PERMISSION_DENIED: Permission 'secretmanager.versions.add' denied" >&2; exit 1; }
    n=$(( $(ls "$dir" | sed 's/\..*//' | sort -n | tail -1) + 1 ))
    cp "$file" "$dir/$n"
    echo "Created version [$n] of the secret [$secret]." >&2 ;;
  *) echo "unexpected gcloud $*" >&2; exit 3 ;;
esac
EOF
cat > "$work/bin/schematic-operator" <<'EOF'
#!/usr/bin/env bash
echo "schematic-operator $*" >> "$STUB_CALLS"
d=$SCHEMATIC_OPERATOR_DIR
case "$1 $2" in
  "init ca") printf 'pki:\n  root_ca: GENERATED-CA-KEY\n' > "$d/crypto.yaml"; echo GENERATED-CA-CERT > "$d/ca.pem" ;;
  "init cluster") [ -f "$d/crypto.yaml" ] && printf '  cluster: GENERATED-CLUSTER-KEY\n' >> "$d/crypto.yaml"
    printf 'fqdn: rewritten\n' > "$d/operator.yaml" ;;
  # generate issues kernel's certificates for operator.yaml's trust domain when crypto.yaml's are not for it, and
  # leaves them alone when they are; with STUB_REISSUE it issues them every time.
  "generate --output") p=$(sed -n 's/^spiffe_prefix: *//p' "$d/operator.yaml")
    if [ -n "${STUB_REISSUE:-}" ] || ! grep -q "kernel_tls: GENERATED-KERNEL-TLS-FOR-${p:-none}\$" "$d/crypto.yaml"; then
      printf '  kernel_tls: GENERATED-KERNEL-TLS-FOR-%s\n' "${p:-none}" >> "$d/crypto.yaml"
    fi ;;
esac
EOF
chmod +x "$work/bin/"*

sm=$work/sm/tacplus-dev
failures=0
# fresh: the two secrets, made by tacplus-dev/cloud, with no version.
fresh() { rm -rf "$work/sm"; mkdir -p "$sm/fleet-ca-seatrials" "$sm/fleet-crypto-seatrials"; }
# run NAME WANT(pass|fail) EXPECT [VAR=VALUE...]: EXPECT must be in the output.
run() {
  local name=$1 want=$2 expect=$3 status; shift 3
  : > "$work/calls"
  out=$(env PATH="$work/bin:$PATH" STUB_SM="$work/sm" STUB_CALLS="$work/calls" FLEET_KEY_GENERATION=1 "$@" "$here/init-secrets.sh" 2>&1)
  status=$?
  if { [ "$want" = pass ] && [ "$status" -ne 0 ]; } || { [ "$want" = fail ] && [ "$status" -eq 0 ]; } ||
     [[ "$out" != *"$expect"* ]]; then
    echo "FAIL $name: status=$status out=[$out]"; failures=$((failures + 1)); return 1
  fi
  echo "ok   $name"
}
# no_leak NAME: no generated value in the output or any command line.
no_leak() {
  if grep -q 'GENERATED' <<<"$out$(cat "$work/calls")"; then
    echo "FAIL $1: a secret in the output or a command line"; failures=$((failures + 1))
  else echo "ok   $1"; fi
}
want() { # NAME CONDITION...
  local name=$1; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}
versions() { ls "$sm/$1" | wc -l; } # SECRET: how many versions it has

fresh
run "first run: both generated, a version added to each" pass \
  "init-secrets: fleet-ca-seatrials: version 1 added"
want "fleet-crypto-seatrials: one version, crypto.yaml as it is (the CA and the cluster PKI)" \
  test "$(versions fleet-crypto-seatrials)/$(cat "$sm/fleet-crypto-seatrials/1")" = \
    "1/$(printf 'pki:\n  root_ca: GENERATED-CA-KEY\n  cluster: GENERATED-CLUSTER-KEY\n  kernel_tls: GENERATED-KERNEL-TLS-FOR-tacplus.dev')"
want "generate ran on the committed operator.yaml, not init's rewrite, twice (the second must change nothing)" \
  test "$(grep -c 'schematic-operator generate --output' "$work/calls")" = 2
want "fleet-ca-seatrials: one version, ca.pem as it is" \
  test "$(versions fleet-ca-seatrials)/$(cat "$sm/fleet-ca-seatrials/1")" = 1/GENERATED-CA-CERT
want "the crypto file is added before the CA" \
  test "$(grep -o 'versions add [a-z-]*' "$work/calls" | tr '\n' ' ')" = \
    "versions add fleet-crypto-seatrials versions add fleet-ca-seatrials "
want "the cluster PKI for the committed fqdn" grep -q "init cluster --fqdn seatrials.tacplus.dev" "$work/calls"
no_leak "first run: no secret in the output or a command line"
want "the committed operator.yaml untouched" grep -q "^fqdn: seatrials.tacplus.dev" "$here/bootstrap/operator.yaml"

run "second run: skipped, both have a version" pass "nothing to generate"
want "second run: no version added" test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)" = 1/1
want "second run: the operator not run" test -z "$(grep schematic-operator "$work/calls")"

# A later generation (deploy/key-generation): both behind it are generated again, a new version of each; at it,
# nothing; one ahead of the other, refused.
run "generation 2, both at version 1: generated again" pass "behind generation 2 (deploy/key-generation): generating the pair again" FLEET_KEY_GENERATION=2
want "generation 2: a second version of each" test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)" = 2/2
no_leak "generation 2: no secret in the output or a command line"
run "generation 2, both at version 2: nothing" pass "at generation 2 or later: nothing to generate" FLEET_KEY_GENERATION=2
want "generation 2 again: no version added, the operator not run" \
  test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)/$(grep -c schematic-operator "$work/calls")" = 2/2/0
rm "$sm/fleet-ca-seatrials/2"
run "generation 3, the crypto file at 2 and the CA at 1: refused" fail "they are a pair" FLEET_KEY_GENERATION=3
want "an uneven pair: nothing added, no operator" \
  test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)/$(grep -c 'schematic-operator\|versions add' "$work/calls")" = 2/1/0
run "a generation that is no number: refused" fail "holds no generation number" FLEET_KEY_GENERATION=two
fresh
run "an operator that issues new keys on every generate: refused, nothing stored" fail \
  "changes crypto.yaml every time it runs" STUB_REISSUE=1
want "nothing stored" test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)" = 0/0
want "the committed generation is a number" grep -qx '[1-9][0-9]*' <(grep -v '^[[:space:]]*\(#\|$\)' "$here/key-generation")

fresh; echo CRYPTO > "$sm/fleet-crypto-seatrials/1"
run "half pair (the crypto file only): refused" fail \
  "fleet-crypto-seatrials has a version but fleet-ca-seatrials has none"
want "half pair (the crypto file only): nothing added, no operator" \
  test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)/$(grep -c 'schematic-operator\|versions add' "$work/calls")" = 1/0/0

fresh; echo CA > "$sm/fleet-ca-seatrials/1"
run "half pair (the CA only): refused" fail "fleet-ca-seatrials has a version but fleet-crypto-seatrials has none"
want "half pair (the CA only): nothing added, no operator" \
  test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)/$(grep -c 'schematic-operator\|versions add' "$work/calls")" = 0/1/0

fresh; echo CRYPTO > "$sm/fleet-crypto-seatrials/1.disabled"; echo CA > "$sm/fleet-ca-seatrials/1.disabled"
run "disabled versions only: both generated again" pass "fleet-ca-seatrials: version 2 added"

fresh; rmdir "$sm/fleet-ca-seatrials"
run "a secret that does not exist: refused, saying which" fail \
  "listing the versions of fleet-ca-seatrials (project tacplus-dev): ERROR: (gcloud.secrets.versions.list) NOT_FOUND"
want "a secret that does not exist: nothing added" test "$(versions fleet-crypto-seatrials)" = 0

fresh
run "a refused read: fails, saying so" fail "PERMISSION_DENIED" STUB_REFUSE=list
want "a refused read: nothing added" test "$(versions fleet-crypto-seatrials)/$(versions fleet-ca-seatrials)" = 0/0

fresh
run "the CA's add refused: fails, saying the crypto file is added alone and what to do" fail \
  "fleet-crypto-seatrials has version 1 without its CA" STUB_REFUSE=add:fleet-ca-seatrials
no_leak "a refused add: no secret in the output or a command line"

rm -rf "$work/sm"; mkdir -p "$work/sm/elsewhere/fleet-ca-x" "$work/sm/elsewhere/fleet-crypto-x"
run "the project and the secrets' names from the environment" pass "fleet-ca-x: version 1 added" \
  GCP_PROJECT=elsewhere FLEET_CA_SECRET=fleet-ca-x FLEET_CRYPTO_SECRET=fleet-crypto-x

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
