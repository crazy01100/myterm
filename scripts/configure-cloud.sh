#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
firebase_config="$project_dir/Config/Local/GoogleService-Info.plist"
oauth_config="$project_dir/Config/Local/GoogleOAuthClient.json"
output="$project_dir/Config/Local/MyTermCloudConfig.plist"

if [[ ! -f "$firebase_config" ]]; then
    echo "Missing $firebase_config" >&2
    exit 66
fi
if [[ ! -f "$oauth_config" ]]; then
    echo "Missing $oauth_config" >&2
    echo "Download the Desktop OAuth JSON, rename it to GoogleOAuthClient.json, and place it in Config/Local." >&2
    exit 66
fi

/usr/bin/plutil -lint "$firebase_config" >/dev/null
/usr/bin/jq -e '
    .installed
    | type == "object"
      and (.client_id | type == "string")
      and (.client_secret | type == "string")
      and (.project_id | type == "string")
' "$oauth_config" >/dev/null
api_key="$(/usr/bin/plutil -extract API_KEY raw "$firebase_config")"
project_id="$(/usr/bin/plutil -extract PROJECT_ID raw "$firebase_config")"
client_id="$(/usr/bin/jq -er '.installed.client_id' "$oauth_config")"
client_secret="$(/usr/bin/jq -er '.installed.client_secret' "$oauth_config")"
oauth_project_id="$(/usr/bin/jq -er '.installed.project_id' "$oauth_config")"

if [[ "$client_id" != *.apps.googleusercontent.com || ${#client_secret} -lt 10 || "$oauth_project_id" != "$project_id" ]]; then
    echo "GoogleOAuthClient.json is not a valid Desktop OAuth client file." >&2
    exit 65
fi

/bin/chmod 0600 "$oauth_config"

temp_config="$(mktemp /private/tmp/MyTermCloudConfig.XXXXXX.plist)"
trap '/bin/rm -f -- "$temp_config"' EXIT
/usr/bin/plutil -create xml1 "$temp_config"
/usr/bin/plutil -insert GOOGLE_DESKTOP_CLIENT_ID -string "$client_id" "$temp_config"
/usr/bin/plutil -insert GOOGLE_DESKTOP_CLIENT_SECRET -string "$client_secret" "$temp_config"
/usr/bin/plutil -insert FIREBASE_API_KEY -string "$api_key" "$temp_config"
/usr/bin/plutil -insert FIREBASE_PROJECT_ID -string "$project_id" "$temp_config"
/usr/bin/plutil -lint "$temp_config" >/dev/null
/bin/mkdir -p "$project_dir/Config/Local"
/bin/cp "$temp_config" "$output"
/bin/chmod 0600 "$output"

echo "$output"
