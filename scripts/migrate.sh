#!/usr/bin/env bash
# Rewrite a workflow's `uses:` lines to Chainguard Actions, pinned to a commit SHA with the version as a comment.
#
#   scripts/migrate.sh .github/workflows/pipeline-upstream.yml > hardened.yml   # report goes to stderr
#
# For each `uses: owner/repo[/path]@ref`:
#   1. the hardened repository is chainguard-actions/<owner>-<repo>
#   2. if it has the same tag, pin that tag's commit
#   3. if not (most hardened repositories have no major tags such as v7), resolve the upstream ref to its commit,
#      find the exact upstream version tag on that commit, and pin the hardened tag for that version
#   4. if the action is not in the catalog, leave the line alone and say so
# Only `git ls-remote` is used: no GitHub API calls, no token, no rate limit.
set -euo pipefail

file=${1:?usage: migrate.sh <workflow.yml>}
cache=$(mktemp -d); trap 'rm -rf "$cache"' EXIT

# All tags of a repository as "<tag> <commit>", peeled (an annotated tag resolves to the commit it points at).
tags() {
  local key; key=$(echo "$1" | tr '/' '_')
  if [ ! -f "$cache/$key" ]; then
    git ls-remote --tags "https://github.com/$1" 2>/dev/null \
      | awk '{ sub("refs/tags/", "", $2); if ($2 ~ /\^\{\}$/) { sub(/\^\{\}$/, "", $2); peeled[$2] = $1 } else plain[$2] = $1 }
             END { for (t in plain) print t, (t in peeled ? peeled[t] : plain[t]) }' > "$cache/$key" || true
  fi
  cat "$cache/$key"
}

resolve() { # <owner/repo> <ref> -> commit of that tag, or empty
  tags "$1" | awk -v r="$2" '$1 == r { print $2 }'
}

while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ ^([[:space:]]*-?[[:space:]]*uses:[[:space:]]*)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)(/[^@[:space:]]+)?@([^[:space:]#]+)(.*)$ ]]; then
    prefix=${BASH_REMATCH[1]} owner=${BASH_REMATCH[2]} repo=${BASH_REMATCH[3]} sub=${BASH_REMATCH[4]} ref=${BASH_REMATCH[5]}
    up="$owner/$repo"; hr="chainguard-actions/$owner-$repo"
    if [ "$owner" = chainguard-actions ]; then echo "$line"; continue; fi
    if [ -z "$(tags "$hr" | head -1)" ]; then
      echo "MISSING  $up@$ref: not in the catalog; request it at https://github.com/chainguard-actions/.github/issues/new?template=new-action.yml" >&2
      echo "$line"; continue
    fi
    version=$ref sha=$(resolve "$hr" "$ref")
    if [ -z "$sha" ]; then
      # The hardened repo has no tag "$ref": find the exact version upstream's "$ref" points at.
      upc=$(resolve "$up" "$ref")
      version=$(tags "$up" | awk -v c="$upc" '$2 == c && $1 ~ /^v?[0-9]+\.[0-9]+\.[0-9]+$/ { print $1 }' | sort -V | tail -1)
      [ -n "$version" ] && sha=$(resolve "$hr" "$version")
      if [ -z "$sha" ]; then
        echo "NO-MATCH $up@$ref (upstream ${upc:0:12} = ${version:-no version tag}): no hardened tag for that version; pick one by hand" >&2
        echo "$line"; continue
      fi
      echo "RESOLVED $up@$ref -> $version -> $hr@${sha:0:12}" >&2
    else
      echo "PINNED   $up@$ref -> $hr@${sha:0:12}" >&2
    fi
    echo "${prefix}${hr}${sub}@${sha} # ${version}"
  else
    echo "$line"
  fi
done < "$file"
