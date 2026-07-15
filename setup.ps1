# setup.ps1 - IT Crafters Installer, Windows bootstrap.
#
# The student's single entry point. Run in an elevated PowerShell:
#   irm https://raw.githubusercontent.com/bcs-hub/wsl-package-installer/main/setup.ps1 | iex
#
# Resumable state machine: every step checks whether it is already done
# and skips it, so re-running the same command (e.g. after the WSL reboot)
# simply continues from where it left off. Nothing is ever deleted:
# existing distros, users and passwords are left untouched.
#
# All user-facing messages are in Estonian; comments are in English.

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

$RepoSlug = 'bcs-hub/wsl-package-installer'

$SupportedDistros = @('Ubuntu-24.04', 'Ubuntu-22.04')
$DefaultDistro = 'Ubuntu-24.04'
$InstallDirName = 'itcrafters-installer'

# Make wsl.exe output plain UTF-8 instead of UTF-16 so it can be parsed.
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "[x] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Err([string]$m) { Write-Host "X $m" -ForegroundColor Red }
function Fail([string]$m) {
    Write-Err $m
    Write-Host ''
    Write-Host 'Kui vajad abi, pöördu õpetaja poole.' -ForegroundColor Yellow
    exit 1
}

# Run a command inside the distro as root. Returns stdout; sets $LASTEXITCODE.
# stderr is dropped: fresh distros print harmless systemd-session warnings
# that would only scare students; failures are detected via $LASTEXITCODE.
function Invoke-DistroRoot([string]$Name, [string]$Script) {
    & wsl.exe -d $Name -u root -- bash -c $Script 2>$null
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
        Fail 'Programmi wsl.exe ei leitud. Uuenda Windowsit ja proovi uuesti.'
    }
    Write-Ok 'Windowsi eelkontroll läbitud.'
}

function Assert-Wsl {
    & wsl.exe --status *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'WSL on juba paigaldatud.'
        return
    }
    Write-Info 'Paigaldan WSL-i (see võib võtta mõne minuti)...'
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Fail 'WSL-i paigaldamine ebaõnnestus. Proovi arvuti taaskäivitada ja käivita sama käsk uuesti.'
    }
    Write-Ok 'WSL on paigaldatud.'
    Write-Host ''
    Write-Warn 'Nüüd on vaja arvuti TAASKÄIVITADA.'
    Write-Warn 'Pärast taaskäivitust ava PowerShell administraatorina ja käivita sama käsk uuesti.'
    exit 0
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
    & wsl.exe --install -d $Name --no-launch
    if ($LASTEXITCODE -ne 0) {
        Fail "Distro $Name paigaldamine ebaõnnestus. Kontrolli internetiühendust ja proovi uuesti."
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
        Fail "Distro $Name käivitamine ebaõnnestus. Taaskäivita arvuti ja käivita sama käsk uuesti."
    }
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
        Fail ("Sinu olemasolev Ubuntu ($Name) ei tööta korralikult. " +
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
    if ($LASTEXITCODE -ne 0) { Fail 'Kasutaja loomine ebaõnnestus. Pöördu õpetaja poole.' }

    # Make it the default user via /etc/wsl.conf and restart the distro.
    $script = "if grep -q '^default=' /etc/wsl.conf 2>/dev/null; then " +
        "sed -i 's/^default=.*/default=$u/' /etc/wsl.conf; " +
        "elif grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then " +
        "sed -i '/^\[user\]/a default=$u' /etc/wsl.conf; " +
        "else printf '\n[user]\ndefault=%s\n' $u >> /etc/wsl.conf; fi"
    Invoke-DistroRoot $Name $script | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Vaikimisi kasutaja seadistamine ebaõnnestus. Pöördu õpetaja poole.' }

    & wsl.exe --terminate $Name *> $null
    Write-Ok "Ubuntu kasutaja $u on valmis."
    return $u
}

# Passwordless sudo so the installer never has to ask for a password.
# The user's own password (if any) is left untouched.
function Grant-PasswordlessSudo([string]$Name, [string]$User) {
    $script = "printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$User' > /etc/sudoers.d/itcrafters && " +
        'chmod 0440 /etc/sudoers.d/itcrafters && visudo -cf /etc/sudoers.d/itcrafters >/dev/null'
    Invoke-DistroRoot $Name $script | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Sudo seadistamine ebaõnnestus. Pöördu õpetaja poole.' }
    Write-Ok 'Administraatori õigused on seadistatud.'
}

# Download the installer from GitHub (on the Windows side, so the distro
# needs neither git nor curl) and unpack it into the user's home.
function Install-InstallerFiles([string]$Name, [string]$User) {
    $url = "https://github.com/$RepoSlug/archive/refs/heads/$Branch.tar.gz"
    $tmp = Join-Path $env:TEMP 'itcrafters-installer.tar.gz'

    Write-Info 'Laen alla IT Crafters Installeri...'
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    } catch {
        Fail "Allalaadimine ebaõnnestus ($url). Kontrolli internetiühendust ja proovi uuesti."
    }

    $winPath = $tmp -replace '\\', '/'
    $wslTar = (& wsl.exe -d $Name -- wslpath -a $winPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $wslTar) { Fail 'Allalaaditud faili asukoha teisendamine ebaõnnestus.' }

    $script = "rm -rf ~/$InstallDirName && mkdir -p ~/$InstallDirName && " +
        "tar -xzf '$wslTar' -C ~/$InstallDirName --strip-components=1 && " +
        "chmod +x ~/$InstallDirName/install.sh ~/$InstallDirName/scripts/*.sh"
    & wsl.exe -d $Name -u $User -- bash -c $script
    if ($LASTEXITCODE -ne 0) { Fail 'Installeri lahtipakkimine ebaõnnestus.' }
    Write-Ok 'Installer on alla laaditud.'
}

function Invoke-Installer([string]$Name, [string]$User) {
    Write-Host ''
    Write-Info 'Käivitan paigalduse Ubuntu sees. See võib võtta 5-15 minutit...'
    Write-Host ''
    & wsl.exe -d $Name -u $User -- bash -c "cd ~/$InstallDirName && ./install.sh --all"
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Err 'Paigaldus ei lõppenud edukalt.'
        Write-Warn 'Proovi käivitada sama käsk uuesti — juba tehtud osa ei tehta topelt.'
        Write-Warn 'Kui viga kordub, saada õpetajale Ubuntu kaustast fail: ~/.itcrafters/install.log'
        exit 1
    }
}

# --- main flow ---------------------------------------------------------------

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host '  IT Crafters Installer' -ForegroundColor Cyan
Write-Host '  Arvuti ettevalmistamine programmeerimiskursuseks' -ForegroundColor Cyan
Write-Host '==========================================================' -ForegroundColor Cyan
Write-Host ''

Assert-Prerequisites
Assert-Wsl
$target = Select-TargetDistro
Assert-Wsl2 $target
Assert-DistroHealthy $target
$user = Resolve-DistroUser $target
Grant-PasswordlessSudo $target $user
Install-InstallerFiles $target $user
Invoke-Installer $target $user

Write-Host ''
Write-Host '==========================================================' -ForegroundColor Green
Write-Ok 'Valmis! Sinu arvuti on kursuseks ette valmistatud.'
Write-Host ''
Write-Info "Ubuntu avamiseks kirjuta terminali:  wsl -d $target"
Write-Info 'või otsi Start-menüüst "Ubuntu".'
Write-Host '==========================================================' -ForegroundColor Green
