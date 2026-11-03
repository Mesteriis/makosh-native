#!/bin/bash
# Formats or checks Swift files changed relative to a base revision.
# Only changed files are covered; untouched sources keep their history.
#   scripts/format.sh [--check] [BASE]   (BASE defaults to origin/main or HEAD)
set -euo pipefail
cd "$(dirname "$0")/.."
check=0
if [[ "${1:-}" == "--check" ]]; then check=1; shift; fi
base="${1:-}"
if [[ -z "$base" ]]; then
    if git rev-parse --verify --quiet origin/main >/dev/null; then base="origin/main"; else base="HEAD"; fi
fi
if [[ "$base" =~ ^0+$ ]] || ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "format: base revision '$base' is unavailable; checking nothing." >&2
    exit 0
fi
merge_base="$(git merge-base "$base" HEAD)"
# Added, copied, modified and edited-while-renamed files; a pure move (R100)
# keeps its formatting so history and blame follow the rename.
files=()
while IFS= read -r file; do
    [[ -n "$file" && -f "$file" ]] && files+=("$file")
done < <({ git diff --name-status -M --diff-filter=ACMR "$merge_base" -- '*.swift' \
    | awk -F '\t' '$1 != "R100" { print $NF }'; \
    git ls-files --others --exclude-standard -- '*.swift'; } | sort -u)
if [[ ${#files[@]} -eq 0 ]]; then echo "format: no changed Swift files."; exit 0; fi
formatter=(xcrun swift-format)
if [[ $check -eq 0 ]]; then
    "${formatter[@]}" format --in-place --parallel -- "${files[@]}"
    echo "format: formatted ${#files[@]} file(s)."
    exit 0
fi
status=0
for file in "${files[@]}"; do
    if ! "${formatter[@]}" format -- "$file" | cmp -s - "$file"; then
        echo "format: $file is not formatted (run scripts/format.sh $base)." >&2
        status=1
    fi
done
[[ $status -eq 0 ]] && echo "format: ${#files[@]} changed file(s) are formatted."
exit $status
