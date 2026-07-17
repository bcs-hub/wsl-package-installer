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

# Keys 'kind|value' of manifest entries whose removal succeeded; the state
# file is rewritten at the end with only the remaining (failed) entries.
$script:RemovedKeys = @()
$script:FailCount = 0

$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Err([string]$m) { Write-Host "✗ $m" -ForegroundColor Red }

# Same reason as in setup.ps1: 'exit' under 'irm | iex' closes the console
# window before anything can be read — always pause first.
function Stop-Uninstaller([int]$Code) {
    Write-Host ''
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

function Remove-App([string]$Id, [string]$Label, [bool]$FromState) {
    & winget list --id $Id -e --accept-source-agreements *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Ok "$Label — juba eemaldatud"
        if ($FromState) { Set-Removed 'app' $Id }
        return
    }
    Write-Info "Eemaldan: $Label ..."
    & winget uninstall --id $Id -e --silent --disable-interactivity --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "$Label — eemaldatud"
        if ($FromState) { Set-Removed 'app' $Id }
    } else {
        Write-Err "$Label — eemaldamine ebaõnnestus (proovi Windowsi Seaded → Rakendused)"
        $script:FailCount++
    }
}

# Drop the course DB. Runs BEFORE the PostgreSQL app is uninstalled (needs
# psql). A missing server counts as removed; a server we cannot log into
# with the course password is not ours to touch.
function Remove-CourseDb {
    $psql = Get-ChildItem 'C:\Program Files\PostgreSQL\*\bin\psql.exe' -ErrorAction SilentlyContinue |
        Sort-Object FullName -Descending | Select-Object -First 1
    if (-not $psql) {
        Write-Ok "Andmebaas '$DbName' — serverit pole, midagi eemaldada pole"
        Set-Removed 'db' $DbName
        return
    }
    $env:PGPASSWORD = $PgSuperPassword
    & $psql.FullName -h localhost -U postgres -c "DROP DATABASE IF EXISTS $DbName" *> $null
    $rc = $LASTEXITCODE
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if ($rc -eq 0) {
        Write-Ok "Andmebaas '$DbName' — eemaldatud"
        Set-Removed 'db' $DbName
    } else {
        Write-Err "Andmebaasi '$DbName' eemaldamine ebaõnnestus (kas serveri parool pole '$PgSuperPassword'?)"
        $script:FailCount++
    }
}

function Remove-Dir([string]$Kind, [string]$Path, [string]$Label) {
    if (-not (Test-Path $Path)) {
        Write-Ok "$Label — juba eemaldatud"
        Set-Removed $Kind $Path
        return
    }
    Remove-Item -Recurse -Force $Path -ErrorAction SilentlyContinue
    if (Test-Path $Path) {
        Write-Err "$Label — eemaldamine ebaõnnestus ($Path)"
        $script:FailCount++
    } else {
        Write-Ok "$Label — eemaldatud"
        Set-Removed $Kind $Path
    }
}

function Remove-Distro([string]$Name) {
    if (-not ((Get-RegisteredDistros) -contains $Name)) {
        Write-Ok "Ubuntu ($Name) — juba eemaldatud"
        Set-Removed 'distro' $Name
        return
    }
    Write-Info "Eemaldan Ubuntu distro $Name (kõik failid selles kustuvad)..."
    & wsl.exe --unregister $Name *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "Ubuntu ($Name) — eemaldatud"
        Set-Removed 'distro' $Name
    } else {
        Write-Err "Ubuntu ($Name) eemaldamine ebaõnnestus"
        $script:FailCount++
    }
}

# When a distro stays (it was not ours to remove), delete only the
# installer's own traces inside it — these paths are ours by name.
function Clear-DistroTraces([string]$Name) {
    & wsl.exe -d $Name -u root -- bash -c `
        'rm -rf /etc/sudoers.d/vali-it /home/*/vali-it-installer /home/*/.vali-it /root/vali-it-installer /root/.vali-it' 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Ok "Ubuntu ($Name) — installeri jäljed puhastatud (distro ise jääb alles)" }
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
$planApps = @($stateApps | ForEach-Object { [pscustomobject]@{ Id = $_; Label = $_; FromState = $true } })
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
    $answer = Read-Host 'Kas oled kindel? Kirjuta JAH ja vajuta Enter'
    if ($answer -cne 'JAH') {
        Write-Info 'Katkestatud — midagi ei eemaldatud.'
        Stop-Uninstaller 0
    }
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
if ($script:FailCount -gt 0) {
    Write-Err "Osa asju jäi eemaldamata ($script:FailCount) — vaata punaseid ridu ülal. Ebaõnnestunud kirjed jäid manifesti alles; võid sama käsku uuesti proovida."
    Stop-Uninstaller 1
}
Write-Ok 'Valmis! Kõik installeri paigaldatu on eemaldatud.'
Write-Info 'NB! Mõne rakenduse eemaldaja võib jätta kettale andmekaustu (nt PostgreSQL-i andmed, JetBrains-i vahemälud) — need on ohutud käsitsi kustutada.'
Stop-Uninstaller 0
