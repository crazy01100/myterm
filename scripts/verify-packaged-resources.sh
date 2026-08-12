#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path=""
archive_path=""
work_dir=""

usage() {
    echo "Usage: scripts/verify-packaged-resources.sh (--app PATH | --archive PATH)"
}

cleanup() {
    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        /bin/rm -rf -- "$work_dir"
    fi
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
    case "$1" in
        --app)
            (( $# >= 2 )) || { echo "Missing value for --app" >&2; exit 64; }
            app_path="$2"
            shift 2
            ;;
        --archive)
            (( $# >= 2 )) || { echo "Missing value for --archive" >&2; exit 64; }
            archive_path="$2"
            shift 2
            ;;
        -h|--help)
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

if [[ -n "$app_path" && -n "$archive_path" ]] || [[ -z "$app_path" && -z "$archive_path" ]]; then
    usage >&2
    exit 64
fi

if [[ -n "$archive_path" ]]; then
    [[ -f "$archive_path" ]] || { echo "Archive not found: $archive_path" >&2; exit 66; }
    work_dir="$(mktemp -d "${TMPDIR:-/tmp}/MyTerm-resource-check.XXXXXX")"
    /usr/bin/unzip -q "$archive_path" -d "$work_dir"
    app_path="$work_dir/MyTerm.app"
fi

source_icons="$project_dir/Sources/MySSHClient/Resources/PlatformIcons"
packaged_icons="$app_path/Contents/Resources/PlatformIcons"
executable="$app_path/Contents/MacOS/MySSHClient"

[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 66; }
[[ -x "$executable" ]] || { echo "App executable is missing: $executable" >&2; exit 66; }
[[ -d "$source_icons" ]] || { echo "Source platform icons are missing: $source_icons" >&2; exit 66; }
[[ -d "$packaged_icons" ]] || { echo "Packaged platform icons are missing: $packaged_icons" >&2; exit 66; }

if ! /usr/bin/diff -qr "$source_icons" "$packaged_icons" >/dev/null; then
    echo "Packaged platform icons do not exactly match the source resources." >&2
    exit 65
fi

if /usr/bin/find "$app_path" -name 'MySSHClient_MySSHClient.bundle' -print -quit | /usr/bin/grep -q .; then
    echo "Unexpected MyTerm SwiftPM resource bundle is present in the packaged App." >&2
    exit 65
fi

if LC_ALL=C /usr/bin/grep -aF 'MySSHClient_MySSHClient.bundle' "$executable" >/dev/null; then
    echo "Executable contains the unsafe MyTerm SwiftPM resource accessor." >&2
    exit 65
fi

echo "Packaged MyTerm resources verified."
