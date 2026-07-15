#!/usr/bin/env bash
# 01-system.sh - install system tools listed in config/packages.conf.
#
# Runs standalone or via install.sh. Idempotent: only missing packages
# are installed.

set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/bootstrap.sh
source "$PROJECT_ROOT/lib/bootstrap.sh"

main() {
    require_not_root
    ui_header "Süsteemi tööriistade paigaldamine"

    if ! is_supported_ubuntu; then
        ui_warn "Sinu Ubuntu versioon ($(ubuntu_version)) ei ole ametlikult toetatud."
        ui_warn "Toetatud on Ubuntu 22.04 ja 24.04. Proovin siiski jätkata."
    fi

    ensure_sudo
    apt_refresh || die "Paketiloendite uuendamine ebaõnnestus. Kontrolli internetiühendust."
    # Failures are already reported nicely; exit directly past the ERR trap.
    install_apt_packages "$ITC_PACKAGES_CONF" || exit 1
}

main "$@"
