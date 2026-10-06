#!/usr/bin/env bash
# List the upstream actions that hardened composite actions still call inside, at any depth, and print the
# allowlist patterns that a repository restricted to `chainguard-actions/*` also needs. GitHub resolves every nested
# action when a job is set up, even for a step that never runs, so a missing one fails the job at "Set up job".
#
#   scripts/nested.sh .github/workflows/pipeline-hardened.yml
# Reads action.yml files from raw.githubusercontent.com: no API calls, no token. `chainctl actions discover --recursive`
# gives the same graph with more detail.
set -euo pipefail

seen=$(mktemp); out=$(mktemp); trap 'rm -f "$seen" "$out"' EXIT

action_file() { # <owner/repo[/path]> <sha>: print the action definition
  local repo path; repo=$(echo "$1" | cut -d/ -f1-2); path=$(echo "$1" | cut -d/ -f3-)
  for f in action.yml action.yaml; do
    curl -sfL "https://raw.githubusercontent.com/$repo/$2/${path:+$path/}$f" && return 0
  done
  return 0
}

walk() { # <owner/repo[/path]@sha> <depth>
  local ref=$1 depth=$2
  grep -qxF "$ref" "$seen" && return 0
  echo "$ref" >> "$seen"
  local name=${ref%@*} sha=${ref##*@}
  { action_file "$name" "$sha" | grep -oE '^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*[^#[:space:]]+([[:space:]]*#.*)?' || true; } \
    | sed -E 's/^[[:space:]]*(-[[:space:]]*)?uses:[[:space:]]*//; s/[[:space:]]*#.*(v[0-9][0-9.]*).*$/ \1/; s/[[:space:]]*#.*$//' \
    | while read -r inner comment; do
      case $inner in ./*|docker://*) continue ;; esac
      if [[ $inner != chainguard-actions/* ]]; then
        printf "%s\t%s\t%s\t%s\n" "$depth" "$inner" "${comment:--}" "$name" >> "$out"
      fi
      walk "$inner" $((depth + 1))
    done
}

{ grep -hoE 'uses:[[:space:]]*chainguard-actions/[^[:space:]#]+' "$@" || true; } | sed -E 's/uses:[[:space:]]*//' | sort -u | while read -r ref; do
  walk "$ref" 1
done

if [ ! -s "$out" ]; then echo "No nested upstream actions: chainguard-actions/* is enough."; exit 0; fi
printf "%-6s %-74s %-9s %s\n" DEPTH "NESTED UPSTREAM ACTION" VERSION "CALLED BY"
sort -u "$out" | while IFS=$'\t' read -r d ref c v; do printf "%-6s %-74s %-9s %s\n" "$d" "$ref" "$c" "$v"; done
echo
echo "Allowlist patterns (Settings > Actions > General > Allow select actions):"
echo "  chainguard-actions/*"
cut -f2 "$out" | sort -u | sed 's/^/  /'
