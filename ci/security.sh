#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# The security job (#36; tacplus-dev/looper#49's floor, which tacplus-dev/build's
# checks never reach here): this pipeline applies with seatrials' live deploy
# secrets, so its own supply chain is checked on every pipeline.
#
#   OSV-Scanner   the tree's dependency manifests and lock files, at HEAD
#   govulncheck   -mode=binary, every pinned tool binary the pipeline runs (bin/, ci/tools.sh)
#   gitleaks      the history and the tree at HEAD, with .gitleaks.toml and .gitleaksignore
#   Trivy         the CI image the jobs run in (every `image:` of ci/*.gitlab-ci.yml), for this platform
#
# The policy, looper-scan's: any secret fails, and so does a HIGH or CRITICAL
# finding with a fixed version, unless an unexpired entry of
# security-exceptions.yaml accepts it (by its id or an alias). An entry has
# exactly id, reason, decided_by and expires (YYYY-MM-DD); one that has expired,
# or says less or more, fails, and so does a tool that cannot run. The JSON
# report, every finding with whether it fails or is accepted, is
# $SECURITY_OUT/report.json (the job's artifact; raw/ has each tool's own).
#
#   ci/security.sh [REPO]   # needs git, jq, yq and the pinned scanners (ci/tools.sh builds them into bin/)
#
# SECURITY_OUT (default REPO/security), SECURITY_BIN (default REPO/bin) and
# SECURITY_IMAGES (default the CI images above, one per line) override what it reads and writes.
set -uo pipefail
repo=$(cd "${1:-$(dirname "$0")/..}" && pwd)
out=${SECURITY_OUT:-$repo/security}
bin=${SECURITY_BIN:-$repo/bin}
rm -rf "$out" && mkdir -p "$out/raw" "$out/norm" || exit 1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
today=${started%%T*}
commit=$(git -C "$repo" rev-parse HEAD) || exit 1
problems=()
problem() { problems+=("$1"); echo "security: $1" >&2; }
need() { command -v "$1" >/dev/null || { problem "$1: not installed (ci/tools.sh)"; return 1; }; }
for t in git jq yq; do command -v "$t" >/dev/null || { echo "security: $t is not installed" >&2; exit 1; }; done

# The committed tree at HEAD (an uncommitted file, such as the git-ignored
# deploy/bootstrap/crypto.yaml, is never scanned or reported).
tree=$work/tree
mkdir -p "$tree" && git -C "$repo" archive HEAD | tar -x -C "$tree" || exit 1

# A finding, normalized as looper-scan's: {tool, kind (sca|secret), id,
# aliases, severity, fix, where, title}.
JQ_LIB='
def bucket: if . == null then "UNKNOWN" elif . >= 9 then "CRITICAL" elif . >= 7 then "HIGH"
  elif . >= 4 then "MEDIUM" elif . > 0 then "LOW" else "UNKNOWN" end;
