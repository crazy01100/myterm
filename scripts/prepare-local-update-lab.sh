#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
lab_root="$project_dir/build/update-lab"
feed_dir="$lab_root/feed"
beta1_app="$lab_root/beta1/MyTerm.app"
beta2_app="$lab_root/beta2/MyTerm.app"
build_state_file="$lab_root/.last-build-number"
public_key_file="$project_dir/Config/Release/SparklePublicKey.txt"
sparkle_account="MyTerm.Release.ed25519"
port="${MYTERM_UPDATE_LAB_PORT:-48123}"
base_url="http://127.0.0.1:$port"
beta1_version="1.0.0-beta.1"
beta2_version="1.0.0-beta.2"
beta1_build="20260810050100"
beta2_build="20260810050200"

[[ -f "$public_key_file" ]] || { print -u2 -- "缺少正式 Sparkle 公鑰。"; exit 66; }
[[ "$port" =~ '^[1-9][0-9]{3,4}$' ]] || { print -u2 -- "本機測試連接埠格式錯誤：$port"; exit 64; }
public_key="$(/usr/bin/tr -d '\r\n' < "$public_key_file")"

if [[ -d "$lab_root" ]]; then
    /bin/chmod -R u+w "$lab_root"
    /bin/rm -rf -- "$lab_root"
fi
/bin/mkdir -p "$feed_dir" "${beta1_app:h}" "${beta2_app:h}"

common_arguments=(
    --sparkle-feed-url "$base_url/appcast.xml"
    --sparkle-public-key "$public_key"
    --update-lab
    --allow-loopback-http-feed
    --build-state-file "$build_state_file"
)

"$project_dir/scripts/build-app.sh" \
    --version "$beta1_version" \
    --build "$beta1_build" \
    --build-date "2026-08-10 本機更新實驗室 beta.1" \
    --app-output "$beta1_app" \
    "${common_arguments[@]}"
"$project_dir/scripts/verify-app.sh" \
    --app "$beta1_app" --version "$beta1_version" --build "$beta1_build"

"$project_dir/scripts/build-app.sh" \
    --version "$beta2_version" \
    --build "$beta2_build" \
    --build-date "2026-08-10 本機更新實驗室 beta.2" \
    --app-output "$beta2_app" \
    "${common_arguments[@]}"
"$project_dir/scripts/verify-app.sh" \
    --app "$beta2_app" --version "$beta2_version" --build "$beta2_build"

"$project_dir/scripts/package-app.sh" \
    --version "$beta2_version" \
    --build "$beta2_build" \
    --app "$beta2_app" \
    --output "$feed_dir"

archive_name="MyTerm-$beta2_version-build-$beta2_build-arm64.zip"
/bin/cp \
    "$project_dir/Resources/UpdateLab/1.0.0-beta.2.md" \
    "$feed_dir/${archive_name:r}.md"

generate_appcast="$project_dir/.build-app/artifacts/sparkle/Sparkle/bin/generate_appcast"
sign_update="$project_dir/.build-app/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$generate_appcast" && -x "$sign_update" ]] || {
    print -u2 -- "找不到 Sparkle 發布工具。"
    exit 66
}

"$generate_appcast" \
    --account "$sparkle_account" \
    --download-url-prefix "$base_url/" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    "$feed_dir"
"$sign_update" --account "$sparkle_account" --verify "$feed_dir/appcast.xml"

enclosure_version="$(/usr/bin/xmllint --xpath "string(//*[local-name()='version'])" "$feed_dir/appcast.xml")"
short_version="$(/usr/bin/xmllint --xpath "string(//*[local-name()='shortVersionString'])" "$feed_dir/appcast.xml")"
download_url="$(/usr/bin/xmllint --xpath "string(//*[local-name()='enclosure']/@url)" "$feed_dir/appcast.xml")"
signature="$(/usr/bin/xmllint --xpath "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$feed_dir/appcast.xml")"

[[ "$enclosure_version" == "$beta2_build" ]] || { print -u2 -- "appcast Build 不正確。"; exit 1; }
[[ "$short_version" == "$beta2_version" ]] || { print -u2 -- "appcast 版本不正確。"; exit 1; }
[[ "$download_url" == "$base_url/$archive_name" ]] || { print -u2 -- "appcast 下載網址不正確。"; exit 1; }
[[ -n "$signature" ]] || { print -u2 -- "appcast 缺少 Ed25519 更新簽章。"; exit 1; }

for app in "$beta1_app" "$beta2_app"; do
    plist="$app/Contents/Info.plist"
    [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist")" == "tw.local.MySSHClient.UpdateLab" ]]
    [[ "$(/usr/bin/plutil -extract MyTermApplicationSupportDirectory raw "$plist")" == "MyTerm Update Lab" ]]
    [[ "$(/usr/bin/plutil -extract MyTermUpdateLabMode raw "$plist")" == "true" ]]
    [[ ! -e "$app/Contents/Resources/MyTermCloudConfig.plist" ]]
    [[ ! -e "$app/Contents/Resources/GoogleService-Info.plist" ]]
done

print -r -- "本機更新實驗室已準備完成。"
print -r -- "beta.1：$beta1_app"
print -r -- "beta.2：$beta2_app"
print -r -- "feed：$feed_dir/appcast.xml"
print -r -- "網址：$base_url/appcast.xml"
