#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests the fleet's lock against its manifest (#1): the fleet builds its own
# images from source (`images: source`, tacplus#950), so fleet.lock records
# every fleet.yaml service in its stated line, at its release tag's commit
# (what images/build.sh builds), with no image; and the compiler pinned in
# images/pins.yaml is the stamp ci/tools.sh and images/tacplus-build.cloudbuild.yaml
# give it, a release of fleet.yaml's line. Needs bash, git (it reads the tags
# from GitHub) and yq.
#
#   ci/fleet_lock_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }

manifest="$here/fleet.yaml" lock="$here/fleet.lock"
# tag_commit REPO TAG: the commit TAG names (an annotated tag peeled).
tag_commit() {
  git ls-remote "$1" "refs/tags/$2" "refs/tags/$2^{}" 2>/dev/null \
    | awk '{ c[$2] = $1 } END { print (c[t "^{}"] != "" ? c[t "^{}"] : c[t]) }' t="refs/tags/$2"
}

line=$(yq '.tacplus' "$manifest")
[ "$(yq '.tacplus' "$lock")" = "$line" ] && ok "fleet.lock is of fleet.yaml's line, tacplus $line" \
  || fail "fleet.lock's tacplus '$(yq '.tacplus' "$lock")' is fleet.yaml's '$line'"
[ "$(yq '.images' "$manifest")" = source ] && ok "fleet.yaml builds its images from source" \
  || fail "fleet.yaml says images: source, not '$(yq '.images' "$manifest")'"
[ "$(yq '.images' "$lock")" = source ] && ok "fleet.lock was written for images from source" \
  || fail "fleet.lock says images: source, not '$(yq '.images' "$lock")'"

want=$(yq '.services[].name' "$manifest") got=$(yq '.services[].name' "$lock")
[ "$want" = "$got" ] && ok "fleet.lock holds fleet.yaml's services, in order" \
  || fail "fleet.lock's services [$(echo $got)] are fleet.yaml's [$(echo $want)]"

while read -r name stated; do
  version=$(yq ".services[] | select(.name == \"$name\") | .version" "$lock")
  repo=$(yq ".services[] | select(.name == \"$name\") | .repo" "$lock")
  commit=$(yq ".services[] | select(.name == \"$name\") | .commit" "$lock")
  image=$(yq ".services[] | select(.name == \"$name\") | .image // \"\"" "$lock")
  [[ "$version" == "$stated".* ]] || { fail "$name: locked $version, not in its line $stated"; continue; }
  [ -z "$image" ] || fail "$name: locked with the image $image, under images: source"
  tagged=$(tag_commit "$repo" "v$version")
  [ -n "$tagged" ] && [ "$tagged" = "$commit" ] && ok "$name: v$version at its tag's commit ${commit:0:12}" \
    || fail "$name: locked at '$commit', v$version of $repo is '$tagged'"
done < <(yq '.services[] | .name + " " + .version' "$manifest")

pinned=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
stamps=$(grep -ho 'v[0-9][0-9.]*-seatrials' "$here/ci/tools.sh" "$here/images/tacplus-build.cloudbuild.yaml" | sort -u)
if [ "$(wc -l <<<"$stamps")" = 1 ] && [[ "$stamps" == "v$line".* ]]; then
  release=${stamps%-seatrials}
  tagged=$(tag_commit https://github.com/tacplus-dev/tacplus.git "$release")
  [ "$tagged" = "$pinned" ] && ok "the compiler is tacplus $release, stamped $stamps" \
    || fail "images/pins.yaml's tacplus_commit '$pinned' is tacplus $release ('$tagged'), the stamp $stamps"
else
  fail "ci/tools.sh and images/tacplus-build.cloudbuild.yaml stamp one release of tacplus $line, not [$(echo $stamps)]"
fi

[ "$failed" = 0 ] && echo "fleet lock tests passed" || { echo "fleet lock tests failed"; exit 1; }
