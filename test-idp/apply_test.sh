#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests test-idp/apply.sh's seeds (#27), against a stub gcloud, kubectl, curl
# and ci/cert.sh. With no seeds in its environment (the secret test-idp-seeds
# has no version yet), it generates both and adds them as one version of
# test-idp-seeds, two lines NAME=value, and the Secrets it writes are derived
# from them; with the seeds the job read, it stores nothing; with only one, or
# when Secret Manager refuses the version, it fails, saying why, and writes no
# Secret. No seed is printed or on a command line. Needs bash, python3 and yq.
#
#   test-idp/apply_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

# The tree apply.sh runs from: its own files, and a stub ci/cert.sh that passes on version 3.
mkdir -p "$work/tree/test-idp" "$work/tree/ci" "$work/bin" "$work/log"
cp -r "$here/test-idp/apply.sh" "$here/test-idp/testidp.py" "$here/test-idp/keycloak.yaml" "$here/test-idp/realms" \
  "$work/tree/test-idp/"
printf '#!/usr/bin/env bash\necho CERT_VERSION=3 > "$CERT_ENV_OUT"\n' > "$work/tree/ci/cert.sh"

# A stub gcloud: versions add keeps --data-file as the stored version (or refuses
# when SM_REFUSE is set); versions access gives a certificate. Every command
# line is logged.
cat > "$work/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "gcloud \$*" >> "$work/log/cmdline"
case "\$1 \$2 \$3" in
  "secrets versions add")
    [ -z "\${SM_REFUSE:-}" ] || { echo "ERROR: (gcloud.secrets.versions.add) PERMISSION_DENIED: denied" >&2; exit 1; }
    for a in "\$@"; do case "\$a" in --data-file=*) cp "\${a#*=}" "$work/stored" ;; esac; done ;;
  "secrets versions access")
    for a in "\$@"; do case "\$a" in --out-file=*) echo "a certificate" > "\${a#*=}" ;; esac; done ;;
esac
EOF
# A stub kubectl: the dev context; create secret keeps each --from-file under
# secrets/NAME/; everything else succeeds.
cat > "$work/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "kubectl \$*" >> "$work/log/cmdline"
[ "\$*" = "config current-context" ] && { echo gke_tacplus-dev_us-central1-a_dev; exit 0; }
args=("\$@"); [ "\$1" = -n ] && args=("\${args[@]:2}")
if [ "\${args[0]} \${args[1]} \${args[2]}" = "create secret generic" ]; then
  d=$work/secrets/\${args[3]}; mkdir -p "\$d"
  for a in "\${args[@]}"; do case "\$a" in
    --from-file=*=*) f=\${a#--from-file=}; cp "\${f#*=}" "\$d/\${f%%=*}" ;;
    --from-file=*) cp -r "\${a#--from-file=}"/. "\$d/" ;;
  esac; done
  echo "kind: Secret"
fi
[ "\${args[0]}" = apply ] && cat > /dev/null
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 7\n' > "$work/bin/curl"
chmod +x "$work/bin/"* "$work/tree/ci/cert.sh"

# apply [VAR=VALUE...]: apply.sh as the job runs it, its output in out.
apply() {
  rm -rf "$work/log/"* "$work/stored" "$work/secrets"
  env -i HOME="$work" PATH="$work/bin:$PATH" "$@" "$work/tree/test-idp/apply.sh" > "$work/out" 2>&1
}
# derived SEED_VAR=SEED... PURPOSE: what testidp.py derives for PURPOSE from those seeds.
derived() { env "${@:1:$#-1}" python3 "$work/tree/test-idp/testidp.py" secret "${*: -1}"; }

if apply; then
  seed=$(sed -n 's/^TEST_IDP_SEED=//p' "$work/stored" 2>/dev/null)
  client=$(sed -n 's/^TEST_IDP_CLIENT_SEED=//p' "$work/stored" 2>/dev/null)
  [ "$(wc -l < "$work/stored")" = 2 ] && [ "${#seed}" -ge 32 ] && [ "${#client}" -ge 32 ] && [ "$seed" != "$client" ] &&
    ok "with no seeds, both are generated and stored as one version of test-idp-seeds, two lines NAME=value" ||
    fail "the stored version: $(sed 's/=.*/=.../' "$work/stored" 2>/dev/null)"
  grep -q '^gcloud secrets versions add test-idp-seeds --project=tacplus-dev --data-file=' "$work/log/cmdline" &&
    ok "they are added to test-idp-seeds in tacplus-dev" || fail "versions add: $(grep versions "$work/log/cmdline")"
  [ "$(cat "$work/secrets/keycloak-admin/password")" = "$(derived TEST_IDP_SEED="$seed" admin)" ] &&
    ok "the admin's password is derived from the stored seed" || fail "keycloak-admin is not derived from the stored seed"
  grep -q "$(derived TEST_IDP_CLIENT_SEED="$client" client/google/tacplus-dev)" "$work/secrets/keycloak-realms/google.json" &&
    ok "the realms' client secrets are derived from the stored client seed" || fail "keycloak-realms is not derived from the stored client seed"
  grep -qx 'seeds: generated and stored as the first version of the secret test-idp-seeds' "$work/out" &&
    ok "it says it generated and stored them" || fail "output: $(cat "$work/out")"
  ! grep -qF -e "$seed" -e "$client" "$work/out" "$work/log/cmdline" &&
    ok "no seed is printed or on a command line" || fail "a seed was printed or on a command line"
else
  fail "apply.sh with no seeds: $(cat "$work/out")"
fi

if apply TEST_IDP_SEED=the-user-seed-0123456789abcdefghijklmn TEST_IDP_CLIENT_SEED=the-client-seed-0123456789abcdefghijk; then
  [ ! -e "$work/stored" ] && ! grep -q 'versions add' "$work/log/cmdline" &&
    [ "$(cat "$work/secrets/keycloak-admin/password")" = "$(derived TEST_IDP_SEED=the-user-seed-0123456789abcdefghijklmn admin)" ] &&
    ok "with the seeds the job read, nothing is stored, and the Secrets are derived from them" ||
    fail "apply.sh with seeds: $(cat "$work/out")"
else
  fail "apply.sh with seeds: $(cat "$work/out")"
fi

if apply TEST_IDP_SEED=the-user-seed-0123456789abcdefghijklmn; then
  fail "apply.sh passes with only one seed: $(cat "$work/out")"
else
  grep -q 'one of TEST_IDP_SEED and TEST_IDP_CLIENT_SEED is set, not both' "$work/out" && [ ! -e "$work/secrets" ] &&
    [ ! -e "$work/stored" ] && ok "only one seed is refused, before anything is written" || fail "one seed: $(cat "$work/out")"
fi

if apply SM_REFUSE=1; then
  fail "apply.sh passes when Secret Manager refuses the seeds: $(cat "$work/out")"
else
  grep -q 'storing the seeds in the secret test-idp-seeds: ERROR: .*PERMISSION_DENIED' "$work/out" && [ ! -e "$work/secrets" ] &&
    ok "a refused store fails with Secret Manager's error, before anything is written" || fail "refused: $(cat "$work/out")"
fi

[ "$failed" = 0 ] && echo "apply tests passed" || { echo "apply tests failed"; exit 1; }
