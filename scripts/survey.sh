#!/usr/bin/env bash
# For each upstream action: its latest release, the latest hardened tag, and what the hardened release ships.
#   scripts/survey.sh                      # the actions this repository's pipelines use
#   scripts/survey.sh owner/repo ...       # any others
# Columns: RUNS (node/composite/docker), HOOK (usage hook wired in: a JS `pre:` or a composite telemetry step),
# PROV (signed SLSA provenance file present), TESTS (Chainguard's recorded test run), FINDINGS (HARDENING.md).
# Uses the GitHub API (gh); about 8 calls per action.
set -uo pipefail

list=("$@")
[ ${#list[@]} -eq 0 ] && list=(actions/checkout actions/setup-go actions/upload-artifact docker/setup-buildx-action
  docker/login-action docker/metadata-action docker/build-push-action anchore/scan-action anchore/sbom-action
  sigstore/cosign-installer tj-actions/changed-files actions/attest-build-provenance aquasecurity/trivy-action
  zizmorcore/zizmor-action)

get() { gh api "repos/chainguard-actions/$1/contents/$2?ref=$3" --jq .content 2>/dev/null | base64 -d 2>/dev/null; }

printf "%-32s %-9s %-9s %-10s %-5s %-5s %-6s %s\n" UPSTREAM LATEST HARDENED RUNS HOOK PROV TESTS FINDINGS
for up in "${list[@]}"; do
  hr="${up%%/*}-${up#*/}"
  latest=$(gh api "repos/$up/releases/latest" --jq .tag_name 2>/dev/null || echo "-")
  tag=$(gh api "repos/chainguard-actions/$hr/tags?per_page=100" --jq '[.[].name | select(test("^v[0-9]+\\.[0-9]+"))] | first // empty' 2>/dev/null)
  if [ -z "$tag" ]; then printf "%-32s %-9s %s\n" "$up" "$latest" "not in the catalog"; continue; fi
  act=$(get "$hr" action.yml "$tag"); [ -z "$act" ] && act=$(get "$hr" action.yaml "$tag")
  runs=$(echo "$act" | awk '/^runs:/ { f = 1 } f && /using:/ { gsub(/[\r"'\'']/, "", $2); print $2; exit }')
  hook=$(echo "$act" | grep -qE 'pre: *chainguard-phonehome|Chainguard usage telemetry' && echo yes || echo no)
  prov=$(gh api "repos/chainguard-actions/$hr/contents/attestations?ref=$tag" --jq length 2>/dev/null >/dev/null && echo yes || echo no)
  tests=$(get "$hr" .actionchain/test-result.json "$tag" | jq -r 'if .ran then (if .passed then "pass" else "fail" end) else "none" end' 2>/dev/null)
  findings=$(get "$hr" HARDENING.md "$tag" | grep -oE '[0-9]+ finding\(s\)' | grep -oE '^[0-9]+')
  printf "%-32s %-9s %-9s %-10s %-5s %-5s %-6s %s\n" "$up" "$latest" "$tag" "${runs:--}" "$hook" "$prov" "${tests:-none}" "${findings:-?}"
done
