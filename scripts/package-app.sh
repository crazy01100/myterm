#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_path="$project_dir/build/MyTerm.app"
output_dir="$project_dir/build/release"
version=""
build_number=""
require_stable_signing=0

usage() {
    echo "Usage: scripts/package-app.sh --version VERSION --build BUILD [--app PATH] [--output DIR] [--require-stable-signing]"
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
        --app)
            (( $# >= 2 )) || { echo "Missing value for --app" >&2; exit 64; }
            app_path="$2"
            shift 2
            ;;
        --output)
            (( $# >= 2 )) || { echo "Missing value for --output" >&2; exit 64; }
            output_dir="$2"
            shift 2
            ;;
        --require-stable-signing)
            require_stable_signing=1
            shift
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
verify_arguments=(--app "$app_path" --version "$version" --build "$build_number")
if (( require_stable_signing == 1 )); then
    verify_arguments+=(--require-stable-signing)
fi
"$project_dir/scripts/verify-app.sh" "${verify_arguments[@]}"

mkdir -p "$output_dir"
archive="$output_dir/MyTerm-$version-build-$build_number-arm64.zip"
checksums="$output_dir/CHECKSUMS.txt"
if [[ -e "$archive" ]]; then
    echo "Release archive already exists: $archive" >&2
    exit 65
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_path" "$archive"
digest="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"
print -r -- "$digest  ${archive:t}" > "$checksums"

verification_dir="$(mktemp -d /private/tmp/MyTerm-package.XXXXXX)"
trap '/bin/rm -rf -- "$verification_dir"' EXIT
/usr/bin/ditto -x -k "$archive" "$verification_dir"
extracted_verify_arguments=(
    --app "$verification_dir/MyTerm.app"
    --version "$version"
    --build "$build_number"
)
if (( require_stable_signing == 1 )); then
    extracted_verify_arguments+=(--require-stable-signing)
fi
"$project_dir/scripts/verify-app.sh" "${extracted_verify_arguments[@]}"

echo "Archive: $archive"
echo "SHA-256: $digest"
echo "Checksums: $checksums"
