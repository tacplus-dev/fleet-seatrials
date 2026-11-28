#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the client (#14): client/tacplus.yaml pins every contract it generates
# from, its depends and theirs, to the line fleet.yaml runs (name@MAJOR.MINOR,
# the line's newest patch tag), so the client follows the fleet's releases and
# never a contract's main, whose tacplus floor may be past the fleet's compiler.
# tacplus resolves a name once, at its first entry's version, so naming the
# whole closure in client/tacplus.yaml pins the transitive contracts too. Then
# the README's client step, on a clean copy of client/ with the compiler
# ci/tools.sh builds: `tacplus build && go build -o seatrials ./cmd/seatrials`,
# its Go tests, and govulncheck over the generated client, with ci/tools.sh's Go
# toolchain.
# Needs bash, git (it reads the contracts from GitHub), yq, go, and tacplus and
# govulncheck (bin/, by ci/tools.sh).
#
#   ci/client_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

manifest="$here/fleet.yaml" lock="$here/fleet.lock" client="$here/client/tacplus.yaml"
# contract_depends NAME: the depends of NAME's contract at its locked commit, each name alone.
contract_depends() {
  local repo commit dir=$tmp/contract-$1
  repo=$(yq ".services[] | select(.name == \"$1\") | .contract" "$lock")
  commit=$(yq ".services[] | select(.name == \"$1\") | .contract_commit" "$lock")
  git init -q "$dir" && git -C "$dir" fetch -q --depth 1 "$repo" "$commit" 2>/dev/null \
    || { echo "cannot fetch $repo at $commit" >&2; return 1; }
  git -C "$dir" show FETCH_HEAD:tacplus.yaml 2>/dev/null | yq '.depends // [] | .[] | sub("@.*$"; "")'
}

floor=$(yq '.tacplus' "$manifest")
[ "$(yq '.tacplus' "$client")" = "$floor" ] && ok "client's tacplus floor is fleet.yaml's, $floor" \
  || fail "client's tacplus floor '$(yq '.tacplus' "$client")' is fleet.yaml's '$floor'"

declare -A listed=()
while read -r entry; do
  [ -n "$entry" ] || continue
  name=${entry%@*} line=${entry#*@}
  listed[$name]=1
  stated=$(yq ".services[] | select(.name == \"$name\") | .version" "$manifest")
  if [ -z "$stated" ]; then
    fail "client depends on $name, which fleet.yaml does not run"
  elif [ "$entry" = "$name" ]; then
    fail "client depends on $name unpinned (its contract's main), not $name@$stated"
  elif [ "$line" != "$stated" ]; then
    fail "client depends on $entry, not fleet.yaml's line $name@$stated"
  else
    ok "client depends on $entry, fleet.yaml's line"
  fi
done < <(yq '.depends[]' "$client")

# The closure: every contract the listed ones depend on, at their locked commits, is listed too.
declare -A seen=()
queue=("${!listed[@]}")
while [ "${#queue[@]}" -gt 0 ]; do
  name=${queue[0]}
  queue=("${queue[@]:1}")
  [ -z "${seen[$name]:-}" ] || continue
  seen[$name]=1
  deps=$(contract_depends "$name") || { fail "$name: its contract's depends cannot be read"; continue; }
  for d in $deps; do
    [ -n "${listed[$d]:-}" ] || fail "$name depends on $d, which client/tacplus.yaml does not pin (it would resolve at $d's main)"
    queue+=("$d")
  done
done
[ "$failed" = 0 ] && ok "client/tacplus.yaml pins its whole closure: ${!seen[*]}"

# The README's client step, on a clean copy of client/ (the tree as committed).
TACPLUS=${TACPLUS:-$(command -v tacplus)}
if [ -z "$TACPLUS" ] || ! command -v govulncheck >/dev/null; then
  fail "tacplus and govulncheck are on PATH (ci/tools.sh builds them into bin/)"
else
  go_toolchain=$(sed -n 's/^go_toolchain=\([^ ]*\).*/\1/p' "$here/ci/tools.sh")
  goroot=$(cd / && GOTOOLCHAIN=$go_toolchain GOMODCACHE=$tmp/toolchain go env GOROOT) \
    || fail "cannot download $go_toolchain"
  export PATH=$goroot/bin:$PATH GOTOOLCHAIN=local GOCACHE=$tmp/go-build GOMODCACHE=$tmp/go-mod
  mkdir -p "$tmp/client"
  git -C "$here" archive HEAD client | tar -x -C "$tmp"
  # No CI job token: tacplus would send it to github.com as a GitLab credential, and the registry clone fails.
  if (cd "$tmp/client" && env -u CI_JOB_TOKEN "$TACPLUS" build > "$tmp/generate.log" 2>&1); then
    ok "the client generates with $("$TACPLUS" version 2>/dev/null | head -1)"
    if (cd "$tmp/client" && go build -o seatrials ./cmd/seatrials > "$tmp/build.log" 2>&1); then
      ok "the client builds with $go_toolchain"
    else
      fail "the client builds with $go_toolchain:"; sed 's/^/  /' "$tmp/build.log" | tail -40
    fi
    if (cd "$tmp/client" && go test ./cmd/seatrials > "$tmp/test.log" 2>&1); then
      ok "the client's tests pass: $(tail -1 "$tmp/test.log")"
    else
      fail "the client's tests (go test ./cmd/seatrials):"; sed 's/^/  /' "$tmp/test.log" | tail -40
    fi
    if (cd "$tmp/client" && govulncheck ./... > "$tmp/vuln.log" 2>&1); then
      ok "govulncheck ./... in client/: $(tail -1 "$tmp/vuln.log")"
    else
      fail "govulncheck ./... in client/:"; sed 's/^/  /' "$tmp/vuln.log" | tail -60
    fi
  else
    fail "the client generates (cd client && tacplus build):"; sed 's/^/  /' "$tmp/generate.log" | tail -40
  fi
fi
[ "$failed" = 0 ] && echo "client: all passed" || { echo "client: failed"; exit 1; }
