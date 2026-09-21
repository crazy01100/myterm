#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
test_dir="$(mktemp -d /private/tmp/MyTerm-snippet-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
cd "$project_dir"
swiftc -swift-version 5 -parse-as-library \
 Sources/MySSHClient/Models/CommandSnippet.swift \
 Sources/MySSHClient/Models/CommandSnippetSync.swift \
 Sources/MySSHClient/Models/TerminalSessionState.swift \
 Sources/MySSHClient/Models/TerminalSessionPresentation.swift \
 Sources/MySSHClient/Services/AppPaths.swift \
 Sources/MySSHClient/Services/AppShortcutStore.swift \
 Sources/MySSHClient/Services/CommandSnippetStore.swift \
 SelfTests/CommandSnippetTests.swift -o "$test_dir/tests"
"$test_dir/tests"
