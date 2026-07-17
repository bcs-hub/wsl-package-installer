# setup.ps1 - Vali-IT Installer, Windows bootstrap.
#
# The student's single entry point. Run in an elevated PowerShell:
#   irm https://raw.githubusercontent.com/bcs-hub/vali-it-installer/main/setup.ps1 | iex
#
# Resumable state machine: every step checks whether it is already done
# and skips it, so re-running the same command (e.g. after the WSL reboot)
# simply continues from where it left off. Nothing is ever deleted:
# existing distros, apps, users and passwords are left untouched.
#
# Order: Windows apps (winget) first, then WSL + Ubuntu. A possible WSL
# reboot therefore lands AFTER the Windows apps are already done.
#
# All user-facing messages are in Estonian; comments are in English.
# NB: keep this file UTF-8 WITHOUT BOM (PS 5.1 + 'irm | iex' chokes on BOM).

# NOTE: no param() block on purpose — Windows PowerShell 5.1 cannot parse a
# top-level param block through 'irm ... | iex'. Optional overrides come from
# environment variables instead (instructor/testing use):
#   $env:ITC_DISTRO = 'Ubuntu-22.04'   # force a specific distro
#   $env:ITC_BRANCH = 'my-branch'      # install from a non-main branch
$Distro = if ($env:ITC_DISTRO) { $env:ITC_DISTRO } else { '' }
$Branch = if ($env:ITC_BRANCH) { $env:ITC_BRANCH } else { 'main' }

# Deliberately NOT 'Stop': in Windows PowerShell 5.1 that turns any native
# command's stderr output (e.g. harmless WSL systemd warnings) into a fatal
# error whenever the stream is redirected. Failures are detected through
# $LASTEXITCODE checks instead; cmdlets that must throw use -ErrorAction Stop.
$ErrorActionPreference = 'Continue'

$RepoSlug = 'bcs-hub/vali-it-installer'

$SupportedDistros = @('Ubuntu-24.04', 'Ubuntu-22.04')
$DefaultDistro = 'Ubuntu-24.04'
$InstallDirName = 'vali-it-installer'
$DbName = 'vali_it'
$PgSuperPassword = 'student123'
$WslGuidePdf = 'docs/install/006-WSL-Ubuntu-install-Windows-masinas.pdf'

# State manifest: records what THIS installer actually installed, as opposed
# to what was already on the machine. Re-runs use it to say "installed on an
# earlier run" instead of a confusing warning, and uninstall.ps1 removes ONLY
# the items recorded here (pre-existing software is never its business).
$StateDir = Join-Path $env:LOCALAPPDATA 'vali-it'
$StateFile = Join-Path $StateDir 'installed.txt'

# winget runs in a background job (so the console can tick elapsed time);
# its own output lands here instead of the screen.
$WingetLogFile = Join-Path $env:TEMP 'vali-it-winget.log'

# Result tracking for the final summary.
$script:OkList = @()
$script:FailList = @()
$script:ManualList = @()   # dynamic manual steps discovered during the run
$script:RepoTar = ''
$script:RepoDir = ''
$script:WslAbort = $null   # set by Stop-WslPart, read by the main-flow catch
$script:RunTimer = [System.Diagnostics.Stopwatch]::StartNew()   # whole-run duration

# Make wsl.exe output plain UTF-8 instead of UTF-16 so it can be parsed.
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# A single mouse click into a classic console window starts a QuickEdit text
# selection that FREEZES all output until a key is pressed — the install
# keeps running but looks hung, and the unfreezing keypress lands in the
# input buffer. Turn QuickEdit off for this console (best-effort; only
# affects this window).
try {
    if (-not ('ValiIt.ConsoleMode' -as [type])) {
        Add-Type -Namespace 'ValiIt' -Name 'ConsoleMode' -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@
    }
    $cm = 'ValiIt.ConsoleMode' -as [type]
    $hIn = $cm::GetStdHandle(-10)   # STD_INPUT_HANDLE
    $mode = [uint32]0
    if ($cm::GetConsoleMode($hIn, [ref]$mode)) {
        # Clear ENABLE_QUICK_EDIT_MODE (0x40); ENABLE_EXTENDED_FLAGS (0x80)
        # must be set for the QuickEdit bit to be honoured. The original
        # mode is restored at exit so select/copy works again afterwards.
        $script:OrigConsoleMode = $mode
        [void]$cm::SetConsoleMode($hIn, ($mode -band (-bnot [uint32]0x40)) -bor [uint32]0x80)
    }
} catch { }

function Restore-ConsoleMode {
    try {
        if ($null -ne $script:OrigConsoleMode) {
            $cm = 'ValiIt.ConsoleMode' -as [type]
            [void]$cm::SetConsoleMode($cm::GetStdHandle(-10), [uint32]$script:OrigConsoleMode)
            $script:OrigConsoleMode = $null
        }
    } catch { }
}

# Everything on screen also goes to a log file, so an error can still be
# read after the window has closed (best-effort — a failed transcript must
# not stop the install).
$SetupLogFile = Join-Path $env:TEMP 'vali-it-setup.log'
$script:LogStarted = $false
try {
    # -Append: a rerun (e.g. after the WSL reboot) must not wipe the log of
    # the run where the actual failure happened; the transcript header
    # separates the sessions.
    Start-Transcript -Path $SetupLogFile -Append -Force *> $null
    $script:LogStarted = $true
} catch { }

function Stop-SetupLog {
    if ($script:LogStarted) {
        try { Stop-Transcript *> $null } catch { }
        $script:LogStarted = $false
        Write-Host "Kogu väljund on salvestatud faili: $SetupLogFile" -ForegroundColor Cyan
    }
}

function Write-Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Err([string]$m) { Write-Host "✗ $m" -ForegroundColor Red }

function Format-Duration([TimeSpan]$t) {
    $s = [int][math]::Floor($t.TotalSeconds)
    if ($s -lt 60) { return "${s}s" }
    if ($s -lt 3600) { return "$([math]::Floor($s / 60))m $($s % 60)s" }
    return "$([math]::Floor($s / 3600))h $([math]::Floor(($s % 3600) / 60))m"
}

