#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version=""
build_number=""
build_date=""
notes_file=""
prepare_only=0
feed_url="https://mtus.lieniapp.work/appcast.xml"

usage() {
    cat <<'EOF'
用法：scripts/release.sh --version VERSION --build BUILD --notes FILE [選項]

選項：
  --build-date DATE   固定 App 內顯示的建置日期
  --prepare-only      完成建置與資產驗證後停止，不建立 GitHub Draft Release

此指令最多只會建立 GitHub Draft Release。
它永遠不會公開 Release，也不會觸發 Cloudflare Pages 正式部署。
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
        --build-date)
            (( $# >= 2 )) || { print -u2 -- "缺少 --build-date 的值"; exit 64; }
            build_date="$2"
            shift 2
            ;;
        --prepare-only)
            prepare_only=1
            shift
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
notes_file="${notes_file:A}"
if /usr/bin/grep -Fq '## 發布前確認' "$notes_file"; then
    print -u2 -- "Release notes 仍包含範本的『發布前確認』區塊；請完成內容並移除該區塊。"
    exit 65
fi

cd "$project_dir"
[[ -z "$(git status --porcelain)" ]] || {
    print -u2 -- "Git 工作目錄不是乾淨狀態；請先檢查、提交或移除未追蹤檔案。"
    exit 65
}

branch="$(git branch --show-current)"
[[ "$branch" == "main" ]] || { print -u2 -- "正式發布只能從 main 建立，目前為：$branch"; exit 65; }

print -- "[1/6] 確認 GitHub 與遠端 main 狀態"
gh auth status >/dev/null
git fetch --quiet origin main --tags
head_sha="$(git rev-parse HEAD)"
origin_sha="$(git rev-parse origin/main)"
[[ "$head_sha" == "$origin_sha" ]] || {
    print -u2 -- "本機 HEAD 與 origin/main 不一致，請先完成推送或更新。"
    exit 65
}

tag="v$version"
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    print -u2 -- "本機已存在 tag：$tag"
    exit 65
fi
if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
    print -u2 -- "GitHub 已存在 tag：$tag"
    exit 65
fi
if gh release view "$tag" >/dev/null 2>&1; then
    print -u2 -- "GitHub 已存在 Release：$tag"
    exit 65
fi

print -- "[2/6] 執行安全掃描、測試、Release 建置與 App 驗證"
build_arguments=(--version "$version" --build "$build_number" --sparkle-feed-url "$feed_url")
if [[ -n "$build_date" ]]; then
    build_arguments+=(--build-date "$build_date")
fi
"$project_dir/scripts/prepare-release-build.sh" "${build_arguments[@]}"

print -- "[3/6] 建立並簽署正式更新資產"
assets_dir="$project_dir/build/releases/MyTerm-$version-build-$build_number"
"$project_dir/scripts/prepare-release-assets.sh" \
    --version "$version" \
    --build "$build_number" \
    --notes "$notes_file" \
    --output "$assets_dir"

print -- "[4/6] 再次驗證即將上傳的五個檔案"
"$project_dir/scripts/verify-release-assets.sh" \
    --assets "$assets_dir" \
    --version "$version" \
    --build "$build_number"

if (( prepare_only == 1 )); then
    print -- "[5/6] 已依 --prepare-only 停止"
    print -- "[6/6] 未建立 GitHub Release，也未公開或部署任何版本。"
    print -- "候選資產：$assets_dir"
    exit 0
fi

print -- "[5/6] 建立 GitHub Draft Release"
archive_name="MyTerm-$version-build-$build_number-arm64.zip"
release_flags=(
    --draft
    --target "$head_sha"
    --title "MyTerm $version"
    --notes-file "$notes_file"
)
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    release_flags+=(--prerelease)
fi
gh release create "$tag" \
    "$assets_dir/$archive_name" \
    "$assets_dir/appcast.xml" \
    "$assets_dir/release-notes.html" \
    "$assets_dir/CHECKSUMS.txt" \
    "$assets_dir/release-manifest.json" \
    "${release_flags[@]}"

draft_url="$(gh release view "$tag" --json url --jq .url)"
print -- "[6/6] GitHub Draft Release 已建立"
print -- "草稿：$draft_url"
print -- "狀態：尚未公開，Cloudflare Pages workflow 不會執行。"
print -- "請人工核對版本、說明、ZIP、appcast 與校驗碼後，再決定是否發布。"
