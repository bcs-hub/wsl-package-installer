# uninstall.ps1 - Vali-IT Installer, eemaldaja.
#
# Removes what setup.ps1 itself installed on this machine, using the state
# manifest at %LOCALAPPDATA%\vali-it\installed.txt. Software that was already
# on the machine before the installer ran is not in the manifest and is left
# untouched — the exact mirror of the installer's "never touch existing
# things" rule. Primarily an instructor tool for resetting test machines.
#
# Run in an elevated PowerShell:
#   irm https://raw.githubusercontent.com/bcs-hub/vali-it-installer/main/uninstall.ps1 | iex
#
# NOTE: no param() block on purpose — Windows PowerShell 5.1 cannot parse a
# top-level param block through 'irm ... | iex'. Overrides are env vars:
#   $env:ITC_YES = '1'     # skip the confirmation prompt (automation)
#   $env:ITC_PURGE = '1'   # FULL test-machine reset: also removes everything
#                          # the manifest does not mention — course apps from
#                          # config/windows-apps.conf, every supported Ubuntu
#                          # distro, the course folder from config/course.conf,
#                          # JetBrains config dirs and PostgreSQL leftovers.
#                          # For machines where the installer ran before the
#                          # manifest existed, or for a clean slate.
#   $env:ITC_BRANCH = 'my-branch'
#
# All user-facing messages are in Estonian; comments are in English.
# NB: keep this file UTF-8 WITHOUT BOM (PS 5.1 + 'irm | iex' chokes on BOM).

$Branch = if ($env:ITC_BRANCH) { $env:ITC_BRANCH } else { 'main' }
$Purge = ($env:ITC_PURGE -eq '1')
$AutoYes = ($env:ITC_YES -eq '1')

$ErrorActionPreference = 'Continue'
$RepoSlug = 'bcs-hub/vali-it-installer'
$KnownDistros = @('Ubuntu-24.04', 'Ubuntu-22.04', 'Ubuntu')
$DbName = 'vali_it'
$PgSuperPassword = 'student123'
$StateDir = Join-Path $env:LOCALAPPDATA 'vali-it'
$StateFile = Join-Path $StateDir 'installed.txt'

# Friendly names for the manifest's bare winget ids, so the plan reads
# "Slack" not "SlackTechnologies.Slack". Purge mode overrides these from
# the live config; this map covers the manifest-only (offline) path.
$AppNames = @{
    'Git.Git'                        = 'Git (Windows)'
    'OpenJS.NodeJS.LTS'              = 'Node.js LTS (Windows)'
    'PostgreSQL.PostgreSQL.17'       = 'PostgreSQL 17 andmebaasiserver'
    'EclipseAdoptium.Temurin.21.JDK' = 'Java 21 (Temurin JDK)'
    'JetBrains.IntelliJIDEA'         = 'IntelliJ IDEA'
    'Docker.DockerDesktop'           = 'Docker Desktop'
    'SlackTechnologies.Slack'        = 'Slack'
    'Zoom.Zoom'                      = 'Zoom'
}

# Keys 'kind|value' of manifest entries whose removal succeeded; the state
# file is rewritten at the end with only the remaining (failed) entries.
$script:RemovedKeys = @()
$script:FailCount = 0
$script:RunTimer = [System.Diagnostics.Stopwatch]::StartNew()   # whole-run duration

$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

# Same as setup.ps1: a mouse click into a classic console window starts a
# QuickEdit selection that freezes all output until a key is pressed —
# turn QuickEdit off for this console (best-effort).
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
# not stop the uninstall).
$LogFile = Join-Path $env:TEMP 'vali-it-uninstall.log'
$script:LogStarted = $false
try {
    # -Append for the same reason as in setup.ps1: a retry run must not
    # wipe the log of the run where the failure happened.
    Start-Transcript -Path $LogFile -Append -Force *> $null
    $script:LogStarted = $true
} catch { }

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

