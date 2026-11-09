#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The cert job (#35; tacplus-dev/roadmap decisions/certificates-by-pipeline-2026-11-03.md):
# the pipeline owns the fleet's public certificate. It is kept in Secret Manager,
# one version per certificate, each the leaf, its chain and the key in PEM, and
# never in the cluster outside the deployment's own delivery. This job:
#
#   - checks the latest version of CERT_SECRET (ci/cert-check.sh), for CERT_DOMAINS and
#     the fleet's fqdn;
#   - missing, expired, wrong-hostname or invalid: lego obtains a new certificate
#     (ACME DNS-01 in the challenge zone CERT_DNS_ZONE, apex plus wildcard);
#   - valid or due: lego is given the current one and renews it when Let's Encrypt's
#     renewal information (ARI) says so, or else in the last third of its lifetime;
#   - a certificate lego wrote is checked, then added as a new version;
#   - a supplied certificate (CERT_SUPPLIED_SECRET, somebody else's) is checked the same
#     way and never obtained: due is a warning, expired, wrong-hostname or invalid fails;
#   - it passes the secret and the version on, CERT_SECRET=... CERT_VERSION=... in
#     CERT_ENV_OUT (the job's dotenv): every later job installs that version, never latest.
#
# lego's ACME account (its key and registration) is kept in its own secret,
# ACME_ACCOUNT_SECRET, a tar of lego's accounts/; the first run registers it.
# lego's working directory is rebuilt from the two secrets in a private
# temporary directory and removed on exit. Nothing secret is printed and
# nothing is left on disk; never run it with `set -x`.
#
#   CERT_PROJECT=tacplus-dev ci/cert.sh      # after ci_gcp (ci/lib.sh); needs gcloud, lego, yq, openssl
#
# CERT_SECRET (tls-seatrials), ACME_ACCOUNT_SECRET (acme-account-seatrials),
# CERT_DOMAINS (comma-separated; tacplus.dev,*.tacplus.dev), CERT_DNS_ZONE (the
# Cloud DNS zone of _acme-challenge.<domain>), ACME_SERVER (lego's --server:
# letsencrypt, or letsencrypt-staging for a test run, with CERT_CHECK_CAFILE its
# roots), ACME_EMAIL (optional contact), CERT_SUPPLIED_SECRET, CERT_ENV_OUT, CERT_FQDN
# (the name the certificate must also cover; operator.yaml's fqdn by default: the
# test IdP's job names its own, test-idp/apply.sh).
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "cert: $*" >&2; exit 1; }
say() { echo "cert: $*"; }
project=${CERT_PROJECT:?CERT_PROJECT, the project of the certificate secrets, is not set}
secret=${CERT_SECRET:-tls-seatrials}
account_secret=${ACME_ACCOUNT_SECRET:-acme-account-seatrials}
supplied=${CERT_SUPPLIED_SECRET:-}
server=${ACME_SERVER:-letsencrypt}
IFS=, read -ra domains <<<"${CERT_DOMAINS:-tacplus.dev,*.tacplus.dev}"
fqdn=${CERT_FQDN:-$(yq '.fqdn' "${OPERATOR_YAML:-$here/deploy/bootstrap/operator.yaml}")}
[ -n "$fqdn" ] && [ "$fqdn" != null ] || die "no fqdn in operator.yaml"
name=seatrials # lego's name for the certificate and the account

umask 077
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# latest SECRET: the number of SECRET's latest enabled version; nothing when it has none.
latest() {
  local v
  v=$(gcloud secrets versions list "$1" --project="$project" --filter=state=ENABLED --sort-by=~createTime \
      --limit=1 --format='value(name)' 2>"$work/err") ||
    die "cannot list the versions of the secret $1 in $project: $(grep -m1 ERROR "$work/err" || head -c 300 "$work/err")"
  echo "${v##*/}"
}
# access SECRET VERSION FILE: that version's payload in FILE.
access() {
  gcloud secrets versions access "$2" --secret="$1" --project="$project" --out-file="$3" 2>"$work/err" ||
    die "cannot read version $2 of the secret $1: $(grep -m1 ERROR "$work/err" || head -c 300 "$work/err")"
}
# add SECRET FILE: FILE as SECRET's new version; its number on stdout.
add() {
  local v
  v=$(gcloud secrets versions add "$1" --project="$project" --data-file="$2" --format='value(name)' 2>"$work/err") ||
    die "cannot add a version to the secret $1: $(grep -m1 ERROR "$work/err" || head -c 300 "$work/err")"
  echo "${v##*/}"
}
# check PAYLOAD: cert-check.sh's word for it, for the domains and the fleet's fqdn.
check() { "$here/ci/cert-check.sh" "$1" "${domains[@]}" "$fqdn" || true; }
# pass SECRET VERSION: the certificate every later job installs.
pass() {
  say "the fleet's certificate: the secret $1, version $2"
  [ -z "${CERT_ENV_OUT:-}" ] || printf 'CERT_SECRET=%s\nCERT_VERSION=%s\n' "$1" "$2" > "$CERT_ENV_OUT"
}
# digest DIR: one hash over DIR's files, to tell whether lego changed them.
digest() { [ -d "$1" ] || { echo none; return; }; (cd "$1" && find . -type f -print0 | sort -z | xargs -0r sha256sum) | sha256sum; }

