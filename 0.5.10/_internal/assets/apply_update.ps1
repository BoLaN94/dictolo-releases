<#
.SYNOPSIS
    Primeni update-ove na instalaciju Dictolo-a.

.DESCRIPTION
    Skripta NE traži elevaciju. Per-user instalacija (%LOCALAPPDATA%\Programs\Dictolo) je
    upisiva bez admin prava, pa updater pokreće ovu skriptu neelevirano i korisnik ne vidi
    nikakav UAC prompt. Stare instalacije u Program Files updater i dalje pokreće s RunAs —
    tada ovo radi kao i prije, samo bez #Requires (koji bi neeleviran start odbio odmah).
    Koraci:
    1. Čeka da se glavni app proces (MainPid) zatvori
    2. Backup-a originalne fajlove u _update_backup\
    3. Atomski prebacuje fajlove iz staging-a na cilj
    4. Restarta app (iz eleviranog procesa preko explorer.exe, da ne ostane admin)
    5. Liveness check — ako app propadne, auto-rollback
    6. Ako rollback se desi, upiše update_failed.json za GUI

    Nikad ne diram instalaciju ako ne mogu da garantujem da je safe.
    Fail-safe: ako app ne startuje nakon update-a, sve se vraća na staro.

.PARAMETER StagingDir
    Putanja do staging direktorija (npr. %APPDATA%\Dictolo\update_staging\0.5.0\)

.PARAMETER InstallDir
    Putanja do instalacionog direktorija (npr. %LOCALAPPDATA%\Programs\Dictolo\)

.PARAMETER MainPid
    PID glavnog app procesa koji se čeka da se zatvori

.PARAMETER NewExePath
    Putanja do novog Dictolo.exe-a (u instalacionom direktoriju)
#>

param(
    [Parameter(Mandatory=$true)] [string] $StagingDir,
    [Parameter(Mandatory=$true)] [string] $InstallDir,
    [Parameter(Mandatory=$true)] [int] $MainPid,
    [Parameter(Mandatory=$true)] [string] $NewExePath
)

$ErrorActionPreference = "Stop"

# %APPDATA%\Dictolo se izvodi iz $StagingDir (.../Dictolo/update_staging/<verzija>), ne iz
# $env:APPDATA — eleviran proces moze raditi pod drugim admin nalogom pa bi $env:APPDATA
# pokazivao na tudji profil. Log i update_failed.json moraju zavrsiti tamo gdje ih app cita.
$AppDataDir = Split-Path (Split-Path $StagingDir -Parent) -Parent
if (-not (Test-Path -LiteralPath $AppDataDir)) {
    $AppDataDir = Join-Path $env:APPDATA "Dictolo"
}
$LogPath = Join-Path $AppDataDir "update_apply.log"

$script:IsElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-Log {
    param([string] $Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message"
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
}

function Wait-ForProcess {
    param([int] $ProcessId, [int] $TimeoutSeconds = 30)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            Write-Log "Glavni proces završio"
            return $true
        }
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    Write-Log "Timeout čekanja na glavni proces (${TimeoutSeconds}s)"
    return $false
}

function Start-App {
    # Iz eleviranog procesa bi novi Dictolo naslijedio admin prava — explorer.exe ga vrati
    # na normalne. Kad skripta ionako radi neelevirano (per-user instalacija), Start-Process
    # je direktniji i ne ovisi o tome da li explorer uopste odgovara.
    if ($script:IsElevated) {
        & explorer.exe "$NewExePath"
    } else {
        Start-Process -FilePath $NewExePath
    }
}

function Backup-File {
    param([string] $Source, [string] $RelPath)
    $BackupDir = Join-Path $InstallDir "_update_backup"
    $BackupPath = Join-Path $BackupDir $RelPath
    $BackupParent = Split-Path $BackupPath -Parent

    if (Test-Path $Source) {
        New-Item -ItemType Directory -Path $BackupParent -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $BackupPath -Force
        Write-Log "Backup: $RelPath"
    }
}

