#!/usr/bin/env bash
# 03-verify.sh - verify the installation. NEVER installs anything.
#
# Runs standalone or via install.sh. Exit code 0 = everything present.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$PROJECT_ROOT/lib/bootstrap.sh"

main() {
    ui_header "Paigalduse kontroll"
    # "Tools are missing" is an expected outcome, not an unexpected error:
    # exit directly so the ERR trap does not add a misleading message.
    verify_all "$ITC_PACKAGES_CONF" "$ITC_AI_TOOLS_CONF" || exit 1
}

main "$@"
