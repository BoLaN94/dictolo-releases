<#
.SYNOPSIS
    Primijeni azuriranje na instalaciju Dictola.

.DESCRIPTION
    Fajl je namjerno CIST ASCII: Windows PowerShell 5.1 skriptu bez BOM-a cita u ANSI
    kodnoj stranici, pa bi UTF-8 crtica (E2 80 94) postala znak navoda U+201D i mogla
    prelomiti string. Zato bez kvacica i bez dugih crtica, i u komentarima.

    Skripta NE trazi elevaciju. Per-user instalacija (%LOCALAPPDATA%\Programs\Dictolo) je
    upisiva bez admin prava, pa updater pokrece ovu skriptu neelevirano, sakriveno i bez
    UAC prompta. Stare instalacije u Program Files updater i dalje pokrece s RunAs.

    Koraci:
    1. Ceka da se glavni proces (MainPid) zatvori
    2. Brise zaostali _update_backup (od prekinute ranije primjene) i pravi novi
    3. Prebacuje fajlove iz staging-a na cilj (i pamti koji su NOVI)
    4. Pokrece novu verziju
    5. Provjera zdravlja: nova verzija mora raditi cijelo vrijeme do HealthSeconds (20 s)
    6. Uspjeh -> brise backup i staging. Pad -> rollback: vrati stare fajlove, obrisi
       nove, obrisi backup, upisi update_failed.json i pokreni staru verziju

    Nikad ne diram instalaciju ako ne mogu da garantujem da je sigurno.

.PARAMETER StagingDir
    Putanja do staging direktorija (npr. %APPDATA%\Dictolo\update_staging\0.5.0\)

.PARAMETER InstallDir
    Putanja do instalacionog direktorija (npr. %LOCALAPPDATA%\Programs\Dictolo\)

.PARAMETER MainPid
    PID glavnog app procesa koji se ceka da se zatvori

.PARAMETER NewExePath
    Putanja do novog Dictolo.exe-a (u instalacionom direktoriju)

.PARAMETER HealthSeconds
    Koliko dugo nova verzija mora ostati ziva da bi se update smatrao uspjelim
#>

param(
    [Parameter(Mandatory=$true)] [string] $StagingDir,
    [Parameter(Mandatory=$true)] [string] $InstallDir,
    [Parameter(Mandatory=$true)] [int] $MainPid,
    [Parameter(Mandatory=$true)] [string] $NewExePath,
    [int] $HealthSeconds = 20
)

$ErrorActionPreference = "Stop"

# %APPDATA%\Dictolo se izvodi iz $StagingDir (.../Dictolo/update_staging/<verzija>), ne iz
# $env:APPDATA: eleviran proces moze raditi pod drugim admin nalogom pa bi $env:APPDATA
# pokazivao na tudji profil. Log i update_failed.json moraju zavrsiti tamo gdje ih app cita.
$AppDataDir = Split-Path (Split-Path $StagingDir -Parent) -Parent
if (-not (Test-Path -LiteralPath $AppDataDir)) {
    $AppDataDir = Join-Path $env:APPDATA "Dictolo"
}
$LogPath = Join-Path $AppDataDir "update_apply.log"
$BackupDir = Join-Path $InstallDir "_update_backup"

$script:IsElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
$script:NewFiles = New-Object System.Collections.Generic.List[string]
$script:StartedPid = 0

function Write-Log {
    param([string] $Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $LogPath -Value "[$timestamp] $Message" -ErrorAction SilentlyContinue
}

function Wait-ForProcess {
    param([int] $ProcessId, [int] $TimeoutSeconds = 30)
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            Write-Log "Glavni proces zavrsio"
            return $true
        }
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    Write-Log "Timeout cekanja na glavni proces (${TimeoutSeconds}s)"
    return $false
}

function Start-App {
    # Iz eleviranog procesa bi novi Dictolo naslijedio admin prava; explorer.exe ga vrati
    # na normalne (tada PID ne znamo, pa se zdravlje prati po putanji exe-a). Neelevirano
    # je Start-Process direktniji i vrati PID.
    $script:StartedPid = 0
    if ($script:IsElevated) {
        & explorer.exe "$NewExePath"
    } else {
        $p = Start-Process -FilePath $NewExePath -PassThru
        if ($p) { $script:StartedPid = $p.Id }
    }
}

function Get-AppProcess {
    # Proces nove verzije: po PID-u kad ga znamo, inace Dictolo.exe iz ove instalacije.
    if ($script:StartedPid -gt 0) {
        return Get-Process -Id $script:StartedPid -ErrorAction SilentlyContinue
    }
    $target = [System.IO.Path]::GetFullPath($NewExePath)
    Get-Process -Name "Dictolo" -ErrorAction SilentlyContinue | Where-Object {
        try { [System.IO.Path]::GetFullPath($_.Path) -ieq $target } catch { $true }
    }
}

function Test-AppHealthy {
    # Nova verzija mora se pojaviti (do 10 s) i onda OSTATI ziva do HealthSeconds.
    # Ranije je bila jedna provjera poslije 3 s, pa pad u 4. sekundi nije vracao staru.
    $deadline = (Get-Date).AddSeconds($HealthSeconds)
    $seen = $false
    $appearBy = (Get-Date).AddSeconds([Math]::Min(10, $HealthSeconds))
    while ((Get-Date) -lt $deadline) {
        $proc = Get-AppProcess
        if ($proc) {
            $seen = $true
        } elseif ($seen) {
            Write-Log "Nova verzija se ugasila tokom provjere zdravlja"
            return $false
        } elseif ((Get-Date) -gt $appearBy) {
            Write-Log "Nova verzija se nije pokrenula"
            return $false
        }
        Start-Sleep -Milliseconds 500
    }
    return $seen
}

