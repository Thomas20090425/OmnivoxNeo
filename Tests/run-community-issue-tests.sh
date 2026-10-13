#!/bin/sh
# Compiles the roadmap parser straight out of the app and runs the checks
# against it, so what is tested is what ships.
#
#     Tests/run-community-issue-tests.sh
#
# Run from the repository root. Exits non-zero if anything fails.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} \
xcrun swiftc \
  -O \
  -parse-as-library \
  -o "$out/community-issue-tests" \
  "$root/OmnivoxNeo/Models/CommunityIssue.swift" \
  "$root/Tests/CommunityIssueTests.swift"

"$out/community-issue-tests"
