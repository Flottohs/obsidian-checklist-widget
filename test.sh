#!/bin/zsh
# Runs the tests in Tests/main.swift. Never touches real notes.
set -e
cd "$(dirname "$0")"
out=$(mktemp -d -t checklist-tests)
trap 'rm -rf "$out"' EXIT
swiftc -swift-version 5 Core.swift Tests/main.swift -o "$out/tests"
result=0
"$out/tests" > "$out/output" || result=$?
grep -E '^(FAILED|all [0-9]+ checks|[0-9]+ of [0-9]+ checks)' "$out/output" || cat "$out/output"
exit $result
