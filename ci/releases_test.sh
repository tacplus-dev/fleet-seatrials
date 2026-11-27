#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests ci/releases.sh (#82) against local service repositories, a stub package
# registry (curl) and a stub cluster (kubectl):
#   set       fleet.lock's services, their commits and versions
#   deployed  the set the last apply recorded, nothing before the first
#   plan      every record read and checked: a service with no main release
#             stays on its tag; a record that cannot be read, is malformed,
#             names another image than its commit's, or is older than or
#             diverged from the deployed release holds the whole fleet (it
#             fails); D4, a record naming another tacplus than tacplus's
#             release holds it too; the job token is sent, in a header file
#   guard     the set about to be applied is never behind the deployed one:
#             a lower tag, a tag after a main release, an older or diverged
#             main release refused; a newer or the same one passes
#   record    the set applied, as the deployed set
# Needs bash, git and yq.
#
#   ci/releases_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL $1"; failures=$((failures + 1)); }
ok() { echo "ok   $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got [$2], want [$3]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else fail "$1: [$3] not in: $2"; fi; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# Two services' repositories: kernel and pigeonhost (repository pigeon), each
# with a tag v0.1.0 then main moving on: c1 (the tag), c2, c3; and a side
# branch from c1, diverged from main.
declare -A c1 c2 c3 side
for r in kernel pigeon; do
  g=$work/repos/$r.git
  git init -q -b main "$g"
  git -C "$g" config uploadpack.allowFilter true
  git -C "$g" config uploadpack.allowAnySHA1InWant true
  for n in 1 2 3; do git -C "$g" commit -q --allow-empty -m "$r $n"; eval "c$n[$r]=\$(git -C \"\$g\" rev-parse HEAD)"; done
  git -C "$g" tag v0.1.0 "${c1[$r]}"
  git -C "$g" checkout -q -b side "${c1[$r]}"
  git -C "$g" commit -q --allow-empty -m "$r side"
  side[$r]=$(git -C "$g" rev-parse HEAD)
  git -C "$g" checkout -q main
done

# The tree releases.sh runs in: a lock of the two services at their tags.
tree=$work/tree
mkdir -p "$tree/ci" "$tree/deploy/bootstrap" "$tree/images" "$work/bin"
cp "$here/ci/releases.sh" "$tree/ci/"
cp "$here/deploy/namespaces.sh" "$tree/deploy/"
cp "$here/images/pins.yaml" "$tree/images/"
printf 'deployment: seatrials\n' > "$tree/deploy/bootstrap/operator.yaml"
lock() { # KERNEL_COMMIT KERNEL_VERSION PIGEON_COMMIT PIGEON_VERSION
  cat > "$tree/fleet.lock" <<EOF
# Written by tacplus fleet build.
tacplus: "2.6"
images: source
registries:
    - repo: https://github.com/tacplus-dev/registry.git
      commit: 0000000000000000000000000000000000000000
services:
    - name: kernel
      id: 8
      version: $2
      repo: file://$work/repos/kernel.git
      commit: $1
      depends:
        - pigeonhost
    - name: pigeonhost
      id: 107
      version: $4
      repo: file://$work/repos/pigeon.git
      commit: $3
libraries:
    - name: notaservice
      id: 9
      contract: https://github.com/tacplus-dev/registry.git
EOF
}
lock "${c1[kernel]}" 0.1.0 "${c1[pigeon]}" 0.1.0

# curl: the package registry. A URL under $RELEASE_RECORDS is the file of the
# same path under $STUB_RECORDS, 200; a <path>.code beside it, that status
# (and no file); none, 404. It logs the URL and the headers it was handed.
cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
out= url= hdr=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -H) hdr=$2; shift ;;
    -w) shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