# Result collectors: every removal outcome goes to the console AND into a
# list, so the run can be summarised as an HTML file at the end (same idea
# as setup.ps1's desktop summary).
$script:DoneList = @()
$script:FailList = @()
function Add-Done([string]$m) {
    Write-Ok $m
    $script:DoneList += $m
}
function Add-Failed([string]$m) {
    Write-Err $m
    $script:FailList += $m
    $script:FailCount++
}

# Same reason as in setup.ps1: 'exit' under 'irm | iex' closes the console
# window before anything can be read — always pause first.
function Stop-Uninstaller([int]$Code) {
    Write-Host ''
    if ($script:LogStarted) {
        try { Stop-Transcript *> $null } catch { }
        $script:LogStarted = $false
        Write-Info "Kogu väljund on salvestatud faili: $LogFile"
        Write-Host ''
    }
    # Restore QuickEdit before the pause so select/copy works again, then
    # flush keystrokes pressed while the removals ran — they would answer
    # this Read-Host instantly, closing the window before anything can be
    # read.
    Restore-ConsoleMode
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    Read-Host 'Vajuta Enter, et lõpetada (aken läheb kinni)' | Out-Null
    exit $Code
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Read the state manifest ('kind|value|date' lines) into objects.
function Read-StateEntries {
    $rows = @()
    if (-not (Test-Path $StateFile)) { return $rows }
    foreach ($line in (Get-Content -Path $StateFile -Encoding UTF8)) {
        $p = $line -split '\|'
        if ($p.Count -ge 2 -and $p[0].Trim()) {
            $rows += [pscustomobject]@{ Kind = $p[0].Trim(); Value = $p[1].Trim() }
        }
    }
    return $rows
}

# Purge mode reads the repo config files; download the tarball once.
$script:CfgDir = ''
function Get-RepoConfigDir {
    if ($script:CfgDir) { return $script:CfgDir }
    $tar = Join-Path $env:TEMP 'vali-it-uninstall.tar.gz'
    $dir = Join-Path $env:TEMP 'vali-it-uninstall-src'
    try {
        Invoke-WebRequest -Uri "https://github.com/$RepoSlug/archive/refs/heads/$Branch.tar.gz" `
            -OutFile $tar -UseBasicParsing -ErrorAction Stop
    } catch { return '' }
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & tar.exe -xzf $tar -C $dir --strip-components=1 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    $script:CfgDir = $dir
    return $dir
}

# Read a repo "a | b | c | d" config file into F1..F4 objects (same format
# as setup.ps1's Read-ConfigFile). Empty when the download failed.
function Read-RepoConf([string]$File) {
    $rows = @()
    $dir = Get-RepoConfigDir
    if (-not $dir) { return $rows }
    $conf = Join-Path $dir "config\$File"
    if (-not (Test-Path $conf)) { return $rows }
    foreach ($raw in (Get-Content -Path $conf -Encoding UTF8)) {
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

function Get-RegisteredDistros {
    $list = & wsl.exe --list --quiet 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $list) { return @() }
    return @($list | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Set-Removed([string]$Kind, [string]$Value) {
    $script:RemovedKeys += "$Kind|$Value"
}

# Run one winget uninstall attempt; its (often very long, e.g. Docker's
# whole install log) output goes to $LogFile, not the screen. Returns the
# exit code.
function Invoke-WingetUninstall([string]$Id, [string[]]$Extra) {
    $wingetArgs = @('uninstall', '--id', $Id, '-e', '--silent',
        '--disable-interactivity', '--accept-source-agreements') + $Extra
    & winget @wingetArgs *>> $LogFile
    return $LASTEXITCODE
}

function Remove-App([string]$Id, [string]$Label, [bool]$FromState) {
    & winget list --id $Id -e --accept-source-agreements *> $null
    if ($LASTEXITCODE -ne 0) {
        Add-Done "$Label — juba eemaldatud"
        if ($FromState) { Set-Removed 'app' $Id }
        return
    }
    # Docker Desktop's uninstaller can sit for many minutes; warn so a
    # patient student does not think it hung.
    if ($Id -like 'Docker.*') {
        Write-Info "Eemaldan: $Label ... (võib võtta mitu minutit, palun oota)"
    } else {
        Write-Info "Eemaldan: $Label ..."
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rc = Invoke-WingetUninstall $Id @()
    # User-scope apps (Slack, Zoom) cannot be uninstalled from an elevated
    # winget — exit 0x8a15002b / the "installed for user scope cannot be
    # uninstalled when running with administrator privileges" message.
    # Retry once scoped to the user before giving up.
    if ($rc -ne 0) {
        $rc = Invoke-WingetUninstall $Id @('--scope', 'user')
    }
    if ($rc -eq 0) {
        Add-Done "$Label — eemaldatud ($(Format-Duration $sw.Elapsed))"
        if ($FromState) { Set-Removed 'app' $Id }
    } else {
        Add-Failed ("$Label — eemaldamine ebaõnnestus. Eemalda käsitsi: ava Start → Seaded → " +
            'Rakendused → Installitud rakendused, otsi rakendus ja vali Eemalda.')
    }
}

# Drop the course DB. Runs BEFORE the PostgreSQL app is uninstalled (needs
# psql). A missing server counts as removed; a server we cannot log into
# with the course password is not ours to touch.
function Remove-CourseDb {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $psql) {
        Add-Done "Andmebaas '$DbName' — serverit pole, midagi eemaldada pole"
        Set-Removed 'db' $DbName
        return
    }
    $env:PGPASSWORD = $PgSuperPassword
    & $psql.FullName -h localhost -U postgres -c "DROP DATABASE IF EXISTS $DbName" *> $null
    $rc = $LASTEXITCODE
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if ($rc -eq 0) {
        Add-Done "Andmebaas '$DbName' — eemaldatud"
        Set-Removed 'db' $DbName
    } else {
        Add-Failed "Andmebaasi '$DbName' eemaldamine ebaõnnestus (kas serveri parool pole '$PgSuperPassword'?)"
    }
}

function Remove-Dir([string]$Kind, [string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        Add-Done "$Label — juba eemaldatud"
        Set-Removed $Kind $Path
        return
    }
    Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    if (Test-Path $Path) {
        Add-Failed "$Label — eemaldamine ebaõnnestus ($Path)"
    } else {
        Add-Done "$Label — eemaldatud"
        Set-Removed $Kind $Path
    }
}

function Remove-Distro([string]$Name) {
    if (-not ((Get-RegisteredDistros) -contains $Name)) {
        Add-Done "Ubuntu ($Name) — juba eemaldatud"
        Set-Removed 'distro' $Name
        return
    }
    Write-Info "Eemaldan Ubuntu distro $Name (kõik failid selles kustuvad)..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & wsl.exe --unregister $Name *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Done "Ubuntu ($Name) — eemaldatud ($(Format-Duration $sw.Elapsed))"
        Set-Removed 'distro' $Name
    } else {
        Add-Failed "Ubuntu ($Name) eemaldamine ebaõnnestus"
    }
}

# When a distro stays (it was not ours to remove), delete only the
# installer's own traces inside it — these paths are ours by name.
function Clear-DistroTraces([string]$Name) {
    & wsl.exe -d $Name -u root -- bash -c `
        'rm -rf /etc/sudoers.d/vali-it /home/*/vali-it-installer /home/*/.vali-it /root/vali-it-installer /root/.vali-it' 2>$null
    if ($LASTEXITCODE -eq 0) { Add-Done "Ubuntu ($Name) — installeri jäljed puhastatud (distro ise jääb alles)" }
}

function ConvertTo-HtmlText([string]$s) {
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;')
}

# Same idea as setup.ps1's desktop summary: the console dies with the
# window, the HTML file stays. Separate filename on purpose — this script
# deletes the installer's own summary as part of the cleanup.
function Write-UninstallHtml {
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { return }
        $path = Join-Path $desktop 'Vali-IT-eemaldamise-kokkuvote.html'

        $retry = "irm https://raw.githubusercontent.com/$RepoSlug/main/uninstall.ps1 | iex"
        if ($Purge) { $retry = "`$env:ITC_PURGE = '1'; $retry" }

        $h = @()
        $h += '<!doctype html><html lang="et"><head><meta charset="utf-8">'
        $h += '<title>Vali-IT eemaldamise kokkuvõte</title><style>'
        $h += 'body{font-family:"Segoe UI",sans-serif;max-width:800px;margin:2em auto;padding:0 1em;line-height:1.5}'
        $h += 'h1{border-bottom:2px solid #ccc;padding-bottom:.3em} .aeg{color:#666}'
        $h += '.ok{color:#1a7f37} .fail{color:#b30000}'
        $h += 'li{margin:.4em 0} code{background:#f2f2f2;padding:2px 5px}'
        $h += '</style></head><body>'
        $h += '<h1>Vali-IT eemaldamise kokkuvõte</h1>'
        $h += "<p class='aeg'>$(Get-Date -Format 'dd.MM.yyyy HH:mm') · Kogu eemaldamine kestis: $(Format-Duration $script:RunTimer.Elapsed)</p>"
        $h += "<p>See kokkuvõte on salvestatud faili <code>$(ConvertTo-HtmlText $path)</code>.</p>"

        if ($script:DoneList.Count -gt 0) {
            $h += '<h2 class="ok">Eemaldatud</h2><ul>'
            foreach ($x in $script:DoneList) { $h += "<li class='ok'>✓ $(ConvertTo-HtmlText $x)</li>" }
            $h += '</ul>'
        }
        if ($script:FailList.Count -gt 0) {
            $h += '<h2 class="fail">Ebaõnnestus</h2><ul>'
            foreach ($x in $script:FailList) { $h += "<li class='fail'>✗ $(ConvertTo-HtmlText $x)</li>" }
            $h += '</ul>'
            $h += '<p>Ebaõnnestunud kirjed jäid manifesti alles. Uuesti proovimiseks ava PowerShell administraatorina ja käivita:<br>'
            $h += "<code>$(ConvertTo-HtmlText $retry)</code></p>"
        }
        $h += '<p>Mõne rakenduse eemaldaja võib jätta kettale andmekaustu (nt PostgreSQL-i andmed, JetBrains-i vahemälud) — need on ohutud käsitsi kustutada.</p>'
        $h += "<p>Tehniline logi: <code>$(ConvertTo-HtmlText $LogFile)</code></p>"
        $h += '</body></html>'

        ($h -join "`n") | Out-File -FilePath $path -Encoding UTF8
        # Full path on purpose: with OneDrive folder redirection or a UAC
        # elevation under another account, "the desktop" may not be the
        # desktop the user is looking at.
        Write-Ok "Kokkuvõte salvestati faili: $path"
        Start-Process $path
    } catch {
        Write-Warn 'Kokkuvõtte salvestamine töölauale ebaõnnestus.'
    }
}

# --- main flow ---------------------------------------------------------------

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host '  Vali-IT Installer — EEMALDAJA' -ForegroundColor Cyan
Write-Host '  Eemaldab selle, mille installer ise paigaldas' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-IsAdmin)) {
    Write-Err 'Seda skripti tuleb käivitada administraatorina. Tee Start-nupul paremklõps, vali "Terminal (Admin)" ja proovi uuesti.'
    Stop-Uninstaller 1
}

