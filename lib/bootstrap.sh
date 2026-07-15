#!/usr/bin/env bash
# bootstrap.sh - load all library modules in dependency order.
#
# Every top-level script does:
#   PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   source "$PROJECT_ROOT/lib/bootstrap.sh"
#
# This file is sourced, never executed.

[[ -n "${_ITC_BOOTSTRAP_LOADED:-}" ]] && return 0
_ITC_BOOTSTRAP_LOADED=1

if [[ -z "${PROJECT_ROOT:-}" ]]; then
    echo "PROJECT_ROOT must be set before sourcing bootstrap.sh" >&2
    exit 1
fi

# shellcheck source=lib/colors.sh
source "$PROJECT_ROOT/lib/colors.sh"
# shellcheck source=lib/logger.sh
source "$PROJECT_ROOT/lib/logger.sh"
# shellcheck source=lib/ui.sh
source "$PROJECT_ROOT/lib/ui.sh"
# shellcheck source=lib/checks.sh
source "$PROJECT_ROOT/lib/checks.sh"
# shellcheck source=lib/utils.sh
source "$PROJECT_ROOT/lib/utils.sh"
# shellcheck source=lib/installer.sh
source "$PROJECT_ROOT/lib/installer.sh"
# shellcheck source=lib/verify.sh
source "$PROJECT_ROOT/lib/verify.sh"

# Used by the step scripts, not inside this file.
# shellcheck disable=SC2034
ITC_PACKAGES_CONF="$PROJECT_ROOT/config/packages.conf"
# shellcheck disable=SC2034
ITC_AI_TOOLS_CONF="$PROJECT_ROOT/config/ai-tools.conf"

log_init
itc_setup_error_trap
