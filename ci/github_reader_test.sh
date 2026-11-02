#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# Tests how the deploy pipeline reads this private repository (#29): only
# through the keyless tacplus-reader GitHub App, never a stored GitHub token.
# The pipeline files reference no static token, and the block that mints the
# app's token and fetches (.github-reader) is the same in both and is what
# fleet-plan and every child job run first. That block, run against a stub
# gcloud (WIF and KMS) and a stub GitHub, asks KMS to sign the app's JWT,
# asks for contents: read on this repository alone, hands the token to git
# only, and refuses a job that holds anything shaped like a GitHub token.
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
  [ "$(yq '.variables.TACPLUS_READER_KMS_KEY' "$deploy")" != null ] &&
  ok "both pipelines name the same KMS key" || fail "TACPLUS_READER_KMS_KEY is missing or differs"

# --- the block, against stubs -------------------------------------------------

# A stub gcloud: WIF (records the credential configuration it was asked for)
# and KMS (signs with a key made here, or refuses when KMS_REFUSE is set).
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
    want=output-file; echo '{"type":"external_account"}' > "\$(arg "\$@")" ;;
  "auth login") ;;
  "kms asymmetric-sign")
    [ -z "\${KMS_REFUSE:-}" ] || { echo "PERMISSION_DENIED" >&2; exit 1; }
    want=key; arg "\$@" > "$work/log/kms-key"
    want=input-file; in=\$(arg "\$@"); cp "\$in" "$work/log/jwt-input"
    want=signature-file; openssl dgst -sha256 -sign "$work/app.pem" -out "\$(arg "\$@")" "\$in" ;;
  *) echo "unexpected gcloud \$*" >&2; exit 1 ;;
esac
EOF
# A stub curl for GitHub's access_tokens: records the call and the JWT, checks
# the JWT's signature against the app's key, and answers with a token (or
# fails when GITHUB_REFUSE is set).
cat > "$work/bin/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/log/curl"
[ -z "\${GITHUB_REFUSE:-}" ] || { echo "curl: (22) The requested URL returned error: 401" >&2; exit 22; }
jwt=\$(printf '%s\n' "\$@" | sed -n 's/^Authorization: Bearer //p')
printf '%s' "\${jwt%.*}" > "$work/log/signed"
printf '%s' "\${jwt##*.}" | tr '_-' '/+' | { s=\$(cat); while ((\${#s} % 4)); do s+="="; done; printf '%s' "\$s"; } |
  base64 -d > "$work/log/sig"
openssl dgst -sha256 -verify "$work/app.pub" -signature "$work/log/sig" "$work/log/signed" >/dev/null || exit 22
printf '{\n  "token": "ghs_stubreadertoken0123456789",\n  "expires_at": "2026-11-02T01:00:00Z"\n}\n'
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
  [ "$(cat "$work/log/kms-key")" = projects/p/locations/us/keyRings/looper/cryptoKeys/tacplus-reader ] &&
    grep -q -- '--version=1 ' "$work/log/gcloud" &&
    ok "KMS signs with the tacplus-reader key" || fail "KMS: $(cat "$work/log/gcloud")"
  input=$(cat "$work/log/jwt-input")
  header=$(b64url_decode "${input%%.*}"); payload=$(b64url_decode "${input#*.}")
  jq -e '.alg == "RS256"' <<<"$header" >/dev/null &&
    jq -e '.iss == "4242" and (.exp - .iat) <= 600 and .iat <= now and .exp > now' <<<"$payload" >/dev/null &&
    ok "the app's JWT: RS256, the app's id, under ten minutes" || fail "the JWT: $header $payload"
  url=$(grep '^https://' "$work/log/curl"); body=$(sed -n '/^-d$/{n;p}' "$work/log/curl")
  [ "$url" = https://api.github.com/app/installations/777/access_tokens ] && grep -qx -- -X "$work/log/curl" &&
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

job KMS_REFUSE=1 -- 'github_fetch src refs/heads/main' && fail "KMS refused, yet the fetch went on" ||
  { [ ! -e "$work/log/curl" ] && [ ! -d "$work/job/src" ] && grep -q 'KMS' "$work/out" &&
    ok "a KMS refusal fails the job before GitHub" || fail "a KMS refusal: $(cat "$work/out")"; }
job GITHUB_REFUSE=1 -- 'github_fetch src refs/heads/main' && fail "GitHub refused, yet the fetch went on" ||
  { [ ! -d "$work/job/src" ] && grep -q 'GitHub' "$work/out" &&
    ok "GitHub's refusal fails the job" || fail "GitHub's refusal: $(cat "$work/out")"; }
job STALE=github_pat_11AAAAAAA0stored -- 'github_fetch src refs/heads/main' && fail "a stored token was not refused" ||
  { [ ! -e "$work/log/gcloud" ] && grep -q STALE "$work/out" &&
    ok "a job holding a stored GitHub token is refused" || fail "a stored token: $(cat "$work/out")"; }
job -- 'unset GCP_ID_TOKEN; github_fetch src refs/heads/main' && fail "no id_token, yet a fetch" ||
  { grep -q GCP_ID_TOKEN "$work/out" && ok "no id_token: refused" || fail "no id_token: $(cat "$work/out")"; }

[ "$failed" = 0 ] && echo "OK" || { echo "FAILED"; exit 1; }