def finding($tool; $kind; $id; $aliases; $sev; $fix; $where; $title):
  {tool: $tool, kind: $kind, id: $id, aliases: ($aliases // [] | map(select(. != $id)) | unique),
   severity: $sev, fix: $fix, where: $where, title: ($title // "" | tostring | .[0:300])};
'
norm() { # name jq-program raw [jq args...]
  local name=$1 prog=$2 raw=$3; shift 3
  jq -s "$@" "$JQ_LIB $prog" "$raw" > "$out/norm/$name.json" || problem "$name: its report could not be read"
}

# OSV-Scanner: the manifests and lock files of the tree (exit 1: found some; 128: no manifest).
if need osv-scanner; then
  rc=0
  osv-scanner scan source -r --no-call-analysis=all --format json --output-file "$out/raw/osv-scanner.json" "$tree" \
    >/dev/null 2>"$out/raw/osv-scanner.log" || rc=$?
  case $rc in
    0|1) norm osv-scanner '
           [.[0].results[]? | (.source.path | ltrimstr($root + "/")) as $where | .packages[]? | .package as $p
            | (.vulnerabilities // []) as $vs | .groups[]? | . as $g
            | ([$vs[] | select(.id as $i | $g.ids | index($i)) | .affected[]?.ranges[]?.events[]? | .fixed // empty] | length > 0) as $fix
            | finding("osv-scanner"; "sca"; $g.ids[0]; ($g.aliases + $g.ids);
                      ($g.max_severity | if . == null or . == "" then null else tonumber end | bucket);
                      $fix; ($p.name + "@" + ($p.version // "") + " (" + $where + ")");
                      ([$vs[] | select(.id == $g.ids[0]) | .summary // empty][0]))]' \
           "$out/raw/osv-scanner.json" --arg root "$tree" ;;
    128) echo '[]' > "$out/norm/osv-scanner.json" ;;
    *) problem "osv-scanner exited $rc: $(grep -m1 -i error "$out/raw/osv-scanner.log")" ;;
  esac
fi

# govulncheck: each pinned binary, the vulnerable symbols it holds.
binaries=()
while IFS= read -r b; do binaries+=("$b"); done < <(find "$bin" -maxdepth 1 -type f -perm -u+x 2>/dev/null | LC_ALL=C sort)
((${#binaries[@]})) || problem "no pinned tool binaries in ${bin#"$repo"/}/ to check (ci/tools.sh builds them)"
if need govulncheck; then
  for b in "${binaries[@]}"; do
    name=${b##*/}
    if ! govulncheck -mode=binary -format json "$b" > "$out/raw/govulncheck-$name.json" 2>"$out/raw/govulncheck-$name.log"; then
      problem "govulncheck: ${b#"$repo"/}: $(grep -m1 . "$out/raw/govulncheck-$name.log")"; continue
    fi
    norm "govulncheck-$name" '
      ([.[] | .osv // empty | {(.id): .}] | add // {}) as $osv
      | [.[] | .finding // empty | select(.trace[0].function != null)] | unique_by(.osv)
      | map(.trace[0] as $t
        | finding("govulncheck"; "sca"; .osv; ($osv[.osv].aliases // []); "HIGH"; ((.fixed_version // "") != "");
                  ($where + " (" + ($t.module // "") + "@" + ($t.version // "") + ", " + ($t.package // "") + "." + ($t.function // "") + ")");
                  $osv[.osv].summary))' \
      "$out/raw/govulncheck-$name.json" --arg where "${b#"$repo"/}"
  done
fi

# gitleaks: the history (each commit's additions) and the tree at HEAD.
if need gitleaks; then
  for scan in history tree; do
    rc=0
    if [ "$scan" = history ]; then
      gitleaks git --no-banner --redact --exit-code 0 --config "$repo/.gitleaks.toml" -f json -r "$out/raw/gitleaks-$scan.json" "$repo" \
        >/dev/null 2>"$out/raw/gitleaks-$scan.log" || rc=$?
    else
      gitleaks dir --no-banner --redact --exit-code 0 --config "$repo/.gitleaks.toml" -f json -r "$out/raw/gitleaks-$scan.json" "$tree" \
        >/dev/null 2>"$out/raw/gitleaks-$scan.log" || rc=$?
    fi
    [ "$rc" = 0 ] || { problem "gitleaks ($scan) exited $rc: $(tail -1 "$out/raw/gitleaks-$scan.log")"; continue; }
    norm "gitleaks-$scan" '
      [.[0][]? | (.File | ltrimstr($root + "/")) as $f
       | (if $scan == "history" then .Fingerprint else $f + ":" + .RuleID + ":" + (.StartLine | tostring) end) as $id
       | finding("gitleaks"; "secret"; $id; [.RuleID]; "CRITICAL"; true;
                 (if $scan == "history" then "commit " + .Commit[0:12] + ": " else "HEAD: " end) + $f + ":" + (.StartLine | tostring);
                 .Description)]' \
      "$out/raw/gitleaks-$scan.json" --arg root "$tree" --arg scan "$scan"
  done
fi

# Trivy: the CI image, as this platform's jobs run it.
images=()
if [ -n "${SECURITY_IMAGES+set}" ]; then
  while IFS= read -r i; do [ -z "$i" ] || images+=("$i"); done <<<"$SECURITY_IMAGES"
else
  while IFS= read -r i; do [ -z "$i" ] || images+=("$i"); done < <(
    yq -N '.. | select(tag == "!!map" and has("image")) | .image | select(tag == "!!str")' "$tree"/ci/*.gitlab-ci.yml | LC_ALL=C sort -u)
fi
((${#images[@]})) || problem "no CI image to check in ci/*.gitlab-ci.yml"
case $(uname -m) in aarch64|arm64) platform=linux/arm64 ;; *) platform=linux/amd64 ;; esac
if need trivy; then
  n=0
  for i in "${images[@]}"; do
    n=$((n + 1)); rc=0
    trivy image -q --scanners vuln --platform "$platform" --format json -o "$out/raw/trivy-$n.json" "$i" \
      2>"$out/raw/trivy-$n.log" || rc=$?
    [ "$rc" = 0 ] || { problem "trivy: $i exited $rc: $(tail -1 "$out/raw/trivy-$n.log")"; continue; }
    norm "trivy-$n" '
      [.[0].Results[]? | .Target as $t | (.Vulnerabilities // [])[]
       | finding("trivy"; "sca"; .VulnerabilityID; []; (.Severity // "UNKNOWN"); ((.FixedVersion // "") != "");
                 (.PkgName + "@" + (.InstalledVersion // "") + " (" + $image + ": " + $t + ")"); .Title)]' \
      "$out/raw/trivy-$n.json" --arg image "$i"
  done
fi

# The exceptions: exactly id, reason, decided_by and expires (YYYY-MM-DD), each unexpired.
exceptions='[]'
if [ -f "$tree/security-exceptions.yaml" ]; then
  if ! exceptions=$(yq -o=json '.' "$tree/security-exceptions.yaml" 2>"$work/exc.err" |
                    jq -c 'if type == "object" and (keys == ["exceptions"]) and (.exceptions | type == "array" or . == null)
                           then .exceptions // [] else error("it is not a list exceptions:") end' 2>>"$work/exc.err"); then
    problem "security-exceptions.yaml: $(grep -m1 . "$work/exc.err")"; exceptions='[]'
  fi
fi
while IFS= read -r e; do [ -z "$e" ] || problem "$e"; done < <(jq -r --arg today "$today" '.[] |
  if type != "object" then "security-exceptions.yaml: an entry that is not id, reason, decided_by and expires"
  elif (keys - ["id", "reason", "decided_by", "expires"]) != [] then
    "exception \(.id // "?"): \(keys - ["id", "reason", "decided_by", "expires"] | join(", ")): an entry has only id, reason, decided_by and expires"
  elif ([.id, .reason, .decided_by] | map(type == "string" and . != "") | all | not) then
    "exception \(.id // "?"): it needs an id, a reason and who decided (decided_by)"
  elif ((.expires | tostring) | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not) then
    "exception \(.id): expires \(.expires | tostring | @json) is not a date YYYY-MM-DD"
  elif (.expires | tostring) < $today then "exception \(.id) expired on \(.expires) (\(.decided_by): \(.reason))"
  else empty end' <<<"$exceptions")

# The policy, and the report.
norms=("$out"/norm/*.json)
[ -e "${norms[0]}" ] || norms=(/dev/null)
jq -s --argjson exc "$exceptions" --arg today "$today" '
  [.[][]] | unique_by([.tool, .id, .where]) | map(
    . as $f
    | ([$exc[] | select(type == "object" and (.expires | tostring) >= $today
                        and (.id as $x | $f.id == $x or any($f.aliases[]; . == $x)))][0]) as $e
    | . + {excepted: ($e.id // null),
           blocking: ($e == null and (.kind == "secret" or ((.severity == "HIGH" or .severity == "CRITICAL") and .fix)))})
  | sort_by(if .blocking then 0 else 1 end, {"CRITICAL": 0, "HIGH": 1, "MEDIUM": 2, "LOW": 3}[.severity] // 4, .tool, .id, .where)' \
  "${norms[@]}" > "$work/findings.json" || { problem "the findings could not be read together"; echo '[]' > "$work/findings.json"; }

blocking=$(jq '[.[] | select(.blocking)] | length' "$work/findings.json")
if ((${#problems[@]})); then verdict="fail: ${problems[0]}$( ((${#problems[@]} > 1)) && echo " (and $((${#problems[@]} - 1)) more)")"
elif ((blocking)); then verdict="fail: $blocking finding(s) the policy fails: $(jq -r '[.[] | select(.blocking) | .id][0:3] | join(", ")' "$work/findings.json")"
else verdict=pass; fi

version() { "$@" 2>/dev/null | grep -m1 . || true; }
jq -n --arg commit "$commit" --arg started "$started" --arg verdict "$verdict" --arg platform "$platform" \
  --slurpfile findings "$work/findings.json" \
  --argjson problems "$(printf '%s\n' "${problems[@]+"${problems[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')" \
  --argjson images "$(printf '%s\n' "${images[@]+"${images[@]}"}" | jq -R . | jq -sc 'map(select(. != ""))')" \
  --argjson binaries "$(for b in "${binaries[@]+"${binaries[@]}"}"; do echo "${b#"$repo"/}"; done | jq -R . | jq -sc .)" \
  --arg osv "$(version osv-scanner --version)" --arg govulncheck "$(version govulncheck -version)" \
  --arg gitleaks "$(version gitleaks version)" --arg trivy "$(version trivy version)" '
  {commit: $commit, started: $started, verdict: $verdict, problems: $problems,
   tools: {"osv-scanner": $osv, govulncheck: $govulncheck, gitleaks: $gitleaks, trivy: $trivy},
   images: $images, platform: $platform, binaries: $binaries, findings: $findings[0]}' > "$out/report.json"

# The summary: what fails, what is accepted, and why.
jq -r '"\(.findings | length) finding(s): \([.findings[] | select(.blocking)] | length) failing the policy, \([.findings[] | select(.excepted)] | length) accepted by security-exceptions.yaml; checked \(.binaries | length) binaries and \(.images | join(", ")) (\(.platform))",
       (.problems[] | "problem: \(.)"),
       (.findings[] | select(.blocking) | "FAIL \(.severity) \(.tool) \(.id): \(.where)\(if .title != "" then ": " + .title else "" end)"),
       (.findings[] | select(.excepted) | "accepted \(.excepted): \(.tool) \(.id) \(.where)")' "$out/report.json"
if [ "$verdict" = pass ]; then echo "security verdict: pass ($commit)"; exit 0; fi
echo "security verdict: FAIL: ${verdict#fail: } (${out#"$repo"/}/report.json)"
exit 1
