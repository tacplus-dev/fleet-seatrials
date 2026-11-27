#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Dev rolls to each green main release, never back (#82; tacplus-dev/roadmap
# decisions/agentic-dev-flow-2026-11-25.md, step 8, item 12, D4). The release
# build publishes each repository's main release by digest and records it in
# tacplus-dev/build's generic package release-<repo>, version main, file
# record (tacplus-dev/looper#252; its README, Release builds by branch):
#
#   repo <repo>
#   branch main
#   commit <40 hex>
#   image <registry>/<repo>:main-<commit, 12 hex>@sha256:<64 hex>
#   tacplus <40 hex> <image by digest>    the tacplus it was built with (tacplus-dev/looper#262)
#   run <the pipeline>
#   at <UTC time>
#
# A set is one line a service: `<service> <commit> <version>`, the version a
# tag's (0.1.7) or a main release's (main-<12 hex>). The deployed set is the
# one the last apply recorded, in the ConfigMap seatrials-releases of the
# platform namespace (data key `set`).
#
#   ci/releases.sh set        # the set this checkout applies: fleet.lock's services
#   ci/releases.sh deployed   # the deployed set; nothing before the first apply
#   ci/releases.sh plan       # every service's main release record read and checked (the releases job)
#   ci/releases.sh guard      # refuses unless `set` is no older than `deployed`, every service (apply)
#   ci/releases.sh record     # `set` as the deployed set (apply, once applied)
#
# Forward only, by ancestry, never by time: a main release rolls when the
# deployed one is it or its ancestor, never when it is behind or diverged; a
# tag never after a lower tag nor after a main release; leaving a tag for a
# main release is the move #82 makes. `plan` fails, and so holds the whole
# fleet where it is, on any record it cannot read, that is malformed, names
# an image other than its commit's by digest, or is behind the deployed
# release; and (D4, consumers checked against tacplus's release before deploy,
# not in tacplus's merge path) on a record built with another tacplus than
# tacplus's own main release. A service with no main release yet stays on its
# tag. Until `tacplus fleet build` can lock a service at a release's commit
# and image (tacplus-dev/tacplus#981), the plan rolls nothing: the lock's
# contracts are its tags', and a main image beside them would run main's code
# against them.
#
# The records are read with the job's own token (CI_JOB_TOKEN; tacplus-dev/build
# admits this project, tacplus-dev/looper#262), in a header file, never on a
# command line. Ancestry is read from the services' public repositories.
#
#   RELEASE_RECORDS   the generic packages of tacplus-dev/build (default: tacplus-dev/build, by its path)
#   RELEASE_REGISTRY  where the release images are (default us-docker.pkg.dev/jody1-328023/tacplus)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
records=${RELEASE_RECORDS:-${CI_API_V4_URL:-https://gitlab.com/api/v4}/projects/tacplus-dev%2Fbuild/packages/generic}
registry=${RELEASE_REGISTRY:-us-docker.pkg.dev/jody1-328023/tacplus}
configmap=seatrials-releases
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

usage() { echo "usage: ci/releases.sh set | deployed | plan | guard | record" >&2; exit 2; }

# lock_services: "<service> <repo> <commit> <version>" a line, fleet.lock's services in order.
lock_services() {
  yq -r '.services[] | [.name, .repo, .commit, .version] | join(" ")' "$here/fleet.lock"
}
set_of_lock() { lock_services | awk '{ print $1, $3, $4 }'; }
namespace() { "$here/deploy/namespaces.sh" platform; }

deployed() {
  local ns
  ns=$(namespace)
  kubectl get configmap "$configmap" -n "$ns" --ignore-not-found -o jsonpath='{.data.set}' ||
    { echo "cannot read the deployed set (the ConfigMap $configmap in $ns)" >&2; return 1; }
}

# repo_name URL: the repository's name, the record's: pigeon for .../pigeon.git.
repo_name() { local r=${1%/}; r=${r##*/}; echo "${r%.git}"; }

# ancestor REPO OLD NEW: 0 when OLD is NEW or an ancestor of it; 1 when not;
# 2 when it cannot read their histories (a commit it cannot fetch).
ancestor() {
  local g
  [ "$2" != "$3" ] || return 0
  g=$(mktemp -d "$tmp/git.XXXXXX")
  git init -q "$g" &&
    git -C "$g" -c credential.helper= fetch -q --filter=tree:0 "$1" "$2" "$3" 2>/dev/null || return 2
  git -C "$g" merge-base --is-ancestor "$2" "$3" && return 0
  return 1
}

# forward SERVICE REPO OLD-COMMIT OLD-VERSION NEW-COMMIT NEW-VERSION: 0 when
# the new may follow the old (none deployed, the same, or newer); otherwise
# says why on stderr and returns 1.
forward() {
  local s=$1 repo=$2 oc=$3 ov=$4 nc=$5 nv=$6 rc
  [ -n "$oc" ] && [ "$oc" != "$nc" ] || return 0
  case "$ov:$nv" in
    main-*:main-*)
      rc=0; ancestor "$repo" "$oc" "$nc" || rc=$?
      case $rc in
        0) return 0 ;;
        1) echo "$s: refused: $nv is behind or diverged from $ov, deployed: never back to an older release" >&2 ;;
        *) echo "$s: refused: cannot read whether $ov, deployed, is an ancestor of $nv ($repo)" >&2 ;;
      esac
      return 1 ;;
    main-*:*) echo "$s: refused: v$nv after $ov, deployed: never back from a main release to a tag" >&2; return 1 ;;
    *:main-*) return 0 ;;
    *)
      if [ "$ov" != "$nv" ] && [ "$(printf '%s\n%s\n' "$ov" "$nv" | sort -V | tail -n1)" = "$nv" ]; then return 0; fi
      echo "$s: refused: v$nv is older than v$ov, deployed (or the same version at another commit)" >&2
      return 1 ;;
  esac
}

