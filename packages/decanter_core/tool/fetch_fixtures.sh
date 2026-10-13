#!/usr/bin/env bash
# Fetches real SillyTavern-produced files for the regression tests.
#
# These fixtures are deliberately NOT committed to this repository. They are
# AGPL-3.0 content owned by the SillyTavern project, so we pull them from the
# source at test time rather than redistributing them here. The fixture tests
# skip themselves when the files are absent, so a checkout without network
# access still runs green.
set -euo pipefail

BASE="https://raw.githubusercontent.com/SillyTavern/SillyTavern/release/default/content"
DIR="$(cd "$(dirname "$0")/.." && pwd)/testdata/real"
FILES=(default_Seraphina.png Eldoria.json)

mkdir -p "$DIR"

for f in "${FILES[@]}"; do
  if [ -s "$DIR/$f" ]; then
    echo "already have $f"
    continue
  fi
  echo "fetching $f"
  # -4 because this dev VM has a broken IPv6 path that hangs intermittently.
  curl -4 -sSL --retry 3 --retry-delay 2 -m 180 -o "$DIR/$f" "$BASE/$f"
done

ls -lh "$DIR"
