#!/bin/zsh

MYTERM_CODE_SIGN_IDENTITY_FILE="Config/Local/CodeSigningIdentity.txt"
MYTERM_CODE_SIGN_CERTIFICATE_SHA256_FILE="Config/Release/CodeSigningCertificateSHA256.txt"
MYTERM_CODE_SIGN_REQUIREMENT_FILE="Config/Release/CodeSigningDesignatedRequirement.txt"

read_trimmed_file() {
    local path="$1"
    [[ -f "$path" ]] || return 1
    /usr/bin/tr -d '\r\n' < "$path"
}

read_local_code_sign_identity() {
    local project_dir="$1"
    read_trimmed_file "$project_dir/$MYTERM_CODE_SIGN_IDENTITY_FILE"
}

require_code_sign_identity() {
    local identity="$1"
    [[ -n "$identity" && "$identity" != "-" ]] || {
        print -u2 -- "正式建置需要固定 Code Signing 身分，禁止使用 ad-hoc 簽署。"
        return 66
    }

    local identities
    identities="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null)"
    if ! print -r -- "$identities" | /usr/bin/grep -Fq -- "$identity"; then
        print -u2 -- "登入 Keychain 找不到可用的 Code Signing 身分：$identity"
        return 66
    fi
}

extract_code_sign_certificate_sha256() {
    local app_path="$1"
    local work_dir
    local prefix
    local certificate

    work_dir="$(mktemp -d /private/tmp/MyTerm-CodeSign-cert.XXXXXX)"
    prefix="$work_dir/certificate"
    certificate="${prefix}0"
    # The prefix is an optional argument in codesign's parser. macOS 26
    # requires the --option=value form or it treats the prefix as code input.
    if ! /usr/bin/codesign -d "--extract-certificates=$prefix" "$app_path" >/dev/null 2>&1; then
        /bin/rm -rf -- "$work_dir"
        return 1
    fi
    if [[ ! -f "$certificate" ]]; then
        /bin/rm -rf -- "$work_dir"
        return 1
    fi

    /usr/bin/shasum -a 256 "$certificate" | /usr/bin/awk '{print tolower($1)}'
    /bin/rm -rf -- "$work_dir"
}

extract_designated_requirement() {
    local app_path="$1"
    /usr/bin/codesign -d -r- "$app_path" 2>&1 \
        | /usr/bin/sed -n 's/^designated => //p' \
        | /usr/bin/head -1
}

validate_stable_code_signature() {
    local project_dir="$1"
    local app_path="$2"
    local expected_fingerprint_file="$project_dir/$MYTERM_CODE_SIGN_CERTIFICATE_SHA256_FILE"
    local expected_requirement_file="$project_dir/$MYTERM_CODE_SIGN_REQUIREMENT_FILE"
    local signature_details
    local expected_fingerprint
    local actual_fingerprint
    local expected_requirement
    local actual_requirement

    [[ -s "$expected_fingerprint_file" ]] || {
        print -u2 -- "缺少正式 Code Signing 憑證指紋：$expected_fingerprint_file"
        return 66
    }
    [[ -s "$expected_requirement_file" ]] || {
        print -u2 -- "缺少正式 designated requirement：$expected_requirement_file"
        return 66
    }

    signature_details="$(/usr/bin/codesign -dvvv "$app_path" 2>&1)"
    if print -r -- "$signature_details" | /usr/bin/grep -Fq 'Signature=adhoc'; then
        print -u2 -- "正式 App 不可使用 ad-hoc Code Signing。"
        return 1
    fi

    expected_fingerprint="$(read_trimmed_file "$expected_fingerprint_file" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    actual_fingerprint="$(extract_code_sign_certificate_sha256 "$app_path")" || {
        print -u2 -- "無法讀取 App 簽署憑證。"
        return 1
    }
    [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
        print -u2 -- "Code Signing 憑證指紋不符。"
        print -u2 -- "預期：$expected_fingerprint"
        print -u2 -- "實際：$actual_fingerprint"
        return 1
    }

    expected_requirement="$(read_trimmed_file "$expected_requirement_file")"
    actual_requirement="$(extract_designated_requirement "$app_path")"
    [[ -n "$actual_requirement" ]] || {
        print -u2 -- "App 缺少 designated requirement。"
        return 1
    }
    if print -r -- "$actual_requirement" | /usr/bin/grep -Fq 'cdhash'; then
        print -u2 -- "designated requirement 仍綁定單一版本 cdhash，不可作為固定發行身分。"
        return 1
    fi
    [[ "$actual_requirement" == "$expected_requirement" ]] || {
        print -u2 -- "App designated requirement 與正式基準不符。"
        print -u2 -- "預期：$expected_requirement"
        print -u2 -- "實際：$actual_requirement"
        return 1
    }
}