$entries = @(Read-StateEntries)
if ($entries.Count -eq 0 -and -not $Purge) {
    Write-Warn "Manifesti ei leitud ($StateFile) — installer pole siin masinas midagi paigaldanud"
    Write-Warn 'või paigaldus tehti vanema versiooniga, mis manifesti veel ei pidanud.'
    Write-Info "Kõigi kursuse rakenduste eemaldamiseks käivita enne sama käsku:  `$env:ITC_PURGE = '1'"
    Stop-Uninstaller 0
}

# Build the removal plan. Manifest entries first; purge mode widens it to a
# full test-machine reset from the repo config (apps, every supported
# distro on the machine, the course folder, leftover config/data dirs).
$stateApps = @($entries | Where-Object { $_.Kind -eq 'app' } | ForEach-Object { $_.Value })
$planApps = @($stateApps | ForEach-Object {
        $lbl = if ($AppNames.ContainsKey($_)) { $AppNames[$_] } else { $_ }
        [pscustomobject]@{ Id = $_; Label = $lbl; FromState = $true }
    })
$planDb = ($Purge -or @($entries | Where-Object { $_.Kind -eq 'db' }).Count -gt 0)
$planSettings = @($entries | Where-Object { $_.Kind -eq 'idea-settings' } | ForEach-Object { $_.Value })
$planCourse = @($entries | Where-Object { $_.Kind -eq 'course' } | ForEach-Object { $_.Value })
$planDistros = @($entries | Where-Object { $_.Kind -eq 'distro' } | ForEach-Object { $_.Value })
$planExtraDirs = @()
if ($Purge) {
    foreach ($a in @(Read-RepoConf 'windows-apps.conf')) {
        if ($stateApps -contains $a.F1) { continue }
        $desc = if ($a.F3) { $a.F3 } else { $a.F1 }
        $planApps += [pscustomobject]@{ Id = $a.F1; Label = "$desc (polnud manifestis)"; FromState = $false }
    }
    # The whole course parent folder (e.g. %USERPROFILE%\vali-it).
    foreach ($r in @(Read-RepoConf 'course.conf')) {
        if (-not $r.F2) { continue }
        $p = Join-Path $env:USERPROFILE $r.F2
        if ((Test-Path $p) -and $planCourse -notcontains $p) { $planCourse += $p }
    }
    # Every supported distro on the machine, manifest or not.
    foreach ($d in @(Get-RegisteredDistros)) {
        if ($KnownDistros -contains $d -and $planDistros -notcontains $d) { $planDistros += $d }
    }
    # Dirs the app uninstallers leave behind (IDE settings, DB data).
    foreach ($p in @((Join-Path $env:APPDATA 'JetBrains'), (Join-Path $env:LOCALAPPDATA 'JetBrains'),
            'C:\Program Files\PostgreSQL')) {
        if (Test-Path $p) { $planExtraDirs += $p }
    }
}