function Remove-Backup {
    if (Test-Path -LiteralPath $BackupDir) {
        Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Backup-File {
    param([string] $Source, [string] $RelPath)
    $BackupPath = Join-Path $BackupDir $RelPath
    $BackupParent = Split-Path $BackupPath -Parent

    if (Test-Path -LiteralPath $Source) {
        New-Item -ItemType Directory -Path $BackupParent -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $BackupPath -Force
        Write-Log "Backup: $RelPath"
    } else {
        # Fajl koji prije nije postojao (npr. novi font): na rollback se brise.
        $script:NewFiles.Add($RelPath) | Out-Null
    }
}

function Rollback {
    param([string] $Reason)
    Write-Log "ROLLBACK: $Reason"

    # Nova verzija mozda jos radi (ili visi): ne moze se prepisati dok drzi exe.
    Get-AppProcess | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
    Start-Sleep -Milliseconds 800

    if (Test-Path -LiteralPath $BackupDir) {
        Get-ChildItem -LiteralPath $BackupDir -Recurse -File | ForEach-Object {
            $RelPath = $_.FullName.Substring($BackupDir.Length + 1)
            $TargetPath = Join-Path $InstallDir $RelPath
            $TargetDir = Split-Path $TargetPath -Parent

            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
            Copy-Item -LiteralPath $_.FullName -Destination $TargetPath -Force
            Write-Log "Rollback: $RelPath"
        }
    }
    foreach ($rel in $script:NewFiles) {
        $p = Join-Path $InstallDir $rel
        Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        Write-Log "Rollback, obrisan novi fajl: $rel"
    }
    # Backup je odradio posao; ostavljen bi se sljedeci put pomijesao s novim.
    Remove-Backup

    # update_failed.json marker za GUI (app ga procita i obrise pri startu)
    $FailedMarker = @{
        old_version = $script:OldVersion
        new_version = $script:NewVersion
        reason = $Reason
        timestamp = Get-Date -Format "o"
    } | ConvertTo-Json
    Set-Content -LiteralPath (Join-Path $AppDataDir "update_failed.json") -Value $FailedMarker -Force

    Write-Log "Pokretanje stare verzije"
    Start-App
}

$script:Applied = $false

try {
    Write-Log "=== Update primjena pocela ==="
    Write-Log "StagingDir: $StagingDir"
    Write-Log "InstallDir: $InstallDir"
    Write-Log "MainPid: $MainPid"

    if (-not (Wait-ForProcess $MainPid)) {
        # App se nije zatvorio na vrijeme: odustani. Staging OSTAJE: nista nije dirano,
        # pa sljedeci klik na "Ponovo pokreni za azuriranje" radi bez novog preuzimanja.
        Write-Log "Odustajanje: app se nije zatvorio na vrijeme (staging ostaje za retry)"
        exit 1
    }

    $OldExePath = Join-Path $InstallDir "Dictolo.exe"
    $script:OldVersion = "unknown"
    # Staging dir se zove po verziji (update_staging\<verzija>): pouzdanije od
    # FileVersionInfo, koji na PyInstaller .exe-u zna biti prazan.
    $script:NewVersion = Split-Path $StagingDir -Leaf
    if (Test-Path -LiteralPath $OldExePath) {
        $script:OldVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($OldExePath).FileVersion
    }

    # Zaostali backup od prekinute primjene ne smije se pomijesati s ovim.
    Remove-Backup

    Get-ChildItem -LiteralPath $StagingDir -Recurse -File | ForEach-Object {
        $RelPath = $_.FullName.Substring($StagingDir.Length + 1)
        Backup-File (Join-Path $InstallDir $RelPath) $RelPath
    }

    Write-Log "Primjena update-a..."
    $script:Applied = $true
    Get-ChildItem -LiteralPath $StagingDir -Recurse -File | ForEach-Object {
        $RelPath = $_.FullName.Substring($StagingDir.Length + 1)
        $TargetPath = Join-Path $InstallDir $RelPath
        $TargetDir = Split-Path $TargetPath -Parent

        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Move-Item -LiteralPath $_.FullName -Destination $TargetPath -Force
        Write-Log "Azuriran: $RelPath"
    }

    Write-Log "Pokretanje azurirane verzije (elevated=$script:IsElevated)"
    Start-App

    if (Test-AppHealthy) {
        Write-Log "Provjera zdravlja prosla (${HealthSeconds}s)"
        Remove-Backup
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log "Update uspio: backup i staging obrisani"
    } else {
        Rollback "Nova verzija nije radila ${HealthSeconds}s nakon pokretanja"
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

} catch {
    Write-Log "Greska tokom update-a: $_"
    Write-Log $_.ScriptStackTrace

    if ($script:Applied) {
        Rollback "Iznimka tokom update-a"
    } else {
        # Nista nije prebaceno: samo pocisti djelimican backup i vrati staru verziju.
        Remove-Backup
        if (-not (Get-Process -Name "Dictolo" -ErrorAction SilentlyContinue)) {
            Start-App
        }
    }

    Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Log "=== Update primjena zavrsena uspjesno ==="
exit 0