# Run a slow external command in a background job while ticking the elapsed
# time on one console line — a silent minutes-long step looks hung, and the
# ticking seconds are the student's proof of life. The command's own output
# goes to $OutLog, not the screen. Returns @{ Code; Duration }; Code 999
# means the job machinery itself failed (caller may fall back to running in
# the foreground).
function Invoke-TickedJob([string]$Label, [string]$Exe, [object[]]$CmdArgs,
    [string]$Dir = '', [string]$JavaHome = '', [string]$OutLog = '') {
    $j = Start-Job -ScriptBlock {
        param($Exe, $CmdArgs, $Dir, $JavaHome)
        if ($Dir) { Set-Location $Dir }
        if ($JavaHome) { $env:JAVA_HOME = $JavaHome }
        $out = & $Exe @CmdArgs 2>&1 | Out-String
        [pscustomobject]@{ Out = $out; Code = $LASTEXITCODE }
    } -ArgumentList @($Exe, $CmdArgs, $Dir, $JavaHome)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($j.State -eq 'Running') {
        Write-Host ("`r$Label ... " + (Format-Duration $sw.Elapsed) + '  ') -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    $dur = Format-Duration $sw.Elapsed
    Write-Host ("`r$Label ... $dur  ") -ForegroundColor Cyan
    $res = @(Receive-Job $j 2>$null) |
        Where-Object { $_ -and $_.PSObject.Properties['Code'] } | Select-Object -Last 1
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    # No result object, or a null exit code (command not found inside the
    # job) — both mean the command never really ran.
    if ($null -eq $res -or $null -eq $res.Code) { return [pscustomobject]@{ Code = 999; Duration = $dur } }
    if ($res.Out -and $OutLog) {
        # Run separator: these logs grow across reruns and would otherwise
        # be one unreadable blob.
        try {
            "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Label ===`r`n$($res.Out)" |
                Out-File -FilePath $OutLog -Append -Encoding UTF8
        } catch { }
    }
    return [pscustomobject]@{ Code = $res.Code; Duration = $dur }
}

function Add-Ok([string]$Name) { $script:OkList += $Name }
function Add-Fail([string]$Name, [string]$Pdf, [string]$Extra = '') {
    $script:FailList += [pscustomobject]@{ Name = $Name; Pdf = $Pdf; Extra = $Extra }
}
function Add-Manual([string]$Name, [string]$Pdf, [string]$Extra = '') {
    $script:ManualList += [pscustomobject]@{ Name = $Name; Pdf = $Pdf; Extra = $Extra }
}
# ?raw=true makes GitHub serve the file as a direct download — no need to
# hunt for the download button on the blob page.
function Get-DocUrl([string]$Path) { "https://github.com/$RepoSlug/blob/main/$Path`?raw=true" }
function Get-RawUrl([string]$Path) { "https://raw.githubusercontent.com/$RepoSlug/main/$Path" }

# Exiting kills the whole PowerShell session under 'irm | iex' — the console
# window closes before the student can read anything. Always pause first.
function Stop-Installer([int]$Code) {
    Write-Host ''
    Stop-SetupLog
    # Restore QuickEdit BEFORE the pause, so the student can select/copy
    # text from the window while it is still open.
    Restore-ConsoleMode
    # Keystrokes pressed during the long installs sit in the console input
    # buffer and would answer this Read-Host instantly, closing the window
    # before anything can be read — flush them first.
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    Read-Host 'Vajuta Enter, et lõpetada (aken läheb kinni)' | Out-Null
    exit $Code
}

function Fail([string]$m) {
    Write-Err $m
    Write-Host ''
    Write-Host 'Kui vajad abi, pöördu õpetaja poole.' -ForegroundColor Yellow
    Stop-Installer 1
}

# Abort ONLY the WSL/Ubuntu part of the run: record the reason and unwind to
# the main flow, whose catch adds one fail entry (usually with the WSL guide
# PDF) and carries on. A WSL problem must not cost the student the summary —
# the Windows apps are already done by the time we get here.
function Stop-WslPart([string]$Msg, [string]$Pdf = '', [string]$Extra = '') {
    $script:WslAbort = [pscustomobject]@{ Msg = $Msg; Pdf = $Pdf; Extra = $Extra }
    throw 'wsl-abort'
}

# --- state manifest ----------------------------------------------------------

# Both helpers are best-effort on purpose: a state-file hiccup must never
# fail an installation step. Lines are 'kind|value|date'.
function Test-StateEntry([string]$Kind, [string]$Value) {
    try {
        if (-not (Test-Path $StateFile)) { return $false }
        foreach ($line in (Get-Content -Path $StateFile -Encoding UTF8)) {
            $p = $line -split '\|'
            if ($p.Count -ge 2 -and $p[0].Trim() -eq $Kind -and $p[1].Trim() -eq $Value) { return $true }
        }
    } catch { }
    return $false
}

# $Note is a free-form fourth field (e.g. the install duration); readers
# only ever look at the first two fields.
function Add-StateEntry([string]$Kind, [string]$Value, [string]$Note = '') {
    try {
        if (Test-StateEntry $Kind $Value) { return }
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        $line = "$Kind|$Value|$(Get-Date -Format 'yyyy-MM-dd HH:mm')"
        if ($Note) { $line += "|$Note" }
        $line | Out-File -FilePath $StateFile -Append -Encoding UTF8
    } catch { }
}

# Run a command inside the distro as root. Returns stdout; sets $LASTEXITCODE.
# stderr is dropped: fresh distros print harmless systemd-session warnings
# that would only scare students; failures are detected via $LASTEXITCODE.
function Invoke-DistroRoot([string]$Name, [string]$Script) {
    & wsl.exe -d $Name -u root -- bash -c $Script 2>$null
}

# Read a "a | b | c | d" config file into objects with F1..F4 fields.
function Read-ConfigFile([string]$Path) {
    $rows = @()
    if (-not (Test-Path $Path)) { return $rows }
    foreach ($raw in (Get-Content -Path $Path -Encoding UTF8)) {
        $line = ($raw -split '#', 2)[0].Trim()
        if (-not $line) { continue }
        $p = $line -split '\|'
        $rows += [pscustomobject]@{
            F1 = $p[0].Trim()
            F2 = $(if ($p.Count -gt 1) { $p[1].Trim() } else { '' })
            F3 = $(if ($p.Count -gt 2) { $p[2].Trim() } else { '' })
            F4 = $(if ($p.Count -gt 3) { $p[3].Trim() } else { '' })
        }
    }
    return $rows
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Prerequisites {
    if (-not (Test-IsAdmin)) {
        Fail ('Seda skripti tuleb käivitada administraatorina. ' +
            'Tee Start-nupul paremklõps, vali "Terminal (Admin)" ja proovi uuesti.')
    }
    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt 19041) {
        Fail ("Sinu Windowsi versioon on liiga vana (build $build). " +
            'Vajalik on Windows 10 versioon 2004 (build 19041) või uuem. Uuenda Windowsit ja proovi uuesti.')
    }
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        Write-Err 'Sinu Windowsil puudub WSL-i tugi (wsl.exe). Tõenäoliselt on Windows pikalt uuendamata.'
        Write-Host ''
        Write-Info 'Kuidas parandada:'
        Write-Info '  1. Ava: Seaded -> Windows Update'
        Write-Info '  2. Paigalda KÕIK pakutavad uuendused (võib vajada mitut taaskäivitust).'
        Write-Info '  3. Käivita seejärel sama käsk uuesti.'
        Fail 'Paigaldust ei saa enne Windowsi uuendamist jätkata.'
    }
    Write-Ok 'Windowsi eelkontroll läbitud.'
}

# Download the installer from GitHub and unpack it on the Windows side too:
# the config files drive the Windows-apps step, and tar.exe ships with
# Windows 10 1803+, so no extra tools are needed.
function Get-RepoFiles {
    $url = "https://github.com/$RepoSlug/archive/refs/heads/$Branch.tar.gz"
    $script:RepoTar = Join-Path $env:TEMP 'vali-it-installer.tar.gz'
    $script:RepoDir = Join-Path $env:TEMP 'vali-it-installer-src'

    Write-Info 'Laen alla Vali-IT installeri...'
    try {
        Invoke-WebRequest -Uri $url -OutFile $script:RepoTar -UseBasicParsing -ErrorAction Stop
    } catch {
        Fail "Allalaadimine ebaõnnestus ($url). Kontrolli internetiühendust ja proovi uuesti."
    }
    if (Test-Path $script:RepoDir) { Remove-Item -Recurse -Force $script:RepoDir }
    New-Item -ItemType Directory -Path $script:RepoDir -Force | Out-Null
    & tar.exe -xzf $script:RepoTar -C $script:RepoDir --strip-components=1
    if ($LASTEXITCODE -ne 0) { Fail 'Installeri lahtipakkimine ebaõnnestus.' }
    Write-Ok 'Installer on alla laaditud.'
}