# The course-folder question comes BEFORE the plan is shown, so the list
# the user confirms is exactly what will happen. Default (plain Enter)
# keeps the folder — it may hold the student's own work. ('-eq'/'-ne' are
# case-insensitive on purpose: jah/Jah/JAH all count.)
if (-not $AutoYes -and $planCourse.Count -gt 0) {
    # Stray keystrokes from earlier must not answer the prompt.
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    Write-Host ''
    $q = 'Kas kustutada ka kursuse projektikaust (' + ($planCourse -join ', ') +
        ')? Kirjuta "jah" kustutamiseks või vajuta lihtsalt Enter, et kaust alles jätta'
    $a = Read-Host $q
    if ($a -eq 'jah') {
        Write-Warn 'Kursuse projektikaust kustutatakse koos ülejäänuga.'
    } else {
        Write-Info 'Kursuse projektikaust jääb alles.'
        $planCourse = @()
    }
    Write-Host ''
}

Write-Info 'Eemaldatakse:'
foreach ($a in $planApps) { Write-Host "  - Rakendus: $($a.Label)" }
if ($planDb) { Write-Host "  - PostgreSQL andmebaas: $DbName" }
foreach ($s in $planSettings) { Write-Host "  - IntelliJ seaded ja pluginad: $s" }
foreach ($c in $planCourse) { Write-Host "  - Kursuse projekt: $c  (KAUST KOOS KOGU TÖÖGA KUSTUB!)" -ForegroundColor Yellow }
foreach ($d in $planDistros) { Write-Host "  - Ubuntu distro: $d  (KÕIK FAILID SELLES KUSTUVAD!)" -ForegroundColor Yellow }
foreach ($p in $planExtraDirs) { Write-Host "  - Jääkkaust: $p" }
Write-Host '  - Installeri jäljed: töölaua kokkuvõte, ajutised failid, manifest'
Write-Host ''