if [ -n "$supplied" ]; then
  v=$(latest "$supplied")
  [ -n "$v" ] || die "the supplied certificate's secret $supplied has no version: add the certificate, its chain and key to it"
  access "$supplied" "$v" "$work/current.pem"
  state=$(check "$work/current.pem")
  case $state in
    valid) ;;
    due) echo "cert: warning: the supplied certificate (the secret $supplied, version $v) is due: add a renewed one to $supplied" ;;
    *) die "the supplied certificate (the secret $supplied, version $v) is $state: add a valid one to $supplied" ;;
  esac
  pass "$supplied" "$v"
  exit 0
fi

lp=$work/lego
mkdir -p "$lp/certificates"
av=$(latest "$account_secret")
if [ -n "$av" ]; then
  access "$account_secret" "$av" "$work/account.tgz"
  tar -xzf "$work/account.tgz" -C "$lp" || die "version $av of the secret $account_secret is not lego's accounts/"
fi
account_before=$(digest "$lp/accounts")

v=$(latest "$secret") state=missing
if [ -n "$v" ]; then
  access "$secret" "$v" "$work/current.pem"
  state=$(check "$work/current.pem")
fi
say "the secret $secret, version ${v:-none}: $state"
case $state in
  valid|due)
    # lego renews what it has: the certificate, its key, and its record of what it ordered.
    sed '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/d' "$work/current.pem" > "$lp/certificates/$name.crt"
    sed -n '/BEGIN .*PRIVATE KEY/,/END .*PRIVATE KEY/p' "$work/current.pem" > "$lp/certificates/$name.key"
    printf '%s\n' "${domains[@]}" | jq -R . | jq -s --arg id "$name" \
      '{id: $id, domains: ., keyType: "EC256", certUrl: "", certStableUrl: ""}' > "$lp/certificates/$name.json"
    say "lego renews it if Let's Encrypt's renewal information says so, or in the last third of its lifetime" ;;
  *) say "lego obtains a new certificate (DNS-01): ${domains[*]}" ;;
esac
cert_before=$(digest "$lp/certificates")

args=(run --path "$lp" --server "$server" --accept-tos --account-id "$name" --cert.name "$name" --key-type EC256
  --dns gcloud --log.format text)
for d in "${domains[@]}"; do args+=(--domains "$d"); done
[ -z "${ACME_EMAIL:-}" ] || args+=(--email "$ACME_EMAIL")
rc=0
GCE_PROJECT=$project GCE_ZONE_ID=${CERT_DNS_ZONE:?CERT_DNS_ZONE, the challenge zone, is not set} \
  "${LEGO:-lego}" "${args[@]}" || rc=$?

# The account first: a registration is kept even when the order failed.
if [ "$(digest "$lp/accounts")" != "$account_before" ]; then
  tar -C "$lp" -czf "$work/account.tgz" accounts
  say "the ACME account: the secret $account_secret, version $(add "$account_secret" "$work/account.tgz")"
fi
[ "$rc" = 0 ] || die "lego failed (exit $rc); the secret $secret is unchanged"

if [ "$(digest "$lp/certificates")" != "$cert_before" ]; then
  cat "$lp/certificates/$name.crt" "$lp/certificates/$name.key" > "$work/new.pem"
  state=$(check "$work/new.pem")
  [ "$state" = valid ] || die "the certificate lego wrote is $state; nothing is added to the secret $secret"
  v=$(add "$secret" "$work/new.pem")
  say "a new certificate: the secret $secret, version $v"
else
  say "lego wrote nothing: not due"
fi
[ -n "$v" ] || die "no certificate: the secret $secret has no version and lego wrote none"
pass "$secret" "$v"
