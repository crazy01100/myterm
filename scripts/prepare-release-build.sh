#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
version=""
build_number=""
build_date=""
sparkle_feed_url="${MYTERM_SPARKLE_FEED_URL:-}"
sparkle_public_key="${MYTERM_SPARKLE_PUBLIC_KEY:-}"
skip_tests=0

usage() {
    cat <<'EOF'
Usage: scripts/prepare-release-build.sh --version VERSION --build BUILD [options]

Options:
  --build-date DATE  Fix the displayed build date for a repeatable candidate
  --skip-tests       Local diagnosis only; never use for a release candidate
  --sparkle-feed-url URL
                     HTTPS appcast URL; requires --sparkle-public-key
  --sparkle-public-key KEY
                     Sparkle Ed25519 public key; may be staged before the feed URL
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { echo "Missing value for --version" >&2; exit 64; }
            version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || { echo "Missing value for --build" >&2; exit 64; }
            build_number="$2"
            shift 2
            ;;
        --build-date)
            (( $# >= 2 )) || { echo "Missing value for --build-date" >&2; exit 64; }
            build_date="$2"
            shift 2
            ;;
        --skip-tests)
            skip_tests=1
            shift
            ;;
        --sparkle-feed-url)
            (( $# >= 2 )) || { echo "Missing value for --sparkle-feed-url" >&2; exit 64; }
            sparkle_feed_url="$2"
            shift 2
            ;;
        --sparkle-public-key)
            (( $# >= 2 )) || { echo "Missing value for --sparkle-public-key" >&2; exit 64; }
            sparkle_public_key="$2"
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

[[ -n "$version" && -n "$build_number" ]] || { usage >&2; exit 64; }

cd "$project_dir"
candidate_dir="$project_dir/build/candidates/MyTerm-$version-build-$build_number"
candidate_app="$candidate_dir/MyTerm.app"
candidate_build_state="$project_dir/build/candidates/.last-build-number"
"$project_dir/scripts/check-release-safety.sh"
python3 "$project_dir/scripts/security-audit.py" --output "$project_dir/build/security-preflight.json"
sparkle_arguments=()
if [[ -n "$sparkle_feed_url" ]]; then
    sparkle_arguments+=(--sparkle-feed-url "$sparkle_feed_url")
fi
if [[ -n "$sparkle_public_key" ]]; then
    sparkle_arguments+=(--sparkle-public-key "$sparkle_public_key")
fi
candidate_arguments=(
    --channel candidate
    --version "$version"
    --build "$build_number"
    --app-output "$candidate_app"
    --build-state-file "$candidate_build_state"
)
candidate_arguments+=("${sparkle_arguments[@]}")
candidate_arguments+=(--require-stable-signing)
"$project_dir/scripts/build-app.sh" "${candidate_arguments[@]}" --preflight
if (( skip_tests == 0 )); then
    python3 "$project_dir/scripts/run-isolated-tests.py"
fi

build_arguments=("${candidate_arguments[@]}")
if [[ -n "$build_date" ]]; then
    build_arguments+=(--build-date "$build_date")
fi
"$project_dir/scripts/build-app.sh" "${build_arguments[@]}"
"$project_dir/scripts/verify-app.sh" \
    --app "$candidate_app" \
    --version "$version" \
    --build "$build_number" \
    --require-stable-signing
"$project_dir/scripts/package-app.sh" \
    --app "$candidate_app" \
    --output "$candidate_dir" \
    --version "$version" \
    --build "$build_number" \
    --require-stable-signing

echo "Release candidate prepared without publishing anything:"
echo "$candidate_dir"