function Rollback {
    param([string] $BackupDir, [string] $Reason)
    Write-Log "ROLLBACK: $Reason"

    $BackupDir = Join-Path $InstallDir "_update_backup"
    if (Test-Path $BackupDir) {
        Get-ChildItem -LiteralPath $BackupDir -Recurse -File | ForEach-Object {
            $RelPath = $_.FullName.Substring($BackupDir.Length + 1)
            $TargetPath = Join-Path $InstallDir $RelPath
            $TargetDir = Split-Path $TargetPath -Parent

            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $TargetPath -Force
            Write-Log "Rollback: $RelPath"
        }
    }

    # Upiši update_failed.json marker za GUI
    $FailedMarker = @{
        old_version = $script:OldVersion
        new_version = $script:NewVersion
        reason = $Reason
        timestamp = Get-Date -Format "o"
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $AppDataDir "update_failed.json") -Value $FailedMarker -Force

    # Restart stare verzije
    Write-Log "Pokretanje stare verzije"
    Start-App
}

try {
    Write-Log "=== Update primjena počela ==="
    Write-Log "StagingDir: $StagingDir"
    Write-Log "InstallDir: $InstallDir"
    Write-Log "MainPid: $MainPid"

    # Čekaj da se glavni proces zatvori
    if (-not (Wait-ForProcess $MainPid)) {
        # App se nije zatvorio na vrijeme — odustani. Staging OSTAJE: nista nije dirano,
        # pa sljedeci klik na "Ponovo pokreni za azuriranje" radi bez novog download-a.
        Write-Log "Odustajanje: app se nije zatvorio na vrijeme (staging ostaje za retry)"
        exit 1
    }

    # Pripremi verzije za logging
    $OldExePath = Join-Path $InstallDir "Dictolo.exe"
    $script:OldVersion = "unknown"
    # Staging dir se zove po verziji (update_staging\<verzija>) — pouzdanije od
    # FileVersionInfo, koji na PyInstaller .exe-u zna biti prazan.
    $script:NewVersion = Split-Path $StagingDir -Leaf
    if (Test-Path $OldExePath) {
        $script:OldVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($OldExePath).FileVersion
    }

    # Backup original fajlova
    Get-ChildItem -LiteralPath $StagingDir -Recurse -File | ForEach-Object {
        $RelPath = $_.FullName.Substring($StagingDir.Length + 1)
        Backup-File (Join-Path $InstallDir $RelPath) $RelPath
    }

    # Atomski prebaci fajlove iz staging-a
    Write-Log "Primjena update-a..."
    Get-ChildItem -LiteralPath $StagingDir -Recurse -File | ForEach-Object {
        $RelPath = $_.FullName.Substring($StagingDir.Length + 1)
        $TargetPath = Join-Path $InstallDir $RelPath
        $TargetDir = Split-Path $TargetPath -Parent

        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Move-Item -LiteralPath $_.FullName -Destination $TargetPath -Force
        Write-Log "Ažuriran: $RelPath"
    }

    # Restart ažurirane verzije
    Write-Log "Pokretanje ažurirane verzije (elevated=$script:IsElevated)"
    Start-App

    # Liveness check — čekaj 3s i provjeri da je proces pokrenuta
    Start-Sleep -Seconds 3
    $AppProcesses = Get-Process -Name "Dictolo" -ErrorAction SilentlyContinue

    if ($AppProcesses) {
        Write-Log "Liveness check prošao — app je pokrenuta"

        # Očisti backup i staging
        Remove-Item -LiteralPath (Join-Path $InstallDir "_update_backup") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Update uspio — backup i staging obrisani"
    } else {
        # App nije proradila — automatski rollback
        Rollback (Join-Path $InstallDir "_update_backup") "App se nije pokrenula nakon update-a"
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

} catch {
    Write-Log "Greška tijekom update-a: $_"
    Write-Log $_.ScriptStackTrace

    # Try to rollback ako je backup kreiran
    $BackupDir = Join-Path $InstallDir "_update_backup"
    if (Test-Path $BackupDir) {
        Rollback $BackupDir "Iznimka tijekom update-a"
    }

    # Čisti staging
    Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Log "=== Update primjena završena uspješno ==="
exit 0