# fetch REPO OUT: the record of REPO's main release into OUT. 0 when read; 1
# when there is none (404); 2 when it cannot be read, saying why.
fetch() {
  local url=$records/release-$1/main/record code
  if [ -n "${CI_JOB_TOKEN:-}" ]; then
    ( umask 077; printf 'JOB-TOKEN: %s\n' "$CI_JOB_TOKEN" > "$tmp/auth" )
  else
    : > "$tmp/auth"
  fi
  code=$(curl -sS -o "$2" -w '%{http_code}' -H @"$tmp/auth" "$url" 2>"$tmp/curl-err") || code=${code:-none}
  rm -f "$tmp/auth"
  case "$code" in
    200) return 0 ;;
    404) return 1 ;;
    *) echo "release-$1/main/record: HTTP $code $(head -c 300 "$2" "$tmp/curl-err" 2>/dev/null | tr '\n' ' ')" >&2; return 2 ;;
  esac
}

# field FILE KEY: the value of a record's line KEY; fails, saying why, when it
# has none or more than one.
field() {
  local n
  n=$(grep -c "^$2 " "$1" || true)
  [ "$n" = 1 ] || { if [ "$n" = 0 ]; then echo "no $2 line" >&2; else echo "two $2 lines" >&2; fi; return 1; }
  sed -n "s/^$2 //p" "$1"
}

# check_record REPO FILE: the record's commit, when it is REPO's main release
# by digest; fails, saying why.
check_record() {
  local r=$1 f=$2 v commit image
  v=$(field "$f" repo) || return 1
  [ "$v" = "$r" ] || { echo "repo is $v, not $r" >&2; return 1; }
  v=$(field "$f" branch) || return 1
  [ "$v" = main ] || { echo "branch is $v, not main" >&2; return 1; }
  commit=$(field "$f" commit) || return 1
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "commit is $commit, not 40 hex" >&2; return 1; }
  image=$(field "$f" image) || return 1
  [[ "$image" =~ ^"$registry/$r:main-${commit:0:12}"@sha256:[0-9a-f]{64}$ ]] ||
    { echo "image $image is not $registry/$r:main-${commit:0:12}@sha256:<64 hex>" >&2; return 1; }
  echo "$commit"
}

