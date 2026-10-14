#!/bin/sh
# Prints what the accent matcher makes of real photographs.
#
#     Tests/run-accent-probe.sh NeoWallpaper/*.jpg
#
# Compiles the shipping matcher together with the shipping accent definitions,
# so what it reports is what the app would decide.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
xcrun swiftc \
  -O \
  -parse-as-library \
  -o "$out/accent-probe" \
  "$root/OmnivoxNeoShared/AccentChoice.swift" \
  "$root/OmnivoxNeo/Services/WallpaperAccentSuggestion.swift" \
  "$root/Tests/AccentSuggestionProbe.swift"

"$out/accent-probe" "$@"
