#!/usr/bin/env bash
# Check every Chainguard Actions pin in the given workflows:
#   pin       the reference is a full 40-character commit SHA (anything else is mutable)
#   tag       whether the version in the comment still points at that SHA. Chainguard re-hardens versions in place
#             and moves the tag, so "moved" means a newer hardening exists: Dependabot will propose it
#   files     every file in the action at that SHA matches the SHA-256 digests in its signed SLSA provenance
#             (attestations/provenance.intoto.jsonl). The DSSE signature itself cannot be checked yet: Chainguard
#             has not published the signing key. This proves the files are the ones the provenance describes.
#
#   scripts/verify-pins.sh .github/workflows/pipeline-hardened.yml [more.yml ...]
# Exit code 1 if any pin is not a SHA or any file does not match. A moved tag is reported, not failed.
set -uo pipefail

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
fail=0

grep -hoE 'uses:[[:space:]]*chainguard-actions/[^[:space:]]+(@[^[:space:]]+)?([[:space:]]*#[[:space:]]*[^[:space:]]+)?' "$@" \
  | sed -E 's/uses:[[:space:]]*//; s/[[:space:]]*#[[:space:]]*/ /' | sort -u > "$work/pins"

printf "%-38s %-14s %-10s %-24s %s\n" ACTION PIN VERSION TAG FILES
while read -r ref version; do
  path=${ref%@*}; sha=${ref##*@}; repo=$(echo "$path" | cut -d/ -f1-2); sub=$(echo "$path" | cut -d/ -f3-)
  if ! [[ $sha =~ ^[0-9a-f]{40}$ ]]; then
    printf "%-38s %-14s %-10s %-24s %s\n" "$path" "NOT A SHA" "${version:--}" "-" "-"; fail=1; continue
  fi
  now=$(git ls-remote "https://github.com/$repo" "refs/tags/${version}^{}" "refs/tags/${version}" | tail -1 | cut -c1-40)
  if [ -z "$version" ]; then tag="no version comment"
  elif [ "$now" = "$sha" ]; then tag="current"
  elif [ -z "$now" ]; then tag="tag not found"
  else tag="moved -> ${now:0:12}"; fi

  dir="$work/${repo//\//_}-$sha"
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" && curl -sfL "https://codeload.github.com/$repo/tar.gz/$sha" | tar -xz -C "$dir" --strip-components 1
  fi
  base="$dir${sub:+/$sub}"; prov="$base/attestations/provenance.intoto.jsonl"
  if [ ! -f "$prov" ]; then
    files="no provenance (published before signing began)"
  else
    # Executed: the action definition, its scripts and its bundled code. Not executed: docs, the action's own CI
    # workflows, tests and package manifests. Only a difference in an executed file fails the check.
    ok=0 missing=0 differs=0 bad_exec=0
    while IFS=$'\t' read -r name digest; do
      if [ ! -f "$base/$name" ]; then state=missing; missing=$((missing + 1))
      elif [ "$(sha256 "$base/$name")" != "$digest" ]; then state=differs; differs=$((differs + 1))
      else ok=$((ok + 1)); continue; fi
      if [[ $name =~ ^(action\.ya?ml|.*/action\.ya?ml|dist/.*|.*\.(sh|js|cjs|mjs|py|ps1))$ && ! $name =~ ^(\.github|tests?|__tests__)/ ]]; then
        bad_exec=$((bad_exec + 1)); echo "  EXECUTED FILE $state: $path/$name" >&2
      else
        echo "  not executed, $state: $path/$name" >&2
      fi
    done < <(tail -1 "$prov" | jq -r '.payload | @base64d | fromjson | .subject[] | "\(.name)\t\(.digest.sha256)"')
    total=$((ok + missing + differs))
    src=$(tail -1 "$prov" | jq -r '.payload | @base64d | fromjson | .predicate.buildDefinition.externalParameters.source.commit[0:12]')
    files="$ok/$total match"
    [ $((missing + differs)) -gt 0 ] && files="$files ($missing missing, $differs differ, none executed)"
    [ "$bad_exec" -gt 0 ] && { files="$ok/$total match, $bad_exec EXECUTED FILES DO NOT MATCH"; fail=1; }
    files="$files; upstream $src"
  fi
  printf "%-38s %-14s %-10s %-24s %s\n" "$path" "${sha:0:12}" "${version:--}" "$tag" "$files"
done < "$work/pins"
exit $fail
