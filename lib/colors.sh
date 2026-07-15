#!/usr/bin/env bash
# colors.sh - terminal colors and status symbols.
#
# Colors are enabled only when stdout is a terminal, so log files and
# piped output stay clean.
#
# This file is sourced, never executed.
# shellcheck disable=SC2034  # variables are used by the other lib modules

[[ -n "${_ITC_COLORS_LOADED:-}" ]] && return 0
_ITC_COLORS_LOADED=1

if [[ -t 1 ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_CYAN=''
    C_BOLD=''
    C_RESET=''
fi

SYM_OK="[x]"
SYM_WARN="⚠"
SYM_ERR="✗"
