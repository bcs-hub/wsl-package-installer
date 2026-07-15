#!/usr/bin/env bash
# logger.sh - file logging.
#
# All technical command output (apt, npm, curl, ...) goes to the log file
# so the screen shows only clean Estonian progress messages. When something
# fails, the student sends this file to the instructor.
#
# This file is sourced, never executed.

[[ -n "${_ITC_LOGGER_LOADED:-}" ]] && return 0
_ITC_LOGGER_LOADED=1

ITC_LOG_DIR="${ITC_LOG_DIR:-$HOME/.vali-it}"
ITC_LOG_FILE="${ITC_LOG_FILE:-$ITC_LOG_DIR/install.log}"

log_init() {
    mkdir -p "$ITC_LOG_DIR"
    touch "$ITC_LOG_FILE"
}

# log <level> <message...> - append a timestamped line to the log file.
log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >>"$ITC_LOG_FILE"
}

# run_logged <description> <command...> - run a command with all of its
# output redirected to the log file. Returns the command's exit code.
run_logged() {
    local desc="$1"
    shift
    local rc=0
    log INFO "START: $desc: $*"
    "$@" >>"$ITC_LOG_FILE" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then
        log INFO "OK: $desc"
    else
        log ERROR "FAIL (exit $rc): $desc"
    fi
    return "$rc"
}
