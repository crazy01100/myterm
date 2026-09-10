#!/bin/bash

set -euo pipefail

base_url="${MYTERM_UPDATE_BASE_URL:-}"
assets_dir=""
release_version=""
attempts=12
retry_delay=5

usage() {
    cat <<'USAGE'
用法：scripts/verify-public-update-site.sh --assets DIR --version VERSION [選項]

選項：
  --base-url URL       Your own HTTPS update site; required unless MYTERM_UPDATE_BASE_URL is set
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
update_user_agent="MyTerm/$release_version Sparkle/2.9.5"

work_dir="$(mktemp -d /tmp/myterm-public-verification.XXXXXX)"
trap '/bin/rm -rf "$work_dir"' EXIT
last_error="尚未執行驗證"

fetch_public_file() {
    local label="$1"
    local url="$2"
    local output="$3"
    local headers="$4"
    local max_time="$5"
    local error_file="$work_dir/curl-error.txt"
    local -a curl_args=(
        --fail
        --silent
        --show-error
        --location
        --user-agent "$update_user_agent"
        --connect-timeout 15
        --max-time "$max_time"
        -o "$output"
    )

    if [[ -n "$headers" ]]; then
        curl_args+=( -D "$headers" )
    fi

    if ! curl "${curl_args[@]}" "$url" 2>"$error_file"; then
        local curl_message
        curl_message="$(/usr/bin/tr '\n' ' ' < "$error_file" | /usr/bin/sed -E 's/[[:space:]]+$//')"
        # macOS 內建的 Bash 3.2 在部分語系下，可能把緊接變數的全形
        # 標點誤判成變數名稱的一部分；明確加上大括號以避免錯誤。
        last_error="${label} 取得失敗（${url}）：${curl_message:-curl 未提供錯誤內容}"
        return 1
    fi
}

verify_once() {
    /bin/rm -f "$work_dir"/*

    fetch_public_file "首頁" "$base_url/" "$work_dir/index.html" "$work_dir/index.headers" 60 || return 1
    fetch_public_file "appcast" "$base_url/appcast.xml" "$work_dir/appcast.xml" "$work_dir/appcast.headers" 60 || return 1
    fetch_public_file "更新說明" "$base_url/releases/$release_version.html" "$work_dir/release-notes.html" "" 60 || return 1
    fetch_public_file "安裝檔" "$base_url/downloads/$archive_name" "$work_dir/$archive_name" "" 120 || return 1

    if ! /usr/bin/cmp -s "$appcast" "$work_dir/appcast.xml"; then
        last_error="公開 appcast.xml 與 GitHub Release 資產不同。"
        return 1
    fi
    if ! /usr/bin/cmp -s "$notes" "$work_dir/release-notes.html"; then
        last_error="公開更新說明與 GitHub Release 資產不同。"
        return 1
    fi
    local actual_archive_sha
    actual_archive_sha="$(/usr/bin/shasum -a 256 "$work_dir/$archive_name" | awk '{print $1}')"
    if [[ "$actual_archive_sha" != "$expected_archive_sha" ]]; then
        last_error="公開安裝檔 SHA-256 不符（預期 ${expected_archive_sha}，實際 ${actual_archive_sha}）。"
        return 1
    fi
    if ! /usr/bin/grep -Fq "$release_version" "$work_dir/index.html"; then
        last_error="公開首頁尚未顯示版本 ${release_version}。"
        return 1
    fi

    /usr/bin/tr -d '\r' < "$work_dir/index.headers" > "$work_dir/index.normalized.headers"
    /usr/bin/tr -d '\r' < "$work_dir/appcast.headers" > "$work_dir/appcast.normalized.headers"
    if ! /usr/bin/grep -Eiq '^content-security-policy:' "$work_dir/index.normalized.headers"; then
        last_error="公開首頁缺少 Content-Security-Policy。"
        return 1
    fi
    if ! /usr/bin/grep -Eiq '^strict-transport-security:[[:space:]]*max-age=31536000' "$work_dir/index.normalized.headers"; then
        last_error="公開首頁缺少預期的 Strict-Transport-Security。"
        return 1
    fi
    if ! /usr/bin/grep -Eiq '^x-content-type-options:[[:space:]]*nosniff' "$work_dir/index.normalized.headers"; then
        last_error="公開首頁缺少 X-Content-Type-Options: nosniff。"
        return 1
    fi
    if ! /usr/bin/grep -Eiq '^cache-control:.*no-cache.*no-store.*must-revalidate' "$work_dir/appcast.normalized.headers"; then
        last_error="公開 appcast.xml 的 Cache-Control 不符合禁止快取要求。"
        return 1
    fi
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
        echo "公開更新站尚未收斂（${attempt}/${attempts}）：${last_error}"
        echo "${retry_delay} 秒後重試。"
        /bin/sleep "$retry_delay"
    fi
done

echo "公開更新站在 $attempts 次驗證後仍未通過：$last_error" >&2
exit 1
