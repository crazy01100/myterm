#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/code-signing-common.sh"
app_path=""
expected_version=""
expected_build=""
require_stable_signing=0

usage() {
    echo "Usage: scripts/verify-app.sh --app /path/to/App.app --version VERSION --build BUILD [--require-stable-signing]"
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { echo "Missing value for --version" >&2; exit 64; }
            expected_version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || { echo "Missing value for --build" >&2; exit 64; }
            expected_build="$2"
            shift 2
            ;;
        --app)
            (( $# >= 2 )) || { echo "Missing value for --app" >&2; exit 64; }
            app_path="$2"
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

if [[ -z "$app_path" || -z "$expected_version" || -z "$expected_build" ]]; then
    usage >&2
    exit 64
fi
[[ "$app_path" != "$project_dir/build/MyTerm.app" ]] || {
    echo "build/MyTerm.app is prohibited; verify build/dev, a candidate, or a release artifact." >&2
    exit 64
}

plist="$app_path/Contents/Info.plist"
executable="$app_path/Contents/MacOS/MySSHClient"
sparkle_framework="$app_path/Contents/Frameworks/Sparkle.framework"
[[ -d "$app_path" ]] || { echo "App bundle not found: $app_path" >&2; exit 1; }
[[ -x "$executable" ]] || { echo "Executable missing or not executable: $executable" >&2; exit 1; }
[[ -d "$sparkle_framework" ]] || { echo "Sparkle.framework is missing: $sparkle_framework" >&2; exit 1; }
"$project_dir/scripts/verify-packaged-resources.sh" --app "$app_path"
[[ -x "$sparkle_framework/Versions/Current/Autoupdate" ]] || {
    echo "Sparkle Autoupdate helper is missing or not executable." >&2
    exit 1
}
[[ -d "$sparkle_framework/Versions/Current/Updater.app" ]] || {
    echo "Sparkle Updater.app is missing." >&2
    exit 1
}
/usr/bin/plutil -lint "$plist" >/dev/null

if [[ "$app_path" == "$project_dir/build/dev/MyTerm Dev.app" ]]; then
    development_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist")"
    development_support_directory="$(/usr/bin/plutil -extract MyTermApplicationSupportDirectory raw "$plist")"
    development_keychain_service="$(/usr/bin/plutil -extract MyTermLocalSecretVaultKeychainService raw "$plist")"
    [[ "$development_bundle_id" == "tw.local.MySSHClient.Development" ]] || {
        echo "Development App must use its isolated Bundle ID." >&2
        exit 1
    }
    [[ "$development_support_directory" == "MyTerm Development" ]] || {
        echo "Development App must use its isolated Application Support directory." >&2
        exit 1
    }
    [[ "$development_keychain_service" == "tw.local.MySSHClient.Development.local-secret-vault-root" ]] || {
        echo "Development App must use its isolated local-vault Keychain service." >&2
        exit 1
    }
fi

required_sftp_drag_types=(
    "tw.local.MySSHClient.sftp.local-drag-payload"
    "tw.local.MySSHClient.sftp.remote-drag-payload"
)
for required_type in "${required_sftp_drag_types[@]}"; do
    type_is_declared=0
    for index in {0..1}; do
        identifier="$(/usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations:$index:UTTypeIdentifier" "$plist" 2>/dev/null || true)"
        conforms_to="$(/usr/libexec/PlistBuddy -c "Print :UTExportedTypeDeclarations:$index:UTTypeConformsTo:0" "$plist" 2>/dev/null || true)"
        if [[ "$identifier" == "$required_type" && "$conforms_to" == "public.data" ]]; then
            type_is_declared=1
            break
        fi
    done
    (( type_is_declared == 1 )) || {
        echo "Required SFTP drag type is missing from Info.plist or does not conform to public.data: $required_type" >&2
        exit 1
    }
done

sparkle_public_key_file="$project_dir/Config/Release/SparklePublicKey.txt"
if [[ -f "$sparkle_public_key_file" ]]; then
    expected_sparkle_public_key="$(/usr/bin/tr -d '\r\n' < "$sparkle_public_key_file")"
    actual_sparkle_public_key="$(/usr/bin/plutil -extract SUPublicEDKey raw "$plist" 2>/dev/null || true)"
    [[ "$actual_sparkle_public_key" == "$expected_sparkle_public_key" ]] || {
        echo "Sparkle public key is missing or does not match the staged release key." >&2
        exit 1
    }
fi

actual_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")"
actual_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$plist")"
minimum_system="$(/usr/bin/plutil -extract LSMinimumSystemVersion raw "$plist")"
architectures="$(/usr/bin/lipo -archs "$executable")"

[[ "$actual_version" == "$expected_version" ]] || {
    echo "Version mismatch: expected $expected_version, got $actual_version" >&2
    exit 1
}
[[ "$actual_build" == "$expected_build" ]] || {
    echo "Build mismatch: expected $expected_build, got $actual_build" >&2
    exit 1
}
[[ "$minimum_system" == "26.0" ]] || {
    echo "Minimum macOS mismatch: expected 26.0, got $minimum_system" >&2
    exit 1
}
[[ "$architectures" == "arm64" ]] || {
    echo "Architecture mismatch: expected arm64, got $architectures" >&2
    exit 1
}

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$sparkle_framework"
if (( require_stable_signing == 1 )); then
    validate_stable_code_signature "$project_dir" "$app_path"
    expected_release_requirement="$(read_trimmed_file "$project_dir/$MYTERM_CODE_SIGN_REQUIREMENT_FILE")"
    embedded_release_requirement="$(/usr/bin/plutil -extract MyTermStableReleaseRequirement raw "$plist" 2>/dev/null || true)"
    [[ "$embedded_release_requirement" == "$expected_release_requirement" ]] || {
        echo "Stable release requirement is missing from Info.plist or does not match the signing baseline." >&2
        exit 1
    }
fi

sparkle_link="$(/usr/bin/otool -L "$executable" | /usr/bin/awk '/Sparkle\.framework/ {print $1; exit}')"
[[ "$sparkle_link" == @rpath/Sparkle.framework/* ]] || {
    echo "Unexpected Sparkle linkage: ${sparkle_link:-missing}" >&2
    exit 1
}
if ! /usr/bin/otool -l "$executable" \
    | /usr/bin/awk '/cmd LC_RPATH/ {found=1} found && /path @loader_path\/\.\.\/Frameworks|path @executable_path\/\.\.\/Frameworks/ {ok=1} END {exit !ok}'; then
    echo "Executable does not contain the required Sparkle Frameworks rpath." >&2
    exit 1
fi
"$project_dir/scripts/check-release-safety.sh" --app "$app_path"

echo "Verified MyTerm $actual_version (Build $actual_build), macOS $minimum_system+, $architectures."
