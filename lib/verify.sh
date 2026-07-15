#!/usr/bin/env bash
# verify.sh - config-driven verification engine.
#
# Reads the SAME config files as the install engine, so a tool added to
# config is automatically both installed and verified. This module NEVER
# installs anything.
#
# This file is sourced, never executed.

[[ -n "${_ITC_VERIFY_LOADED:-}" ]] && return 0
_ITC_VERIFY_LOADED=1

# verify_config <config-file> <fix-hint> - check every tool in the config.
# Prints one line per tool; returns the number of missing tools (0 = ok).
verify_config() {
    local file="$1" hint="$2"
    local -a lines
    mapfile -t lines < <(read_config "$file")
    local missing=0 line cmd desc

    for line in "${lines[@]}"; do
        split_config_line "$line"
        cmd="$CFG_2"
        desc="$CFG_3"
        if tool_available "$cmd"; then
            ui_ok "$desc"
        else
            ui_error "$desc — käsk '${cmd}' puudub"
            printf '    → Kuidas parandada: %s\n' "$hint"
            missing=$((missing + 1))
        fi
    done
    return "$missing"
}

# verify_all <packages.conf> <ai-tools.conf> - full verification with an
# Estonian summary. Returns 0 only when everything is present.
verify_all() {
    local packages_conf="$1" ai_tools_conf="$2"
    local missing=0

    ui_info "Kontrollin süsteemi tööriistu..."
    verify_config "$packages_conf" \
        "käivita ./install.sh ja vali '1. Paigalda süsteemi tööriistad'" || missing=$((missing + $?))

    printf '\n'
    ui_info "Kontrollin AI tööriistu..."
    verify_config "$ai_tools_conf" \
        "käivita ./install.sh ja vali '2. Paigalda AI tööriistad'" || missing=$((missing + $?))

    printf '\n'
    if [[ $missing -eq 0 ]]; then
        ui_ok "Kõik korras! Sinu arvuti on kursuseks valmis."
        return 0
    fi
    ui_error "Puudu on $missing tööriist(a)."
    ui_warn "Kui paigaldamine ei aita, saada õpetajale fail: $ITC_LOG_FILE"
    return 1
}
