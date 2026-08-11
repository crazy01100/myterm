#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/code-signing-common.sh"
scratch_dir="$project_dir/.build-app"
app_dir="$project_dir/build/MyTerm.app"
release_dir="$scratch_dir/arm64-apple-macosx/release"
build_state_file="$project_dir/build/.last-build-number"

usage() {
    cat <<'EOF'
Usage: scripts/build-app.sh --version VERSION --build BUILD [options]

  --version       Display version, for example 0.12.0 or 1.0.0-beta.1
  --build         Positive, monotonically increasing integer
  --build-date    Optional display date; defaults to the current local time
  --allow-rebuild Allow rebuilding the same Build for local diagnosis only
  --preflight     Validate version and Build ordering without compiling
  --sparkle-feed-url URL
                  HTTPS appcast URL; requires --sparkle-public-key
  --sparkle-public-key KEY
                  Sparkle Ed25519 public key; may be staged before the feed URL
  --update-lab    Build an isolated local-update test app with no cloud config
  --allow-loopback-http-feed
                  Allow only 127.0.0.1/localhost HTTP for --update-lab
  --app-output PATH
                  Update-lab-only App path under build/update-lab
  --build-state-file PATH
                  Update-lab-only Build state under build/update-lab
  --code-sign-identity ID
                  Fixed Code Signing identity; defaults to Config/Local
  --require-stable-signing
                  Reject ad-hoc signing and require the pinned release identity

The MYTERM_VERSION, MYTERM_BUILD_NUMBER, MYTERM_BUILD_DATE,
MYTERM_SPARKLE_FEED_URL, MYTERM_SPARKLE_PUBLIC_KEY and
MYTERM_CODE_SIGN_IDENTITY environment variables remain available for automation.
EOF
}