echo "curl $url" >> "$STUB_LOG"
case "$hdr" in @*) echo "header $(cat "${hdr#@}")" >> "$STUB_LOG" ;; ?*) echo "header-inline $hdr" >> "$STUB_LOG" ;; esac
path=${url#"$RELEASE_RECORDS"/}
if [ -f "$STUB_RECORDS/$path.code" ]; then : > "$out"; printf '%s' "$(cat "$STUB_RECORDS/$path.code")"
elif [ -f "$STUB_RECORDS/$path" ]; then cp "$STUB_RECORDS/$path" "$out"; printf 200
else echo '{"message":"404 Package Not Found"}' > "$out"; printf 404; fi
EOF
# kubectl: the ConfigMap seatrials-releases, its set kept in $STUB_STATE/set.
cat > "$work/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "kubectl $*" >> "$STUB_LOG"
case "$*" in
  "get configmap seatrials-releases -n tac-seatrials --ignore-not-found -o jsonpath={.data.set}")
    [ -z "${STUB_KUBE_FAILS:-}" ] || { echo "error: the server is unreachable" >&2; exit 1; }
    [ ! -f "$STUB_STATE/set" ] || cat "$STUB_STATE/set" ;;
  "create configmap seatrials-releases -n tac-seatrials --from-file=set="*" --dry-run=client -o yaml")
    a="$*"; f=${a#*--from-file=set=}; f=${f%% *}
    printf 'kind: ConfigMap\nfrom: %s\n' "$f" ;;
  "apply -f -")
    f=$(sed -n 's/^from: //p'); cp "$f" "$STUB_STATE/set" ;;
  *) echo "unexpected kubectl $*" >&2; exit 3 ;;
esac
EOF
chmod +x "$work/bin/curl" "$work/bin/kubectl"
export PATH=$work/bin:$PATH STUB_LOG=$work/log STUB_RECORDS=$work/records STUB_STATE=$work/state
export RELEASE_RECORDS=https://gitlab.example/api/v4/projects/1/packages/generic
export RELEASE_REGISTRY=us-docker.pkg.dev/jody1-328023/tacplus
export CI_JOB_TOKEN=job-token-value
mkdir -p "$STUB_STATE"

