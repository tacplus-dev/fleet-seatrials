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
#                            govulncheck, osv-scanner and trivy are the security job's (ci/security.sh, #36)
#   bin/lego                 the cert job's ACME client (ci/cert.sh, #35): the same, as its release builds it
#                            (#49: its release binary holds go1.27.3's fixed GO-2026-6859)
#
# Every one is built with the pinned Go toolchain, go_toolchain, not the CI image's
# go: the standard library is in each binary, and govulncheck fails a fixed
# vulnerability in it (#49). The toolchain is Go's own download (checked against
# sum.golang.org), fetched once; each binary is refused unless it reports it.
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
go_toolchain=go1.27.4   # every tool's: GO-2026-6859 (net/http) is fixed in go1.27.4 (#49)
# The fixed dependency versions (#40), each MODULE@VERSION=H1. Drop one from a tool once its release requires it.
compress_fix=github.com/klauspost/compress@v1.20.3=h1:zWNoFqq/lSuYQRim3dUXlXeA0IqwuZGicdG5ZTfY5j4=   # GO-2026-6865, fixed in v1.20.2
brotli_fix=github.com/andybalholm/brotli@v1.2.8=h1:H9F6r7RNwzSRsx/lytpIYkbjNFMt2yNBwsJ2+0gpx78=   # GO-2026-6888, fixed in v1.2.7
xz_fix=github.com/ulikunitz/xz@v0.5.17=h1:flR0y/x1hgM8EGV1AW3Xll6T413G0glV8UfBwR617V4=   # GO-2025-3922, fixed in v0.5.15
lego_version=v5.6.0 lego_h1=h1:tdr1k0mPExMhqFUee09aAD8kSDcM7rha9k8IBs1wuX0=
mkdir -p "$here/bin"
tmp=$(mktemp -d)
# The pinned toolchain, in a module cache of its own that go_drop leaves (Go makes it read-only).
goroot=$(cd / && GOTOOLCHAIN=$go_toolchain GOMODCACHE=$tmp/toolchain go env GOROOT) \
  || die "cannot download $go_toolchain"
export PATH=$goroot/bin:$PATH GOTOOLCHAIN=local
[ "$(go env GOVERSION)" = "$go_toolchain" ] || die "go is $(go env GOVERSION), not the pinned $go_toolchain"
export GOCACHE=$tmp/go-build GOMODCACHE=$tmp/go-mod
# go_drop: Go's caches emptied (go clean: the module cache is read-only), run from /, outside any module.
go_drop() { ( cd / && go clean -cache -modcache ); }
trap 'go_drop >/dev/null 2>&1; chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT

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
go_build_fixed osv-scanner github.com/google/osv-scanner/v2/cmd/osv-scanner github.com/google/osv-scanner/v2 \
  "$osv_version" "$osv_h1" "" "$compress_fix"
# trivy as its release builds it (goreleaser.yml), its symbols kept for govulncheck.
CGO_ENABLED=0 go_build_fixed trivy github.com/aquasecurity/trivy/cmd/trivy github.com/aquasecurity/trivy \
  "$trivy_version" "$trivy_h1" "-w -X github.com/aquasecurity/trivy/pkg/version/app.ver=${trivy_version#v}" "$compress_fix"
# lego as its release builds it (.goreleaser.yml: its tags, trimmed paths), its symbols kept for govulncheck.
CGO_ENABLED=0 GOFLAGS="-trimpath -tags=urfave_cli_no_template,ozzo_validation_no_template,grpcnotrace,validator_novalidatefn" \
  go_build_fixed lego github.com/go-acme/lego/v5 github.com/go-acme/lego/v5 "$lego_version" "$lego_h1" \
  "-w -X main.version=${lego_version#v}"
for b in "$here"/bin/*; do
  v=$(go version "$b" | awk '{print $2}') || die "${b#"$here"/}: not a Go binary"
  [ "$v" = "$go_toolchain" ] || die "${b#"$here"/} is built with $v, not the pinned $go_toolchain"
done
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
