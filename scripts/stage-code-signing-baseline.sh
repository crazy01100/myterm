#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source "$project_dir/scripts/code-signing-common.sh"

identity="${MYTERM_CODE_SIGN_IDENTITY:-}"
if (( $# == 2 )) && [[ "$1" == "--identity" ]]; then
    identity="$2"
elif (( $# != 0 )); then
    print -u2 -- "用法：scripts/stage-code-signing-baseline.sh [--identity SHA1]"
    exit 64
fi
if [[ -z "$identity" ]]; then
    identity="$(read_local_code_sign_identity "$project_dir" 2>/dev/null || true)"
fi
require_code_sign_identity "$identity"

work_dir="$(mktemp -d /private/tmp/MyTerm-CodeSign-baseline.XXXXXX)"
probe_app="$work_dir/MyTerm.app"
cleanup() {
    /bin/rm -rf -- "$work_dir"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/Resources"
/bin/cp /usr/bin/true "$probe_app/Contents/MacOS/MySSHClient"
/usr/bin/plutil -create xml1 "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleIdentifier -string "tw.local.MySSHClient" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string "MySSHClient" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundlePackageType -string "APPL" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleName -string "MyTerm" "$probe_app/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "1" "$probe_app/Contents/Info.plist"
/usr/bin/codesign --force --timestamp=none --sign "$identity" "$probe_app"

fingerprint="$(extract_code_sign_certificate_sha256 "$probe_app")"
requirement="$(extract_designated_requirement "$probe_app")"
[[ -n "$fingerprint" && -n "$requirement" ]] || {
    print -u2 -- "無法從測試 App 取得固定簽署基準。"
    exit 1
}
if print -r -- "$requirement" | /usr/bin/grep -Fq 'cdhash'; then
    print -u2 -- "產生的 designated requirement 仍含 cdhash，拒絕建立基準。"
    exit 1
fi

fingerprint_file="$project_dir/$MYTERM_CODE_SIGN_CERTIFICATE_SHA256_FILE"
requirement_file="$project_dir/$MYTERM_CODE_SIGN_REQUIREMENT_FILE"
if [[ -s "$fingerprint_file" ]]; then
    existing_fingerprint="$(read_trimmed_file "$fingerprint_file" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    [[ "$existing_fingerprint" == "$fingerprint" ]] || {
        print -u2 -- "既有憑證指紋不同；為避免意外輪替而停止。"
        exit 65
    }
fi
if [[ -s "$requirement_file" ]]; then
    existing_requirement="$(read_trimmed_file "$requirement_file")"
    [[ "$existing_requirement" == "$requirement" ]] || {
        print -u2 -- "既有 designated requirement 不同；為避免意外輪替而停止。"
        exit 65
    }
fi

/bin/mkdir -p "$project_dir/Config/Local" "$project_dir/Config/Release"
umask 077
print -r -- "$identity" > "$project_dir/$MYTERM_CODE_SIGN_IDENTITY_FILE"
/bin/chmod 0600 "$project_dir/$MYTERM_CODE_SIGN_IDENTITY_FILE"
print -r -- "$fingerprint" > "$fingerprint_file"
print -r -- "$requirement" > "$requirement_file"
/bin/chmod 0644 "$fingerprint_file" "$requirement_file"

validate_stable_code_signature "$project_dir" "$probe_app"
print -r -- "固定 Code Signing 基準已建立。"
print -r -- "憑證 SHA-256：$fingerprint"
print -r -- "designated requirement：$requirement"