digest() { printf 'sha256:%064d' "$1"; }
# record REPO COMMIT [LINE...]: a green main record of REPO at COMMIT.
record() {
  local r=$1 c=$2; shift 2
  mkdir -p "$STUB_RECORDS/release-$r/main"
  { printf 'repo %s\nbranch main\ncommit %s\nimage %s/%s:main-%s@%s\n' "$r" "$c" "$RELEASE_REGISTRY" "$r" "${c:0:12}" "$(digest 7)"
    for l in "$@"; do echo "$l"; done
    printf 'run https://gitlab.example/p/1\nat 2026-11-26T00:00:00Z\n'; } > "$STUB_RECORDS/release-$r/main/record"
}
reset() { rm -rf "$STUB_RECORDS" "$STUB_STATE"/* "$STUB_LOG"; mkdir -p "$STUB_RECORDS"; }
run() { (cd "$tree" && ci/releases.sh "$@" 2>&1); }
tacplus_commit=$(printf 'a%.0s' {1..40})

# set: fleet.lock's services, in order.
check "set: fleet.lock's services, commit and version" "$(run set)" \
  "$(printf 'kernel %s 0.1.0\npigeonhost %s 0.1.0' "${c1[kernel]}" "${c1[pigeon]}")"

# deployed: nothing before the first apply; a cluster it cannot read fails.
reset
out=$(run deployed); rc=$?
check "deployed: nothing before the first apply" "$rc:$out" "0:"
out=$(STUB_KUBE_FAILS=1 run deployed); rc=$?
check "deployed: a cluster it cannot read fails" "$rc" 1

# record, then deployed: the set applied.
reset
run record >/dev/null; rc=$?
check "record: passes" "$rc" 0
check "record: the set applied is the deployed set" "$(run deployed)" "$(run set)"

# plan: no service has a main release yet: each stays on its tag, it passes.
reset
out=$(run plan); rc=$?
check "plan: no main release yet passes" "$rc" 0
has "plan: a service with no main release stays on its tag" "$out" "kernel: no main release (release-kernel/main/record): stays on v0.1.0"
has "plan: the repository names the record (pigeonhost's is pigeon)" "$out" "release-pigeon/main/record"
has "plan: the job token is sent from a header file" "$(cat "$STUB_LOG")" "header JOB-TOKEN: job-token-value"
if grep -q "header-inline" "$STUB_LOG"; then fail "plan: the job token is on curl's command line"; else ok "plan: no token on curl's command line"; fi

# plan: a record ahead of the deployed tag is a release to roll to; the
# tacplus release is read and the record's tacplus checked against it.
reset
run record >/dev/null
record kernel "${c3[kernel]}" "tacplus $tacplus_commit $(digest 3)"
record tacplus "$tacplus_commit"
out=$(run plan); rc=$?
check "plan: a valid main release passes" "$rc" 0
has "plan: it names the release" "$out" "kernel: main-${c3[kernel]:0:12}"
has "plan: D4, the record's tacplus is tacplus's release" "$out" "built with tacplus ${tacplus_commit:0:12}, tacplus's main release"
has "plan: the roll waits on the lock (tacplus#981)" "$out" "tacplus-dev/tacplus#981"

# plan: what holds the fleet (fails, saying which record and why).
holds() { # NAME WANT-IN-OUTPUT
  local out rc
  out=$(run plan); rc=$?
  check "plan holds the fleet: $1" "$rc" 1
  has "plan says why: $1" "$out" "$2"
  has "plan says dev stays: $1" "$out" "dev stays where it is"
}
reset; record tacplus "$tacplus_commit"
mkdir -p "$STUB_RECORDS/release-kernel/main"; echo 403 > "$STUB_RECORDS/release-kernel/main/record.code"
holds "a record it cannot read" "release-kernel/main/record: HTTP 403"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i 's/^branch main/branch release-0.1/' "$STUB_RECORDS/release-kernel/main/record"
holds "a record of another branch" "branch is release-0.1, not main"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i 's/^repo kernel/repo opa/' "$STUB_RECORDS/release-kernel/main/record"
holds "a record of another repository" "repo is opa, not kernel"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i "s/main-${c3[kernel]:0:12}/main-${c2[kernel]:0:12}/" "$STUB_RECORDS/release-kernel/main/record"
holds "an image whose tag is another commit's" "is not $RELEASE_REGISTRY/kernel:main-${c3[kernel]:0:12}@sha256:<64 hex>"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i 's/@sha256:.*$//' "$STUB_RECORDS/release-kernel/main/record"
holds "an image not by digest" "is not $RELEASE_REGISTRY/kernel:main-"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i 's/^commit .*/commit abc/' "$STUB_RECORDS/release-kernel/main/record"
holds "a commit that is not 40 hex" "commit is abc, not 40 hex"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}"; sed -i '/^image /d' "$STUB_RECORDS/release-kernel/main/record"
holds "a record with no image" "no image line"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}" "commit ${c2[kernel]}"
holds "a record with a line twice" "two commit lines"
reset
record kernel "${c3[kernel]}" "tacplus $tacplus_commit $(digest 3)"
holds "D4: no tacplus release to check against" "release-tacplus/main/record: no main release of tacplus"
reset; record tacplus "$tacplus_commit"
record kernel "${c3[kernel]}" "tacplus $(printf 'b%.0s' {1..40}) $(digest 3)"
holds "D4: a record built with another tacplus" "built with tacplus bbbbbbbbbbbb, not tacplus's main release aaaaaaaaaaaa"