# --- Windows apps (winget) ---------------------------------------------------

# Find a JDK 21 java.exe in the standard vendor locations. A freshly
# installed Temurin is not on the current session's PATH yet, and an old
# PATH java (e.g. Java 8) must not count as JDK 21 — hence explicit globs
# instead of Get-Command. Newest version wins.
function Find-Jdk21 {
    $globs = @(
        'C:\Program Files\Eclipse Adoptium\jdk-21*\bin\java.exe',
        'C:\Program Files\Java\jdk-21*\bin\java.exe',
        'C:\Program Files\Microsoft\jdk-21*\bin\java.exe'
    )
    $found = @()
    foreach ($g in $globs) {
        $found += @(Get-ChildItem $g -ErrorAction SilentlyContinue)
    }
    return $found | Sort-Object { $_.VersionInfo.ProductVersion } -Descending |
        Select-Object -First 1
}

function Test-WingetApp([string]$Id) {
    & winget list --id $Id -e --accept-source-agreements *> $null
    return ($LASTEXITCODE -eq 0)
}

# Install every missing app from config/windows-apps.conf. An app counts as
# present when winget knows its id OR its check command is on PATH (covers
# manually installed versions winget cannot match, e.g. a non-LTS Node).
# Existing installs (any version) are left untouched — upgrading mid-course
# is a deliberate manual act, not a side effect.
function Install-WindowsApps {
    Write-Host ''
    Write-Info 'Paigaldan Windowsi rakendused...'
    $apps = @(Read-ConfigFile (Join-Path $script:RepoDir 'config\windows-apps.conf'))

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Warn 'winget puudub — Windowsi rakendusi ei saa automaatselt paigaldada.'
        foreach ($a in $apps) { Add-Fail $a.F3 $a.F4 }
        return
    }

    $i = 0
    $n = $apps.Count
    foreach ($a in $apps) {
        $i++
        $checkCmd = $a.F2
        $present = $false
        if ($checkCmd -and $checkCmd -ne '-' -and (Get-Command $checkCmd -ErrorAction SilentlyContinue)) {
            $present = $true
        } elseif ($a.F1 -like 'JetBrains.IntelliJIDEA*' -and (Find-IdeaExe)) {
            # IDEA has no PATH command; Toolbox installs are invisible to
            # 'winget list --id', so look for idea64.exe in known locations.
            $present = $true
        } elseif ($a.F1 -like 'EclipseAdoptium.Temurin*' -and (Find-Jdk21)) {
            # Any vendor's JDK 21 counts (Oracle/Microsoft installs are
            # invisible to the Temurin winget id).
            $present = $true
        } elseif (Test-WingetApp $a.F1) {
            $present = $true
        }
        if ($present) {
            # The state manifest tells "this installer did it earlier" apart
            # from "was on the machine before us" — without it a re-run would
            # claim our own install was 'already there', confusing students.
            if (Test-StateEntry 'app' $a.F1) {
                Write-Ok "[$i/$n] $($a.F3) — paigaldatud (varasemal käivitusel)"
                Add-Ok "$($a.F3) — paigaldatud varasemal käivitusel"
            } else {
                Write-Ok "[$i/$n] $($a.F3) — juba olemas"
                Add-Ok "$($a.F3) — oli juba olemas"
            }
            continue
        }
        $wingetArgs = @('install', '--id', $a.F1, '-e', '--silent',
            '--accept-package-agreements', '--accept-source-agreements',
            '--disable-interactivity')
        if ($a.F1 -like 'PostgreSQL.*') {
            # EDB installer: unattended mode with the course-standard password.
            $wingetArgs += @('--override',
                "--mode unattended --unattendedmodeui none --superpassword $PgSuperPassword")
        }
        if ($a.F1 -like 'EclipseAdoptium.Temurin*') {
            # MSI: put java on PATH and set JAVA_HOME machine-wide, so
            # gradlew, IntelliJ and the student's own terminal all find it.
            # --override replaces the default silent switches -> include /quiet.
            $wingetArgs += @('--override',
                '/quiet ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome')
        }
        $r = Invoke-TickedJob "[$i/$n] Paigaldan: $($a.F3) (võib võtta mitu minutit)" `
            'winget' $wingetArgs '' '' $WingetLogFile
        if ($r.Code -eq 999) {
            # Job machinery failed on this machine — run in the foreground
            # like the old days (winget's own progress shows instead).
            & winget @wingetArgs
            $r = [pscustomobject]@{ Code = $LASTEXITCODE; Duration = '' }
        }
        $durText = if ($r.Duration) { " ($($r.Duration))" } else { '' }
        if ($r.Code -eq 0) {
            Write-Ok "[$i/$n] $($a.F3) — paigaldatud$durText"
            Add-Ok "$($a.F3)$durText"
            Add-StateEntry 'app' $a.F1 $r.Duration
        } else {
            Write-Err "[$i/$n] $($a.F3) — paigaldamine ebaõnnestus"
            Add-Fail $a.F3 $a.F4
        }
    }
}

# Create the course database. NEVER touches an existing PostgreSQL setup:
# if the superuser password is not the course default, this lands in the
# manual list instead.
function Invoke-PostgresSetup {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $psql) {
        Add-Fail "PostgreSQL andmebaas '$DbName'" 'docs/install/009-Create-new-database-in-PostgreSQL.pdf'
        return
    }
    $env:PGPASSWORD = $PgSuperPassword
    $exists = & $psql.FullName -h localhost -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$DbName'" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Ei saanud PostgreSQL serveriga ühendust (kas parool pole '$PgSuperPassword'?). Loo andmebaas käsitsi."
        Add-Fail "PostgreSQL andmebaas '$DbName' (server olemas, aga ühendus ebaõnnestus)" 'docs/install/009-Create-new-database-in-PostgreSQL.pdf'
    } elseif ("$exists".Trim() -eq '1') {
        if (Test-StateEntry 'db' $DbName) {
            Write-Ok "Andmebaas '$DbName' — loodud (varasemal käivitusel)"
            Add-Ok "PostgreSQL andmebaas '$DbName' — loodud varasemal käivitusel"
        } else {
            Write-Ok "Andmebaas '$DbName' — juba olemas"
            Add-Ok "PostgreSQL andmebaas '$DbName' — oli juba olemas"
        }
    } else {
        & $psql.FullName -h localhost -U postgres -c "CREATE DATABASE $DbName" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Andmebaas '$DbName' — loodud"
            Add-Ok "PostgreSQL andmebaas '$DbName'"
            Add-StateEntry 'db' $DbName
        } else {
            Add-Fail "PostgreSQL andmebaas '$DbName'" 'docs/install/009-Create-new-database-in-PostgreSQL.pdf'
        }
    }
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
}

# Find idea64.exe wherever IDEA may live: classic installer / winget
# (Program Files) or JetBrains Toolbox (LocalAppData). Newest version wins.
function Find-IdeaExe {
    $globs = @(
        'C:\Program Files\JetBrains\*\bin\idea64.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\*\bin\idea64.exe'),
        (Join-Path $env:LOCALAPPDATA 'JetBrains\Toolbox\apps\*\*\*\bin\idea64.exe')
    )
    $found = @()
    foreach ($g in $globs) {
        $found += @(Get-ChildItem $g -ErrorAction SilentlyContinue)
    }
    return $found | Sort-Object { $_.VersionInfo.ProductVersion } -Descending |
        Select-Object -First 1
}

# Seed the exported IDE settings (before first launch) and install the
# course plugins headlessly. Both are best-effort: failures land in the
# summary with a PDF fallback, they never abort the run.
function Invoke-IdeaSetup {
    $ideaExe = Find-IdeaExe
    if (-not $ideaExe) {
        Add-Fail 'IntelliJ pluginad' 'docs/install/016-IntelliJ-plugin-Rainbow-Brackets.pdf'
        Add-Fail 'IntelliJ seaded' 'docs/install/011-IntelliJ-seadete-importimine.pdf'
        return
    }
    $installDir = Split-Path (Split-Path $ideaExe.FullName)

    # Settings: the import mechanism is just "unzip into the config dir".
    # Three outcomes: fresh config -> seed automatically; existing config ->
    # leave it alone but tell the student to import manually (PDF 009);
    # anything unexpected -> failed list.
    $settingsPdf = 'docs/install/011-IntelliJ-seadete-importimine.pdf'
    $outcome = 'failed'
    $cfgDir = ''
    try {
        $info = Get-Content (Join-Path $installDir 'product-info.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($info.dataDirectoryName) {
            $cfgDir = Join-Path $env:APPDATA "JetBrains\$($info.dataDirectoryName)"
            if (Test-Path (Join-Path $cfgDir 'options')) {
                # The manifest tells our own earlier seeding apart from a
                # genuine pre-existing configuration — otherwise a re-run
                # would warn about settings WE installed and send the
                # student off to import them manually for nothing.
                if (Test-StateEntry 'idea-settings' $cfgDir) {
                    $outcome = 'seeded-earlier'
                } else {
                    $outcome = 'existing'
                }
            } else {
                New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
                Expand-Archive -Path (Join-Path $script:RepoDir 'docs\IntelliJ\settings.zip') `
                    -DestinationPath $cfgDir -Force -ErrorAction Stop
                $outcome = 'seeded'
            }
        }
    } catch { $outcome = 'failed' }
    switch ($outcome) {
        'seeded' {
            Write-Ok 'IntelliJ seaded — paigaldatud'
            Add-Ok 'IntelliJ seaded (heap, ML-completion, brauser jm)'
            Add-StateEntry 'idea-settings' $cfgDir
        }
        'seeded-earlier' {
            Write-Ok 'IntelliJ seaded — paigaldatud (varasemal käivitusel)'
            Add-Ok 'IntelliJ seaded — paigaldatud varasemal käivitusel'
        }
        'existing' {
            Write-Warn 'IntelliJ-l on juba oma seadistus — installer ei kirjuta seda üle. Impordi kursuse seaded ise (juhis kokkuvõttes).'
            Add-Manual 'IntelliJ seaded: sinu IntelliJ-l on juba oma seadistus, mida installer üle ei kirjuta — impordi kursuse seaded ise' $settingsPdf `
                "[Seadete fail]($(Get-RawUrl 'docs/IntelliJ/settings.zip')) — salvesta TERVE zip ja ÄRA paki seda lahti (IDEA impordib zip-faili tervikuna)"
        }
        default {
            Add-Fail 'IntelliJ seadete import' $settingsPdf
        }
    }

    $plugins = @(Read-ConfigFile (Join-Path $script:RepoDir 'config\intellij-plugins.conf'))
    if ($plugins.Count -eq 0) { return }
    $pluginNames = @($plugins | ForEach-Object { $_.F2 }) -join ', '

    # Skip the headless install when an earlier run already did this exact
    # plugin set (the state value changes when the config list changes) —
    # a student who deliberately removed a plugin is left alone.
    $pluginSet = (@($plugins | ForEach-Object { $_.F1 }) | Sort-Object) -join ' '
    if (Test-StateEntry 'idea-plugins' $pluginSet) {
        Write-Ok 'IntelliJ pluginad — paigaldatud (varasemal käivitusel)'
        Add-Ok "IntelliJ pluginad — paigaldatud varasemal käivitusel: $pluginNames"
        return
    }

    # Headless plugin install cannot work while the IDE itself is running.
    if (Get-Process -Name idea64 -ErrorAction SilentlyContinue) {
        $guideLines = @($plugins | ForEach-Object { "[$($_.F2)]($(Get-DocUrl $_.F3))" })
        Write-Warn 'IntelliJ on praegu avatud — pluginaid ei saa paigaldada, kui IntelliJ töötab.'
        Add-Manual "IntelliJ pluginad ($pluginNames): IntelliJ oli paigalduse ajal avatud. Sulge IntelliJ ja käivita installer uuesti — siis paigalduvad pluginad automaatselt" `
            '' `
            ("Käsitsi paigalduse juhendid:`n" + ($guideLines -join "`n"))
        return
    }

    $ids = @($plugins | ForEach-Object { $_.F1 })
    # A GUI exe returns immediately under '&', so poll the process while
    # ticking the elapsed time (same proof-of-life as Invoke-TickedJob).
    $label = 'Paigaldan IntelliJ pluginad'
    $proc = Start-Process -FilePath $ideaExe.FullName -ArgumentList (@('installPlugins') + $ids) `
        -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if (-not $proc) {
        Write-Err 'IntelliJ pluginate paigaldamine ebaõnnestus'
        foreach ($p in $plugins) { Add-Fail "IntelliJ plugin: $($p.F2)" $p.F3 }
        return
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $proc.HasExited) {
        Write-Host ("`r$label ... " + (Format-Duration $sw.Elapsed) + '  ') -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    $dur = Format-Duration $sw.Elapsed
    Write-Host ("`r$label ... $dur  ") -ForegroundColor Cyan
    if ($proc.ExitCode -eq 0) {
        Write-Ok "IntelliJ pluginad — paigaldatud ($dur)"
        Add-Ok "IntelliJ pluginad: $pluginNames"
        Add-StateEntry 'idea-plugins' $pluginSet $dur
    } else {
        Write-Err 'IntelliJ pluginate paigaldamine ebaõnnestus'
        foreach ($p in $plugins) { Add-Fail "IntelliJ plugin: $($p.F2)" $p.F3 }
    }
}

# --- WSL + Ubuntu ------------------------------------------------------------

function Show-RebootBanner {
    Write-Host ''
    Write-Host '##########################################################' -ForegroundColor Red
    Write-Host '#                                                        #' -ForegroundColor Red
    Write-Host '#   TAASKÄIVITA ARVUTI KOHE!                             #' -ForegroundColor Red
    Write-Host '#                                                        #' -ForegroundColor Red
    Write-Host '#   Pärast taaskäivitust:                                #' -ForegroundColor Red
    Write-Host '#   1. Ava PowerShell administraatorina                  #' -ForegroundColor Red
    Write-Host '#   2. Käivita täpselt sama käsk uuesti                  #' -ForegroundColor Red
    Write-Host '#                                                        #' -ForegroundColor Red
    Write-Host '#   Paigaldus jätkub sealt, kus see pooleli jäi.         #' -ForegroundColor Red
    Write-Host '#                                                        #' -ForegroundColor Red
    Write-Host '##########################################################' -ForegroundColor Red
}

function Assert-Wsl {
    & wsl.exe --status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'WSL on juba paigaldatud.'
        return
    }
    Write-Info 'Paigaldan WSL-i (see võib võtta mõne minuti)...'
    & wsl.exe --install --no-distribution | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Stop-WslPart ('WSL-i paigaldamine ebaõnnestus. Taaskäivita arvuti ja käivita sama käsk uuesti. ' +
            'Kui ka siis ei õnnestu, paigalda WSL ja Ubuntu käsitsi juhendi järgi.') $WslGuidePdf
    }
    Write-Ok 'WSL on paigaldatud. Windowsi rakendused on juba tehtud — pärast taaskäivitust jätkub ainult Ubuntu osa.'
    Show-RebootBanner
    Stop-Installer 0
}

