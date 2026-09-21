#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
dev_app="$project_dir/build/dev/MyTerm Dev.app"
dev_executable="$dev_app/Contents/MacOS/MySSHClient"
version=""
build_number=""
build_date=""
build_only=0

usage() {
    cat <<'EOF'
Usage: scripts/run-dev-app.sh --version VERSION --build BUILD [options]

Safely closes only build/dev/MyTerm Dev.app, rebuilds it in the fixed
development location, verifies the bundle, then launches and identifies the
actual running process. Stops if production is running; the user must close it
manually. /Applications/MyTerm.app is never touched.

Options:
  --build-date DATE  Optional display date
  --build-only       Build and verify without launching
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --version)
            (( $# >= 2 )) || { print -u2 -- "Missing value for --version"; exit 64; }
            version="$2"
            shift 2
            ;;
        --build)
            (( $# >= 2 )) || { print -u2 -- "Missing value for --build"; exit 64; }
            build_number="$2"
            shift 2
            ;;
        --build-date)
            (( $# >= 2 )) || { print -u2 -- "Missing value for --build-date"; exit 64; }
            build_date="$2"
            shift 2
            ;;
        --build-only)
            build_only=1
            shift
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

[[ -n "$version" && -n "$build_number" ]] || { usage >&2; exit 64; }

exact_dev_pids() {
    local pid command_line
    local -a candidates matches
    candidates=("${(@f)$(/usr/bin/pgrep -f -- "${dev_executable:t}" 2>/dev/null || true)}")
    for pid in "${candidates[@]}"; do
        [[ -n "$pid" ]] || continue
        command_line="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command_line" == "$dev_executable" || "$command_line" == "$dev_executable "* ]]; then
            matches+=("$pid")
        fi
    done
    (( ${#matches[@]} > 0 )) && print -rl -- "${matches[@]}"
    return 0
}

foreign_myterm_processes() {
    local pid command_line
    local -a candidates matches
    candidates=("${(@f)$(/usr/bin/pgrep -f -- "MySSHClient" 2>/dev/null || true)}")
    for pid in "${candidates[@]}"; do
        [[ -n "$pid" ]] || continue
        command_line="$(/bin/ps -ww -p "$pid" -o command= 2>/dev/null || true)"
        if [[ "$command_line" == *"/Contents/MacOS/MySSHClient" || "$command_line" == *"/Contents/MacOS/MySSHClient "* ]]; then
            if [[ "$command_line" != "$dev_executable" && "$command_line" != "$dev_executable "*
                && "$command_line" != "/Applications/MyTerm.app/Contents/MacOS/MySSHClient"
                && "$command_line" != "/Applications/MyTerm.app/Contents/MacOS/MySSHClient "* ]]; then
                matches+=("$pid  $command_line")
            fi
        fi
    done
    (( ${#matches[@]} > 0 )) && print -rl -- "${matches[@]}"
    return 0
}

refresh_dev_pids() {
    local output
    output="$(exact_dev_pids)"
    running_pids=()
    [[ -n "$output" ]] && running_pids=("${(@f)output}")
    return 0
}

check_production_stopped() {
    "$project_dir/scripts/project-python.sh" "$project_dir/scripts/check-dev-launch.py"
}

# Fail before stopping the old Dev or building. Never terminate production.
check_production_stopped

typeset -a running_pids
foreign_processes="$(foreign_myterm_processes)"
if [[ -n "$foreign_processes" ]]; then
    print -u2 -- "Another MyTerm App is running from a non-development path."
    print -u2 -- "Close it manually before development verification; it will not be terminated automatically:"
    print -u2 -- "$foreign_processes"
    exit 70
fi

refresh_dev_pids
if (( ${#running_pids[@]} > 0 )); then
    print -- "Closing the existing development App: ${running_pids[*]}"
    for pid in "${running_pids[@]}"; do
        /bin/kill -TERM "$pid"
    done
    for _ in {1..50}; do
        refresh_dev_pids
        (( ${#running_pids[@]} == 0 )) && break
        /bin/sleep 0.2
    done
    refresh_dev_pids
    if (( ${#running_pids[@]} > 0 )); then
        print -u2 -- "Development App did not exit cleanly; refusing to rebuild: ${running_pids[*]}"
        exit 70
    fi
fi

build_arguments=(
    --channel development
    --version "$version"
    --build "$build_number"
)
if [[ -n "$build_date" ]]; then
    build_arguments+=(--build-date "$build_date")
fi

"$project_dir/scripts/build-app.sh" "${build_arguments[@]}"
"$project_dir/scripts/verify-app.sh" \
    --app "$dev_app" \
    --version "$version" \
    --build "$build_number"

if (( build_only == 1 )); then
    print -- "Development build verified without launching: $dev_app"
    exit 0
fi

# Recheck after the build: production may have been opened in the meantime.
check_production_stopped
/usr/bin/open -n "$dev_app"
for _ in {1..50}; do
    refresh_dev_pids
    (( ${#running_pids[@]} > 0 )) && break
    /bin/sleep 0.2
done
refresh_dev_pids
if (( ${#running_pids[@]} != 1 )); then
    print -u2 -- "Expected exactly one running development App, found ${#running_pids[@]}."
    exit 70
fi

plist="$dev_app/Contents/Info.plist"
actual_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")"
actual_build="$(/usr/bin/plutil -extract CFBundleVersion raw "$plist")"
bundle_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$plist")"
designated_requirement="$(/usr/bin/codesign -d -r- "$dev_app" 2>&1 | /usr/bin/sed -n 's/^designated => //p')"

print -- "Runtime verification passed:"
print -- "  channel: development"
print -- "  PID: ${running_pids[1]}"
print -- "  executable: $dev_executable"
print -- "  version: $actual_version"
print -- "  build: $actual_build"
print -- "  bundle ID: $bundle_id"
print -- "  designated requirement: $designated_requirement"
