#!/bin/sh
# An independent distributor supplies its own HTTPS base URL. No upstream endpoint.
validate_update_source() {
    export MYTERM_UPDATE_BASE_URL
    python3 - <<'CHECK'
import os, sys
from urllib.parse import urlsplit
value = os.environ.get("MYTERM_UPDATE_BASE_URL", "").rstrip("/")
try:
    u = urlsplit(value)
    port = u.port
except ValueError:
    sys.exit("Invalid HTTPS update base URL.")
if (u.scheme != "https" or not u.hostname or u.username is not None or u.password is not None
        or u.query or u.fragment or any(c.isspace() for c in value)):
    sys.exit("Set MYTERM_UPDATE_BASE_URL to your own HTTPS update base URL (no credentials, query, or fragment).")
CHECK
    result=$?
    [ "$result" -eq 0 ] || return "$result"
    MYTERM_UPDATE_BASE_URL="${MYTERM_UPDATE_BASE_URL%/}"
    export MYTERM_UPDATE_BASE_URL
}