function Get-InstalledDistros {
    $list = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $list) { return @() }
    return @($list | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Return the Ubuntu VERSION_ID inside a distro ('22.04', '24.04', ...) or ''.
function Get-DistroUbuntuVersion([string]$Name) {
    $v = Invoke-DistroRoot $Name '. /etc/os-release && printf %s "$VERSION_ID"'
    if ($LASTEXITCODE -ne 0) { return '' }
    return ($v | Out-String).Trim()
}

function Install-Distro([string]$Name) {
    Write-Info "Paigaldan distro $Name (see võib võtta mitu minutit)..."
    # Out-Host is load-bearing: this runs inside Select-TargetDistro, whose
    # return value the caller captures — without it the wsl.exe progress
    # text would join the returned distro name (which once produced a bogus
    # "your Ubuntu is broken" failure on a perfectly healthy machine).
    & wsl.exe --install -d $Name --no-launch | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Stop-WslPart ("Ubuntu ($Name) paigaldamine ebaõnnestus. Kontrolli internetiühendust ja proovi sama käsku uuesti. " +
            'Kui ka siis ei õnnestu, paigalda Ubuntu käsitsi juhendi järgi.') $WslGuidePdf
    }
    # Initialise without the interactive first-run wizard: running a command
    # as root registers the distro and skips the username/password prompt.
    $tries = 0
    while ($tries -lt 5) {
        & wsl.exe -d $Name -u root -- true *> $null
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 5
        $tries++
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-WslPart ("Ubuntu ($Name) käivitamine ebaõnnestus. Taaskäivita arvuti ja käivita sama käsk uuesti — " +
            'paigaldus jätkub poolelijäänud kohast. Kui ka pärast taaskäivitust ei õnnestu, paigalda Ubuntu käsitsi juhendi järgi.') $WslGuidePdf
    }
    Add-StateEntry 'distro' $Name
    Write-Ok "Distro $Name on paigaldatud."
}

