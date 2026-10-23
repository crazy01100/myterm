#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-file-drop-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swift build -c debug --target SwiftTerm
terminal_build_dir="$(swift build -c debug --show-bin-path)"
swiftc -swift-version 5 -parse-as-library \
    -I "$terminal_build_dir/Modules" \
    Sources/MySSHClient/Models/LocalTerminalFileDrop.swift \
    Sources/MySSHClient/Models/CommandSnippet.swift \
    Sources/MySSHClient/Views/SnippetGuardedTerminalView.swift \
    Sources/MySSHClient/Views/FileDropTerminalView.swift \
    SelfTests/LocalTerminalFileDropTests.swift \
    "$terminal_build_dir"/SwiftTerm.build/*.o \
    -o "$test_dir/LocalTerminalFileDropTests"
"$test_dir/LocalTerminalFileDropTests"
