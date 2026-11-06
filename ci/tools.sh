#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The deploy pipeline's tools, built natively on the runner from pinned
# sources, into bin/ (the tools job's artifact; none holds a secret):
#
#   bin/tacplus              the fleet's tacplus, images/pins.yaml tacplus_commit
#   bin/schematic-operator   deploy/build-operator.sh with that tacplus
#   bin/yq, bin/govulncheck  built from pinned module versions, each refused unless its module's hash
#                            (h1:, a SHA-256 of its content) is the pinned one
#   bin/opa, bin/gitleaks,   the same, each in a module of its own that raises the dependencies whose
#   bin/osv-scanner,         fixed vulnerabilities its release does not take yet to pinned fixed versions,
#   bin/trivy                each refused unless its version and hash are the pinned ones (#40: GO-2026-6865,
#                            klauspost/compress; GO-2026-6888, andybalholm/brotli; GO-2025-3922, ulikunitz/xz).
#                            govulncheck, osv-scanner and trivy are the security job's (ci/security.sh, #36);
#                            osv-scanner and trivy are built with the pinned Go toolchain (osv-scanner's
#                            release is built with go1.27.0, whose fixed standard-library vulnerabilities
#                            govulncheck finds in it; both need go 1.27)
#   bin/lego                 the cert job's ACME client (ci/cert.sh, #35): its release download,
#                            pinned by version and SHA-256
#
#   ci/tools.sh              # needs go, protoc and jq (ghcr.io/tacplus-dev/tacplus/build) and
#                            # git access to github.com, with no credential (ci_github); linux arm64 or amd64
#
# Go's build and module caches are its own, in a temporary directory, never the
# caller's: each tool's are dropped once it is built, so its disk use peaks at
# the largest one build, not all of them (#37: on GitHub's runner the CI image
# leaves too little disk for them all).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "tools.sh: $*" >&2; exit 1; }
yq_version=v4.54.1 yq_h1=h1:wFk+RhKFcx6fU6tkjC9z069vLTL4uDoXi9R4SytFB8s=
opa_version=v1.21.4 opa_h1=h1:zTVuy8yd8BM715t8WxMzAIkIX4w1x3MMHEv99IGUY2w=   # the pipeline's check CLI; the fleet's OPA library pin is dependencies.yaml's (#13)
gitleaks_version=v8.30.1 gitleaks_h1=h1:PmEvCfVI7ti9dV3s5aMZUY7sS2GxRvG3yzih7E+cS3w=   # ci/secrets.sh; .github/workflows/secrets.yml installs the same release
govulncheck_version=v1.9.0 govulncheck_h1=h1:12VaqnI9kJfqwRoPptxoqsUhQtdfrSbdksT7X/KY/sc=
osv_version=v2.7.0 osv_h1=h1:7aOrJ9vB7qbzxC3R+QCXs03SHQiRuM80RJdqZhUEl2g=
trivy_version=v0.76.2 trivy_h1=h1:RYBcQklHCFOHg/sfYSfe8v4/W5H2rAZrP5THPWY5F+A=
go_toolchain=go1.27.3   # osv-scanner's and trivy's: they need go 1.27
# The fixed dependency versions (#40), each MODULE@VERSION=H1. Drop one from a tool once its release requires it.
compress_fix=github.com/klauspost/compress@v1.20.3=h1:zWNoFqq/lSuYQRim3dUXlXeA0IqwuZGicdG5ZTfY5j4=   # GO-2026-6865, fixed in v1.20.2
brotli_fix=github.com/andybalholm/brotli@v1.2.8=h1:H9F6r7RNwzSRsx/lytpIYkbjNFMt2yNBwsJ2+0gpx78=   # GO-2026-6888, fixed in v1.2.7
xz_fix=github.com/ulikunitz/xz@v0.5.17=h1:flR0y/x1hgM8EGV1AW3Xll6T413G0glV8UfBwR617V4=   # GO-2025-3922, fixed in v0.5.15
lego_version=5.6.0
case $(uname -m) in
  aarch64|arm64) lego_arch=linux_arm64 lego_sha=34d87a6552d69390c4a4560237045c47713a8e148d899e16db0e97040894ed1f ;;
  x86_64|amd64) lego_arch=linux_amd64 lego_sha=f02fc11b6f56b97e387fa7caa0268f86f5a336953b22458e6430e4651fea439a ;;
  *) die "no pinned lego for $(uname -m)" ;;
esac
mkdir -p "$here/bin"
tmp=$(mktemp -d)
export GOCACHE=$tmp/go-build GOMODCACHE=$tmp/go-mod
# go_drop: Go's caches emptied (go clean: the module cache is read-only), run from /, outside any module.
go_drop() { ( cd / && go clean -cache -modcache ); }
trap 'go_drop >/dev/null 2>&1; rm -rf "$tmp"' EXIT

