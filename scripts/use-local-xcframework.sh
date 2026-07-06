#!/usr/bin/env bash
#
# Point Packages/Ezvpn at the locally built xcframework from the sibling repo
# (../ezvpn/dist/ios, reached via the committed symlink local/libezvpn.xcframework).
#
# This edits Package.swift (flips `useLocalXcframework` to true), so the mode is
# persistent and every tool — xcodegen, xcodebuild, the Xcode GUI — links the
# same artifact. No environment variable to forget. Switch back with
# scripts/use-release-xcframework.sh before committing/releasing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/../Packages/Ezvpn/Package.swift"
LINK="$SCRIPT_DIR/../Packages/Ezvpn/local/libezvpn.xcframework"

die() { echo "error: $*" >&2; exit 1; }

# Refuse to point at a missing/stale build: SPM's own failure mode here is a
# cryptic resolve error, and a half-present dist dir would silently link an
# old slice.
[ -e "$LINK/Info.plist" ] || die "no built xcframework at $LINK
Build it first:  (cd ../ezvpn && ./build-ios.sh release)"

grep -q '^let useLocalXcframework = ' "$MANIFEST" \
  || die "marker line not found in $MANIFEST (manifest layout changed?)"

TMP="$(mktemp)"
sed 's/^let useLocalXcframework = .*/let useLocalXcframework = true/' "$MANIFEST" > "$TMP"
mv "$TMP" "$MANIFEST"

grep -q '^let useLocalXcframework = true$' "$MANIFEST" \
  || die "failed to flip useLocalXcframework in $MANIFEST"

echo "Packages/Ezvpn -> LOCAL xcframework ($(readlink "$LINK"))"
echo "Build normally (no env var needed): xcodegen generate && xcodebuild ..."
echo "Switch back before committing/releasing: scripts/use-release-xcframework.sh [tag]"
