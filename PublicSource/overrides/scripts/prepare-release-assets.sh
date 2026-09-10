#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/sparkle-key-common.sh"
source "$project_dir/scripts/update-source-config.sh"

version=""
build_number=""
notes_file=""
output_dir=""

usage() {
    cat <<'EOF'
用法：scripts/prepare-release-assets.sh --version VERSION --build BUILD --notes FILE [--output DIR]

從已驗證的 MyTerm ZIP 建立：
  appcast.xml
  release-notes.html
  CHECKSUMS.txt
  release-manifest.json

不會建立 GitHub Release，也不會上傳或公開任何檔案。
EOF
}

while (( $# > 0 )); do
    case "$1" in
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
        --notes)
            (( $# >= 2 )) || { print -u2 -- "缺少 --notes 的值"; exit 64; }
            notes_file="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { print -u2 -- "缺少 --output 的值"; exit 64; }
            output_dir="$2"
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

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' ]] || {
    print -u2 -- "版本格式不正確：$version"
    exit 65
}
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || { print -u2 -- "Build 必須是正整數：$build_number"; exit 65; }
[[ -n "$notes_file" && -f "$notes_file" && -s "$notes_file" ]] || {
    print -u2 -- "Release notes 必須是存在且非空白的檔案。"
    exit 66
}

validate_update_source
notes_file="${notes_file:A}"
archive_name="MyTerm-$version-build-$build_number-arm64.zip"
source_archive="$project_dir/build/candidates/MyTerm-$version-build-$build_number/$archive_name"
[[ -f "$source_archive" ]] || { print -u2 -- "找不到已封裝的 App：$source_archive"; exit 66; }

if [[ -z "$output_dir" ]]; then
    output_dir="$project_dir/build/releases/MyTerm-$version-build-$build_number"
fi
output_dir="${output_dir:A}"
case "$output_dir" in
    "$project_dir"/build/*|/private/tmp/*|/tmp/*) ;;
    *)
        print -u2 -- "輸出目錄必須位於專案 build 或暫存目錄：$output_dir"
        exit 65
        ;;
esac
[[ ! -e "$output_dir" ]] || { print -u2 -- "為避免覆蓋既有資產而停止：$output_dir"; exit 65; }

stage_dir="$(mktemp -d /private/tmp/MyTerm-release-assets.XXXXXX)"
trap '/bin/rm -rf -- "$stage_dir"' EXIT
/bin/cp "$source_archive" "$stage_dir/$archive_name"

notes_companion="$stage_dir/${archive_name:r}.md"
/bin/cp "$notes_file" "$notes_companion"

/usr/bin/python3 - "$notes_file" "$stage_dir/release-notes.html" "$version" <<'PY'
import html
import re
import sys

source_path, output_path, version = sys.argv[1:]
with open(source_path, encoding="utf-8") as source:
    lines = source.read().splitlines()

parts = []
paragraph = []
list_kind = None

def flush_paragraph():
    if paragraph:
        text = " ".join(item.strip() for item in paragraph)
        parts.append(f"<p>{html.escape(text)}</p>")
        paragraph.clear()

def close_list():
    global list_kind
    if list_kind:
        parts.append(f"</{list_kind}>")
        list_kind = None

for raw in lines:
    line = raw.rstrip()
    if not line:
        flush_paragraph()
        close_list()
        continue
    heading = re.match(r"^(#{1,3})\s+(.+)$", line)
    bullet = re.match(r"^\s*[-*]\s+(.+)$", line)
    numbered = re.match(r"^\s*\d+[.)]\s+(.+)$", line)
    if heading:
        flush_paragraph()
        close_list()
        level = min(len(heading.group(1)) + 1, 4)
        parts.append(f"<h{level}>{html.escape(heading.group(2))}</h{level}>")
    elif bullet or numbered:
        flush_paragraph()
        desired = "ul" if bullet else "ol"
        if list_kind != desired:
            close_list()
            list_kind = desired
            parts.append(f"<{desired}>")
        value = (bullet or numbered).group(1)
        parts.append(f"<li>{html.escape(value)}</li>")
    else:
        close_list()
        paragraph.append(line)

flush_paragraph()
close_list()
body = "\n        ".join(parts)
document = f'''<!doctype html>
<html lang="zh-Hant">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="MyTerm {html.escape(version)} 版本更新說明。">
  <title>MyTerm {html.escape(version)} 更新說明</title>
  <link rel="stylesheet" href="/assets/site.css">
</head>
<body>
  <main class="shell document">
    <a class="back-link" href="/">← 回到 MyTerm</a>
    <h1>MyTerm {html.escape(version)}</h1>
    <section class="card">
        {body}
    </section>
  </main>
</body>
</html>
'''
with open(output_path, "w", encoding="utf-8", newline="\n") as output:
    output.write(document)
PY

generate_appcast="$(find_sparkle_tool "$project_dir" generate_appcast)"
"$generate_appcast" \
    --account "$MYTERM_SPARKLE_KEY_ACCOUNT" \
    --download-url-prefix "$MYTERM_UPDATE_BASE_URL/downloads/" \
    --embed-release-notes \
    --versions "$build_number" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    "$stage_dir"

# 正式 feed 一律加上完整 Ed25519 簽章。即使候選 App 尚未要求
# SUVerifyUpdateBeforeExtraction，也不能因此產生未簽署的 appcast。
sign_update="$(find_sparkle_tool "$project_dir" sign_update)"
"$sign_update" --account "$MYTERM_SPARKLE_KEY_ACCOUNT" "$stage_dir/appcast.xml"

/bin/rm -f "$notes_companion"
/bin/rm -rf "$stage_dir/old_updates"

archive_sha="$(/usr/bin/shasum -a 256 "$stage_dir/$archive_name" | awk '{print $1}')"
appcast_sha="$(/usr/bin/shasum -a 256 "$stage_dir/appcast.xml" | awk '{print $1}')"
notes_sha="$(/usr/bin/shasum -a 256 "$stage_dir/release-notes.html" | awk '{print $1}')"
commit_sha="$(git -C "$project_dir" rev-parse HEAD)"
created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/python3 - "$stage_dir/release-manifest.json" "$version" "$build_number" "$commit_sha" "$created_at" "$archive_name" "$archive_sha" "$appcast_sha" "$notes_sha" <<'PY'
import json
import os
import sys

(path, version, build, commit, created_at, archive_name,
 archive_sha, appcast_sha, notes_sha) = sys.argv[1:]
manifest = {
    "schemaVersion": 1,
    "product": "MyTerm",
    "version": version,
    "build": build,
    "tag": f"v{version}",
    "commit": commit,
    "createdAtUTC": created_at,
    "archive": archive_name,
    "archiveSHA256": archive_sha,
    "appcastSHA256": appcast_sha,
    "releaseNotesSHA256": notes_sha,
    "downloadURL": os.environ["MYTERM_UPDATE_BASE_URL"] + f"/downloads/{archive_name}",
}
with open(path, "w", encoding="utf-8", newline="\n") as output:
    json.dump(manifest, output, ensure_ascii=False, indent=2, sort_keys=True)
    output.write("\n")
PY

(
    cd "$stage_dir"
    /usr/bin/shasum -a 256 \
        "$archive_name" \
        appcast.xml \
        release-notes.html \
        release-manifest.json > CHECKSUMS.txt
)

"$project_dir/scripts/verify-release-assets.sh" \
    --assets "$stage_dir" \
    --version "$version" \
    --build "$build_number"

/bin/mkdir -p "${output_dir:h}"
/bin/mv "$stage_dir" "$output_dir"
trap - EXIT

print -- "正式發布資產已準備完成，但尚未上傳："
print -- "  $output_dir"
print -- "下一步必須由 release 腳本建立 GitHub Draft Release。"
