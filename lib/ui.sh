#!/usr/bin/env bash
# ui.sh - all user-facing output helpers.
#
# Every message a student sees goes through these functions, which keeps
# the look consistent and makes it easy to confirm everything is Estonian.
#
# This file is sourced, never executed.

[[ -n "${_ITC_UI_LOADED:-}" ]] && return 0
_ITC_UI_LOADED=1

ui_header() {
    printf '%s\n' "${C_BOLD}=========================================================="
    printf '  %s\n' "$@"
    printf '%s%s\n' "==========================================================" "$C_RESET"
}

ui_info() {
    printf '%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"
}

ui_ok() {
    printf '%s%s%s %s\n' "$C_GREEN" "$SYM_OK" "$C_RESET" "$*"
}

ui_warn() {
    printf '%s%s%s %s\n' "$C_YELLOW" "$SYM_WARN" "$C_RESET" "$*"
}

ui_error() {
    printf '%s%s%s %s\n' "$C_RED" "$SYM_ERR" "$C_RESET" "$*" >&2
}

# ui_task <description> <command...> - show a progress line, run the
# command through the logger and print the result symbol.
ui_task() {
    local desc="$1"
    shift
    printf '%s ... ' "$desc"
    if run_logged "$desc" "$@"; then
        printf '%s%s%s\n' "$C_GREEN" "$SYM_OK" "$C_RESET"
        return 0
    fi
    printf '%s%s%s\n' "$C_RED" "$SYM_ERR" "$C_RESET"
    return 1
}

# ui_pause - wait for Enter before returning to the menu.
ui_pause() {
    printf '\n'
    read -rp "Vajuta Enter, et jätkata..." _ || true
}
