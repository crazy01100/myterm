#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
revision=3219b171cacbe011635f1c1b6c47b0725ff56d3a
if [[ $# != 1 ]]; then
    echo "Usage: bash scripts/verify-swiftterm-vendor.sh /path/to/upstream-git-checkout" >&2
    exit 64
fi
upstream="$1"
git -C "$upstream" cat-file -e "$revision^{commit}"
snapshot="$(mktemp -d "${TMPDIR:-/tmp}/myterm-swiftterm-audit.XXXXXX")"
# The directory is a freshly created, uniquely named verification snapshot.
trap 'rm -r -- "$snapshot"' EXIT
git -C "$upstream" archive "$revision" Sources/SwiftTerm LICENSE | tar -x -C "$snapshot"
vendor="$project_dir/Vendor/SwiftTerm"
diff <(cd "$snapshot" && find Sources/SwiftTerm -type f | LC_ALL=C sort) \
     <(cd "$vendor" && find Sources/SwiftTerm -type f | LC_ALL=C sort)
cmp "$snapshot/LICENSE" "$vendor/LICENSE"
while IFS= read -r file; do
    case "$file" in
        Sources/SwiftTerm/Mac/MacTerminalView.swift|Sources/SwiftTerm/Apple/AppleTerminalView.swift)
            diff -u "$snapshot/$file" "$vendor/$file" || [[ $? == 1 ]]
            ;;
        *) cmp "$snapshot/$file" "$vendor/$file" ;;
    esac
done < <(cd "$snapshot" && find Sources/SwiftTerm -type f | LC_ALL=C sort)
echo "Vendor file list, unchanged sources and license verified; review the two renderer diffs above."
