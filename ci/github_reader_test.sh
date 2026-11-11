#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests how the deploy pipeline reads this private repository (#29, #30): only
# through the keyless tacplus-reader GitHub App, never a stored GitHub token.
# The pipeline files reference no static token, and the block that mints the
# app's token and fetches (.github-reader) is the same in both and is what
# fleet-plan and every child job run first. That block, run against a stub
# gcloud (WIF), a stub KMS and a stub GitHub, asks KMS to sign the app's JWT,
# as the job itself or, when KMS refuses that principal, as the service
# account TACPLUS_READER_SA; logs KMS's and GitHub's status and error, never a
# token; asks for contents: read on this repository alone, hands the token to
# git only, and refuses a job that holds anything shaped like a GitHub token.
# Needs bash, git, jq, yq and openssl.
#
#   ci/github_reader_test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
fail() { echo "FAIL $*"; failed=1; }
ok() { echo "ok   $*"; }
project=$here/ci/gitlab-project.gitlab-ci.yml
deploy=$here/ci/deploy.gitlab-ci.yml

# --- the pipeline files -------------------------------------------------------

# No static GitHub token: the old project variable, a token kept in the
# GitLab project, or a credential helper other than the block's.
old=FLEET_GITHUB_READ_""TOKEN
hits=$(grep -rnE "$old|GH_TOKEN|GITHUB_TOKEN|(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9]" \
  "$here"/ci/*.yml "$here"/ci/lib.sh "$here"/ci/tools.sh "$here"/docs "$here/README.md")
[ -z "$hits" ] && ok "no static GitHub token is referenced" || fail "a static GitHub token is referenced: $hits"
hits=$(grep -nE 'password=|credential\.[^ ]*helper=!' "$here"/ci/*.yml "$here"/ci/lib.sh | grep -v 'password=\$TACPLUS_READER_TOKEN')
[ -z "$hits" ] && ok "the only GitHub credential is the reader token" || fail "another credential helper: $hits"
hits=$(grep -n 'TACPLUS_READER_TOKEN=' "$here"/ci/*.yml "$here"/ci/lib.sh | grep -v 'TACPLUS_READER_TOKEN=\$token git ')
[ -z "$hits" ] && ok "the reader token is set for git alone" || fail "the reader token is set elsewhere: $hits"

block=$(yq '.".github-reader"' "$deploy")
[ -n "$block" ] && [ "$block" != null ] || { fail "ci/deploy.gitlab-ci.yml has no .github-reader"; block=""; }
[ "$(yq '.".github-reader"' "$project")" = "$block" ] &&
  ok "the .github-reader block is the same in both pipeline files" ||
  fail "the .github-reader block differs between ci/gitlab-project.gitlab-ci.yml and ci/deploy.gitlab-ci.yml"
[ "$(yq 'explode(.) | .fleet-plan.script[0]' "$project")" = "$block" ] &&
  yq 'explode(.) | .fleet-plan.script[1]' "$project" | grep -q '^github_fetch src ' &&
  ok "fleet-plan fetches through the block" || fail "fleet-plan does not fetch through the block"
[ "$(yq 'explode(.) | .default.before_script[0]' "$deploy")" = "$block" ] &&
  yq 'explode(.) | .default.before_script[1]' "$deploy" | grep -q '^github_fetch src "\$FLEET_COMMIT"' &&
  ok "every child job fetches through the block" || fail "the child pipeline's before_script does not fetch through the block"
# Every job that fetches has the id_token the block exchanges.
[ "$(yq '.default.id_tokens.GCP_ID_TOKEN.aud' "$deploy")" = 'https://iam.googleapis.com/$GCP_WIF_PROVIDER' ] &&
  [ "$(yq '.fleet-plan.id_tokens.GCP_ID_TOKEN.aud' "$project")" = 'https://iam.googleapis.com/$GCP_WIF_PROVIDER' ] &&
  ok "fleet-plan and every child job have GCP_ID_TOKEN" || fail "a job that fetches has no id_tokens GCP_ID_TOKEN"
[ "$(yq '.variables.TACPLUS_READER_KMS_KEY' "$deploy")" = "$(yq '.variables.TACPLUS_READER_KMS_KEY' "$project")" ] &&
  [ "$(yq '.variables.TACPLUS_READER_KMS_KEY' "$deploy")" = projects/tacplus-ci/locations/us-central1/keyRings/looper/cryptoKeys/tacplus-reader ] &&
  ok "both pipelines name the same KMS key" || fail "TACPLUS_READER_KMS_KEY is missing or differs"
[ "$(yq '.variables.TACPLUS_READER_SA' "$deploy")" = "$(yq '.variables.TACPLUS_READER_SA' "$project")" ] &&
  [ "$(yq '.variables.TACPLUS_READER_SA' "$deploy")" = fleet-seatrials-reader@tacplus-ci.iam.gserviceaccount.com ] &&
  ok "both pipelines name the same service account to fall back to" || fail "TACPLUS_READER_SA is missing or differs"

# --- the block, against stubs -------------------------------------------------

# A stub gcloud: WIF (records each credential configuration it was asked for,
# and answers print-access-token with a federated token, or the service
# account's when the configuration impersonates one; refuses the exchange when
# STS_REFUSE is set).
mkdir -p "$work/bin" "$work/log"
openssl genrsa -out "$work/app.pem" 2048 2>/dev/null
openssl rsa -in "$work/app.pem" -pubout -out "$work/app.pub" 2>/dev/null
cat > "$work/bin/gcloud" <<EOF
#!/usr/bin/env bash
echo "gcloud \$*" >> "$work/log/gcloud"
arg() { local a; for a in "\$@"; do case "\$a" in --\$want=*) echo "\${a#*=}" ;; esac; done; }
case "\$1 \$2" in
  "iam workload-identity-pools")
    want=credential-source-file; cp "\$(arg "\$@")" "$work/log/oidc-token"
    want=service-account; sa=\$(arg "\$@")
    want=output-file; jq -n --arg sa "\$sa" '{type: "external_account", sa: \$sa}' > "\$(arg "\$@")" ;;
  "auth login")
    want=cred-file; mkdir -p "\$CLOUDSDK_CONFIG"; cp "\$(arg "\$@")" "\$CLOUDSDK_CONFIG/cred.json" ;;
  "auth print-access-token")
    [ -z "\${STS_REFUSE:-}" ] || { echo "ERROR: (gcloud.auth.print-access-token) invalid_grant: The audience in ID Token does not match" >&2; exit 1; }
    case "\$(jq -r .sa "\$CLOUDSDK_CONFIG/cred.json")" in
      "") echo ya29.direct-stub-token ;;
      *) echo "ya29.sa-stub-token-\$(jq -r .sa "\$CLOUDSDK_CONFIG/cred.json")" ;;
    esac ;;
  *) echo "unexpected gcloud \$*" >&2; exit 1 ;;
esac
EOF
# A stub curl. Cloud KMS's asymmetricSign: records the call, the digest and
# who asked, and signs with a key made here; it refuses the federated token
# with KMS_DIRECT=CODE and the service account's with KMS_SA=CODE, as KMS
# does. GitHub's access_tokens: records the call and the JWT, checks the JWT's
# signature against the app's key, and answers with a token (or refuses when
# GITHUB_REFUSE is set).
cat > "$work/bin/curl" <<EOF
#!/usr/bin/env bash
out=/dev/stdout write=; body=; headers=(); url=
while ((\$#)); do
  case "\$1" in
    -o) out=\$2; shift ;;
    -w) write=\$2; shift ;;
    -d) body=\$2; shift ;;
    -H) case "\$2" in @*) while IFS= read -r h; do headers+=("\$h"); done < "\${2#@}" ;; *) headers+=("\$2") ;; esac; shift ;;
    -X) shift ;;
    https://*) url=\$1 ;;
  esac
  shift
done
bearer=\$(printf '%s\n' "\${headers[@]}" | sed -n 's/^Authorization: Bearer //p')
answer() { printf '%s\n' "\$2" > "\$out"; [ -z "\$write" ] || printf '%s' "\$1"; }
case "\$url" in
  https://cloudkms.googleapis.com/*)
    printf '%s\n' "\$url" > "$work/log/kms-url"; printf '%s\n' "\$body" > "$work/log/kms-body"
    echo "\$bearer" >> "$work/log/kms-as"
    refuse=
    case "\$bearer" in ya29.direct-stub-token) refuse=\${KMS_DIRECT:-} ;; ya29.sa-stub-token-*) refuse=\${KMS_SA:-} ;; *) refuse=401 ;; esac
    case "\$refuse" in
      "") jq -r .digest.sha256 <<<"\$body" | base64 -d > "$work/log/kms-digest"
          sig=\$(openssl pkeyutl -sign -inkey "$work/app.pem" -pkeyopt digest:sha256 -in "$work/log/kms-digest" | base64 -w0)
          answer 200 "{\"signature\": \"\$sig\", \"name\": \"k/cryptoKeyVersions/1\"}" ;;
      403) answer 403 '{"error": {"code": 403, "message": "Permission '"'"'cloudkms.cryptoKeyVersions.useToSign'"'"' denied on resource (or it may not exist).", "status": "PERMISSION_DENIED"}}' ;;
      404) answer 404 '{"error": {"code": 404, "message": "CryptoKeyVersion k/cryptoKeyVersions/1 not found.", "status": "NOT_FOUND"}}' ;;
      *) answer "\$refuse" "<html>error \$refuse</html>" ;;
    esac ;;
  https://api.github.com/*)
    printf '%s\n' "\$url" > "$work/log/curl"; printf '%s\n' "\$body" > "$work/log/github-body"
    [ -z "\${GITHUB_REFUSE:-}" ] || { answer 404 '{"message": "Not Found", "status": "404"}'; exit 0; }
    printf '%s' "\${bearer%.*}" > "$work/log/signed"
    printf '%s' "\${bearer##*.}" | tr '_-' '/+' | { s=\$(cat); while ((\${#s} % 4)); do s+="="; done; printf '%s' "\$s"; } |
      base64 -d > "$work/log/sig"
    openssl dgst -sha256 -verify "$work/app.pub" -signature "$work/log/sig" "$work/log/signed" >/dev/null ||
      { answer 401 '{"message": "A JSON web token could not be decoded"}'; exit 0; }
    answer 201 '{"token": "ghs_stubreadertoken0123456789", "expires_at": "2026-11-02T01:00:00Z"}' ;;
  *) echo "unexpected curl \$url" >&2; exit 6 ;;
esac
EOF
# A git wrapper: for the fetch, what git's credential helper would give
# github.com, and whether the token is in git's environment.
real_git=$(command -v git)
cat > "$work/bin/git" <<EOF
#!/usr/bin/env bash
cfg=(); for a in "\$@"; do case "\$a" in credential.*) cfg+=(-c "\$a") ;; esac; done
if ((\${#cfg[@]})); then
  printf 'protocol=https\nhost=github.com\npath=tacplus-dev/fleet-seatrials.git\n\n' |
    "$real_git" "\${cfg[@]}" credential fill > "$work/log/credential" 2>&1
  echo "\${TACPLUS_READER_TOKEN:-}" > "$work/log/git-env"
fi
exec "$real_git" "\$@"
EOF
chmod +x "$work/bin/"*

# The origin, standing in for github.com/tacplus-dev/fleet-seatrials.
"$real_git" init -q --bare "$work/origin.git"
"$real_git" init -q "$work/up" && "$real_git" -C "$work/up" config user.email t@example.invalid &&
  "$real_git" -C "$work/up" config user.name t
echo one > "$work/up/f" && "$real_git" -C "$work/up" add f && "$real_git" -C "$work/up" commit -qm one
first=$("$real_git" -C "$work/up" rev-parse HEAD)
echo two > "$work/up/f" && "$real_git" -C "$work/up" commit -qam two
"$real_git" -C "$work/up" push -q "$work/origin.git" HEAD:refs/heads/main

printf '%s\n' "$block" > "$work/block.sh"
# job [VAR=VALUE...] -- COMMANDS: the block, then COMMANDS, as a job runs them.
job() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  rm -rf "$work/job" "$work/log/"*; mkdir -p "$work/job"
  ( cd "$work/job" && env -i HOME="$work" PATH="$work/bin:$PATH" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="url.file://$work/origin.git.insteadOf" \
      GIT_CONFIG_VALUE_0=https://github.com/tacplus-dev/fleet-seatrials.git \
      GCP_ID_TOKEN=the-jobs-id-token GCP_WIF_PROVIDER=projects/1/locations/global/workloadIdentityPools/p/providers/g \
      TACPLUS_READER_KMS_KEY=projects/p/locations/us/keyRings/looper/cryptoKeys/tacplus-reader \
      TACPLUS_READER_SA=reader@p.iam.gserviceaccount.com \
      TACPLUS_READER_APP_ID=4242 TACPLUS_READER_INSTALLATION_ID=777 "${envs[@]}" \
      bash -c "set -euo pipefail; source '$work/block.sh'; $1" ) > "$work/out" 2>&1
}
b64url_decode() { local s; s=$(tr '_-' '/+' <<<"$1"); while ((${#s} % 4)); do s+="="; done; base64 -d <<<"$s"; }

if job -- 'github_fetch src refs/heads/main; git -C src rev-parse HEAD; env | grep -c ghs_ || true; echo "set:${TACPLUS_READER_TOKEN:-}"'; then
  [ "$("$real_git" -C "$work/job/src" rev-parse HEAD)" = "$("$real_git" -C "$work/up" rev-parse HEAD)" ] &&
    ok "github_fetch checks out main's head" || fail "github_fetch: not main's head: $(cat "$work/out")"
  [ "$(cat "$work/log/oidc-token")" = the-jobs-id-token ] &&
    grep -q '^gcloud iam workload-identity-pools create-cred-config projects/1/locations/global/workloadIdentityPools/p/providers/g ' "$work/log/gcloud" &&
    ! grep -q -- '--service-account' "$work/log/gcloud" &&
    ok "the job's id_token is exchanged through WIF, as itself" || fail "WIF: $(cat "$work/log/gcloud")"
  [ "$(cat "$work/log/kms-url")" = https://cloudkms.googleapis.com/v1/projects/p/locations/us/keyRings/looper/cryptoKeys/tacplus-reader/cryptoKeyVersions/1:asymmetricSign ] &&
    [ "$(cat "$work/log/kms-as")" = ya29.direct-stub-token ] &&
    ok "KMS signs with the tacplus-reader key, version 1, asked as the job itself" ||
    fail "KMS: $(cat "$work/log/kms-url" "$work/log/kms-as")"
  input=$(cat "$work/log/signed")
  [ "$(openssl dgst -sha256 -binary "$work/log/signed" | od -An -tx1)" = "$(od -An -tx1 < "$work/log/kms-digest")" ] &&
    ok "KMS is given the JWT's SHA-256 digest alone" || fail "the digest KMS signed: $(cat "$work/log/kms-body")"
  header=$(b64url_decode "${input%%.*}"); payload=$(b64url_decode "${input#*.}")
  jq -e '.alg == "RS256"' <<<"$header" >/dev/null &&
    jq -e '.iss == "4242" and (.exp - .iat) <= 600 and .iat <= now and .exp > now' <<<"$payload" >/dev/null &&
    ok "the app's JWT: RS256, the app's id, under ten minutes" || fail "the JWT: $header $payload"
  url=$(cat "$work/log/curl"); body=$(cat "$work/log/github-body")
  [ "$url" = https://api.github.com/app/installations/777/access_tokens ] &&
    jq -e '. == {"permissions":{"contents":"read"},"repositories":["fleet-seatrials"]}' <<<"$body" >/dev/null &&
    ok "the token asked for: contents read, on fleet-seatrials alone" || fail "the token request: $url $body"
  grep -qx username=x-access-token "$work/log/credential" &&
    grep -qx password=ghs_stubreadertoken0123456789 "$work/log/credential" &&
    [ "$(cat "$work/log/git-env")" = ghs_stubreadertoken0123456789 ] &&
    ok "git gets the token for github.com" || fail "git's credential: $(cat "$work/log/credential")"
  grep -qx 0 "$work/out" && grep -qx 'set:' "$work/out" &&
    ok "the job keeps no token after the fetch" || fail "the token outlives the fetch: $(cat "$work/out")"
else
  fail "github_fetch main: $(cat "$work/out")"
fi

job -- "github_fetch src $first" && [ "$("$real_git" -C "$work/job/src" rev-parse HEAD)" = "$first" ] &&
  ok "github_fetch checks out an exact commit" || fail "github_fetch a commit: $(cat "$work/out")"
job -- "github_fetch src refs/heads/main" && [ "$("$real_git" -C "$work/job/src" rev-list --count HEAD)" = 1 ] &&
  ok "github_fetch fetches that commit alone" || fail "github_fetch, its depth: $(cat "$work/out")"
job FLEET_FETCH_HISTORY=1 -- "github_fetch src refs/heads/main" && [ "$("$real_git" -C "$work/job/src" rev-list --count HEAD)" = 2 ] &&
  ok "with FLEET_FETCH_HISTORY=1, its whole history (the security job's gitleaks)" ||
  fail "github_fetch FLEET_FETCH_HISTORY=1: $(cat "$work/out")"

# KMS's refusals (#30): its HTTP status and error are in the log, never a
# token or the request.
secret='ya29\.|ghs_|the-jobs-id-token|"digest"'
job KMS_DIRECT=403 TACPLUS_READER_SA= -- 'github_fetch src refs/heads/main' && fail "KMS refused, yet the fetch went on" ||
  { [ ! -e "$work/log/curl" ] && [ ! -d "$work/job/src" ] &&
    grep -q 'Cloud KMS refused to sign with projects/p/locations/us/keyRings/looper/cryptoKeys/tacplus-reader as the job itself: HTTP 403 PERMISSION_DENIED: Permission .cloudkms.cryptoKeyVersions.useToSign. denied' "$work/out" &&
    ok "a KMS refusal fails the job before GitHub, with KMS's status and error" || fail "a KMS refusal: $(cat "$work/out")"; }
! grep -qE "$secret" "$work/out" && ok "a KMS refusal logs no token and no request" || fail "a KMS refusal logs: $(cat "$work/out")"
job KMS_DIRECT=502 TACPLUS_READER_SA= -- 'github_fetch src refs/heads/main' && fail "KMS failed, yet the fetch went on" ||
  { grep -q 'HTTP 502 <html>error 502</html>' "$work/out" && ok "a KMS answer that is not JSON is shown as is" ||
    fail "a KMS 502: $(cat "$work/out")"; }
job STS_REFUSE=1 -- 'github_fetch src refs/heads/main' && fail "WIF refused, yet the fetch went on" ||
  { [ ! -e "$work/log/kms-url" ] && grep -q 'Workload Identity Federation refused this job.*invalid_grant: The audience' "$work/out" &&
    ! grep -qE "$secret" "$work/out" &&
    ok "a refused token exchange says why, before KMS" || fail "a refused exchange: $(cat "$work/out")"; }

# Direct federation refused: the job signs as the service account it may
# impersonate, TACPLUS_READER_SA.
if job KMS_DIRECT=403 -- 'github_fetch src refs/heads/main'; then
  [ "$("$real_git" -C "$work/job/src" rev-parse HEAD)" = "$("$real_git" -C "$work/up" rev-parse HEAD)" ] &&
    ok "direct federation refused: github_fetch through the service account checks out main's head" ||
    fail "impersonation: not main's head: $(cat "$work/out")"
  grep -q -- 'create-cred-config projects/1/locations/global/workloadIdentityPools/p/providers/g --service-account=reader@p.iam.gserviceaccount.com ' "$work/log/gcloud" &&
    [ "$(cat "$work/log/kms-as")" = "$(printf 'ya29.direct-stub-token\nya29.sa-stub-token-reader@p.iam.gserviceaccount.com')" ] &&
    ok "KMS is asked as the job, then as reader@p.iam.gserviceaccount.com" || fail "impersonation: $(cat "$work/log/gcloud" "$work/log/kms-as")"
  grep -q 'as the job itself: HTTP 403 PERMISSION_DENIED' "$work/out" &&
    grep -q 'signing as the service account reader@p.iam.gserviceaccount.com' "$work/out" && ! grep -qE "$secret" "$work/out" &&
    ok "the log says direct federation was refused, and why" || fail "impersonation's log: $(cat "$work/out")"
else
  fail "github_fetch through the service account: $(cat "$work/out")"
fi
job KMS_DIRECT=403 KMS_SA=403 -- 'github_fetch src refs/heads/main' && fail "KMS refused both, yet the fetch went on" ||
  { [ ! -e "$work/log/curl" ] && grep -q 'as the job itself: HTTP 403' "$work/out" &&
    grep -q 'as reader@p.iam.gserviceaccount.com: HTTP 403 PERMISSION_DENIED' "$work/out" &&
    ok "both refused: the job fails before GitHub, with both errors" || fail "both refused: $(cat "$work/out")"; }
job KMS_DIRECT=404 -- 'github_fetch src refs/heads/main' && fail "no key version, yet the fetch went on" ||
  { grep -q 'HTTP 404 NOT_FOUND' "$work/out" && ! grep -q -- --service-account "$work/log/gcloud" &&
    ok "a refusal that is not about the caller is not retried as the service account" || fail "a 404: $(cat "$work/out")"; }

job GITHUB_REFUSE=1 -- 'github_fetch src refs/heads/main' && fail "GitHub refused, yet the fetch went on" ||
  { [ ! -d "$work/job/src" ] && grep -q 'GitHub refused the tacplus-reader app a token for fleet-seatrials: HTTP 404 Not Found' "$work/out" &&
    ! grep -qE "$secret" "$work/out" &&
    ok "GitHub's refusal fails the job, with GitHub's status and message" || fail "GitHub's refusal: $(cat "$work/out")"; }
job STALE=github_pat_11AAAAAAA0stored -- 'github_fetch src refs/heads/main' && fail "a stored token was not refused" ||
  { [ ! -e "$work/log/gcloud" ] && grep -q STALE "$work/out" &&
    ok "a job holding a stored GitHub token is refused" || fail "a stored token: $(cat "$work/out")"; }
job -- 'unset GCP_ID_TOKEN; github_fetch src refs/heads/main' && fail "no id_token, yet a fetch" ||
  { grep -q GCP_ID_TOKEN "$work/out" && ok "no id_token: refused" || fail "no id_token: $(cat "$work/out")"; }

[ "$failed" = 0 ] && echo "OK" || { echo "FAILED"; exit 1; }
