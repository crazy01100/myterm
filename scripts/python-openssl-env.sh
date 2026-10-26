#!/bin/bash
# Sourced only by project Python launchers. No GITHUB_ENV or global loader changes.
myterm_verify_python_openssl() {
  local runtime_dir="$project_dir/.build/openssl-runtime"
  local library_dir="$runtime_dir/lib"
  local part
  for part in "$project_dir/.build" "$runtime_dir" "$library_dir" "$library_dir/libssl.so.3" "$library_dir/libcrypto.so.3"; do
    [[ ! -L "$part" ]] || { echo 'Linked project OpenSSL source rejected.' >&2; return 69; }
  done
  [[ -f "$library_dir/libssl.so.3" && -f "$library_dir/libcrypto.so.3" ]] || {
    echo 'Prepare project OpenSSL before launching CI Python.' >&2; return 69;
  }
  # An injected third library could affect the interpreter before Python starts.
  local count
  count="$(/usr/bin/find "$library_dir" -mindepth 1 -maxdepth 1 | /usr/bin/wc -l)"
  [[ "$count" -eq 2 ]] || { echo 'Unexpected project OpenSSL library files.' >&2; return 69; }
  [[ -z "${LD_PRELOAD:-}" && -z "${LD_AUDIT:-}" && -z "${OPENSSL_CONF:-}" && -z "${OPENSSL_MODULES:-}" ]] || {
    echo 'Custom loader or OpenSSL provider settings require review.' >&2; return 69;
  }
  # This verifier must not load libraries from the directory it is verifying.
  if [[ -x /usr/bin/sha256sum ]]; then
    (cd "$library_dir" && /usr/bin/env -u LD_LIBRARY_PATH /usr/bin/sha256sum --strict --check "$project_dir/Config/Security/openssl-runtime.sha256" >/dev/null) || return 69
  else
    (cd "$library_dir" && /usr/bin/env -u LD_LIBRARY_PATH /usr/bin/shasum -a 256 --check "$project_dir/Config/Security/openssl-runtime.sha256" >/dev/null) || return 69
  fi
  case "${LD_LIBRARY_PATH:-}" in
    "$library_dir"|"$library_dir":*) ;;
    *) export LD_LIBRARY_PATH="$library_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" ;;
  esac
}
case "${MYTERM_CI_OPENSSL:-}" in
  '') ;; # Independent stdlib-only monitor health and non-CI tools remain unchanged.
  required)
    [[ "$(/usr/bin/uname -s)" == Linux && "$(/usr/bin/uname -m)" == x86_64 && "${GITHUB_ACTIONS:-}" == true ]] || {
      echo 'Isolated OpenSSL selection is limited to Linux x86_64 project CI.' >&2; exit 69;
    }
    myterm_verify_python_openssl || exit $?
    ;;
  *) echo 'Unknown project OpenSSL selection.' >&2; exit 69 ;;
esac
