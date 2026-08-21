#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/build"
version=""
build_number=""
apply_cleanup=0

usage() {
    cat <<'EOF'
用法：scripts/cleanup-build-artifacts.sh --version VERSION --build BUILD [--apply]

正式版完成發布、部署與人工驗收後，重新下載並驗證 GitHub Release
的五項資產，確認沒有程序從專案 build/ 執行，再清除整個 build/。

預設只顯示可清理範圍；加入 --apply 才會實際清除。

選項：
  --version VERSION  已完成驗收的正式版本，例如 1.0.12
  --build BUILD       該正式版本的 Build 編號
  --apply             通過所有防呆後清除整個 build/
EOF
}

fail() {
    print -u2 -- "錯誤：$1"
    exit "${2:-65}"
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || fail "缺少 --version 的值" 64
            version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || fail "缺少 --build 的值" 64
            build_number="$2"
            shift 2
            ;;
        --apply)
            apply_cleanup=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "未知參數：$1" 64
            ;;
    esac
done

[[ "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || {
    fail "只允許已驗收的正式版本，版本格式必須是 X.Y.Z：$version"
}
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || fail "Build 必須是正整數：$build_number"

expected_build_dir="$project_dir/build"
resolved_build_dir="${build_dir:A}"
[[ "$resolved_build_dir" == "$expected_build_dir" ]] || {
    fail "清理路徑不等於專案 build/：$resolved_build_dir"
}
[[ ! -L "$build_dir" ]] || fail "build/ 不得是符號連結，拒絕清理。"

command -v gh >/dev/null 2>&1 || fail "找不到 GitHub CLI（gh）。" 69
cd "$project_dir"

tag="v$version"
print -- "[1/5] 確認 GitHub 正式版狀態：$tag"
gh auth status >/dev/null
release_state="$(gh release view "$tag" --json isDraft,isPrerelease --jq '[.isDraft, .isPrerelease] | @tsv')"
IFS=$'\t' read -r is_draft is_prerelease <<< "$release_state"
[[ "$is_draft" == "false" ]] || fail "$tag 仍是 Draft，拒絕清理。"
[[ "$is_prerelease" == "false" ]] || fail "$tag 仍是 prerelease，拒絕清理。"

repo_name="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
latest_tag="$(gh api "repos/$repo_name/releases/latest" --jq .tag_name)"
[[ "$latest_tag" == "$tag" ]] || {
    fail "GitHub 最新正式版是 $latest_tag，不是 $tag，拒絕清理。"
}

print -- "[2/5] 從 GitHub 重新下載並驗證五項發布資產"
download_dir="$(/usr/bin/mktemp -d /private/tmp/MyTerm-build-cleanup.XXXXXX)"
cleanup_temp() {
    [[ -n "${download_dir:-}" && -d "$download_dir" ]] && /bin/rm -rf -- "$download_dir"
}
trap cleanup_temp EXIT INT TERM
gh release download "$tag" --dir "$download_dir"
"$project_dir/scripts/verify-release-assets.sh" \
    --assets "$download_dir" \
    --version "$version" \
    --build "$build_number"

print -- "[3/5] 確認沒有程序從 build/ 執行"
process_snapshot="$(/bin/ps -ax -ww -o pid=,command=)" || {
    fail "無法列舉目前程序，為避免刪除執行中的 App，拒絕清理。" 70
}
running_from_build="$(print -r -- "$process_snapshot" | /usr/bin/awk -v prefix="$build_dir/" '
    index($0, prefix) > 0 && index($0, "/Contents/MacOS/") > 0 { print }
')"
[[ -z "$running_from_build" ]] || {
    print -u2 -- "下列 App 仍從 build/ 執行，請先正常關閉："
    print -u2 -- "$running_from_build"
    exit 70
}

if [[ ! -e "$build_dir" ]]; then
    print -- "[4/5] build/ 已不存在，沒有本機產物需要清理。"
    print -- "[5/5] 完成；原始碼、正式 App、使用者資料與簽章材料未變更。"
    exit 0
fi

size_kib="$(/usr/bin/du -sk "$build_dir" | /usr/bin/awk '{print $1}')"
size_mib="$(/usr/bin/awk -v kib="$size_kib" 'BEGIN { printf "%.1f", kib / 1024 }')"

print -- "[4/5] 已通過清理防呆"
print -- "  目標：$build_dir"
print -- "  大小：約 $size_mib MiB"
print -- "  GitHub 正式版：$tag（Build $build_number）"

if (( apply_cleanup == 0 )); then
    print -- "[5/5] 預覽完成；未刪除任何檔案。加入 --apply 才會清理。"
    exit 0
fi

cleanup_staging="$project_dir/.build-cleanup-$version-$build_number-$$"
[[ ! -e "$cleanup_staging" ]] || fail "暫存清理路徑已存在：$cleanup_staging" 73

# Finder 開著 build/ 時可能在遞迴刪除途中重建 .DS_Store。先把整個目錄
# 原子移出固定路徑，再刪除不會被 Finder 持續寫入的暫存名稱。
/bin/mv -- "$build_dir" "$cleanup_staging"
if ! /bin/rm -rf -- "$cleanup_staging"; then
    fail "無法移除已隔離的清理暫存：$cleanup_staging" 74
fi
[[ ! -e "$cleanup_staging" ]] || fail "清理暫存仍然存在：$cleanup_staging" 74

# Finder 可能在目錄被移走後建立新的空 build/ 與 .DS_Store；只有確認
# 沒有其他內容時才移除這個 UI metadata，不得誤刪同時產生的新建置。
if [[ -e "$build_dir" ]]; then
    [[ -d "$build_dir" && ! -L "$build_dir" ]] || {
        fail "清理期間 build/ 被重新建立為非預期類型，請人工檢查。" 74
    }
    unexpected_recreated="$(find "$build_dir" -mindepth 1 ! -name .DS_Store -print -quit)"
    [[ -z "$unexpected_recreated" ]] || {
        fail "清理期間 build/ 出現新的建置內容，已保留並停止：$unexpected_recreated" 74
    }
    /bin/rm -f -- "$build_dir/.DS_Store"
    /bin/rmdir -- "$build_dir" || fail "Finder 持續使用 build/，請關閉該 Finder 視窗後重試。" 74
fi

[[ ! -e "$build_dir" ]] || fail "清理後 build/ 仍然存在。" 74

print -- "[5/5] 清理完成"
print -- "  已回收：約 $size_mib MiB"
print -- "  保留：原始碼、Git 歷史、正式 App、使用者資料、簽章與本機雲端設定"
