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

# Result tracking for the final summary.
$script:OkList = @()
$script:FailList = @()
$script:ManualList = @()   # dynamic manual steps discovered during the run
$script:RepoTar = ''
$script:RepoDir = ''

# Make wsl.exe output plain UTF-8 instead of UTF-16 so it can be parsed.
$env:WSL_UTF8 = '1'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Write-Info([string]$m) { Write-Host $m -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "✓ $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Write-Err([string]$m) { Write-Host "✗ $m" -ForegroundColor Red }

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
    Read-Host 'Vajuta Enter, et lõpetada (aken läheb kinni)' | Out-Null
    exit $Code
}

function Fail([string]$m) {
    Write-Err $m
    Write-Host ''
    Write-Host 'Kui vajad abi, pöördu õpetaja poole.' -ForegroundColor Yellow
    Stop-Installer 1
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
            Write-Ok "[$i/$n] $($a.F3) — juba olemas"
            Add-Ok "$($a.F3) — oli juba olemas"
            continue
        }
        Write-Info "[$i/$n] Paigaldan: $($a.F3) (võib võtta mitu minutit)..."
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
        & winget @wingetArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "[$i/$n] $($a.F3) — paigaldatud"
            Add-Ok $a.F3
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
        Write-Ok "Andmebaas '$DbName' — juba olemas"
        Add-Ok "PostgreSQL andmebaas '$DbName' — oli juba olemas"
    } else {
        & $psql.FullName -h localhost -U postgres -c "CREATE DATABASE $DbName" *> $null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "Andmebaas '$DbName' — loodud"
            Add-Ok "PostgreSQL andmebaas '$DbName'"
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
    try {
        $info = Get-Content (Join-Path $installDir 'product-info.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($info.dataDirectoryName) {
            $cfgDir = Join-Path $env:APPDATA "JetBrains\$($info.dataDirectoryName)"
            if (Test-Path (Join-Path $cfgDir 'options')) {
                $outcome = 'existing'
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

    # Headless plugin install cannot work while the IDE itself is running.
    if (Get-Process -Name idea64 -ErrorAction SilentlyContinue) {
        $pluginNames = @($plugins | ForEach-Object { $_.F2 }) -join ', '
        $guideLines = @($plugins | ForEach-Object { "[$($_.F2)]($(Get-DocUrl $_.F3))" })
        Write-Warn 'IntelliJ on praegu avatud — pluginaid ei saa paigaldada, kui IntelliJ töötab.'
        Add-Manual "IntelliJ pluginad ($pluginNames): IntelliJ oli paigalduse ajal avatud. Sulge IntelliJ ja käivita installer uuesti — siis paigalduvad pluginad automaatselt" `
            '' `
            ("Käsitsi paigalduse juhendid:`n" + ($guideLines -join "`n"))
        return
    }

    Write-Info 'Paigaldan IntelliJ pluginad (see võib võtta hetke)...'
    $ids = @($plugins | ForEach-Object { $_.F1 })
    $proc = Start-Process -FilePath $ideaExe.FullName -ArgumentList (@('installPlugins') + $ids) `
        -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -eq 0) {
        Write-Ok 'IntelliJ pluginad — paigaldatud'
        Add-Ok "IntelliJ pluginad: $(@($plugins | ForEach-Object { $_.F2 }) -join ', ')"
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
    & wsl.exe --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        Fail 'WSL-i paigaldamine ebaõnnestus. Proovi arvuti taaskäivitada ja käivita sama käsk uuesti.'
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
    $script = "printf '%s ALL=(ALL) NOPASSWD:ALL\n' '$User' > /etc/sudoers.d/vali-it && " +
        'chmod 0440 /etc/sudoers.d/vali-it && visudo -cf /etc/sudoers.d/vali-it >/dev/null && ' +
        'rm -f /etc/sudoers.d/itcrafters'
    Invoke-DistroRoot $Name $script | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'Sudo seadistamine ebaõnnestus. Pöördu õpetaja poole.' }
    Write-Ok 'Administraatori õigused on seadistatud.'
}

# Unpack the already-downloaded tarball into the user's home inside the distro.
function Install-InstallerFiles([string]$Name, [string]$User) {
    $winPath = $script:RepoTar -replace '\\', '/'
    $wslTar = (& wsl.exe -d $Name -- wslpath -a $winPath 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $wslTar) { Fail 'Allalaaditud faili asukoha teisendamine ebaõnnestus.' }

    $script = "rm -rf ~/$InstallDirName && mkdir -p ~/$InstallDirName && " +
        "tar -xzf '$wslTar' -C ~/$InstallDirName --strip-components=1 && " +
        "chmod +x ~/$InstallDirName/install.sh ~/$InstallDirName/scripts/*.sh"
    & wsl.exe -d $Name -u $User -- bash -c $script
    if ($LASTEXITCODE -ne 0) { Fail 'Installeri lahtipakkimine Ubuntusse ebaõnnestus.' }
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
                    Write-Info 'Laen frontendi sõltuvused (npm ci — võib võtta mitu minutit)...'
                    Push-Location $frontend
                    & $npm ci --no-audit --no-fund *>> $log
                    $rc = $LASTEXITCODE
                    Pop-Location
                    if ($rc -eq 0) {
                        Write-Ok "$desc — frontendi sõltuvused laaditud"
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
                Write-Info 'Laen backendi sõltuvused (Gradle — võib võtta mitu minutit)...'
                # Point gradlew at the found JDK explicitly: a fresh Temurin
                # is not on this session's PATH and JAVA_HOME may be unset.
                $oldJavaHome = $env:JAVA_HOME
                $env:JAVA_HOME = Split-Path (Split-Path $jdk.FullName)
                Push-Location $backend
                & .\gradlew.bat --no-daemon dependencies *>> $log
                $rc = $LASTEXITCODE
                Pop-Location
                $env:JAVA_HOME = $oldJavaHome
                if ($rc -eq 0) {
                    Write-Ok "$desc — backendi sõltuvused laaditud"
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
        $h += 'table{border-collapse:collapse} td{padding:3px 14px 3px 0;vertical-align:top}'
        $h += '</style></head><body>'
        $h += '<h1>Vali-IT paigalduse kokkuvõte</h1>'
        $h += "<p class='aeg'>$(Get-Date -Format 'dd.MM.yyyy HH:mm')</p>"
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
Assert-Wsl
$target = Select-TargetDistro
Assert-Wsl2 $target
Assert-DistroHealthy $target
$user = Resolve-DistroUser $target
Grant-PasswordlessSudo $target $user
Install-InstallerFiles $target $user
Invoke-Installer $target $user
Invoke-CourseSetup
Show-Summary $target
Write-HtmlSummary $target

if ($script:FailList.Count -gt 0) {
    Write-Err 'Osa asju jäi tegemata — vaata punast nimekirja ülal.'
    Stop-Installer 1
}
Write-Host '==========================================================' -ForegroundColor Green
Write-Ok 'Valmis! Sinu arvuti on kursuseks ette valmistatud.'
Write-Host '==========================================================' -ForegroundColor Green