if (-not $AutoYes) {
    try { $Host.UI.RawUI.FlushInputBuffer() } catch { }
    $answer = Read-Host 'Kas eemaldan kõik ülaltoodud? Kirjuta "jah" ja vajuta Enter (mis tahes muu vastus katkestab)'
    if ($answer -ne 'jah') {
        Write-Info 'Katkestatud — midagi ei eemaldatud.'
        Stop-Uninstaller 0
    }
    Write-Info 'Alustan eemaldamisega...'
}
Write-Host ''

# Order matters: the DB drop needs psql, so it runs before the PostgreSQL
# app is uninstalled.
if ($planDb) { Remove-CourseDb }
foreach ($a in $planApps) { Remove-App $a.Id $a.Label $a.FromState }
foreach ($s in $planSettings) {
    Remove-Dir 'idea-settings' $s 'IntelliJ seaded ja pluginad'
    if ($script:RemovedKeys -contains "idea-settings|$s") {
        # Plugins live inside the settings dir; their entries go with it.
        foreach ($p in @($entries | Where-Object { $_.Kind -eq 'idea-plugins' })) {
            Set-Removed 'idea-plugins' $p.Value
        }
    }
}
foreach ($p in $planExtraDirs) { Remove-Dir 'extra' $p "Jääkkaust $p" }
foreach ($c in $planCourse) { Remove-Dir 'course' $c 'Kursuse projekt' }
foreach ($d in $planDistros) {
    Remove-Distro $d
    if ($script:RemovedKeys -contains "distro|$d") {
        foreach ($u in @($entries | Where-Object { $_.Kind -eq 'wsl-user' -and $_.Value -like "$d/*" })) {
            Set-Removed 'wsl-user' $u.Value
        }
    }
}

