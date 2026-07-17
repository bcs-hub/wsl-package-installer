# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Vali-IT Installer** (formerly "IT Crafters Installer"; the GitHub repo is
`bcs-hub/vali-it-installer`, while this local working folder may still be named
`wsl-package-installer`) — a two-layer installer that sets up a complete Java development
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

# PSScriptAnalyzer for setup.ps1 + uninstall.ps1 (0 errors required; Write-Host warnings are
# intentional; -Path takes one string, hence the loop)
docker run --rm -v "$PWD:/src:ro" mcr.microsoft.com/powershell pwsh -NoProfile -Command \
  'Install-Module PSScriptAnalyzer -RequiredVersion 1.22.0 -Force -Scope CurrentUser *>$null; foreach ($f in "/src/setup.ps1", "/src/uninstall.ps1") { Invoke-ScriptAnalyzer -Path $f -Severity Error }'

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
- The Windows side is config-driven too: `config/windows-apps.conf` (winget id | check
  command | desc | fallback PDF | optional time-hint that replaces the generic "võib võtta
  mitu minutit" during install — `Read-ConfigFile` now parses F1..F5),
  `config/intellij-plugins.conf`, `config/manual-steps.conf`.
  setup.ps1 extracts the repo tarball on the Windows side to read these. Winget/PostgreSQL/
  IntelliJ behavior CANNOT be tested from this WSL dev machine — only PSSA + parse checks
  here; real verification happens on the user's Windows machines.
- Windows apps run BEFORE the WSL part (a WSL reboot then lands after apps are done).
  Existing Windows installs are never touched or upgraded. Slow steps (winget installs,
  IntelliJ plugins, npm ci, gradlew) run through `Invoke-TickedJob` (background job) or a
  process-poll loop so the console line ticks elapsed seconds — proof of life for students;
  winget's own output goes to `%TEMP%\vali-it-winget.log`, durations land in the summary
  and as the manifest's 4th field. `Code = 999` from Invoke-TickedJob means the job
  machinery failed → the winget call site falls back to a visible foreground run. An app counts as present when
  winget knows the id OR its check command is on PATH (a differently-packaged Node broke
  this once); IntelliJ is found via `Find-IdeaExe` path globs (Program Files, LocalAppData,
  Toolbox — winget can't see Toolbox installs). PostgreSQL superuser password is
  `student123`, course DB `vali_it`; a server with another password → DB creation goes to
  the manual list instead of failing the run. Plugins are skipped (→ manual step) while
  `idea64` is running — headless installPlugins fails then.
- **State manifest**: `%LOCALAPPDATA%\vali-it\installed.txt` (`kind|value|date` lines,
  helpers `Add-StateEntry`/`Test-StateEntry`) records what the installer ITSELF installed
  (apps by winget id, db, distro, idea-settings, idea-plugins set, course clone, wsl-user).
  Re-runs use it to say "paigaldatud varasemal käivitusel" instead of "juba olemas" /
  the IntelliJ "impordi ise" warning (which confused testers into redoing work), and to
  skip the headless plugin re-install. `uninstall.ps1` removes ONLY manifest entries by
  default — pre-existing software stays untouched, mirroring the installer.
  `$env:ITC_PURGE='1'` is a FULL test-machine reset: also config-listed apps, every
  supported distro on the machine, the course folder, JetBrains config dirs and
  PostgreSQL leftovers (for machines installed before the manifest existed).
  `$env:ITC_YES='1'` skips the JAH confirmation. Both helpers are best-effort and must never fail a step.
- **The WSL/Ubuntu part of setup.ps1 is best-effort**: distro-level failures go through
  `Stop-WslPart` (throw → main-flow catch → one red summary entry with PDF 006) and the
  run continues to course setup + summary; only pre-WSL problems (no admin, old Windows,
  unsupported `ITC_DISTRO`) still hard-`Fail`. Inside `Install-Distro` the
  `wsl.exe --install` output MUST stay piped to `Out-Host`: it runs inside
  `Select-TargetDistro` whose return value is captured, and unpiped progress text once
  corrupted the returned distro name (bogus "your Ubuntu is broken" on a healthy machine).
- The summary is three lists (ok / failed+PDF / manual+PDF). Manual steps = static
  `config/manual-steps.conf` + dynamic `Add-Manual` entries. The same summary is written
  to the desktop as `Vali-IT-kokkuvote.html` (opened in the browser; includes DB
  connection details) — the console version dies with the window. Guide links use
  `?raw=true` so GitHub serves the PDF as a direct download.
- Student guide PDFs live in `docs/install/` (001-Slack … 025-Serverite-kaivitamine;
  several are generated placeholders awaiting the instructor's real screenshots). When
  renumbering, update every reference in setup.ps1 + configs + README and verify each
  referenced file exists on disk.
- Course-repo preload (last setup.ps1 step, `Invoke-CourseSetup`): `config/course.conf`
  (`repo-url | folder under %USERPROFILE% | desc`; folder name derives from the URL's
  last segment) → clone to `%USERPROFILE%\vali-it\<repo>` (existing folder = student's
  work, clone skipped; preload still runs — it only writes caches), then `npm ci` in
  frontend (skipped when node_modules exists; requires committed package-lock.json) and
  `gradlew.bat dependencies` in backend (requires committed gradlew.bat). All best-effort:
  failures → Fail list, first build downloads deps itself. Temurin 21 installs via winget
  with `--override '/quiet ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome'`
  (PATH + JAVA_HOME); its conf check command is `-` on purpose — an old PATH `java` must
  not count as JDK 21; presence comes from `Find-Jdk21` (Adoptium/Oracle/Microsoft globs).
  Freshly installed tools are not on the running session's PATH → `Find-GitExe`/
  `Find-NpmCmd`/`Find-Jdk21` fallbacks, JAVA_HOME passed explicitly to gradlew. No build,
  no server start — students start servers in IntelliJ. The summary is outcome-driven
  (no static manual-steps.conf line): project on disk → dynamic Add-Manual "start the
  servers" step (PDF 025 + folder path, even when the preload failed — the first build
  downloads deps itself); clone failed/git missing → Add-Fail with the manual-download
  guide (PDF 023) and a clickable repo link (fail entries support an Extra field like
  manual steps). npm/gradle output goes to `%TEMP%\vali-it-course.log`.
- NVM is a shell function, not a binary: `lib/checks.sh::load_nvm` sources it explicitly
  (with `set -u` relaxed — nvm.sh is not set-u clean). Always use `tool_available`, not
  bare `command -v`, when checking tools: it loads NVM first AND rejects `/mnt/*` hits
  (WSL interop puts Windows-side tools on PATH; a tool installed only on Windows must not
  satisfy a Linux-side check).

## Binding Decisions (2026-07-15, override the spec — rationale in docs/ARCHITECTURE.md)

- **Docker inside WSL is OUT of scope**: no `docker.io`, no Docker group, no docker check
  in the Linux verify. Docker Desktop IS installed on Windows via winget; its first launch
  + WSL integration is a manual student step (PDF 019).
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
- **Public GitHub repo: `bcs-hub/vali-it-installer`**; students fetch `main` directly
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