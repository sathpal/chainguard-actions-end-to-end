#!/usr/bin/env bash
# Regenerate pipeline-hardened.yml from pipeline-upstream.yml. Only the `uses:` lines, the name, the FLAVOR and the
# header comment change, so `diff` between the two files shows exactly what the migration did.
set -euo pipefail
cd "$(dirname "$0")/.."
src=.github/workflows/pipeline-upstream.yml
dst=.github/workflows/pipeline-hardened.yml
{
  cat <<'HEADER'
# AFTER: the same pipeline on Chainguard Actions. Generated from pipeline-upstream.yml by scripts/regen-hardened.sh
# (the one-time migration); from then on Dependabot maintains the pins. Every action is a hardened copy built from
# the exact upstream commit of that version, pinned by commit SHA with the version as a comment. Chainguard
# re-hardens versions in place and moves their tags, so the SHA is the only immutable reference; Dependabot
# (.github/dependabot.yml) proposes each new hardening as a pull request, and this pipeline tests it there.
HEADER
  scripts/migrate.sh "$src" | sed -e '1,/^name:/{/^#/d;}' \
    -e 's/^name: pipeline (upstream actions, tags)$/name: pipeline (Chainguard Actions, pinned)/' \
    -e 's/^  FLAVOR: upstream$/  FLAVOR: hardened/'
} > "$dst"
echo "wrote $dst" >&2
