#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
target_app=""

usage() {
    echo "Usage: scripts/check-release-safety.sh [--app /path/to/MyTerm.app]"
}

while (( $# > 0 )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || { echo "Missing value for --app" >&2; exit 64; }
            target_app="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

cd "$project_dir"
failures=0

fail() {
    echo "ERROR: $*" >&2
    failures=$((failures + 1))
}

require_ignore() {
    local candidate_path="$1"
    if [[ -d .git ]]; then
        if ! /usr/bin/git check-ignore -q -- "$candidate_path"; then
            fail "$candidate_path is not protected by .gitignore"
        fi
        return
    fi

    # R5 才會初始化 Git；在那之前先確認必要的目錄規則存在。
    if [[ "$candidate_path" == Config/Local/* ]]; then
        /usr/bin/grep -Fqx "/Config/Local/" .gitignore || fail "$candidate_path is not protected by .gitignore"
    elif [[ "$candidate_path" == Exports/Termius/* ]]; then
        /usr/bin/grep -Fqx "/Exports/Termius/*" .gitignore || fail "$candidate_path is not protected by .gitignore"
    else
        fail "cannot prove that $candidate_path is protected by .gitignore"
    fi
}

require_ignore "Config/Local/GoogleOAuthClient.json"
require_ignore "Config/Local/GoogleService-Info.plist"
require_ignore "Config/Local/MyTermCloudConfig.plist"

for exported_file in Exports/Termius/*(N.); do
    [[ "${exported_file:t}" == "README.md" ]] && continue
    require_ignore "$exported_file"
done

secret_pattern='-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|AIza[0-9A-Za-z_-]{35}|GOCSPX-[0-9A-Za-z_-]{20,}|ya29\.[0-9A-Za-z._-]{20,}|1//[0-9A-Za-z_-]{20,}|gh[pousr]_[0-9A-Za-z]{36,}|github_pat_[0-9A-Za-z_]{50,}|AKIA[0-9A-Z]{16}|xox[baprs]-[0-9A-Za-z-]{20,}'
secret_matches=""

if [[ -d .git ]]; then
    # Scan exactly what Git could commit: tracked files plus untracked files
    # that are not protected by .gitignore. Print only filenames so the check
    # itself never echoes a credential into CI or a release log.
    candidate_list="$(/usr/bin/mktemp -t myterm-release-candidates)"
    trap '/bin/rm -f "$candidate_list"' EXIT
    /usr/bin/git ls-files -z --cached --others --exclude-standard > "$candidate_list"
    secret_matches="$(/usr/bin/xargs -0 rg -l --no-messages -e "$secret_pattern" < "$candidate_list" || true)"
else
    secret_matches="$(rg -l --no-messages -uu -e "$secret_pattern" . \
        -g '!.git/**' \
        -g '!.build/**' \
        -g '!.build-*/**' \
        -g '!build/**' \
        -g '!DerivedData/**' \
        -g '!node_modules/**' \
        -g '!.npm-cache/**' \
        -g '!.firebase/**' \
        -g '!firebase-emulator-data/**' \
        -g '!Config/Local/**' \
        -g '!Exports/Termius/**' \
        -g '!*.zip' \
        -g '!*.dmg' \
        -g '!*.pkg' \
        -g '!*.log' || true)"
fi

if [[ -n "$secret_matches" ]]; then
    print -u2 -- "Credential-like material was found in these source candidates:"
    print -u2 -- "$secret_matches"
    fail "high-confidence credential material was found in source candidates"
fi

if [[ -n "$target_app" ]]; then
    [[ -d "$target_app" ]] || fail "app bundle does not exist: $target_app"
    if [[ -d "$target_app" ]]; then
        forbidden_names=(
            "*.p8" "*.p12" "*.key" "*.mobileprovision" "*.provisionprofile"
            ".env" ".env.*" "*recovery-key*" "GoogleOAuthClient.json"
        )
        for pattern in "${forbidden_names[@]}"; do
            if /usr/bin/find "$target_app" -name "$pattern" -print -quit | /usr/bin/grep -q .; then
                fail "forbidden file is present in app bundle: $pattern"
            fi
        done
        if /usr/bin/find "$target_app" -path "*/Config/Local/*" -print -quit | /usr/bin/grep -q .; then
            fail "raw Config/Local directory is present in app bundle"
        fi
        if /usr/bin/find "$target_app" -path "*/Exports/*" -print -quit | /usr/bin/grep -q .; then
            fail "migration exports are present in app bundle"
        fi
    fi
fi

if (( failures > 0 )); then
    echo "Release safety check failed with $failures issue(s)." >&2
    exit 1
fi

echo "Release safety check passed."
