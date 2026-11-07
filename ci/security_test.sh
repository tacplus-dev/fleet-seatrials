#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/security.sh (#36) on throwaway repositories: a planted secret fails
# the job, an expired exception fails it, and a clean tree passes; a HIGH or
# CRITICAL finding with a fix fails unless an unexpired exception accepts it,
# one with no fix does not, in the CI image and in an image this repository
# deploys (#41), scanned for its nodes' platform; a malformed exception and a
# tool that cannot run fail; the JSON report is written either way. gitleaks is the real one, with
# this repository's configuration. OSV-Scanner, govulncheck and Trivy are
# stand-ins on PATH that answer what each case sets in $stub (their real runs
# need the network and change with each day's databases). Needs git, gitleaks,
# jq and yq.
#
#   ci/security_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }

# The stand-ins: each writes $stub/<tool>.json (or nothing found) where the
# real tool writes its JSON report, and exits $stub/<tool>.rc (default 0);
# each call's arguments are a line of $stub/<tool>.args.
stub=$work/stub
mkdir -p "$work/path" "$stub"
for tool in osv-scanner govulncheck trivy; do
  cat > "$work/path/$tool" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$stub/$tool.args"
out=
while [ \$# -gt 0 ]; do case \$1 in --output-file|-o) out=\$2; shift ;; esac; shift; done
rc=\$(cat "$stub/$tool.rc" 2>/dev/null || echo 0)
[ "\$rc" = 0 ] || { echo "$tool: made to fail" >&2; exit "\$rc"; }
report=\$(cat "$stub/$tool.json" 2>/dev/null || echo '$( [ "$tool" = govulncheck ] && echo '{"config": {}}' || echo '{}')')
if [ -n "\$out" ]; then echo "\$report" > "\$out"; else echo "\$report"; fi
EOF
  chmod +x "$work/path/$tool"
done
export PATH=$work/path:$PATH

# A private key made up here, never committed to this repository.
key() {
  echo "-----BEGIN EC PRIVATE KEY-----"
  head -c 120 /dev/urandom | base64 -w 64
  echo "-----END EC PRIVATE KEY-----"
}
# repo NAME: a repository with this one's gitleaks configuration, one pinned
# tool binary in bin/ and a first commit.
repo() {
  local r=$work/$1
  git init -q "$r"
  git -C "$r" config user.email test@example.invalid
  git -C "$r" config user.name test
  cp "$here/.gitleaks.toml" "$r/"
  mkdir -p "$r/ci" "$r/bin"
  printf 'default:\n  image: registry.example.invalid/ci:1\n' > "$r/ci/deploy.gitlab-ci.yml"
  printf '#!/bin/sh\n' > "$r/bin/tool" && chmod +x "$r/bin/tool"
  echo "# seatrials" > "$r/README.md"
  git -C "$r" add -A && git -C "$r" commit -qm init
  echo "$r"
}
# exceptions REPO ID EXPIRES [EXTRA-LINE]: a security-exceptions.yaml accepting ID until EXPIRES, committed.
exceptions() {
  { echo "exceptions:"
    echo "  - id: $2"
    echo "    reason: \"made up for the test\""
    echo "    decided_by: \"test\""
    echo "    expires: $3"
    [ -z "${4:-}" ] || echo "    $4"
  } > "$1/security-exceptions.yaml"
  git -C "$1" add -A && git -C "$1" commit -qm exceptions
}
# stubs: every stand-in answers nothing found again.
stubs() { rm -f "$stub"/*; }
# A HIGH vulnerability with a fixed version, as each tool reports one.
osv_high() { # fixed?
  jq -n --arg fixed "$1" '{results: [{source: {path: "/src/client/go.mod"}, packages: [{
    package: {name: "golang.org/x/net", version: "0.60.0"},
    vulnerabilities: [{id: "GO-2026-0001", summary: "made up", affected: [{ranges: [{events: [{introduced: "0"}, (if $fixed != "" then {fixed: $fixed} else empty end)]}]}]}],
    groups: [{ids: ["GO-2026-0001"], aliases: ["CVE-2026-0001"], max_severity: "7.5"}]}]}]}'
}
trivy_critical() {
  jq -n '{Results: [{Target: "registry.example.invalid/ci:1 (debian 13)", Vulnerabilities: [
    {VulnerabilityID: "CVE-2026-0002", PkgName: "libssl3", InstalledVersion: "3.0.0", FixedVersion: "3.0.1", Severity: "CRITICAL", Title: "made up"}]}]}'
}
govulncheck_found() {
  echo '{"config": {"db": "https://vuln.go.dev"}}'
  echo '{"osv": {"id": "GO-2026-0003", "aliases": ["CVE-2026-0003"], "summary": "made up"}}'
  echo '{"finding": {"osv": "GO-2026-0003", "fixed_version": "v1.2.3", "trace": [{"module": "example.com/m", "version": "v1.2.2", "package": "example.com/m/p", "function": "F"}]}}'
}

# scan NAME WANT REPO [GREP]: ci/security.sh on REPO exits 0 (WANT pass) or
# not (fail), writes its JSON report either way, and says GREP if given.
scan() {
  local out status
  out=$(SECURITY_OUT="$work/out" "$here/ci/security.sh" "$3" 2>&1); status=$?
  case "$2" in
    pass) [ "$status" -eq 0 ] || { fail "$1: status=$status: $out"; return; } ;;
    fail) [ "$status" -ne 0 ] || { fail "$1: status=0: $out"; return; } ;;
  esac
  jq -e --arg want "$2" '.verdict | startswith($want)' "$work/out/report.json" >/dev/null 2>&1 ||
    { fail "$1: no report.json with the verdict $2: $out"; return; }
  [ -z "${4:-}" ] || grep -q -- "$4" <<<"$out" || { fail "$1: does not say \"$4\": $out"; return; }
  echo "ok   $1"
}

stubs
r=$(repo clean)
scan "a clean tree passes" pass "$r" "security verdict: pass"
jq -e '.findings == [] and (.tools | has("osv-scanner") and has("govulncheck") and has("gitleaks") and has("trivy"))
       and .images == ["registry.example.invalid/ci:1"] and .binaries == ["bin/tool"]' "$work/out/report.json" >/dev/null &&
  echo "ok   the report names the tools, the CI image and the binaries scanned" ||
  fail "the report: $(cat "$work/out/report.json")"

r=$(repo secret)
mkdir -p "$r/deploy/bootstrap"
key > "$r/deploy/bootstrap/kernel.yaml"
git -C "$r" add -A && git -C "$r" commit -qm key
scan "a planted secret fails" fail "$r" "private-key"
git -C "$r" rm -q deploy/bootstrap/kernel.yaml && git -C "$r" commit -qm "remove the key"
scan "a secret removed from the tree but in the history still fails" fail "$r" "private-key"

r=$(repo vulnerable)
osv_high 0.62.0 > "$stub/osv-scanner.json"
scan "a HIGH dependency vulnerability with a fix fails" fail "$r" "GO-2026-0001"
exceptions "$r" CVE-2026-0001 2999-01-01
scan "an unexpired exception accepts it, by an alias" pass "$r"
exceptions "$r" GO-2026-0001 2020-01-01
scan "an expired exception fails" fail "$r" "expired on 2020-01-01"
exceptions "$r" GO-2026-0001 2999-01-01 "owner: \"someone\""
scan "an exception with a field beyond id, reason, decided_by and expires fails" fail "$r" "owner"
exceptions "$r" GO-2026-0001 "next month"
scan "an exception whose expiry is not YYYY-MM-DD fails" fail "$r" "not a date"
osv_high "" > "$stub/osv-scanner.json"
exceptions "$r" GO-2026-0009 2999-01-01
scan "a HIGH vulnerability with no fix does not fail" pass "$r"

stubs
r=$(repo image)
trivy_critical > "$stub/trivy.json"
scan "a CRITICAL in the CI image with a fix fails" fail "$r" "CVE-2026-0002"
exceptions "$r" CVE-2026-0002 2999-01-01
scan "an exception accepts it" pass "$r"

stubs
r=$(repo deployed)
mkdir -p "$r/test-idp"
cat > "$r/test-idp/idp.yaml" <<'EOF'
apiVersion: v1
kind: Namespace
metadata: { name: test-idp }
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: idp }
spec:
  template:
    spec:
      nodeSelector: { kubernetes.io/arch: s390x }
      containers:
        - name: idp
          image: registry.example.invalid/idp:1@sha256:0000
EOF
git -C "$r" add -A && git -C "$r" commit -qm idp
trivy_critical > "$stub/trivy.json"
scan "a CRITICAL with a fix in an image this repository deploys fails" fail "$r" "registry.example.invalid/idp:1@sha256:0000"
jq -e '.images == ["registry.example.invalid/ci:1", "registry.example.invalid/idp:1@sha256:0000"]' "$work/out/report.json" >/dev/null &&
  echo "ok   the report names the deployed image beside the CI image" ||
  fail "the deployed image's report: $(jq -c .images "$work/out/report.json")"
grep -q -- "--platform linux/s390x .*registry.example.invalid/idp:1@sha256:0000" "$stub/trivy.args" &&
  echo "ok   the deployed image is scanned for its nodes' platform, not the runner's" ||
  fail "the deployed image's platform: $(cat "$stub/trivy.args")"
exceptions "$r" CVE-2026-0002 2999-01-01
scan "an exception accepts it in the deployed image too" pass "$r"

stubs
r=$(repo binary)
govulncheck_found > "$stub/govulncheck.json"
scan "a vulnerability govulncheck finds in a pinned binary, with a fix, fails" fail "$r" "GO-2026-0003"

stubs
r=$(repo broken)
echo 2 > "$stub/trivy.rc"
scan "a tool that cannot run fails" fail "$r" "trivy"

stubs
[ "$failed" = 0 ] && echo "security tests passed" || { echo "security tests failed"; exit 1; }
