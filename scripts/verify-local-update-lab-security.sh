#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
feed_dir="$project_dir/build/update-lab/feed"
archive="$feed_dir/MyTerm-1.0.0-beta.2-build-20260810050200-arm64.zip"
appcast="$feed_dir/appcast.xml"
sign_update="$project_dir/.build-app/artifacts/sparkle/Sparkle/bin/sign_update"
sparkle_account="MyTerm.Release.ed25519"
test_dir="$(mktemp -d /private/tmp/MyTerm-update-security.XXXXXX)"
trap '/bin/rm -rf -- "$test_dir"' EXIT

[[ -f "$archive" && -f "$appcast" && -x "$sign_update" ]] || {
    print -u2 -- "缺少本機更新實驗室產物。"
    exit 66
}

signature="$(/usr/bin/xmllint --xpath "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$appcast")"
[[ -n "$signature" ]] || { print -u2 -- "appcast 缺少更新簽章。"; exit 1; }

"$sign_update" --account "$sparkle_account" --verify "$archive" "$signature"
"$sign_update" --account "$sparkle_account" --verify "$appcast"

tampered_archive="$test_dir/tampered.zip"
/bin/cp "$archive" "$tampered_archive"
print -rn -- 'MyTerm tamper test' >> "$tampered_archive"
if "$sign_update" --account "$sparkle_account" --verify "$tampered_archive" "$signature" >/dev/null 2>&1; then
    print -u2 -- "安全失敗：遭竄改的 ZIP 通過驗章。"
    exit 1
fi

wrong_first_character="A"
[[ "${signature[1]}" == "A" ]] && wrong_first_character="B"
wrong_signature="$wrong_first_character${signature[2,-1]}"
if "$sign_update" --account "$sparkle_account" --verify "$archive" "$wrong_signature" >/dev/null 2>&1; then
    print -u2 -- "安全失敗：錯誤簽章通過驗證。"
    exit 1
fi

tampered_appcast="$test_dir/tampered-appcast.xml"
/bin/cp "$appcast" "$tampered_appcast"
/usr/bin/sed -i '' 's/1\.0\.0-beta\.2/1.0.0-beta.X/g' "$tampered_appcast"
if "$sign_update" --account "$sparkle_account" --verify "$tampered_appcast" >/dev/null 2>&1; then
    print -u2 -- "安全失敗：遭竄改的 appcast 通過驗章。"
    exit 1
fi

invalid_appcast="$test_dir/invalid.xml"
print -r -- '<rss><channel><item>' > "$invalid_appcast"
if /usr/bin/xmllint --noout "$invalid_appcast" >/dev/null 2>&1; then
    print -u2 -- "安全失敗：無效 XML 被視為有效。"
    exit 1
fi

print -r -- "本機更新安全負向測試通過："
print -r -- "- 原始 ZIP 與 appcast 驗章成功。"
print -r -- "- 遭竄改 ZIP、錯誤簽章與遭竄改 appcast 全部被拒絕。"
print -r -- "- 無效 XML 被拒絕。"
