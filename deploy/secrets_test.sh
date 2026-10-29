#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests deploy/secrets.sh against a stub kubectl: it creates the pipeline
# Secrets the charts reference only where they are missing, so a pipeline run
# never empties a key deploy/signin-secrets.sh put in place.
#
#   deploy/secrets_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *"get secret oauth-pipeline-secrets"*) [ "$STUB_EXISTS" = true ] ;;
  *"--dry-run=client"*) echo "kind: rendered" ;;
  *"apply -f -"*) cat > /dev/null; echo "WRITE" >> "$STUB_LOG" ;;
esac
STUB
chmod +x "$work/bin/kubectl"

failures=0
run() { # NAME EXISTS WANT_WRITES
  : > "$work/log"
  PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_EXISTS=$2 "$here/secrets.sh" > /dev/null 2>&1 ||
    { echo "FAIL $1: exit $?"; failures=$((failures + 1)); return; }
  local writes; writes=$(grep -c WRITE "$work/log")
  if [ "$writes" -eq "$3" ]; then echo "ok   $1"; else echo "FAIL $1: $writes writes, want $3"; failures=$((failures + 1)); fi
}
run "a missing Secret is created" false 1
run "an existing Secret is left as it is" true 0

if [ "$failures" -gt 0 ]; then
  echo "$failures failed"; exit 1
fi
echo "all passed"
