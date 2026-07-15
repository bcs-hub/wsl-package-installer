#!/usr/bin/env bash
# installer.sh - config-driven install engine.
#
# Two kinds of tools exist:
#   1. apt packages (config/packages.conf) - fully described by config.
#   2. custom tools (config/ai-tools.conf) - each id maps to a function
#      named install_tool_<id> defined below. Adding a new custom tool =
#      one config line + one function.
#
# Everything is idempotent: tools that are already present are skipped.
#
# This file is sourced, never executed.

[[ -n "${_ITC_INSTALLER_LOADED:-}" ]] && return 0
_ITC_INSTALLER_LOADED=1

# Pinned NVM release; bump deliberately, not implicitly.
ITC_NVM_VERSION="v0.40.3"

apt_refresh() {
    ui_task "Uuendan paketiloendeid (apt update)" \
        sudo DEBIAN_FRONTEND=noninteractive apt-get update
}

# install_apt_packages <config-file> - install every missing apt package.
install_apt_packages() {
    local file="$1"
    local -a lines
    mapfile -t lines < <(read_config "$file")
    local total=${#lines[@]} i=0 failed=0 line pkg desc

    for line in "${lines[@]}"; do
        i=$((i + 1))
        split_config_line "$line"
        pkg="$CFG_1"
        desc="$CFG_3"
        if apt_package_installed "$pkg"; then
            ui_ok "[$i/$total] $desc — juba paigaldatud"
            continue
        fi
        if ! ui_task "[$i/$total] Paigaldan: $desc" \
            sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        ui_error "$failed paketi paigaldamine ebaõnnestus. Täpsem info: $ITC_LOG_FILE"
        return 1
    fi
    ui_ok "Kõik süsteemi tööriistad on olemas."
}

# install_custom_tools <config-file> - install every missing custom tool.
# Config order matters: nvm must come before node, node before npm/claude.
install_custom_tools() {
    local file="$1"
    local -a lines
    mapfile -t lines < <(read_config "$file")
    local total=${#lines[@]} i=0 failed=0 line id cmd desc func

    for line in "${lines[@]}"; do
        i=$((i + 1))
        split_config_line "$line"
        id="$CFG_1"
        cmd="$CFG_2"
        desc="$CFG_3"
        func="install_tool_${id}"

        if tool_available "$cmd"; then
            ui_ok "[$i/$total] $desc — juba paigaldatud"
            continue
        fi
        if ! declare -F "$func" >/dev/null; then
            ui_error "[$i/$total] $desc — seadistuse viga: funktsioon $func puudub"
            failed=$((failed + 1))
            continue
        fi
        if ! ui_task "[$i/$total] Paigaldan: $desc" "$func"; then
            failed=$((failed + 1))
        fi
    done

    if [[ $failed -gt 0 ]]; then
        ui_error "$failed tööriista paigaldamine ebaõnnestus. Täpsem info: $ITC_LOG_FILE"
        return 1
    fi
    ui_ok "Kõik AI tööriistad on olemas."
}

# --- custom tool installers ------------------------------------------------
# Convention: install_tool_<id> for every id in config/ai-tools.conf.

install_tool_gh() {
    # Official GitHub CLI apt repository (https://github.com/cli/cli).
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg |
        sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture)" |
        sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}

install_tool_nvm() {
    curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${ITC_NVM_VERSION}/install.sh" | bash
}

install_tool_node() {
    load_nvm || return 1
    # nvm's own code is not "set -u" clean; relax it inside a subshell.
    (
        set +u
        nvm install --lts
        nvm alias default 'lts/*'
    )
}

install_tool_npm() {
    # npm ships with Node; if npm is missing, (re)install the Node LTS.
    install_tool_node
}

install_tool_claude() {
    load_nvm || return 1
    (
        set +u
        nvm use default >/dev/null
        npm install -g @anthropic-ai/claude-code
    )
}
