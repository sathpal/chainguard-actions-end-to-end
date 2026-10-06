#!/usr/bin/env bash
# What did hardening change in the code that runs? Clones the hardened version and the exact upstream commit it was
# built from (named in its source.json), then diffs them, leaving out Chainguard's own metadata, the action's CI
# workflows, tests and docs.
#   scripts/diff-upstream.sh sigstore/cosign-installer v4.1.2
set -euo pipefail
up=${1:?usage: diff-upstream.sh owner/repo version}; v=${2:?version}
hr="chainguard-actions/${up%%/*}-${up#*/}"
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
git clone -q --depth 1 -b "$v" "https://github.com/$hr" "$w/hardened" 2>/dev/null
commit=$(jq -r .commit_sha "$w/hardened/source.json")
git init -q "$w/upstream"
git -C "$w/upstream" fetch -q --depth 1 "https://github.com/$up" "$commit"
git -C "$w/upstream" checkout -q FETCH_HEAD
echo "hardened $hr@$v ($(git -C "$w/hardened" rev-parse --short=12 HEAD)) built from $up@${commit:0:12}"
cd "$w"
# Remove what is not executed from both trees first, so a plain `diff -r` works everywhere (BusyBox diff has no -x).
find upstream hardened \( -name .git -o -name .github -o -name .gitignore -o -name HARDENING.md -o -name LICENSE_CHAINGUARD \
  -o -name source.json -o -name attestations -o -name .actionchain -o -name tests -o -name test -o -name '*.md' \
  -o -name LICENSE \) -prune -exec rm -rf {} +
diff -r -U 3 upstream hardened && echo "no difference in executed files"
