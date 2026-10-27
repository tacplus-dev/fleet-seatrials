#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/signin-secrets.sh --microsoft-secret-from-clipboard against stub
# kubectl, pbpaste and yq: a clipboard value that is not an Entra secret value
# is refused (non-zero, saying why, never echoing it) and nothing is written to
# the cluster; a well-formed one is written. Needs bash and jq.
#
#   deploy/signin-secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  "config current-context") echo gke_seatrials ;;
  *"get configmap kernel-config-override"*) echo '{"configs":{"oauth_config":{"providers":[]}}}' ;;
  *"get secret"*) ;;
  *"--dry-run=client"*) echo "kind: rendered" ;;
  *"apply -f -"*) cat > /dev/null; echo "WRITE" >> "$STUB_LOG" ;;
esac
EOF
cat > "$work/bin/pbpaste" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$STUB_CLIPBOARD"
EOF
cat > "$work/bin/yq" <<'EOF'
#!/usr/bin/env bash
echo '[{"name":"Microsoft","client_id":"x","enable":true}]'
EOF
chmod +x "$work/bin/"*

failures=0
# run NAME CLIPBOARD WANT [ARGS...]: WANT is "refuse" or "write".
run() {
  local name=$1 clip=$2 want=$3 out status
  shift 3
  : > "$work/log"
  out=$(PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_CLIPBOARD="$clip" \
    "$here/signin-secrets.sh" --microsoft-secret-from-clipboard "$@" 2>&1)
  status=$?
  local wrote=false
  grep -q WRITE "$work/log" && wrote=true
  case "$want" in
    refuse)
      if [ "$status" -eq 0 ] || $wrote || { [ -n "$clip" ] && [[ "$out" == *"$clip"* ]]; } || [ -z "$out" ]; then
        echo "FAIL $name: status=$status wrote=$wrote out=[$out]"; failures=$((failures + 1)); return
      fi ;;
    write)
      if [ "$status" -ne 0 ] || ! $wrote; then
        echo "FAIL $name: status=$status wrote=$wrote out=[$out]"; failures=$((failures + 1)); return
      fi ;;
  esac
  echo "ok   $name"
}

value=abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ0123456   # 40 characters, the shape Entra issues today
run "well-formed value is written" "$value" write
run "a GUID (the Secret ID) is refused" "3f2b8c1e-9a4d-4e7b-8c2f-1a2b3c4d5e6f" refuse
run "an upper-case GUID is refused" "3F2B8C1E-9A4D-4E7B-8C2F-1A2B3C4D5E6F" refuse
run "a value with a space is refused" "abc8Q~Zx0_yv.Tq-1rLmN PqRsTuVwXyZ0123456" refuse
run "a value with a tab is refused" "abc8Q~Zx0_yv.Tq-1rLmN	PqRsTuVwXyZ0123456" refuse
run "a value with a newline is refused" "$value"$'\n' refuse
run "the script's own command line is refused" \
  "deploy/signin-secrets.sh --microsoft-secret-from-clipboard" refuse
run "a value starting with ~ is refused" "~/Downloads/abcdefghijklmnopqrstuvwxyz0123" refuse
run "a value starting with / is refused" "/abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ012345" refuse
run "a value starting with . is refused" ".abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ012345" refuse
run "29 characters is refused" "abcdefghijABCDEFGHIJ012345678" refuse
run "61 characters is refused" "abcdefghijABCDEFGHIJ0123456789abcdefghijABCDEFGHIJ0123456789x" refuse
run "a character outside [A-Za-z0-9_.~-] is refused" "abc8Q~Zx0_yv.Tq-1rLmNoPqRsTuVwXyZ01234+6" refuse
run "an empty clipboard is refused" "" refuse
printf -- '-----BEGIN PRIVATE KEY-----\nx\n-----END PRIVATE KEY-----\n' > "$work/AuthKey.p8"
run "a refusal writes no Apple key either" "3f2b8c1e-9a4d-4e7b-8c2f-1a2b3c4d5e6f" refuse \
  --apple-key "$work/AuthKey.p8"

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
