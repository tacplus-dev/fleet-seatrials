#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Builds the fleet's images on Cloud Build, one per service in fleet.lock, from
# the exact commits the lock names, against this checkout's build/proto.
#
#   images/build.sh tacplus            # the tacplus image (once per tacplus commit)
#   images/build.sh all                # every service in fleet.lock
#   images/build.sh kernel gateway     # some services
#   images/build.sh changed            # only the services whose fingerprint has no image yet
#   images/build.sh fingerprint        # print each service's fingerprint and whether it is built
#
# A service's image depends on its own repo and on everything it generates
# from: its contract, the contracts of its `depends` closure, and the compiler's
# sys protos. Its FINGERPRINT is the hash of those commits (Jody, 2026-10-25:
# one MAJOR.MINOR across tacplus and types never break within it, so once
# versions exist a dependency's patch bump will drop out of this and only a
# MAJOR.MINOR change will stay). The image carries it as the tag fp-<hash>;
# `changed` builds a service only when the registry has no image with its
# current fingerprint.
#
# Each service's repo is cloned here at the locked commit and submitted as the
# build source, with build/proto copied in at .fleet/proto; Cloud Build clones
# nothing (the repos are private). Images land at
#   <registry>/schematic/<service>:<fleet commit>  and  :local
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
registry=${REGISTRY:-us-central1-docker.pkg.dev/jody1-328023/seabeam}
tacplus_repo=https://github.com/tacplus-dev/tacplus.git
tacplus_commit=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
fleet_commit=$(git -C "$here" rev-parse --short=12 HEAD)
[ -d "$here/build/proto" ] || { echo "build/proto missing: run tacplus fleet build first" >&2; exit 1; }

lock_field() { # service field -> value, from fleet.lock's flat per-service block
  awk -v svc="$1" -v field="$2" '
    /^    - name: / { cur = $3 }
    cur == svc && $1 == field":" { print $2; exit }
  ' "$here/fleet.lock"
}
services() { awk '/^    - name: / { printf "%s ", $3 }' "$here/fleet.lock"; }

# fingerprint SERVICE -> sha256 (12 hex) over: the compiler commit, the service's
# own commit, and the contract commit of every service in its transitive
# `depends` closure, each on its own line, sorted — so the same inputs always
# give the same fingerprint whatever order the lock lists them in.
fingerprint() {
  python3 - "$here/fleet.lock" "$tacplus_commit" "$1" <<'PY'
import sys, hashlib
lock, tacplus, name = sys.argv[1], sys.argv[2], sys.argv[3]
# fleet.lock is regular (tacplus writes it): parse the per-service blocks without
# a yaml library, which this Mac does not have.
svcs, cur, in_dep = {}, None, False
for raw in open(lock):
    line = raw.rstrip("\n")
    if line.startswith("    - name: "):
        cur = line.split(":", 1)[1].strip(); svcs[cur] = {"depends": []}; in_dep = False
    elif cur and line.startswith("      ") and not line.startswith("        "):
        key, _, val = line.strip().partition(":")
        in_dep = key == "depends"
        if val.strip():
            svcs[cur][key] = val.strip()
    elif cur and in_dep and line.startswith("        - "):
        svcs[cur]["depends"].append(line.split("-", 1)[1].strip())
seen, todo = set(), [name]
while todo:
    n = todo.pop()
    if n in seen or n not in svcs:
        continue
    seen.add(n)
    todo.extend(svcs[n]["depends"])
lines = ["tacplus " + tacplus, "self " + svcs[name]["commit"]]
for n in sorted(seen - {name}):
    lines.append(n + " " + svcs[n]["contract_commit"])
print(hashlib.sha256("\n".join(lines).encode()).hexdigest()[:12])
PY
}

# built SERVICE FINGERPRINT -> 0 when the registry already holds an image built
# from exactly these inputs.
built() {
  gcloud artifacts docker tags list "$registry/schematic/$1" --format 'value(tag)' 2>/dev/null | grep -qx "fp-$2"
}

build_tacplus() {
  local src; src=$(mktemp -d)
  git clone -q "$tacplus_repo" "$src" && git -C "$src" checkout -q "$tacplus_commit"
  gcloud builds submit "$src" --config "$here/images/tacplus.cloudbuild.yaml" \
    --substitutions "_REGISTRY=$registry,_TACPLUS_COMMIT=$tacplus_commit" --quiet
  rm -rf "$src"
  # The build image the service steps run in: toolchains + this tacplus + the
  # Java launcher, built from its pinned source placed beside the Dockerfile.
  local launcher_commit; launcher_commit=$(sed -n 's/^launcher_commit: *//p' "$here/images/pins.yaml")
  rm -rf "$here/images/launcher" && git clone -q https://github.com/tacplus-dev/launcher.git "$here/images/launcher" \
    && git -C "$here/images/launcher" checkout -q "$launcher_commit" && rm -rf "$here/images/launcher/.git"
  gcloud builds submit "$here/images" --config "$here/images/tacplus-build.cloudbuild.yaml" \
    --substitutions "_REGISTRY=$registry,_TACPLUS_COMMIT=$tacplus_commit" --quiet
  rm -rf "$here/images/launcher"
}

# language and go main package, read from the service checkout itself.
service_facts() { # dir name -> "lang main"
  local dir=$1 lang main="."
  lang=$(sed -n 's/^language: *//p' "$dir/tacplus.yaml")
  if [ "$lang" = go ] && [ -d "$dir/cmd/$2" ]; then main="./cmd/$2"; fi
  echo "$lang $main"
}

build_service() {
  local name=$1 repo commit src
  repo=$(lock_field "$name" repo); commit=$(lock_field "$name" commit)
  src=$(mktemp -d)
  git clone -q "$repo" "$src" && git -C "$src" checkout -q "$commit"
  mkdir -p "$src/.fleet" && cp -R "$here/build/proto" "$src/.fleet/proto"
  read -r lang main <<<"$(service_facts "$src" "$name")"
  echo "== $name ($lang) @ ${commit:0:12}"
  local fp; fp=$(fingerprint "$name")
  gcloud builds submit "$src" --config "$here/images/service.cloudbuild.yaml" --async --quiet \
    --substitutions "_REGISTRY=$registry,_SERVICE=$name,_LANG=$lang,_MAIN=$main,_COMMIT=$commit,_FLEET_COMMIT=$fleet_commit,_FINGERPRINT=$fp,_TACPLUS_IMAGE=$registry/ci/tacplus-build:$tacplus_commit"
  rm -rf "$src"
}

case "${1:-}" in
  tacplus) build_tacplus ;;
  all) for s in $(services); do build_service "$s"; done ;;
  fingerprint)
    for s in $(services); do
      fp=$(fingerprint "$s")
      if built "$s" "$fp"; then echo "$s $fp built"; else echo "$s $fp NEEDS BUILD"; fi
    done ;;
  changed)
    for s in $(services); do
      fp=$(fingerprint "$s")
      if built "$s" "$fp"; then echo "== $s unchanged ($fp)"; else build_service "$s"; fi
    done ;;
  "") echo "usage: images/build.sh tacplus | all | changed | fingerprint | <service>..." >&2; exit 2 ;;
  *) for s in "$@"; do build_service "$s"; done ;;
esac