version="${MYTERM_VERSION:-}"
build_number="${MYTERM_BUILD_NUMBER:-}"
build_date="${MYTERM_BUILD_DATE:-}"
sparkle_feed_url="${MYTERM_SPARKLE_FEED_URL:-}"
sparkle_public_key="${MYTERM_SPARKLE_PUBLIC_KEY:-}"
code_sign_identity="${MYTERM_CODE_SIGN_IDENTITY:-}"
sparkle_public_key_file="$project_dir/Config/Release/SparklePublicKey.txt"
allow_rebuild=0
preflight_only=0
update_lab=0
allow_loopback_http_feed=0
require_stable_signing=0

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
        --allow-rebuild)
            allow_rebuild=1
            shift
            ;;
        --preflight)
            preflight_only=1
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
        --update-lab)
            update_lab=1
            shift
            ;;
        --allow-loopback-http-feed)
            allow_loopback_http_feed=1
            shift
            ;;
        --app-output)
            (( $# >= 2 )) || { echo "Missing value for --app-output" >&2; exit 64; }
            app_dir="$2"
            shift 2
            ;;
        --build-state-file)
            (( $# >= 2 )) || { echo "Missing value for --build-state-file" >&2; exit 64; }
            build_state_file="$2"
            shift 2
            ;;
        --code-sign-identity)
            (( $# >= 2 )) || { echo "Missing value for --code-sign-identity" >&2; exit 64; }
            code_sign_identity="$2"
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

if [[ -z "$version" || -z "$build_number" ]]; then
    echo "Both --version and --build are required." >&2
    usage >&2
    exit 64
fi
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$' ]]; then
    echo "Invalid version: $version" >&2
    exit 64
fi
if [[ ! "$build_number" =~ '^[1-9][0-9]*$' ]]; then
    echo "Build must be a positive integer: $build_number" >&2
    exit 64
fi
if [[ -z "$sparkle_public_key" && -f "$sparkle_public_key_file" ]]; then
    sparkle_public_key="$(<"$sparkle_public_key_file")"
fi
if [[ -z "$code_sign_identity" ]]; then
    code_sign_identity="$(read_local_code_sign_identity "$project_dir" 2>/dev/null || true)"
fi
if [[ -n "$code_sign_identity" && "$code_sign_identity" != "-" ]]; then
    require_code_sign_identity "$code_sign_identity"
fi
if (( require_stable_signing == 1 )); then
    require_code_sign_identity "$code_sign_identity"
    [[ -s "$project_dir/$MYTERM_CODE_SIGN_CERTIFICATE_SHA256_FILE" ]] || {
        echo "Missing pinned Code Signing certificate fingerprint." >&2
        exit 66
    }
    [[ -s "$project_dir/$MYTERM_CODE_SIGN_REQUIREMENT_FILE" ]] || {
        echo "Missing pinned Code Signing designated requirement." >&2
        exit 66
    }
fi
if [[ -n "$sparkle_feed_url" && -z "$sparkle_public_key" ]]; then
    echo "A Sparkle feed URL requires a public key." >&2
    exit 64
fi
if [[ -n "$sparkle_feed_url" ]]; then
    secure_feed=0
    loopback_feed=0
    [[ "$sparkle_feed_url" =~ '^https://[^[:space:]]+$' ]] && secure_feed=1
    [[ "$sparkle_feed_url" =~ '^http://(127\.0\.0\.1|localhost):[1-9][0-9]*/[^[:space:]]+$' ]] && loopback_feed=1
    if (( secure_feed == 0 && !(update_lab == 1 && allow_loopback_http_feed == 1 && loopback_feed == 1) )); then
        echo "Sparkle feed URL must use HTTPS; loopback HTTP is restricted to --update-lab." >&2
        exit 64
    fi
fi
if (( allow_loopback_http_feed == 1 && update_lab == 0 )); then
    echo "--allow-loopback-http-feed requires --update-lab." >&2
    exit 64
fi
if (( update_lab == 1 )); then
    update_lab_root="$project_dir/build/update-lab"
    if [[ "$app_dir" != "$update_lab_root"/*.app && "$app_dir" != "$update_lab_root"/*/*.app ]]; then
        echo "Update-lab App output must stay under build/update-lab and end in .app." >&2
        exit 64
    fi
    if [[ "$build_state_file" != "$update_lab_root"/* ]]; then
        echo "Update-lab Build state must stay under build/update-lab." >&2
        exit 64
    fi
elif [[ "$app_dir" != "$project_dir/build/MyTerm.app" || "$build_state_file" != "$project_dir/build/.last-build-number" ]]; then
    echo "Custom output and Build state paths require --update-lab." >&2
    exit 64
fi
if [[ -n "$sparkle_public_key" ]]; then
    decoded_key_size="$(print -rn -- "$sparkle_public_key" | /usr/bin/base64 -D 2>/dev/null | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    if [[ "$decoded_key_size" != "32" ]]; then
        echo "Sparkle public key must be a base64-encoded 32-byte Ed25519 public key." >&2
        exit 64
    fi
fi
if [[ -z "$build_date" ]]; then
    build_date="$(date '+%Y-%m-%d %H:%M:%S %z')"
fi

previous_build=""
if [[ -f "$build_state_file" ]]; then
    previous_build="$(<"$build_state_file")"
elif [[ -f "$app_dir/Contents/Info.plist" ]]; then
    previous_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$app_dir/Contents/Info.plist" 2>/dev/null || true)"
fi
if [[ -n "$previous_build" && "$previous_build" =~ '^[1-9][0-9]*$' ]]; then
    if (( build_number < previous_build )); then
        echo "Build $build_number is older than the last successful Build $previous_build." >&2
        exit 65
    fi
    if (( build_number == previous_build && allow_rebuild == 0 )); then
        echo "Build $build_number was already built. Use a larger Build number." >&2
        exit 65
    fi
fi
if (( preflight_only == 1 )); then
    echo "Build preflight passed for MyTerm $version (Build $build_number)."
    exit 0
fi

cd "$project_dir"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_dir/module-cache"
export CLANG_MODULE_CACHE_PATH="$scratch_dir/clang-cache"
swift build -c release --arch arm64 --scratch-path "$scratch_dir"

if [[ -d "$app_dir" ]]; then
    chmod -R u+w "$app_dir"
    /bin/rm -rf -- "$app_dir"
fi
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$release_dir/MySSHClient" "$app_dir/Contents/MacOS/MySSHClient"
/usr/bin/install_name_tool -add_rpath @loader_path/../Frameworks "$app_dir/Contents/MacOS/MySSHClient"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert MyTermBuildDate -string "$build_date" "$app_dir/Contents/Info.plist"
/usr/bin/plutil -insert SUEnableAutomaticChecks -bool false "$app_dir/Contents/Info.plist"
if (( require_stable_signing == 1 )); then
    stable_release_requirement="$(read_trimmed_file "$project_dir/$MYTERM_CODE_SIGN_REQUIREMENT_FILE")"
    /usr/bin/plutil -insert MyTermStableReleaseRequirement -string "$stable_release_requirement" "$app_dir/Contents/Info.plist"
fi
if (( update_lab == 1 )); then
    /usr/bin/plutil -replace CFBundleIdentifier -string "tw.local.MySSHClient.UpdateLab" "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleDisplayName -string "MyTerm 更新實驗室" "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleName -string "MyTerm 更新實驗室" "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert MyTermApplicationSupportDirectory -string "MyTerm Update Lab" "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert MyTermUpdateLabMode -bool true "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert NSAppTransportSecurity -xml '<dict><key>NSAllowsLocalNetworking</key><true/></dict>' "$app_dir/Contents/Info.plist"
fi
if [[ -n "$sparkle_public_key" ]]; then
    /usr/bin/plutil -insert SUPublicEDKey -string "$sparkle_public_key" "$app_dir/Contents/Info.plist"
fi
if [[ -n "$sparkle_feed_url" ]]; then
    /usr/bin/plutil -insert SUFeedURL -string "$sparkle_feed_url" "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert SURequireSignedFeed -bool true "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert SUVerifyUpdateBeforeExtraction -bool true "$app_dir/Contents/Info.plist"
fi
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
firebase_config="$project_dir/Config/Local/GoogleService-Info.plist"
if [[ -f "$firebase_config" ]]; then
    /usr/bin/plutil -lint "$firebase_config" >/dev/null
    app_bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$project_dir/Resources/Info.plist")"
    firebase_bundle_id="$(/usr/bin/plutil -extract BUNDLE_ID raw "$firebase_config")"
    if [[ "$firebase_bundle_id" != "$app_bundle_id" ]]; then
        echo "Firebase Bundle ID mismatch: expected $app_bundle_id, got $firebase_bundle_id" >&2
        exit 1
    fi
    if [[ "${MYTERM_INCLUDE_FIREBASE_CONFIG:-0}" == "1" ]]; then
        cp "$firebase_config" "$app_dir/Contents/Resources/GoogleService-Info.plist"
        chmod 0644 "$app_dir/Contents/Resources/GoogleService-Info.plist"
    fi
else
    echo "Firebase config not found; building local-only MyTerm." >&2
fi
cloud_config="$project_dir/Config/Local/MyTermCloudConfig.plist"
if (( update_lab == 0 )) && [[ -f "$cloud_config" ]]; then
    /usr/bin/plutil -lint "$cloud_config" >/dev/null
    runtime_cloud_config="$app_dir/Contents/Resources/MyTermCloudConfig.plist"
    allowed_cloud_keys=(
        FIREBASE_API_KEY FIREBASE_PROJECT_ID
        GOOGLE_DESKTOP_CLIENT_ID GOOGLE_DESKTOP_CLIENT_SECRET
    )
    unexpected_cloud_keys="$(
        /usr/bin/plutil -convert json -o - "$cloud_config" \
            | /usr/bin/jq -r \
                'keys - ["FIREBASE_API_KEY", "FIREBASE_PROJECT_ID", "GOOGLE_DESKTOP_CLIENT_ID", "GOOGLE_DESKTOP_CLIENT_SECRET"] | .[]'
    )"
    if [[ -n "$unexpected_cloud_keys" ]]; then
        echo "Cloud config contains non-allowlisted keys; refusing to package it." >&2
        exit 1
    fi
    /usr/bin/plutil -create xml1 "$runtime_cloud_config"
    for cloud_key in "${allowed_cloud_keys[@]}"; do
        cloud_value="$(/usr/bin/plutil -extract "$cloud_key" raw "$cloud_config")"
        /usr/bin/plutil -insert "$cloud_key" -string "$cloud_value" "$runtime_cloud_config"
    done
    chmod 0644 "$runtime_cloud_config"
fi
for resource_bundle in "$release_dir"/*.bundle(N); do
    cp -R "$resource_bundle" "$app_dir/Contents/Resources/"
done
sparkle_framework_candidates=("$scratch_dir"/artifacts/**/Sparkle.framework(N/))
if (( ${#sparkle_framework_candidates[@]} != 1 )); then
    echo "Expected one Sparkle.framework artifact, found ${#sparkle_framework_candidates[@]}." >&2
    exit 1
fi
/usr/bin/ditto "${sparkle_framework_candidates[1]}" "$app_dir/Contents/Frameworks/Sparkle.framework"

# Sparkle ships signed nested helpers. Preserve their signatures and seal the
# finished outer bundle instead of recursively replacing every nested signature.
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir/Contents/Frameworks/Sparkle.framework"
if [[ -n "$code_sign_identity" && "$code_sign_identity" != "-" ]]; then
    /usr/bin/codesign --force --timestamp=none --sign "$code_sign_identity" "$app_dir"
else
    /usr/bin/codesign --force --sign - "$app_dir"
fi
if (( require_stable_signing == 1 )); then
    validate_stable_code_signature "$project_dir" "$app_dir"
fi
mkdir -p "${build_state_file:h}"
print -r -- "$build_number" > "$build_state_file"

echo "MyTerm $version (Build $build_number, $build_date)"
echo "$app_dir"
