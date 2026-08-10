#!/bin/bash

set -euo pipefail

base_url="https://mtus.lieniapp.work"
assets_dir=""
release_version=""
attempts=12
retry_delay=5

usage() {
    cat <<'USAGE'
用法：scripts/verify-public-update-site.sh --assets DIR --version VERSION [選項]

選項：
  --base-url URL       公開更新站，預設 https://mtus.lieniapp.work
  --attempts NUMBER    最多驗證次數，預設 12
  --retry-delay SEC    重試間隔秒數，預設 5
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
        --base-url)
            base_url="${2:-}"
            shift 2
            ;;
        --attempts)
            attempts="${2:-}"
            shift 2
            ;;
        --retry-delay)
            retry_delay="${2:-}"
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

[[ "$base_url" == https://* ]] || { echo "公開更新站必須使用 HTTPS。" >&2; exit 65; }
base_url="${base_url%/}"
[[ -n "$assets_dir" && -d "$assets_dir" ]] || { echo "找不到發布資產目錄。" >&2; exit 66; }
[[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
    echo "版本格式不正確：$release_version" >&2
    exit 65
}
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || { echo "驗證次數必須是正整數。" >&2; exit 64; }
[[ "$retry_delay" =~ ^[0-9]+$ ]] || { echo "重試秒數必須是非負整數。" >&2; exit 64; }

appcast="$assets_dir/appcast.xml"
notes="$assets_dir/release-notes.html"
[[ -f "$appcast" && -f "$notes" ]] || { echo "缺少 appcast.xml 或 release-notes.html。" >&2; exit 66; }

zip_count="$(find "$assets_dir" -maxdepth 1 -type f -name 'MyTerm-*-arm64.zip' | wc -l | tr -d ' ')"
[[ "$zip_count" == "1" ]] || { echo "必須恰好有一個 ARM64 MyTerm ZIP，目前為 $zip_count 個。" >&2; exit 65; }
archive="$(find "$assets_dir" -maxdepth 1 -type f -name 'MyTerm-*-arm64.zip' -print -quit)"
archive_name="$(basename "$archive")"
expected_archive_sha="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"

work_dir="$(mktemp -d /tmp/myterm-public-verification.XXXXXX)"
trap '/bin/rm -rf "$work_dir"' EXIT

verify_once() {
    /bin/rm -f "$work_dir"/*

    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 60 \
        -D "$work_dir/index.headers" -o "$work_dir/index.html" "$base_url/" || return 1
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 60 \
        -D "$work_dir/appcast.headers" -o "$work_dir/appcast.xml" "$base_url/appcast.xml" || return 1
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 60 \
        -o "$work_dir/release-notes.html" "$base_url/releases/$release_version.html" || return 1
    curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 \
        -o "$work_dir/$archive_name" "$base_url/downloads/$archive_name" || return 1

    /usr/bin/cmp -s "$appcast" "$work_dir/appcast.xml" || return 1
    /usr/bin/cmp -s "$notes" "$work_dir/release-notes.html" || return 1
    [[ "$(/usr/bin/shasum -a 256 "$work_dir/$archive_name" | awk '{print $1}')" == "$expected_archive_sha" ]] || return 1
    /usr/bin/grep -Fq "$release_version" "$work_dir/index.html" || return 1

    /usr/bin/tr -d '\r' < "$work_dir/index.headers" > "$work_dir/index.normalized.headers"
    /usr/bin/tr -d '\r' < "$work_dir/appcast.headers" > "$work_dir/appcast.normalized.headers"
    /usr/bin/grep -Eiq '^content-security-policy:' "$work_dir/index.normalized.headers" || return 1
    /usr/bin/grep -Eiq '^strict-transport-security:' "$work_dir/index.normalized.headers" || return 1
    /usr/bin/grep -Eiq '^x-content-type-options:[[:space:]]*nosniff' "$work_dir/index.normalized.headers" || return 1
    /usr/bin/grep -Eiq '^cache-control:.*no-cache.*no-store.*must-revalidate' "$work_dir/appcast.normalized.headers" || return 1
}

for ((attempt = 1; attempt <= attempts; attempt++)); do
    if verify_once; then
        echo "公開更新站驗證通過："
        echo "- 版本：$release_version"
        echo "- ZIP SHA-256：$expected_archive_sha"
        echo "- appcast、更新說明、下載檔與安全標頭均與發布資產一致。"
        exit 0
    fi

    if (( attempt < attempts )); then
        echo "公開更新站尚未收斂（$attempt/$attempts），${retry_delay} 秒後重試。"
        /bin/sleep "$retry_delay"
    fi
done

echo "公開更新站在 $attempts 次驗證後仍與 Release 資產不一致。" >&2
exit 1
