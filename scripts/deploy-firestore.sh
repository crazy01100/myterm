#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
project_id=""

usage() {
    cat <<'EOF'
Usage: scripts/deploy-firestore.sh --project FIREBASE_PROJECT_ID

Deploys this repository's Firestore Security Rules and indexes to the
explicitly named Firebase project. No default production project is used.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --project)
            (( $# >= 2 )) || { print -u2 -- "Missing value for --project"; exit 64; }
            project_id="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 -- "Unknown option: $1"
            usage >&2
            exit 64
            ;;
    esac
done

[[ -n "$project_id" ]] || {
    print -u2 -- "A Firebase Project ID is required. Pass --project explicitly."
    usage >&2
    exit 64
}

if [[ ! "$project_id" =~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' ]]; then
    print -u2 -- "Invalid Firebase Project ID: $project_id"
    exit 64
fi

exec "$project_dir/scripts/firebase-tools.sh" deploy \
    --project "$project_id" \
    --only firestore:rules,firestore:indexes
