#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
dropdown_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/makosh-dropdown-tests.XXXXXX")"
trap 'rm -rf "$dropdown_test_dir"' EXIT
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    Sources/MakoshApp/MakoshDropdownNavigation.swift scripts/test-dropdown-navigation.swift \
    -o "$dropdown_test_dir/dropdown-navigation"
"$dropdown_test_dir/dropdown-navigation"
