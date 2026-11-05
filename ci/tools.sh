#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The deploy pipeline's tools, built natively on the runner from pinned
# sources, into bin/ (the tools job's artifact; none holds a secret):
#
#   bin/tacplus              the fleet's tacplus, images/pins.yaml tacplus_commit
#   bin/schematic-operator   deploy/build-operator.sh with that tacplus
#   bin/yq, bin/opa,         built from pinned module versions, each refused unless its module's
#   bin/gitleaks,            hash (h1:, a SHA-256 of its content) is the pinned one; govulncheck and
#   bin/govulncheck,         osv-scanner are the security job's (ci/security.sh, #36), osv-scanner
#   bin/osv-scanner          built with the pinned Go toolchain (its release is built with go1.27.0,
#                            whose fixed standard-library vulnerabilities govulncheck finds in it)
#   bin/trivy                the security job's: its release download, pinned by version and SHA-256
#   bin/lego                 the cert job's ACME client (ci/cert.sh, #35): its release download,
#                            pinned by version and SHA-256
#
#   ci/tools.sh              # needs go, protoc and jq (ghcr.io/tacplus-dev/tacplus/build) and
#                            # git access to github.com, with no credential (ci_github); linux arm64 or amd64
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "tools.sh: $*" >&2; exit 1; }
yq_version=v4.54.1 yq_h1=h1:wFk+RhKFcx6fU6tkjC9z069vLTL4uDoXi9R4SytFB8s=
opa_version=v1.21.4 opa_h1=h1:zTVuy8yd8BM715t8WxMzAIkIX4w1x3MMHEv99IGUY2w=   # the pipeline's check CLI; the fleet's OPA library pin is dependencies.yaml's (#13)
gitleaks_version=v8.30.1 gitleaks_h1=h1:PmEvCfVI7ti9dV3s5aMZUY7sS2GxRvG3yzih7E+cS3w=   # ci/secrets.sh; .github/workflows/secrets.yml installs the same release
govulncheck_version=v1.9.0 govulncheck_h1=h1:12VaqnI9kJfqwRoPptxoqsUhQtdfrSbdksT7X/KY/sc=
osv_version=v2.7.0 osv_h1=h1:7aOrJ9vB7qbzxC3R+QCXs03SHQiRuM80RJdqZhUEl2g= osv_toolchain=go1.27.3   # it needs go 1.27
trivy_version=0.76.1
lego_version=5.6.0
case $(uname -m) in
  aarch64|arm64) trivy_arch=Linux-ARM64 trivy_sha=e174dff2a6dba5e3ae41f8d0537a6324405bd08132497340304c6b20e0f16a1f
    lego_arch=linux_arm64 lego_sha=34d87a6552d69390c4a4560237045c47713a8e148d899e16db0e97040894ed1f ;;
  x86_64|amd64) trivy_arch=Linux-64bit trivy_sha=c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0
    lego_arch=linux_amd64 lego_sha=f02fc11b6f56b97e387fa7caa0268f86f5a336953b22458e6430e4651fea439a ;;
  *) die "no pinned scanners for $(uname -m)" ;;
esac
mkdir -p "$here/bin"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

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
"$here/bin/tacplus" version

TACPLUS="$here/bin/tacplus" "$here/deploy/build-operator.sh"

go_install github.com/mikefarah/yq/v4 github.com/mikefarah/yq/v4 "$yq_version" "$yq_h1"
go_install github.com/open-policy-agent/opa github.com/open-policy-agent/opa "$opa_version" "$opa_h1"
go_install github.com/zricethezav/gitleaks/v8 github.com/zricethezav/gitleaks/v8 "$gitleaks_version" "$gitleaks_h1"
go_install golang.org/x/vuln/cmd/govulncheck golang.org/x/vuln "$govulncheck_version" "$govulncheck_h1"
GOTOOLCHAIN=$osv_toolchain go_install github.com/google/osv-scanner/v2/cmd/osv-scanner github.com/google/osv-scanner/v2 "$osv_version" "$osv_h1"
f=$(fetch "https://github.com/aquasecurity/trivy/releases/download/v$trivy_version/trivy_${trivy_version}_$trivy_arch.tar.gz" "$trivy_sha")
tar -xzf "$f" -C "$tmp" trivy && install -m 0755 "$tmp/trivy" "$here/bin/trivy"
f=$(fetch "https://github.com/go-acme/lego/releases/download/v$lego_version/lego_v${lego_version}_$lego_arch.tar.gz" "$lego_sha")
tar -xzf "$f" -C "$tmp" lego && install -m 0755 "$tmp/lego" "$here/bin/lego"
echo "bin/: $(ls "$here/bin" | tr '\n' ' ')"
