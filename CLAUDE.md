# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Vali-IT Installer** (renamed from "IT Crafters Installer"; repo may later be renamed to
`vali-it-installer`) — a two-layer installer that sets up a complete Java development
environment for beginner students on Windows 10/11 + Ubuntu 22.04/24.04 inside WSL2.
Layer 1 is `setup.ps1` (Windows bootstrap, the student's only entry point): winget apps
(Git, Node, PostgreSQL + `vali_it` DB, IntelliJ + plugins + settings seed, Docker Desktop),
then WSL2 + Ubuntu, then a three-part summary (ok / failed+PDF / manual+PDF). Layer 2 is
`install.sh` + `scripts/` + `lib/` + `config/` (Bash, runs inside Ubuntu). Architecture and
decision rationale: `docs/ARCHITECTURE.md`. Original spec: `Codex_Prompt_IT_Crafters_Installer.md`
(decisions below override it where they conflict). User-visible brand is "Vali-IT",
technical identifiers use `vali-it` (`~/.vali-it/install.log`, `/etc/sudoers.d/vali-it`,
`~/vali-it-installer`); internal shell/PS variable prefixes stay `ITC_`.

## Commands

```bash
# Lint (must stay clean; shellcheck is not installed on this machine, use Docker)
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:v0.10.0 -x install.sh scripts/*.sh lib/*.sh

# PSScriptAnalyzer for setup.ps1 (0 errors required; Write-Host warnings are intentional)
docker run --rm -v "$PWD:/src:ro" mcr.microsoft.com/powershell pwsh -NoProfile -Command \
  'Install-Module PSScriptAnalyzer -RequiredVersion 1.22.0 -Force -Scope CurrentUser *>$null; Invoke-ScriptAnalyzer -Path /src/setup.ps1 -Severity Error'

# Full smoke test in a clean container (swap 24.04 for 22.04; both must pass, twice = idempotency)
docker run --rm -v "$PWD:/src:ro" ubuntu:24.04 bash -c '
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo ca-certificates curl >/dev/null 2>&1 &&
  useradd -m -s /bin/bash student && echo "student ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/student &&
  cp -r /src /home/student/app && chown -R student:student /home/student/app &&
  chmod +x /home/student/app/install.sh /home/student/app/scripts/*.sh &&
  su - student -c "cd ~/app && ./install.sh --all" && su - student -c "cd ~/app && ./install.sh --all"'

# Safe to run on a real machine (read-only check):
./install.sh --verify
```

Never run `./install.sh --all` or the step scripts directly on this development machine —
they install packages system-wide. Use the container. CI (`.github/workflows/ci.yml`) runs
all of the above on every push/PR; `main` must always stay green because students fetch it
directly.

## Architecture Essentials

- **Config drives everything**: `config/*.conf` lines are `package-or-id | check-command |
  Estonian description`. The install engine (`lib/installer.sh`) and verify engine
  (`lib/verify.sh`) read the SAME files. New apt package = one config line. New custom tool
  = config line in `ai-tools.conf` + an `install_tool_<id>` function in `lib/installer.sh`.
- Step scripts (`scripts/0*.sh`) are thin, standalone-runnable orchestrators; all logic
  lives in `lib/`. Every script sources `lib/bootstrap.sh` which loads modules in order.
- `install.sh` runs steps as child processes (`run_step`) so a failed step can't kill the
  menu. Expected failures `exit 1` directly to bypass the ERR trap (which is only for
  unexpected errors and points to the log).
- All user-visible output goes through `lib/ui.sh` helpers and MUST be Estonian; comments
  and log-file content are English. Technical output goes to `~/.vali-it/install.log`
  via `run_logged`, never to the screen.
- The Windows side is config-driven too: `config/windows-apps.conf` (winget id | desc |
  fallback PDF), `config/intellij-plugins.conf`, `config/manual-steps.conf`. setup.ps1
  extracts the repo tarball on the Windows side to read these. Winget/PostgreSQL/IntelliJ
  behavior CANNOT be tested from this WSL dev machine — only PSSA + parse checks here;
  real verification happens on the user's Windows machines.
- Windows apps run BEFORE the WSL part (a WSL reboot then lands after apps are done).
  Existing Windows installs are never touched or upgraded; PostgreSQL with a non-default
  password → the `vali_it` DB creation goes to the manual list instead of failing the run.
- NVM is a shell function, not a binary: `lib/checks.sh::load_nvm` sources it explicitly
  (with `set -u` relaxed — nvm.sh is not set-u clean). Always use `tool_available`, not
  bare `command -v`, when checking tools: it loads NVM first AND rejects `/mnt/*` hits
  (WSL interop puts Windows-side tools on PATH; a tool installed only on Windows must not
  satisfy a Linux-side check).

## Binding Decisions (2026-07-15, override the spec — rationale in docs/ARCHITECTURE.md)

- **Docker is OUT of scope**: no `docker.io`, no Docker group, no docker check in verify.
  Handled as a separate effort later.
- **Never run as root**: `install.sh` refuses `sudo ./install.sh`; only apt commands use
  sudo. NVM/Node/Claude Code must land in the student's home.
- **setup.ps1 is a resumable state machine**: every step is "already done? → skip". It
  creates the Linux user and grants passwordless sudo via `/etc/sudoers.d/vali-it`
  (through `wsl -u root`; never touch an existing user's password).
- **Never delete/reset/unregister an existing distro.** Reuse existing 22.04/24.04; if
  both exist, ask (24.04 recommended; `$env:ITC_DISTRO` skips the prompt). Broken distro →
  Estonian message referring to the instructor, no destructive auto-repair.
- **No top-level `param()` in setup.ps1** — Windows PowerShell 5.1 cannot parse it through
  `irm | iex` (the student path). Overrides are env vars: `$env:ITC_DISTRO`, `$env:ITC_BRANCH`.
- **Public GitHub repo: `bcs-hub/wsl-package-installer`**; students fetch `main` directly
  (`$RepoSlug` in setup.ps1, one-liner URL in README.md). Nothing sensitive in the repo,
  ever.

## Hard Requirements (from the spec)

- **All user-facing messages must be in Estonian.** Code comments in English.
- Support Ubuntu 22.04 AND 24.04; never use a 24.04-only feature without a fallback.
- `set -Eeuo pipefail` everywhere; no raw Bash stack traces shown to users.
- ShellCheck clean, idempotent (re-run safe), `03-verify.sh` never installs anything.
- `setup.ps1` must be UTF-8 **without BOM**: through `irm | iex` (the student path) PS 5.1
  shows a BOM as a red "command not found" error on line 1, while HTTP charset handles the
  decoding anyway. Trade-off: running the *file* locally in PS 5.1 mangles Estonian
  characters — test locally with PowerShell 7 (`pwsh`). Keep CRLF/LF rules from `.gitattributes`.