# Decide which distro to use, installing one if needed. Never touches
# distros we do not support.
function Select-TargetDistro {
    $installed = Get-InstalledDistros

    if ($Distro) {
        if ($installed -contains $Distro) {
            Write-Ok "Kasutan sinu valitud distrot: $Distro"
            return $Distro
        }
        if ($SupportedDistros -contains $Distro) {
            Install-Distro $Distro
            return $Distro
        }
        Fail "Distro $Distro ei ole toetatud. Toetatud: $($SupportedDistros -join ', ')."
    }

    $candidates = @($SupportedDistros | Where-Object { $installed -contains $_ })

    # A distro registered under the plain name 'Ubuntu' may also be 22.04/24.04.
    if ($candidates.Count -eq 0 -and $installed -contains 'Ubuntu') {
        $v = Get-DistroUbuntuVersion 'Ubuntu'
        if ($v -eq '22.04' -or $v -eq '24.04') {
            Write-Ok "Leidsin olemasoleva Ubuntu $v — kasutan seda."
            return 'Ubuntu'
        }
    }

    if ($candidates.Count -eq 1) {
        Write-Ok "Leidsin olemasoleva distro $($candidates[0]) — kasutan seda."
        return $candidates[0]
    }

    if ($candidates.Count -gt 1) {
        Write-Host ''
        Write-Info 'Leidsin kaks Ubuntu versiooni. Kummale paigaldada?'
        Write-Host ''
        Write-Host '  1. Ubuntu 24.04 (soovitatud)'
        Write-Host '  2. Ubuntu 22.04'
        Write-Host ''
        while ($true) {
            $answer = Read-Host 'Vali [1/2]'
            if ($answer -eq '1' -or $answer -eq '') { return 'Ubuntu-24.04' }
            if ($answer -eq '2') { return 'Ubuntu-22.04' }
            Write-Warn 'Palun vasta 1 või 2.'
        }
    }

    Write-Info 'Ubuntut ei leitud — paigaldan Ubuntu 24.04.'
    Install-Distro $DefaultDistro
    return $DefaultDistro
}

function Assert-Wsl2([string]$Name) {
    # 'wsl -l -v' output: NAME STATE VERSION columns; match our distro's row.
    $lines = & wsl.exe --list --verbose 2>$null
    foreach ($line in $lines) {
        $clean = ($line -replace '\*', ' ').Trim()
        if ($clean -match "^$([regex]::Escape($Name))\s+\S+\s+1$") {
            Write-Info "Distro $Name kasutab WSL1 — uuendan WSL2 peale (failid säilivad)..."
            & wsl.exe --set-version $Name 2
            if ($LASTEXITCODE -ne 0) {
                Fail "WSL2 peale uuendamine ebaõnnestus. Käivita sama käsk uuesti või pöördu õpetaja poole."
            }
            Write-Ok 'WSL2 on nüüd kasutusel.'
        }
    }
}

function Assert-DistroHealthy([string]$Name) {
    Invoke-DistroRoot $Name 'true' *> $null
    if ($LASTEXITCODE -ne 0) {
        Stop-WslPart ("Sinu olemasolev Ubuntu ($Name) ei tööta korralikult. " +
            'Ära proovi seda ise kustutada — pöördu õpetaja poole.')
    }
}

# Ensure the distro has a normal (non-root) default user; create one when
# missing. Existing users and their passwords are never modified.
function Resolve-DistroUser([string]$Name) {
    $current = (& wsl.exe -d $Name -- whoami 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0 -and $current -and $current -ne 'root') {
        Write-Ok "Kasutan olemasolevat Ubuntu kasutajat: $current"
        return $current
    }

    # Derive a login name from the Windows username; fall back to 'student'.
    $u = ($env:USERNAME).ToLower() -replace '[^a-z0-9]', ''
    if (-not $u -or $u -notmatch '^[a-z]') { $u = 'student' }

    Write-Info "Loon Ubuntu kasutaja: $u"
    Invoke-DistroRoot $Name "id -u $u >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo $u" | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WslPart 'Ubuntu kasutaja loomine ebaõnnestus. Pöördu õpetaja poole.' }
    Add-StateEntry 'wsl-user' "$Name/$u"

    # Make it the default user via /etc/wsl.conf and restart the distro.
    $script = "if grep -q '^default=' /etc/wsl.conf 2>/dev/null; then " +
        "sed -i 's/^default=.*/default=$u/' /etc/wsl.conf; " +
        "elif grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then " +
        "sed -i '/^\[user\]/a default=$u' /etc/wsl.conf; " +
        "else printf '\n[user]\ndefault=%s\n' $u >> /etc/wsl.conf; fi"
    Invoke-DistroRoot $Name $script | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WslPart 'Ubuntu vaikimisi kasutaja seadistamine ebaõnnestus. Pöördu õpetaja poole.' }

    & wsl.exe --terminate $Name *> $null
    Write-Ok "Ubuntu kasutaja $u on valmis."
    return $u
}

