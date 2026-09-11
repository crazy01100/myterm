#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-key-common.sh"

assets_dir=""
version=""
build_number=""

usage() {
    cat <<'EOF'
用法：scripts/verify-release-assets.sh --assets DIR --version VERSION --build BUILD

驗證 GitHub Release 與 Cloudflare Pages 使用的完整發布資產；不會修改或上傳任何檔案。
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --assets)
            (( $# >= 2 )) || { print -u2 -- "缺少 --assets 的值"; exit 64; }
            assets_dir="$2"
            shift 2
            ;;
        --version)
            (( $# >= 2 )) || { print -u2 -- "缺少 --version 的值"; exit 64; }
            version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || { print -u2 -- "缺少 --build 的值"; exit 64; }
            build_number="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -- "未知參數：$1"
            usage >&2
            exit 64
            ;;
    esac
done

[[ -n "$assets_dir" && -d "$assets_dir" ]] || { print -u2 -- "找不到發布資產目錄。"; exit 66; }
[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' ]] || {
    print -u2 -- "版本格式不正確：$version"
    exit 65
}
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || { print -u2 -- "Build 必須是正整數：$build_number"; exit 65; }

assets_dir="${assets_dir:A}"
archive_name="MyTerm-$version-build-$build_number-arm64.zip"
archive="$assets_dir/$archive_name"
appcast="$assets_dir/appcast.xml"
notes="$assets_dir/release-notes.html"
checksums="$assets_dir/CHECKSUMS.txt"
manifest="$assets_dir/release-manifest.json"

for required_file in "$archive" "$appcast" "$notes" "$checksums" "$manifest"; do
    [[ -f "$required_file" ]] || { print -u2 -- "缺少發布資產：${required_file:t}"; exit 66; }
done
"$project_dir/scripts/security-python.sh" "$project_dir/scripts/verify-signed-release.py" \
    --assets "$assets_dir" --public-key-file "$project_dir/Config/Release/SparklePublicKey.txt" \
    --base-url "https://mtus.lieniapp.work" --version "$version" --build "$build_number"
"$project_dir/scripts/verify-packaged-resources.sh" --archive "$archive"

unexpected="$({
    find "$assets_dir" -mindepth 1 -maxdepth 1 -type f \
        ! -name "$archive_name" \
        ! -name appcast.xml \
        ! -name release-notes.html \
        ! -name CHECKSUMS.txt \
        ! -name release-manifest.json -print
    find "$assets_dir" -mindepth 1 -maxdepth 1 -type d -print
} | head -n 1)"
[[ -z "$unexpected" ]] || { print -u2 -- "發布資產目錄包含未預期項目：$unexpected"; exit 65; }

oversized="$(find "$assets_dir" -type f -size +25M -print -quit)"
[[ -z "$oversized" ]] || { print -u2 -- "Cloudflare Pages 不接受超過 25 MiB 的檔案：$oversized"; exit 65; }

if /usr/bin/grep -InE \
    'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|CLOUDFLARE_API_TOKEN|GOOGLE_CLIENT_SECRET|client_secret[[:space:]]*[:=]|refresh_token[[:space:]]*[:=]' \
    "$appcast" "$notes" "$checksums" "$manifest"; then
    print -u2 -- "發布資產疑似包含機密內容。"
    exit 65
fi

if /usr/bin/grep -InEi '<script|javascript:|on(load|error|click)[[:space:]]*=|<iframe|<object' "$notes" "$appcast"; then
    print -u2 -- "更新說明包含不允許的可執行內容。"
    exit 65
fi

(
    cd "$assets_dir"
    /usr/bin/shasum -a 256 -c CHECKSUMS.txt
)

"$project_dir/scripts/project-python.sh" - "$appcast" "$manifest" "$archive" "$notes" "$version" "$build_number" <<'PY'
import hashlib
import json
import os
import sys
import xml.etree.ElementTree as ET

appcast_path, manifest_path, archive_path, notes_path, version, build = sys.argv[1:]
archive_name = os.path.basename(archive_path)
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

root = ET.parse(appcast_path).getroot()
items = root.findall("./channel/item")
if len(items) != 1:
    raise SystemExit(f"appcast 必須恰好包含一個版本，目前為 {len(items)} 個。")
item = items[0]
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("appcast 缺少 enclosure。")

expected_url = f"https://mtus.lieniapp.work/downloads/{archive_name}"
checks = {
    "版本": (item.findtext(f"{sparkle}shortVersionString"), version),
    "Build": (item.findtext(f"{sparkle}version"), build),
    "最低系統": (item.findtext(f"{sparkle}minimumSystemVersion"), "26.0"),
    "架構": (item.findtext(f"{sparkle}hardwareRequirements"), "arm64"),
    "下載網址": (enclosure.get("url"), expected_url),
}
for label, (actual, expected) in checks.items():
    if actual != expected:
        raise SystemExit(f"appcast {label}不正確：{actual!r}，預期 {expected!r}。")

signature = enclosure.get(f"{sparkle}edSignature")
if not signature:
    raise SystemExit("appcast enclosure 缺少 Sparkle Ed25519 簽章。")
if int(enclosure.get("length", "-1")) != os.path.getsize(archive_path):
    raise SystemExit("appcast enclosure length 與 ZIP 實際大小不同。")
with open(appcast_path, "rb") as source:
    if b"sparkle-signatures:" not in source.read():
        raise SystemExit("appcast 缺少完整 feed 簽章。")

with open(manifest_path, encoding="utf-8") as source:
    manifest = json.load(source)
if manifest.get("schemaVersion") != 1:
    raise SystemExit("release-manifest.json schemaVersion 不支援。")
if manifest.get("version") != version or str(manifest.get("build")) != build:
    raise SystemExit("release-manifest.json 的版本或 Build 不一致。")
if manifest.get("tag") != f"v{version}":
    raise SystemExit("release-manifest.json 的 tag 不一致。")
if manifest.get("archive") != archive_name:
    raise SystemExit("release-manifest.json 的 archive 不一致。")
if manifest.get("downloadURL") != expected_url:
    raise SystemExit("release-manifest.json 的 downloadURL 不一致。")
commit = manifest.get("commit", "")
if len(commit) not in (40, 64) or any(character not in "0123456789abcdef" for character in commit):
    raise SystemExit("release-manifest.json 的 commit 格式不正確。")

for path, key in (
    (archive_path, "archiveSHA256"),
    (appcast_path, "appcastSHA256"),
    (notes_path, "releaseNotesSHA256"),
):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    if manifest.get(key) != digest.hexdigest():
        raise SystemExit(f"release-manifest.json 的 {key} 不符。")
PY

archive_signature="$("$project_dir/scripts/project-python.sh" - "$appcast" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
enclosure = root.find("./channel/item/enclosure")
print(enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature", ""))
PY
)"

sign_update="$(find_sparkle_tool "$project_dir" sign_update)"
"$sign_update" --account "$MYTERM_SPARKLE_KEY_ACCOUNT" --verify "$appcast"
"$sign_update" --account "$MYTERM_SPARKLE_KEY_ACCOUNT" --verify "$archive" "$archive_signature"

print -- "正式發布資產驗證通過："
print -- "  版本：$version"
print -- "  Build：$build_number"
print -- "  ZIP：$archive_name"
print -- "  Sparkle、SHA-256、架構、最低系統與安全檢查均通過。"