# Distros that stay behind (pre-existing, so never ours to remove) still
# get the installer's own files cleaned out of them.
if ($entries.Count -gt 0) {
    foreach ($d in @(Get-RegisteredDistros)) {
        if ($KnownDistros -contains $d -and $planDistros -notcontains $d) { Clear-DistroTraces $d }
    }
}

# Leftover files outside the manifest.
$desktop = [Environment]::GetFolderPath('Desktop')
if ($desktop) { Remove-Item (Join-Path $desktop 'Vali-IT-kokkuvote.html') -Force -ErrorAction SilentlyContinue }
foreach ($t in @('vali-it-installer.tar.gz', 'vali-it-installer-src', 'vali-it-course.log',
        'vali-it-setup.log', 'vali-it-winget.log',
        'vali-it-uninstall.tar.gz', 'vali-it-uninstall-src')) {
    Remove-Item (Join-Path $env:TEMP $t) -Recurse -Force -ErrorAction SilentlyContinue
}

# Rewrite the manifest with only the entries whose removal failed; delete
# it (and the state dir) when nothing is left.
if (Test-Path $StateFile) {
    $keep = @(Get-Content -Path $StateFile -Encoding UTF8 | Where-Object {
            $p = $_ -split '\|'
            -not ($p.Count -ge 2 -and $script:RemovedKeys -contains "$($p[0].Trim())|$($p[1].Trim())")
        })
    if ($keep.Count -eq 0) {
        Remove-Item -Recurse -Force $StateDir -ErrorAction SilentlyContinue
    } else {
        $keep | Out-File -FilePath $StateFile -Encoding UTF8
    }
}

Write-Host ''
Write-UninstallHtml
Write-Host ''
Write-Info "Kogu eemaldamine kestis: $(Format-Duration $script:RunTimer.Elapsed)"
if ($script:FailCount -gt 0) {
    Write-Err "Osa asju jäi eemaldamata ($script:FailCount) — vaata punaseid ridu ülal. Ebaõnnestunud kirjed jäid manifesti alles; võid sama käsku uuesti proovida."
    Stop-Uninstaller 1
}
Write-Ok 'Valmis! Kõik installeri paigaldatu on eemaldatud.'
Write-Info 'NB! Mõne rakenduse eemaldaja võib jätta kettale andmekaustu (nt PostgreSQL-i andmed, JetBrains-i vahemälud) — need on ohutud käsitsi kustutada.'
Stop-Uninstaller 0
