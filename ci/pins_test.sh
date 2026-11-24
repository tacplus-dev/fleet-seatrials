#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the fleet's language pins (#13): every `lang:` pin in dependencies.yaml
# is a YAML string (an unquoted 1.80 is the float 1.8, which `tacplus fleet
# build` writes into build/proto as a version Maven Central does not have), and
# the copies generated from it, build/proto/dependencies.yaml (`tacplus fleet
# build`) and the client's client/proto/dependencies.yaml, carry the same pins;
# and all three import Java from kernel's package (#70). Needs bash and yq.
#
#   ci/pins_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

pins="$here/dependencies.yaml"
# lang FILE: its lang pins, one `<lang> <name> <version>` a line, sorted.
lang() { yq '.lang | to_entries[] | .key as $l | .value.dependencies | to_entries[] | $l + " " + .key + " " + .value' "$1" | sort; }

nonstr=$(yq '.lang[].dependencies | to_entries[] | select(.value | tag != "!!str") | .key + " " + (.value | tag)' "$pins")
[ -z "$nonstr" ] && ok "every lang pin in dependencies.yaml is a string" \
  || fail "dependencies.yaml pins that are not strings (quote them): $(echo $nonstr)"

[ -n "$(lang "$pins")" ] || fail "dependencies.yaml has no lang pins"
for copy in build/proto/dependencies.yaml client/proto/dependencies.yaml; do
  if d=$(diff <(lang "$pins") <(lang "$here/$copy")); then
    ok "$copy carries dependencies.yaml's lang pins"
  else
    fail "$copy differs from dependencies.yaml's lang pins (rerun tacplus fleet build; the client's is build/proto's):"; echo "$d"
  fi
done

# registry.imports.java is the Java package every Java service's generated backend
# imports kernel's runtime from (`<it>.graphs.Manager`, ...): kernel's own, as kernel,
# eventbus and stratum declare it. The fleet's build/proto overrides theirs, and the
# SeaBeam one it held broke kernel's compile (#70).
java_import=com.github.tacplusdev.kernel
for f in dependencies.yaml build/proto/dependencies.yaml client/proto/dependencies.yaml; do
  got=$(yq '.registry.imports.java' "$here/$f")
  [ "$got" = "$java_import" ] && ok "$f imports Java from $java_import" \
    || fail "$f registry.imports.java is $got, not kernel's $java_import"
done

[ "$failed" = 0 ] && echo "pins: all passed" || { echo "pins: failed"; exit 1; }