# Passwordless sudo so the installer never has to ask for a password.
# The user's own password (if any) is left untouched.
function Grant-PasswordlessSudo([string]$Name, [string]$User) {
    $script = "printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$User' > /etc/sudoers.d/vali-it && " +
        'chmod 0440 /etc/sudoers.d/vali-it && visudo -cf /etc/sudoers.d/vali-it >/dev/null && ' +
        'rm -f /etc/sudoers.d/itcrafters'
    Invoke-DistroRoot $Name $script | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-WslPart 'Sudo õiguste seadistamine Ubuntus ebaõnnestus. Pöördu õpetaja poole.' }
    Write-Ok 'Administraatori õigused on seadistatud.'
}

# Unpack the already-downloaded tarball into the user's home inside the distro.
function Install-InstallerFiles([string]$Name, [string]$User) {
    $winPath = $script:RepoTar -replace '\\', '/'
    $wslTar = (& wsl.exe -d $Name -- wslpath -a $winPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $wslTar) { Stop-WslPart 'Allalaaditud faili asukoha teisendamine Ubuntu jaoks ebaõnnestus. Proovi sama käsku uuesti.' }

    $script = "rm -rf ~/$InstallDirName && mkdir -p ~/$InstallDirName && " +
        "tar -xzf '$wslTar' -C ~/$InstallDirName --strip-components=1 && " +
        "chmod +x ~/$InstallDirName/install.sh ~/$InstallDirName/scripts/*.sh"
    & wsl.exe -d $Name -u $User -- bash -c $script
    if ($LASTEXITCODE -ne 0) { Stop-WslPart 'Installeri lahtipakkimine Ubuntusse ebaõnnestus. Proovi sama käsku uuesti.' }
}

function Invoke-Installer([string]$Name, [string]$User) {
    Write-Host ''
    Write-Info 'Käivitan paigalduse Ubuntu sees. See võib võtta 5-15 minutit...'
    Write-Host ''
    & wsl.exe -d $Name -u $User -- bash -c "cd ~/$InstallDirName && ./install.sh --all"
    if ($LASTEXITCODE -eq 0) {
        Add-Ok 'Ubuntu keskkond (kõik kursuse käsurea-tööriistad)'
    } else {
        Write-Host ''
        Write-Err 'Ubuntu keskkonna paigaldus ei lõppenud edukalt.'
        Write-Warn 'Proovi käivitada sama käsk uuesti — juba tehtud osa ei tehta topelt.'
        Write-Warn 'Kui viga kordub, saada õpetajale Ubuntu kaustast fail: ~/.vali-it/install.log'
        Add-Fail 'Ubuntu keskkond (vt ~/.vali-it/install.log)' ''
    }
}

# --- course project ----------------------------------------------------------

# Freshly installed tools are not on the current session's PATH, so fall
# back to their default install locations (same trap Find-IdeaExe solves).
function Find-GitExe {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Program Files\Git\cmd\git.exe'
    if (Test-Path $exe) { return $exe }
    return $null
}

function Find-NpmCmd {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'C:\Program Files\nodejs\npm.cmd'
    if (Test-Path $exe) { return $exe }
    return $null
}

