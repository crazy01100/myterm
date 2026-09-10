#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$project_dir/update-site"
source "$project_dir/scripts/update-source-config.sh"
assets_dir=""
output_dir="$project_dir/build/pages"
release_version=""

usage() {
    cat <<'USAGE'
用法：scripts/prepare-pages-deployment.sh --assets DIR --version VERSION [--output DIR]

必要發布資產：
  appcast.xml
  MyTerm-<版本>-...-arm64.zip（恰好一個）
  release-notes.html

  CHECKSUMS.txt
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --assets)
            assets_dir="${2:-}"
            shift 2
            ;;
        --version)
            release_version="${2:-}"
            shift 2
            ;;
        --output)
            output_dir="${2:-}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知參數：$1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

canonicalize_path() {
    /usr/bin/python3 - "$1" "$project_dir" <<'PY'
import os
import sys

path, project_dir = sys.argv[1:]
if not os.path.isabs(path):
    path = os.path.join(project_dir, path)
print(os.path.realpath(path))
PY
}

validate_update_source
assets_dir="$(canonicalize_path "$assets_dir")"
output_dir="$(canonicalize_path "$output_dir")"

[[ -n "$assets_dir" && -d "$assets_dir" ]] || { echo "找不到發布資產目錄。" >&2; exit 66; }
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "版本格式不正確：$release_version" >&2
    exit 65
}

case "$output_dir" in
    "$project_dir"/build/*|/private/tmp/*|/tmp/*) ;;
    *)
        echo "輸出目錄必須位於專案 build 或暫存目錄：$output_dir" >&2
        exit 65
        ;;
esac

appcast="$assets_dir/appcast.xml"
notes="$assets_dir/release-notes.html"
checksums="$assets_dir/CHECKSUMS.txt"
[[ -f "$appcast" ]] || { echo "缺少 appcast.xml。" >&2; exit 66; }
[[ -f "$notes" ]] || { echo "缺少 release-notes.html。" >&2; exit 66; }
[[ -f "$checksums" ]] || { echo "缺少 CHECKSUMS.txt。" >&2; exit 66; }

zip_count="$(find "$assets_dir" -maxdepth 1 -type f -name 'MyTerm-*-arm64.zip' | wc -l | tr -d ' ')"
[[ "$zip_count" == "1" ]] || { echo "必須恰好有一個 ARM64 MyTerm ZIP，目前為 $zip_count 個。" >&2; exit 65; }
archive="$(find "$assets_dir" -maxdepth 1 -type f -name 'MyTerm-*-arm64.zip' -print -quit)"
archive_name="$(basename "$archive")"

case "$archive_name" in
    *"$release_version"*) ;;
    *) echo "ZIP 檔名沒有包含版本 $release_version：$archive_name" >&2; exit 65 ;;
esac

/usr/bin/python3 - "$appcast" "$archive" "$checksums" <<'PY'
import hashlib
import os
import sys
import xml.etree.ElementTree as ET

path, archive_path, checksums_path = sys.argv[1:]
archive_name = archive_path.rsplit("/", 1)[-1]
root = ET.parse(path).getroot()
enclosures = root.findall(".//enclosure")
if len(enclosures) != 1:
    raise SystemExit(f"appcast 必須恰好包含一個 enclosure，目前為 {len(enclosures)} 個。")
enclosure = enclosures[0]
expected = os.environ["MYTERM_UPDATE_BASE_URL"] + f"/downloads/{archive_name}"
if enclosure.get("url") != expected:
    raise SystemExit(f"appcast 下載網址不正確，預期為 {expected}")
signature = enclosure.get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
if not signature:
    raise SystemExit("appcast enclosure 缺少 Sparkle Ed25519 簽章。")
if int(enclosure.get("length", "-1")) != __import__("os").path.getsize(archive_path):
    raise SystemExit("appcast enclosure length 與 ZIP 實際大小不同。")

with open(path, "rb") as source:
    if b"sparkle-signatures:" not in source.read():
        raise SystemExit("appcast 缺少完整 feed 簽章。")

digest = hashlib.sha256()
with open(archive_path, "rb") as archive:
    for chunk in iter(lambda: archive.read(1024 * 1024), b""):
        digest.update(chunk)
expected_line = f"{digest.hexdigest()}  {archive_name}"
with open(checksums_path, encoding="utf-8") as checksums:
    if expected_line not in {line.strip() for line in checksums}:
        raise SystemExit("CHECKSUMS.txt 與 ZIP 的 SHA-256 不符。")
PY

/bin/rm -rf "$output_dir"
/bin/mkdir -p "$output_dir/downloads" "$output_dir/releases"
/bin/cp -R "$source_dir"/. "$output_dir/"
/bin/cp "$archive" "$output_dir/downloads/$archive_name"
/bin/cp "$appcast" "$output_dir/appcast.xml"
/bin/cp "$notes" "$output_dir/releases/$release_version.html"

/bin/cp "$checksums" "$output_dir/downloads/CHECKSUMS.txt"

/usr/bin/perl -0pi -e "s#<h2 id=\"release-title\">[^<]+</h2>#<h2 id=\"release-title\">$release_version</h2>#; s#<a class=\"button\" href=\"/install/\">查看安裝說明</a>#<a class=\"button\" href=\"/downloads/$archive_name\">下載 Apple Silicon 版本</a>#" "$output_dir/index.html"

echo "Pages 部署目錄已建立：$output_dir"
echo "版本：$release_version"
echo "更新檔：$archive_name"
