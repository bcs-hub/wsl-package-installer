#!/usr/bin/env bash
# 02-ai-tools.sh - install AI tools listed in config/ai-tools.conf
# (GitHub CLI, NVM, Node LTS, npm, Claude Code).
#
# Runs standalone or via install.sh. Idempotent: only missing tools are
# installed.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$PROJECT_ROOT/lib/bootstrap.sh"

main() {
    require_not_root
    ui_header "AI tööriistade paigaldamine"

    command_exists curl ||
        die "Tööriist curl puudub. Käivita kõigepealt: ./install.sh ja vali '1. Paigalda süsteemi tööriistad'."

    ensure_sudo
    # Failures are already reported nicely; exit directly past the ERR trap.
    install_custom_tools "$ITC_AI_TOOLS_CONF" || exit 1

    ui_info "Vihje: uues terminaliaknas on node ja claude kohe saadaval."
}

main "$@"
