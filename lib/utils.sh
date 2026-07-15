#!/usr/bin/env bash
# utils.sh - error handling, sudo management and small shared helpers.
#
# This file is sourced, never executed.

[[ -n "${_ITC_UTILS_LOADED:-}" ]] && return 0
_ITC_UTILS_LOADED=1

die() {
    ui_error "$*"
    exit 1
}

# itc_on_error - ERR trap handler: replace the raw Bash stack trace with a
# short Estonian message pointing at the log file.
itc_on_error() {
    local rc=$1 line=$2 src=$3
    log ERROR "Unexpected error (exit $rc) at ${src}:${line}"
    ui_error "Ootamatu viga (fail: $(basename "$src"), rida: $line)."
    ui_error "Täpsem info: $ITC_LOG_FILE"
    exit "$rc"
}

itc_setup_error_trap() {
    trap 'itc_on_error $? $LINENO "${BASH_SOURCE[0]}"' ERR
}

# require_not_root - the installer must run as the normal user; NVM, Node
# and Claude Code would otherwise land in root's home directory.
require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        ui_error "Ära käivita seda skripti root-kasutajana ega sudo abil."
        ui_error "Käivita lihtsalt: ./install.sh"
        exit 1
    fi
}

# ensure_sudo - make sure sudo is usable before a long install starts.
# With the passwordless setup (setup.ps1) this succeeds silently.
ensure_sudo() {
    if sudo -n true 2>/dev/null; then
        return 0
    fi
    ui_info "Paigaldamiseks on vaja administraatori õigusi."
    ui_info "Sisesta oma Ubuntu kasutaja parool (parool ei paista trükkides):"
    sudo -v
}

# trim <string> - strip leading and trailing whitespace.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# read_config <file> - print config lines with comments and blanks removed.
read_config() {
    local file="$1" line
    [[ -f "$file" ]] || die "Seadistusfail puudub: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        printf '%s\n' "$line"
    done <"$file"
}

# split_config_line <line> - split "a | b | c" into CFG_1, CFG_2, CFG_3.
# The CFG_* globals are read by the install and verify engines.
split_config_line() {
    local f1 f2 f3
    IFS='|' read -r f1 f2 f3 <<<"$1"
    # shellcheck disable=SC2034
    CFG_1="$(trim "${f1:-}")"
    # shellcheck disable=SC2034
    CFG_2="$(trim "${f2:-}")"
    # shellcheck disable=SC2034
    CFG_3="$(trim "${f3:-}")"
}
