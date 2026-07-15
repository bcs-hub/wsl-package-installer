#!/usr/bin/env bash
# install.sh - Vali-IT Installer main entry point.
#
# Modes:
#   ./install.sh            interactive Estonian menu
#   ./install.sh --all      non-interactive: run every step (used by setup.ps1 and CI)
#   ./install.sh --verify   verification only
#   ./install.sh --help     usage

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$PROJECT_ROOT/lib/bootstrap.sh"

# run_step <script> - run a step script as a child process so that one
# failed step reports nicely and the menu keeps working.
run_step() {
    local script="$PROJECT_ROOT/scripts/$1"
    if bash "$script"; then
        return 0
    fi
    printf '\n'
    ui_error "Samm ebaõnnestus. Täpsem info: $ITC_LOG_FILE"
    ui_warn "Võid sama sammu menüüst uuesti käivitada — juba tehtud osa ei tehta topelt."
    return 1
}

run_all() {
    run_step "01-system.sh" || return 1
    printf '\n'
    run_step "02-ai-tools.sh" || return 1
    printf '\n'
    run_step "03-verify.sh"
}

show_menu() {
    printf '\n'
    ui_header "Vali-IT Installer" "Ubuntu keskkonna seadistamine"
    printf '\n'
    printf '  1. Paigalda süsteemi tööriistad\n'
    printf '  2. Paigalda AI tööriistad\n'
    printf '  3. Kontrolli paigaldust\n'
    printf '  4. Paigalda kõik\n'
    printf '  5. Välju\n'
    printf '\n'
}

menu_loop() {
    local choice
    while true; do
        show_menu
        read -rp "Vali tegevus [1-5]: " choice || choice=5
        printf '\n'
        case "$choice" in
            1) run_step "01-system.sh" || true ;;
            2) run_step "02-ai-tools.sh" || true ;;
            3) run_step "03-verify.sh" || true ;;
            4) run_all || true ;;
            5)
                ui_info "Head kodeerimist!"
                return 0
                ;;
            *)
                ui_warn "Tundmatu valik: ${choice}. Palun vali number 1 kuni 5."
                ;;
        esac
        [[ "$choice" =~ ^[1-4]$ ]] && ui_pause
    done
}

usage() {
    cat <<EOF
Vali-IT Installer — Ubuntu keskkonna seadistamine

Kasutamine:
  ./install.sh            interaktiivne menüü
  ./install.sh --all      paigalda kõik ja kontrolli (ilma menüüta)
  ./install.sh --verify   ainult paigalduse kontroll
  ./install.sh --help     see abitekst
EOF
}

main() {
    require_not_root
    # Step failures are already reported by run_step; exit directly so the
    # ERR trap does not add a second, misleading message.
    case "${1:-}" in
        "") menu_loop ;;
        --all) run_all || exit 1 ;;
        --verify) run_step "03-verify.sh" || exit 1 ;;
        --help | -h) usage ;;
        *)
            ui_error "Tundmatu valik: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
