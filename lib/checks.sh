#!/usr/bin/env bash
# checks.sh - environment and command detection.
#
# Shared by the install engine and the verify engine so both always agree
# on whether a tool is present (important for NVM, which is a shell
# function loaded from ~/.nvm, not a binary on PATH).
#
# This file is sourced, never executed.

[[ -n "${_ITC_CHECKS_LOADED:-}" ]] && return 0
_ITC_CHECKS_LOADED=1

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

apt_package_installed() {
    dpkg -s "$1" >/dev/null 2>&1
}

# ubuntu_version - print VERSION_ID from /etc/os-release (e.g. "24.04").
ubuntu_version() {
    # shellcheck disable=SC1091
    (. /etc/os-release && printf '%s\n' "${VERSION_ID:-tundmatu}")
}

is_supported_ubuntu() {
    case "$(ubuntu_version)" in
        22.04 | 24.04) return 0 ;;
        *) return 1 ;;
    esac
}

is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

# load_nvm - load NVM into the current shell. Non-interactive scripts do
# not read ~/.bashrc, so NVM must be sourced explicitly. nvm.sh is not
# "set -u" clean, so strict mode is relaxed while sourcing it.
load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    [[ -s "$NVM_DIR/nvm.sh" ]] || return 1
    set +u
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"
    set -u
}

# tool_available <command> - true if the command is usable, taking into
# account tools that only exist after NVM is loaded (nvm, node, npm, ...).
tool_available() {
    local cmd="$1"
    if command_exists "$cmd"; then
        return 0
    fi
    load_nvm >/dev/null 2>&1 || return 1
    command -v "$cmd" >/dev/null 2>&1
}
