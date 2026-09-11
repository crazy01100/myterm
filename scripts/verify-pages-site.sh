#!/bin/bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
site_dir="${1:-$project_dir/update-site}"

required=(
    "index.html"
    "404.html"
    "appcast.xml"
    "_headers"
    "robots.txt"
    "assets/site.css"
    "assets/release-notes.css"
    "install/index.html"
    "privacy/index.html"
    "security/index.html"
)

for relative_path in "${required[@]}"; do
    [[ -f "$site_dir/$relative_path" ]] || {
        echo "更新站缺少檔案：$relative_path" >&2
        exit 66
    }
done

"$project_dir/scripts/project-python.sh" - "$site_dir/appcast.xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
if root.tag != "rss":
    raise SystemExit("appcast.xml 根節點不是 rss。")
PY

/usr/bin/grep -Fq "Content-Security-Policy:" "$site_dir/_headers" || { echo "缺少 CSP。" >&2; exit 65; }
/usr/bin/grep -Fq "Strict-Transport-Security: max-age=31536000" "$site_dir/_headers" || { echo "缺少 HSTS。" >&2; exit 65; }
/usr/bin/grep -Fq "X-Content-Type-Options: nosniff" "$site_dir/_headers" || { echo "缺少 nosniff。" >&2; exit 65; }
/usr/bin/grep -Fq "Cache-Control: no-cache, no-store, must-revalidate" "$site_dir/_headers" || { echo "appcast 沒有禁止快取。" >&2; exit 65; }
/usr/bin/grep -Fq "Cache-Control: public, max-age=31536000, immutable" "$site_dir/_headers" || { echo "版本化下載檔沒有 immutable 快取。" >&2; exit 65; }

if /usr/bin/grep -RInE 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|CLOUDFLARE_API_TOKEN|client_secret' "$site_dir"; then
    echo "更新站疑似包含機密內容。" >&2
    exit 65
fi

file_count="$(find "$site_dir" -type f | wc -l | tr -d ' ')"
oversized="$(find "$site_dir" -type f -size +25M -print -quit)"
[[ -z "$oversized" ]] || { echo "更新站包含超過 25 MiB 的檔案：$oversized" >&2; exit 65; }

echo "Cloudflare Pages 靜態站驗證通過（$file_count 個檔案）。"
