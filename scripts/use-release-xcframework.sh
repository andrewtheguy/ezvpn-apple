#!/usr/bin/env bash
#
# Point Packages/Ezvpn back at the pinned release zip (url + checksum in
# Package.swift) — the reproducible mode that should be committed.
#
# Usage:
#   scripts/use-release-xcframework.sh          # keep the currently pinned tag
#   scripts/use-release-xcframework.sh v0.0.15  # also bump url+checksum to a tag
#
# Flips `useLocalXcframework` to false; with a tag argument it first delegates
# to scripts/bump-xcframework.sh to rewrite the url and checksum.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../Packages/Ezvpn/Package.swift"

die() { echo "error: $*" >&2; exit 1; }

if [ $# -ge 1 ]; then
  "$SCRIPT_DIR/bump-xcframework.sh" "$1"
fi

grep -q '^let useLocalXcframework = ' "$MANIFEST" \
  || die "marker line not found in $MANIFEST (manifest layout changed?)"

TMP="$(mktemp)"
sed 's/^let useLocalXcframework = .*/let useLocalXcframework = false/' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

grep -q '^let useLocalXcframework = false$' "$MANIFEST" \
  || die "failed to flip useLocalXcframework in $MANIFEST"

echo "Packages/Ezvpn -> RELEASE xcframework:"
grep -E 'url:|checksum: ' "$MANIFEST" | sed 's/^ */  /'
