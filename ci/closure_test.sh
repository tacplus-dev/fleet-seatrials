#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the fleet's closure is consistent (#68): every Go service at the commit
# fleet.lock names generates against this checkout's build/proto and compiles,
# as the images job builds it (images/build.sh, images/service.cloudbuild.yaml:
# `tacplus build --src .fleet/proto`, then `go build` of its main package). The
# lock's own checks (the versions, the depends' floors) pass a doppelganger
# release that calls a field its locked llmproxy does not have: the first
# deploy's images job found it (`resp.GetProviderModel undefined`). The Rust and
# Java services are left to the images job: gateway's generated crate alone
# needs more than the gate's memory (STATE.md). Needs bash, git (it fetches the
# services from GitHub), yq, go, and tacplus (bin/, by ci/tools.sh).
#
#   ci/closure_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT

lock="$here/fleet.lock"
TACPLUS=${TACPLUS:-$(command -v tacplus)}
[ -n "$TACPLUS" ] || { fail "tacplus is on PATH (ci/tools.sh builds it into bin/)"; echo "closure: failed"; exit 1; }
go_toolchain=$(sed -n 's/^go_toolchain=\([^ ]*\).*/\1/p' "$here/ci/tools.sh")
goroot=$(cd / && GOTOOLCHAIN=$go_toolchain GOMODCACHE=$tmp/toolchain go env GOROOT) \
  || { fail "cannot download $go_toolchain"; echo "closure: failed"; exit 1; }
export PATH=$goroot/bin:$PATH GOTOOLCHAIN=local GOCACHE=$tmp/go-build GOMODCACHE=$tmp/go-mod GOFLAGS=-mod=mod

services=$(yq '.services[] | .name + " " + .version + " " + .repo + " " + .commit' "$lock") && [ -n "$services" ] \
  || { fail "fleet.lock lists its services (yq reads them)"; echo "closure: failed"; exit 1; }
while read -r name version repo commit; do
  dir=$tmp/$name
  if ! { git init -q "$dir" && git -C "$dir" fetch -q --depth 1 "$repo" "$commit" 2>/dev/null \
         && git -C "$dir" checkout -q FETCH_HEAD; }; then
    fail "$name: cannot fetch $repo at $commit"; continue
  fi
  # The language and main package as images/build.sh's service_facts reads them.
  lang=$(sed -n 's/^language: *//p' "$dir/tacplus.yaml") main=.
  [ -d "$dir/cmd/$name" ] && main=./cmd/$name
  if [ "$lang" != go ]; then
    ok "$name v$version: $lang, built by the images job only"; continue
  fi
  mkdir -p "$dir/.fleet" && cp -R "$here/build/proto" "$dir/.fleet/proto"
  # No CI job token: tacplus would send it to github.com as a GitLab credential, and the registry clone fails.
  if ! (cd "$dir" && env -u CI_JOB_TOKEN "$TACPLUS" build --src .fleet/proto > "$tmp/$name-generate.log" 2>&1); then
    fail "$name v$version (${commit:0:12}) generates against build/proto:"; sed 's/^/  /' "$tmp/$name-generate.log" | tail -40
  elif ! (cd "$dir" && CGO_ENABLED=0 go build -o /dev/null "$main" > "$tmp/$name-build.log" 2>&1); then
    fail "$name v$version (${commit:0:12}) builds against build/proto, with $go_toolchain:"; sed 's/^/  /' "$tmp/$name-build.log" | tail -40
  else
    ok "$name v$version generates against build/proto and builds"
  fi
  chmod -R u+w "$dir" 2>/dev/null; rm -rf "$dir"
done <<<"$services"
[ "$failed" = 0 ] && echo "closure: all passed" || { echo "closure: failed"; exit 1; }