# Clone the course repo(s) from config/course.conf and pre-download their
# dependencies (frontend: npm ci, backend: gradlew dependencies) so nobody
# waits for downloads in class. Best-effort: failures land in the summary
# and never abort the run — the first build downloads what is missing.
# Servers are NOT started (the student does that in IntelliJ, PDF 025) and
# nothing is built or tested. An existing project folder is the student's
# work and is never touched; the preload still runs (it only writes caches).
function Invoke-CourseSetup {
    $repos = @(Read-ConfigFile (Join-Path $script:RepoDir 'config\course.conf'))
    if ($repos.Count -eq 0) { return }

    $log = Join-Path $env:TEMP 'vali-it-course.log'
    Write-Host ''
    Write-Info 'Laen alla kursuse projekti ja selle sõltuvused...'

    foreach ($r in $repos) {
        $url = $r.F1
        $name = ($url.TrimEnd('/') -split '/')[-1] -replace '\.git$', ''
        $parent = Join-Path $env:USERPROFILE $r.F2
        $dir = Join-Path $parent $name
        $desc = if ($r.F3) { $r.F3 } else { $name }
        $ok = $true

        # Failed clone -> the student can fetch the repo manually: the fail
        # entry carries the how-to guide (PDF 023) plus a clickable repo link.
        $clonePdf = 'docs/install/023-Kursuse-projekti-allalaadimine-ja-avamine.pdf'
        if (Test-Path $dir) {
            Write-Ok "$desc — kaust on juba olemas, ei puutu ($dir)"
        } else {
            $git = Find-GitExe
            if (-not $git) {
                Add-Fail "$desc — git puudub. Käivita installer uuesti, kui Git on paigaldatud, või laadi projekt ise alla" $clonePdf "Repo: $url"
                continue
            }
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            Write-Info "Kloonin: $url"
            & $git clone $url $dir
            if ($LASTEXITCODE -ne 0) {
                Add-Fail "$desc — allalaadimine ebaõnnestus. Kontrolli internetiühendust ja proovi installerit uuesti, või laadi projekt ise alla" $clonePdf "Repo: $url"
                continue
            }
            Add-StateEntry 'course' $dir
        }

        # Frontend: npm ci needs package-lock.json (a course-repo
        # requirement); skipped when node_modules already exists so a
        # re-run stays fast.
        $frontend = Join-Path $dir 'frontend'
        if (Test-Path (Join-Path $frontend 'package.json')) {
            if (Test-Path (Join-Path $frontend 'node_modules')) {
                Write-Ok "$desc — frontendi sõltuvused on juba olemas"
            } else {
                $npm = Find-NpmCmd
                if (-not (Test-Path (Join-Path $frontend 'package-lock.json'))) {
                    Add-Fail "$desc — frontendi package-lock.json puudub repost (anna õpetajale teada)" ''
                    $ok = $false
                } elseif (-not $npm) {
                    Add-Fail "$desc — npm puudub, frontendi sõltuvusi ei saanud ette laadida (esimene käivitus laeb need ise)" ''
                    $ok = $false
                } else {
                    $r = Invoke-TickedJob 'Laen frontendi sõltuvused (npm ci — võib võtta mitu minutit)' `
                        $npm @('ci', '--no-audit', '--no-fund') $frontend '' $log
                    if ($r.Code -eq 0) {
                        Write-Ok "$desc — frontendi sõltuvused laaditud ($($r.Duration))"
                    } else {
                        Add-Fail "$desc — frontendi sõltuvuste eellaadimine ebaõnnestus (esimene käivitus laeb need ise; logi: $log)" ''
                        $ok = $false
                    }
                }
            }
        }

        # Backend: gradlew dependencies warms the Gradle + Maven Central
        # caches in ~/.gradle. Idempotent (re-run is quick when cached).
        $backend = Join-Path $dir 'backend'
        if (Test-Path (Join-Path $backend 'gradlew.bat')) {
            $jdk = Find-Jdk21
            if (-not $jdk) {
                Add-Fail "$desc — Java 21 puudub, backendi sõltuvusi ei saanud ette laadida (esimene käivitus laeb need ise)" ''
                $ok = $false
            } else {
                # Point gradlew at the found JDK explicitly: a fresh Temurin
                # is not on this session's PATH and JAVA_HOME may be unset.
                # The job runs in its own process, so JAVA_HOME stays local.
                $jdkHome = Split-Path (Split-Path $jdk.FullName)
                $r = Invoke-TickedJob 'Laen backendi sõltuvused (Gradle — võib võtta mitu minutit)' `
                    (Join-Path $backend 'gradlew.bat') @('--no-daemon', 'dependencies') $backend $jdkHome $log
                if ($r.Code -eq 0) {
                    Write-Ok "$desc — backendi sõltuvused laaditud ($($r.Duration))"
                } else {
                    Add-Fail "$desc — backendi sõltuvuste eellaadimine ebaõnnestus (esimene käivitus laeb need ise; logi: $log)" ''
                    $ok = $false
                }
            }
        }

        if ($ok) {
            Write-Ok "$desc on valmis: $dir"
            Add-Ok "$desc — $dir (ava see kaust IntelliJ-s)"
        }
        # Reaching this point means the project is on disk (clone failures
        # 'continue' above) -> the "start the servers" step applies, even
        # when the preload failed: the first build downloads what is missing.
        # Dynamic on purpose (not manual-steps.conf), with the concrete path.
        Add-Manual "$($desc): käivita serverid IntelliJ-s (backend + frontend)" `
            'docs/install/025-Serverite-kaivitamine-IntelliJ.pdf' `
            "Ava IntelliJ-s kaust: $dir"
    }
}

# --- summary -----------------------------------------------------------------

# Static manual steps from config + dynamic ones discovered during the run.
function Get-AllManualSteps {
    $manual = @(Read-ConfigFile (Join-Path $script:RepoDir 'config\manual-steps.conf') |
        ForEach-Object { [pscustomobject]@{ Name = $_.F1; Pdf = $_.F2; Extra = '' } })
    $manual += $script:ManualList
    return $manual
}

function ConvertTo-HtmlText([string]$s) {
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

# Extra info as HTML: [name](url) becomes a named link; leftover bare URLs
# (not already inside an href="...") get linkified as-is.
function ConvertTo-ExtraHtml([string]$s) {
    $h = ConvertTo-HtmlText $s
    $h = $h -replace '\[([^\]]+)\]\((https?://[^)]+)\)', '<a href="$2">$1</a>'
    $h = $h -replace '(?<!")(https?://[^\s<"]+)', '<a href="$1">$1</a>'
    return ($h -replace "`n", '<br>')
}

# Write the same summary as a persistent, clickable HTML file on the desktop
# and open it in the browser: the console disappears when the window closes,
# links are not clickable in every console, and the file can be sent to the
# instructor when something failed. Best-effort: never aborts the run.
function Write-HtmlSummary([string]$DistroName) {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { return }
        $path = Join-Path $desktop 'Vali-IT-kokkuvote.html'

        $h = @()
        $h += '<!doctype html><html lang="et"><head><meta charset="utf-8">'
        $h += '<title>Vali-IT paigalduse kokkuvõte</title><style>'
        $h += 'body{font-family:"Segoe UI",sans-serif;max-width:800px;margin:2em auto;padding:0 1em;line-height:1.5}'
        $h += 'h1{border-bottom:2px solid #ccc;padding-bottom:.3em} .aeg{color:#666}'
        $h += '.ok{color:#1a7f37} .fail{color:#b30000} .manual{color:#9a6700}'
        $h += 'li{margin:.4em 0} .lisainfo{font-size:.92em;color:#444} code{background:#f2f2f2;padding:2px 5px}'
        $h += '.teade{color:#b30000;font-weight:600;border:1px solid #b30000;border-radius:6px;padding:.6em .8em;background:#fff5f5}'
        $h += '.vihje{color:#9a6700;border:1px solid #d4a72c;border-radius:6px;padding:.6em .8em;background:#fff8c5}'
        $h += '.vihje{color:#9a6700;border:1px solid #d4a72c;border-radius:6px;padding:.6em .8em;background:#fff8c5}'
        $h += 'table{border-collapse:collapse} td{padding:3px 14px 3px 0;vertical-align:top}'
        $h += '</style></head><body>'
        $h += '<h1>Vali-IT paigalduse kokkuvõte</h1>'
        $h += "<p class='aeg'>$(Get-Date -Format 'dd.MM.yyyy HH:mm') · Kogu paigaldus kestis: $(Format-Duration $script:RunTimer.Elapsed)</p>"
        $h += '<p class="teade">See kokkuvõte on salvestatud sinu töölauale failina Vali-IT-kokkuvote.html — võid lehe sulgeda ja hiljem sealt uuesti avada.</p>'
        $h += '<p>Juhendi lingid laadivad PDF-faili otse alla — vaata brauseri allalaadimiste kausta.</p>'

        if ($script:OkList.Count -gt 0) {
            $h += '<h2 class="ok">Korras</h2><ul>'
            foreach ($x in $script:OkList) { $h += "<li class='ok'>✓ $(ConvertTo-HtmlText $x)</li>" }
            $h += '</ul>'
        }
        if ($script:FailList.Count -gt 0) {
            $h += '<h2 class="fail">Ebaõnnestus — proovi installerit uuesti või tee käsitsi</h2><ul>'
            foreach ($x in $script:FailList) {
                $li = "<li class='fail'>✗ $(ConvertTo-HtmlText $x.Name)"
                if ($x.Pdf) { $li += " — <a href='$(Get-DocUrl $x.Pdf)'>juhend (PDF)</a>" }
                if ($x.Extra) { $li += "<br><span class='lisainfo'>$(ConvertTo-ExtraHtml $x.Extra)</span>" }
                $h += "$li</li>"
            }
            $h += '</ul>'
            $h += '<p>Uuesti proovimiseks ava PowerShell administraatorina ja käivita:<br>'
            $h += "<code>irm https://raw.githubusercontent.com/$RepoSlug/main/setup.ps1 | iex</code></p>"
        }
        $manual = @(Get-AllManualSteps)
        if ($manual.Count -gt 0) {
            $h += ('<p class="vihje"><b>Vihje:</b> kui mõne sammuga tekib probleem või PDF-juhendis jääb midagi segaseks, ' +
                'küsi julgelt abi AI-lt (ChatGPT, Claude, Gemini vms). Kirjelda probleemi oma sõnadega, lisa vestlusse ' +
                'kaasa ka sama PDF-juhend (leiad selle brauseri allalaadimiste kaustast) ja kopeeri juurde täpne veateade, ' +
                'kui see on olemas. Kui ka siis ei õnnestu, pöördu õpetaja poole.</p>')
            $h += '<h2 class="manual">Tee ise läbi</h2><ol>'
            foreach ($m in $manual) {
                $li = "<li>$(ConvertTo-HtmlText $m.Name)"
                if ($m.Pdf) { $li += " — <a href='$(Get-DocUrl $m.Pdf)'>juhend (PDF)</a>" }
                if ($m.Extra) { $li += "<br><span class='lisainfo'>$(ConvertTo-ExtraHtml $m.Extra)</span>" }
                $h += "$li</li>"
            }
            $h += '</ol>'
        }
        $h += '<h2>Andmebaasi andmed</h2>'
        $h += '<table>'
        $h += '<tr><td><b>Host</b></td><td><code>localhost</code></td></tr>'
        $h += '<tr><td><b>Port</b></td><td><code>5432</code></td></tr>'
        $h += "<tr><td><b>Andmebaas</b></td><td><code>$DbName</code></td></tr>"
        $h += '<tr><td><b>Kasutaja</b></td><td><code>postgres</code></td></tr>'
        $h += "<tr><td><b>Parool</b></td><td><code>$PgSuperPassword</code></td></tr>"
        $h += "<tr><td><b>IntelliJ andmeallika URL</b></td><td><code>jdbc:postgresql://localhost:5432/$DbName</code></td></tr>"
        $h += '</table>'

        if ($DistroName) {
            $h += "<p>Ubuntu avamiseks kirjuta terminali: <code>wsl -d $DistroName</code> või otsi Start-menüüst Ubuntu.</p>"
        }

        # Log paths at the end, mirroring the uninstaller's summary: when
        # something failed, these are what the instructor needs to see.
        $h += '<h2>Tehnilised logid</h2>'
        $h += '<p>Kui midagi ebaõnnestus, saada õpetajale koos selle kokkuvõttega ka need failid (ava rada Exploreri aadressiribal):</p>'
        $h += '<table>'
        $courseLog = Join-Path $env:TEMP 'vali-it-course.log'
        $h += "<tr><td><b>Kogu paigalduse väljund</b></td><td><code>$(ConvertTo-HtmlText $SetupLogFile)</code></td></tr>"
        if (Test-Path $WingetLogFile) {
            $h += "<tr><td><b>Rakenduste paigaldus (winget)</b></td><td><code>$(ConvertTo-HtmlText $WingetLogFile)</code></td></tr>"
        }
        if (Test-Path $courseLog) {
            $h += "<tr><td><b>Kursuse projekti eellaadimine</b></td><td><code>$(ConvertTo-HtmlText $courseLog)</code></td></tr>"
        }
        if ($DistroName) {
            $h += '<tr><td><b>Ubuntu sees</b></td><td><code>~/.vali-it/install.log</code></td></tr>'
        }
        $h += '</table>'
        $h += '</body></html>'

        ($h -join "`n") | Out-File -FilePath $path -Encoding UTF8
        Write-Ok "Kokkuvõte salvestati töölauale: Vali-IT-kokkuvote.html"
        Start-Process $path
    } catch {
        Write-Warn 'Kokkuvõtte salvestamine töölauale ebaõnnestus.'
    }
}

function Show-Summary([string]$DistroName) {
    Write-Host ''
    Write-Host '==========================================================' -ForegroundColor Cyan
    Write-Host '  KOKKUVÕTE' -ForegroundColor Cyan
    Write-Host '==========================================================' -ForegroundColor Cyan

    if ($script:OkList.Count -gt 0) {
        Write-Host ''
        Write-Host 'Korras:' -ForegroundColor Green
        foreach ($x in $script:OkList) { Write-Host "  ✓ $x" -ForegroundColor Green }
    }

    # Guide links carry ?raw=true and download directly; tell the student
    # once where the file lands, before the first block with links.
    $pdfHintShown = $false
    $pdfHint = 'NB! Juhendi avamiseks hoia Ctrl all ja klõpsa lingil (või kopeeri link brauserisse).' +
        ' Link laadib PDF-faili otse alla — vaata brauseri allalaadimiste kausta.'

    if ($script:FailList.Count -gt 0) {
        Write-Host ''
        Write-Info $pdfHint
        $pdfHintShown = $true
        Write-Host ''
        Write-Host 'EBAÕNNESTUS — proovi sama käsku uuesti või tee käsitsi:' -ForegroundColor Red
        foreach ($x in $script:FailList) {
            Write-Host "  ✗ $($x.Name)" -ForegroundColor Red
            if ($x.Pdf) { Write-Host "      Juhend: $(Get-DocUrl $x.Pdf)" -ForegroundColor Red }
            if ($x.Extra) {
                foreach ($extraLine in ($x.Extra -split "`n")) {
                    # The console cannot render named links: [name](url) -> "name: url".
                    $plain = $extraLine -replace '\[([^\]]+)\]\((https?://[^)]+)\)', '$1: $2'
                    Write-Host "      $plain" -ForegroundColor Red
                }
            }
        }
    }

    $manual = @(Get-AllManualSteps)
    if ($manual.Count -gt 0) {
        if (-not $pdfHintShown) {
            Write-Host ''
            Write-Info $pdfHint
        }
        Write-Host ''
        Write-Host 'Tee ise läbi (neid ei saa automatiseerida):' -ForegroundColor Yellow
        Write-Host ('  Vihje: kui mõne sammuga tekib probleem, küsi julgelt abi AI-lt (ChatGPT, Claude, Gemini vms) — ' +
            'lisa vestlusse ka PDF-juhend ja täpne veateade.') -ForegroundColor Yellow
        $j = 0
        foreach ($m in $manual) {
            $j++
            Write-Host "  $j. $($m.Name)" -ForegroundColor Yellow
            if ($m.Pdf) { Write-Host "      Juhend: $(Get-DocUrl $m.Pdf)" -ForegroundColor Yellow }
            if ($m.Extra) {
                foreach ($extraLine in ($m.Extra -split "`n")) {
                    # The console cannot render named links: [name](url) -> "name: url".
                    $plain = $extraLine -replace '\[([^\]]+)\]\((https?://[^)]+)\)', '$1: $2'
                    Write-Host "      $plain" -ForegroundColor Yellow
                }
            }
        }
    }

    Write-Host ''
    Write-Info "Kogu paigaldus kestis: $(Format-Duration $script:RunTimer.Elapsed)"
    Write-Host ''
    if ($DistroName) {
        Write-Info "Ubuntu avamiseks kirjuta terminali:  wsl -d $DistroName"
        Write-Info 'või otsi Start-menüüst "Ubuntu".'
        Write-Host ''
    }
}

# --- main flow ---------------------------------------------------------------

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host '  Vali-IT Installer' -ForegroundColor Cyan
Write-Host '  Arvuti ettevalmistamine programmeerimiskursuseks' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host ''

Assert-Prerequisites
Get-RepoFiles
Install-WindowsApps
Invoke-PostgresSetup
Invoke-IdeaSetup

# The WSL/Ubuntu part is best-effort from here on: a failure lands as ONE
# red entry in the summary (with the WSL guide PDF) and the run carries on
# with the course project and the summary — by this point the Windows apps
# are done and hiding that behind a hard stop helps nobody.
$target = ''
try {
    Assert-Wsl
    $target = Select-TargetDistro
    Assert-Wsl2 $target
    Assert-DistroHealthy $target
    $user = Resolve-DistroUser $target
    Grant-PasswordlessSudo $target $user
    Install-InstallerFiles $target $user
    Invoke-Installer $target $user
} catch {
    $abort = $script:WslAbort
    if (-not $abort) {
        # Not a Stop-WslPart unwind but a genuinely unexpected error.
        $abort = [pscustomobject]@{
            Msg = "Ubuntu osas juhtus ootamatu viga: $($_.Exception.Message)"
            Pdf = $WslGuidePdf; Extra = ''
        }
    }
    Write-Err $abort.Msg
    Write-Warn 'Jätkan ülejäänud sammudega — Ubuntu osa saab uuesti proovida sama käsuga.'
    Add-Fail "Ubuntu (WSL): $($abort.Msg)" $abort.Pdf $abort.Extra
    $target = ''   # do not advertise a distro that may not work
}
Invoke-CourseSetup
Show-Summary $target
Write-HtmlSummary $target

if ($script:FailList.Count -gt 0) {
    Write-Err 'Osa asju jäi tegemata — vaata punast nimekirja ülal.'
    Stop-Installer 1
}
Write-Host '==========================================================' -ForegroundColor Green
Write-Ok 'Valmis! Sinu arvuti on kursuseks ette valmistatud.'
Stop-SetupLog
Restore-ConsoleMode
Write-Host '==========================================================' -ForegroundColor Green