# plan: forward only, against the deployed main release.
deployed_main() { # SERVICE COMMIT
  printf '%s %s main-%s\n' "$1" "$2" "${2:0:12}" > "$STUB_STATE/set"
}
reset; record tacplus "$tacplus_commit"
deployed_main kernel "${c2[kernel]}"; record kernel "${c1[kernel]}" "tacplus $tacplus_commit $(digest 3)"
holds "a record older than the deployed release" "main-${c1[kernel]:0:12} is behind or diverged from main-${c2[kernel]:0:12}, deployed"
reset; record tacplus "$tacplus_commit"
deployed_main kernel "${c2[kernel]}"; record kernel "${side[kernel]}" "tacplus $tacplus_commit $(digest 3)"
holds "a record diverged from the deployed release" "is behind or diverged from main-${c2[kernel]:0:12}, deployed"
reset; record tacplus "$tacplus_commit"
deployed_main kernel "${c2[kernel]}"; record kernel "${c3[kernel]}" "tacplus $tacplus_commit $(digest 3)"
out=$(run plan); rc=$?
check "plan: a record ahead of the deployed release passes" "$rc" 0
reset; record tacplus "$tacplus_commit"
deployed_main kernel "${c2[kernel]}"; record kernel "${c2[kernel]}" "tacplus $tacplus_commit $(digest 3)"
out=$(run plan); rc=$?
check "plan: the deployed release itself passes" "$rc" 0
reset; record tacplus "$tacplus_commit"
printf 'kernel %s main-%s\n' "$(printf 'f%.0s' {1..40})" ffffffffffff > "$STUB_STATE/set"
record kernel "${c3[kernel]}" "tacplus $tacplus_commit $(digest 3)"
holds "a deployed commit whose ancestry it cannot read" "cannot read"

# guard: the set this checkout applies against the deployed one.
guard() { # NAME WANT-RC [WANT-IN-OUTPUT]
  local out rc
  out=$(run guard); rc=$?
  check "guard: $1" "$rc" "$2"
  [ -z "${3:-}" ] || has "guard says why: $1" "$out" "$3"
}
reset
guard "nothing deployed yet passes" 0
lock "${c1[kernel]}" 0.1.0 "${c1[pigeon]}" 0.1.0; run record >/dev/null
guard "the deployed set itself passes" 0
lock "${c2[kernel]}" 0.1.1 "${c1[pigeon]}" 0.1.0
guard "a newer tag passes" 0
run record >/dev/null; lock "${c1[kernel]}" 0.1.0 "${c1[pigeon]}" 0.1.0
guard "a lower tag is refused" 1 "kernel: refused: v0.1.0 is older than v0.1.1, deployed"
reset; deployed_main kernel "${c2[kernel]}"
guard "a tag after a main release is refused" 1 "kernel: refused: v0.1.0 after main-${c2[kernel]:0:12}"
reset; deployed_main kernel "${c2[kernel]}"; lock "${c3[kernel]}" "main-${c3[kernel]:0:12}" "${c1[pigeon]}" 0.1.0
guard "a newer main release passes" 0
lock "${c1[kernel]}" "main-${c1[kernel]:0:12}" "${c1[pigeon]}" 0.1.0
guard "an older main release is refused" 1 "is behind or diverged from main-${c2[kernel]:0:12}, deployed"
lock "${side[kernel]}" "main-${side[kernel]:0:12}" "${c1[pigeon]}" 0.1.0
guard "a diverged main release is refused" 1 "is behind or diverged"
reset; printf 'kernel %s 0.1.0\n' "${c1[kernel]}" > "$STUB_STATE/set"
lock "${c3[kernel]}" "main-${c3[kernel]:0:12}" "${c1[pigeon]}" 0.1.0
guard "leaving a tag for main's release passes" 0
out=$(STUB_KUBE_FAILS=1 run guard); rc=$?
check "guard: a deployed set it cannot read refuses" "$rc" 1
lock "${c1[kernel]}" 0.1.0 "${c1[pigeon]}" 0.1.0

# usage
out=$(run); rc=$?
check "no command is a usage error" "$rc" 2

[ "$failures" = 0 ] && echo "all releases tests passed" || { echo "$failures releases test(s) failed"; exit 1; }