# fetch URL SHA256: the download in $tmp/<its name>, refused unless its SHA-256 is SHA256.
fetch() {
  local f=$tmp/${1##*/}
  curl -sSfL --retry 3 -o "$f" "$1" || die "cannot download $1"
  echo "$2  $f" | sha256sum -c --quiet - >/dev/null 2>&1 || die "$1: SHA-256 $(sha256sum "$f" | cut -c1-64), not the pinned $2"
  echo "$f"
}
# go_install PACKAGE MODULE VERSION H1: PACKAGE built into bin/, refused unless MODULE@VERSION's hash is H1.
go_install() {
  local sum
  sum=$(GOFLAGS=-mod=mod go mod download -json "$2@$3" | jq -r .Sum) || die "cannot download $2@$3"
  [ "$sum" = "$4" ] || die "$2@$3: hash $sum, not the pinned $4"
  GOBIN="$here/bin" go install "$1@$3"
  go_drop
}
# go_build_fixed NAME PACKAGE MODULE VERSION H1 LDFLAGS DEP@VERSION=H1...: PACKAGE built into bin/NAME in a
# module of its own that requires MODULE@VERSION and raises each DEP to its fixed VERSION (#40; the way
# tacplus-dev/looper#88 builds Syft). Refused unless MODULE's hash is H1 and each DEP is selected at exactly
# VERSION with its hash H1; go.sum is checked against sum.golang.org, as for go install.
go_build_fixed() {
  local name=$1 pkg=$2 mod=$3 ver=$4 h1=$5 ldflags=$6 dir=$tmp/mod-$1 fix m v h
  shift 6
  mkdir -p "$dir"
  local edits=(-require "$mod@$ver" -tool "$pkg")
  for fix; do edits+=(-require "${fix%=h1:*}"); done
  ( cd "$dir" && go mod init "tools.local/$name" >/dev/null 2>&1 && go mod edit "${edits[@]}" && go mod tidy ) \
    || die "cannot resolve $mod@$ver with ${*:-no fixed dependency}"
  for fix in "$mod@$ver=$h1" "$@"; do
    m=${fix%%@*} v=${fix#*@} v=${v%%=*} h=${fix#*=}
    [ "$(cd "$dir" && go list -m -f '{{.Version}}' "$m")" = "$v" ] || die "$name: $m is not selected at the pinned $v"
    [ "$(cd "$dir" && go mod download -json "$m@$v" | jq -r .Sum)" = "$h" ] || die "$name: $m@$v's hash is not the pinned $h"
  done
  ( cd "$dir" && go build -ldflags "$ldflags" -o "$here/bin/$name" "$pkg" ) || die "cannot build $name"
  go_drop
}

# tacplus, built as images/tacplus.cloudbuild.yaml builds it.
commit=$(sed -n 's/^tacplus_commit: *//p' "$here/images/pins.yaml")
src=$(mktemp -d)
git clone -q https://github.com/tacplus-dev/tacplus.git "$src" && git -C "$src" checkout -q "$commit"
pkg=github.com/tacplus-dev/tacplus/pkg/buildinfo
( cd "$src" && go generate ./pkg/internal/proto/spec/... \
  && CGO_ENABLED=0 go build -trimpath \
     -ldflags="-w -s -X $pkg.Version=v2.2.0-seatrials -X $pkg.GitSha=$commit -X $pkg.BuildID=$commit -X $pkg.ProjectPath=tacplus-dev/tacplus" \
     -o "$here/bin/tacplus" . )
rm -rf "$src"
go_drop
"$here/bin/tacplus" version

TACPLUS="$here/bin/tacplus" "$here/deploy/build-operator.sh"
go_drop

go_install github.com/mikefarah/yq/v4 github.com/mikefarah/yq/v4 "$yq_version" "$yq_h1"
go_build_fixed opa github.com/open-policy-agent/opa github.com/open-policy-agent/opa "$opa_version" "$opa_h1" "" \
  "$compress_fix"
go_build_fixed gitleaks github.com/zricethezav/gitleaks/v8 github.com/zricethezav/gitleaks/v8 "$gitleaks_version" "$gitleaks_h1" \
  "-X github.com/zricethezav/gitleaks/v8/version.Version=$gitleaks_version" "$compress_fix" "$brotli_fix" "$xz_fix"
go_install golang.org/x/vuln/cmd/govulncheck golang.org/x/vuln "$govulncheck_version" "$govulncheck_h1"
GOTOOLCHAIN=$go_toolchain go_build_fixed osv-scanner github.com/google/osv-scanner/v2/cmd/osv-scanner github.com/google/osv-scanner/v2 \
  "$osv_version" "$osv_h1" "" "$compress_fix"
# trivy as its release builds it (goreleaser.yml), its symbols kept for govulncheck.
GOTOOLCHAIN=$go_toolchain CGO_ENABLED=0 go_build_fixed trivy github.com/aquasecurity/trivy/cmd/trivy github.com/aquasecurity/trivy \
  "$trivy_version" "$trivy_h1" "-w -X github.com/aquasecurity/trivy/pkg/version/app.ver=${trivy_version#v}" "$compress_fix"
f=$(fetch "https://github.com/go-acme/lego/releases/download/v$lego_version/lego_v${lego_version}_$lego_arch.tar.gz" "$lego_sha")
tar -xzf "$f" -C "$tmp" lego && install -m 0755 "$tmp/lego" "$here/bin/lego"
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