plan() {
  local dep s repo commit version oc ov r rc commit_new held=0 candidates=() tacplus="" built why
  dep=$(deployed) || { echo "dev stays where it is: nothing new deploys" >&2; return 1; }
  while read -r s repo commit version; do
    r=$(repo_name "$repo")
    rc=0; fetch "$r" "$tmp/record-$s" || rc=$?
    case $rc in
      1) echo "$s: no main release (release-$r/main/record): stays on v$version"; continue ;;
      2) echo "$s: refused: the record cannot be read" >&2; held=1; continue ;;
    esac
    commit_new=$(check_record "$r" "$tmp/record-$s" 2>"$tmp/why") ||
      { echo "$s: refused: release-$r/main/record: $(cat "$tmp/why")" >&2; held=1; continue; }
    oc="" ov=""
    read -r _ oc ov < <(awk -v s="$s" '$1 == s' <<<"$dep") || true
    forward "$s" "$repo" "$oc" "$ov" "$commit_new" "main-${commit_new:0:12}" || { held=1; continue; }
    candidates+=("$s")
  done < <(lock_services)

  # D4: each release about to roll was built with tacplus's own main release.
  if [ ${#candidates[@]} -gt 0 ]; then
    rc=0; fetch tacplus "$tmp/record-tacplus" || rc=$?
    case $rc in
      0) tacplus=$(check_record tacplus "$tmp/record-tacplus" 2>"$tmp/why") ||
           { echo "refused: release-tacplus/main/record: $(cat "$tmp/why")" >&2; held=1; } ;;
      1) echo "refused: release-tacplus/main/record: no main release of tacplus to check the releases against (D4)" >&2; held=1 ;;
      *) echo "refused: release-tacplus/main/record cannot be read (D4)" >&2; held=1 ;;
    esac
    for s in "${candidates[@]}"; do
      r=$(repo_name "$(lock_services | awk -v s="$s" '$1 == s { print $2 }')")
      commit_new=$(field "$tmp/record-$s" commit)
      if ! built=$(field "$tmp/record-$s" tacplus 2>"$tmp/why"); then
        why=$(cat "$tmp/why")
        if [ "$why" = "no tacplus line" ]; then
          echo "$s: main-${commit_new:0:12}: its record names no tacplus, so it is not checked against tacplus's release (tacplus-dev/looper#262)"
        else
          echo "$s: refused: release-$r/main/record: $why" >&2; held=1
        fi
      elif [ -n "$tacplus" ] && [ "${built%% *}" != "$tacplus" ]; then
        echo "$s: refused: main-${commit_new:0:12} was built with tacplus ${built:0:12}, not tacplus's main release ${tacplus:0:12} (D4)" >&2; held=1
      elif [ -n "$tacplus" ]; then
        echo "$s: main-${commit_new:0:12} built with tacplus ${tacplus:0:12}, tacplus's main release"
      fi
    done
  fi

  if [ "$held" = 1 ]; then
    echo "dev stays where it is: nothing new deploys until every record above is read, well formed and no older than what is deployed" >&2
    return 1
  fi
  for s in ${candidates[@]+"${candidates[@]}"}; do
    echo "$s: main-$(field "$tmp/record-$s" commit | cut -c1-12), $(field "$tmp/record-$s" image): rolls once the lock can follow it (tacplus-dev/tacplus#981); until then dev stays on its tag"
  done
  echo "the main releases are checked"
}

guard() {
  local dep s repo commit version oc ov refused=0
  dep=$(deployed) || { echo "refused: the deployed set cannot be read, so nothing is applied" >&2; return 1; }
  while read -r s repo commit version; do
    oc="" ov=""
    read -r _ oc ov < <(awk -v s="$s" '$1 == s' <<<"$dep") || true
    forward "$s" "$repo" "$oc" "$ov" "$commit" "$version" || refused=1
  done < <(lock_services)
  [ "$refused" = 0 ] || { echo "refused: this set is older than the one deployed; nothing is applied" >&2; return 1; }
  echo "the set is no older than the one deployed"
}

record() {
  local ns
  ns=$(namespace)
  set_of_lock > "$tmp/set"
  kubectl create configmap "$configmap" -n "$ns" --from-file=set="$tmp/set" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "the deployed set is recorded in the ConfigMap $configmap ($ns)"
}

case "${1:-}" in
  set) set_of_lock ;;
  deployed) deployed ;;
  plan) plan ;;
  guard) guard ;;
  record) record ;;
  *) usage ;;
esac
