@echo off
setlocal enabledelayedexpansion
title dynamic-crf Installer

:: ================================================================
:: Admin check & herstart als nodig
:: ================================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  [*] Geen admin rechten - herstart als Administrator...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%~dp0'"
    exit /b
)

:: ================================================================
:: PS1 script extracten uit dit bat-bestand (alles na regel 22)
:: ================================================================
set "INSTALL_DIR=%~dp0"
if "%INSTALL_DIR:~-1%"=="\" set "INSTALL_DIR=%INSTALL_DIR:~0,-1%"
set "PS_SCRIPT=%TEMP%\dcrf_install.ps1"

more +28 "%~f0" > "%PS_SCRIPT%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%" -InstallDir "%INSTALL_DIR%"

if exist "%PS_SCRIPT%" del /f /q "%PS_SCRIPT%"
exit /b

#=============================== POWERSHELL CODE ===============================
param([string]$InstallDir = $PSScriptRoot)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
$Host.UI.RawUI.WindowTitle = 'dynamic-crf Installer'

if (-not $InstallDir -or $InstallDir -eq '') {
    $InstallDir = (Get-Location).Path
}

$BinDir   = Join-Path $InstallDir 'bin'
$TempDir  = Join-Path $env:TEMP 'dcrf_setup'
$7zExe    = Join-Path $BinDir '7zip\7za.exe'
$logFile  = Join-Path $InstallDir 'install.log'

# --- Helpers ---
function Log {
    param($m)
    try { Add-Content -Path $logFile -Value "[$(Get-Date -Format 'HH:mm:ss')] $m" -ErrorAction SilentlyContinue } catch {}
}

function Write-Banner {
    param($t)
    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "    $t" -ForegroundColor Cyan
    Write-Host "  +--------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}

function Write-Bar {
    param($step, $total, $label)
    $pct    = [int](($step / $total) * 100)
    $filled = [int](($pct / 100) * 42)
    $empty  = 42 - $filled
    $bar    = ('#' * $filled) + ('-' * $empty)
    Write-Host "  [$bar] $pct%" -NoNewline -ForegroundColor Yellow
    Write-Host "  $label" -ForegroundColor White
}

function Write-OK   { param($m) Write-Host "  [OK]  $m" -ForegroundColor Green;  Log "OK: $m" }
function Write-Info { param($m) Write-Host "  [ ]   $m" -ForegroundColor Gray;   Log $m }
function Write-Warn { param($m) Write-Host "  [!]   $m" -ForegroundColor Yellow; Log "WARN: $m" }
function Write-Err  { param($m) Write-Host "  [!!]  $m" -ForegroundColor Red;    Log "ERROR: $m" }

function Abort {
    param($m)
    Write-Host ""
    Write-Err $m
    Write-Host ""
    Write-Host "  Log opgeslagen in: $logFile" -ForegroundColor Gray
    Write-Host ""
    Read-Host "  Druk Enter om te sluiten"
    exit 1
}

function Get-File {
    param($Url, $Dest)
    $name = [System.IO.Path]::GetFileName($Dest)
    Write-Info "Download: $name"
    Log "URL: $Url"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent','Mozilla/5.0 dcrf-installer')
        $wc.DownloadFile($Url, $Dest)
        $size = (Get-Item $Dest).Length
        if ($size -lt 1024) { Abort "Download te klein ($size bytes), waarschijnlijk een foutpagina: $Url" }
        $ext = [System.IO.Path]::GetExtension($Dest).ToLower()
        if ($ext -eq '.zip' -or $ext -eq '.7z' -or $ext -eq '.exe') {
            $fs = [System.IO.File]::OpenRead($Dest)
            $magic = New-Object byte[] 4
            [void]$fs.Read($magic, 0, 4); $fs.Close()
            $isZip = ($magic[0] -eq 0x50 -and $magic[1] -eq 0x4B)
            $is7z  = ($magic[0] -eq 0x37 -and $magic[1] -eq 0x7A -and $magic[2] -eq 0xBC -and $magic[3] -eq 0xAF)
            $isExe = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A)
            if ($ext -eq '.zip' -and -not $isZip)            { Abort "Ongeldig ZIP-bestand (geen PK header): $Url" }
            if ($ext -eq '.7z'  -and -not ($is7z -or $isExe)) { Abort "Ongeldig 7z-bestand: $Url" }
            if ($ext -eq '.exe' -and -not $isExe)            { Abort "Ongeldig EXE-bestand: $Url" }
        }
        Write-OK "Klaar: $name"
    } catch {
        Abort "Download mislukt ($Url): $($_.Exception.Message)"
    }
}

# --- Mappen aanmaken & log init ---
foreach ($d in @($BinDir, $TempDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
"=== dynamic-crf installer gestart $(Get-Date) ===" | Set-Content $logFile
Log "Installatiemap: $InstallDir"

# --- Intro ---
Clear-Host
Write-Banner "dynamic-crf Installer - Volledig Automatisch"
Write-Host "  Installatiemap : $InstallDir" -ForegroundColor White
Write-Host "  Log bestand    : install.log" -ForegroundColor White
Write-Host ""
Write-Host "  Wat wordt geinstalleerd:" -ForegroundColor White
Write-Host "    [1] 7-Zip portable        (~500KB)"
Write-Host "    [2] Go compiler           (~70MB)"
Write-Host "    [3] Git portable          (~60MB)"
Write-Host "    [4] FFmpeg + libvmaf      (~120MB)"
Write-Host "    [5] MediaInfo CLI         (~5MB)"
Write-Host "    [6] dynamic-crf.exe       (compile)"
Write-Host ""
Write-Bar 0 6 "Klaar om te starten..."
Write-Host ""
Read-Host "  Druk Enter om te starten"

# ============================================================
# STAP 1: 7-Zip portable
# ============================================================
Write-Banner "Stap 1/6 - 7-Zip portable"
Write-Bar 0 6 "7-Zip downloaden..."

if (Test-Path $7zExe) {
    Write-OK "Al aanwezig, skip"
} else {
    $d7 = Join-Path $BinDir '7zip'
    if (-not (Test-Path $d7)) { New-Item -ItemType Directory -Path $d7 -Force | Out-Null }
    $z = Join-Path $TempDir '7za.zip'
    Get-File 'https://www.7-zip.org/a/7za920.zip' $z
    Write-Info "Uitpakken..."
    Expand-Archive -Path $z -DestinationPath $d7 -Force
    if (-not (Test-Path $7zExe)) { Abort "7-Zip installatie mislukt" }
    Write-OK "7-Zip geinstalleerd"
}
Write-Bar 1 6 "7-Zip OK"

# ============================================================
# STAP 2: Go
# ============================================================
Write-Banner "Stap 2/6 - Go compiler"
Write-Bar 1 6 "Go ophalen..."

$GoExe = Join-Path $BinDir 'go\bin\go.exe'
if (Test-Path $GoExe) {
    Write-OK "Al aanwezig, skip"
} else {
    $goUrl = 'https://go.dev/dl/go1.24.3.windows-amd64.zip'
    $goVer = 'go1.24.3'
    try {
        Write-Info "Check nieuwste Go versie..."
        $j = Invoke-RestMethod 'https://go.dev/dl/?mode=json' -TimeoutSec 10
        $f = ($j[0].files | Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive' })[0]
        if ($f) { $goUrl = "https://go.dev/dl/$($f.filename)"; $goVer = $j[0].version }
    } catch { Write-Warn "Versie check mislukt, gebruik $goVer" }
    $z = Join-Path $TempDir 'go.zip'
    Write-Info "Download $goVer (~70MB)..."
    Get-File $goUrl $z
    Write-Info "Uitpakken..."
    Expand-Archive -Path $z -DestinationPath $BinDir -Force
    if (-not (Test-Path $GoExe)) { Abort "Go installatie mislukt" }
    Write-OK "$goVer geinstalleerd"
}
$env:Path       = "$(Join-Path $BinDir 'go\bin');$env:Path"
$env:GOPATH     = Join-Path $InstallDir 'gopath'
$env:GOMODCACHE = Join-Path $InstallDir 'gopath\pkg\mod'
if (-not (Test-Path $env:GOPATH)) { New-Item -ItemType Directory -Path $env:GOPATH -Force | Out-Null }
Write-Bar 2 6 "Go OK"

# ============================================================
# STAP 3: Git portable
# ============================================================
Write-Banner "Stap 3/6 - Git portable"
Write-Bar 2 6 "Git ophalen..."

$GitExe = Join-Path $BinDir 'git\bin\git.exe'
if (Test-Path $GitExe) {
    Write-OK "Al aanwezig, skip"
} else {
    $gitUrl   = 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/PortableGit-2.47.1.2-64-bit.7z.exe'
    $gitFname = 'PortableGit-2.47.1.2-64-bit.7z.exe'
    try {
        Write-Info "Check nieuwste Git versie..."
        $rel   = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest' -TimeoutSec 10
        $asset = ($rel.assets | Where-Object { $_.name -like 'PortableGit*64-bit.7z.exe' })[0]
        if ($asset) { $gitUrl = $asset.browser_download_url; $gitFname = $asset.name }
    } catch { Write-Warn "Versie check mislukt, gebruik fallback" }
    $gitPkg = Join-Path $TempDir $gitFname
    $gitDir = Join-Path $BinDir 'git'
    if (-not (Test-Path $gitDir)) { New-Item -ItemType Directory -Path $gitDir -Force | Out-Null }
    Write-Info "Download Git portable (~60MB)..."
    Get-File $gitUrl $gitPkg
    Write-Info "Uitpakken..."
    & "$7zExe" x "$gitPkg" "-o$gitDir" -y | Out-Null
    if (-not (Test-Path $GitExe)) { Abort "Git installatie mislukt" }
    Write-OK "Git portable geinstalleerd"
}
$env:Path = "$(Join-Path $BinDir 'git\bin');$(Join-Path $BinDir 'git\cmd');$env:Path"
Write-Bar 3 6 "Git OK"

# ============================================================
# STAP 4: FFmpeg full build (met libvmaf!)
# ============================================================
Write-Banner "Stap 4/6 - FFmpeg full build (libvmaf)"
Write-Bar 3 6 "FFmpeg ophalen (~120MB)..."

$FfExe = Join-Path $BinDir 'ffmpeg\bin\ffmpeg.exe'
if (Test-Path $FfExe) {
    Write-OK "Al aanwezig, skip"
} else {
    $ff7z = Join-Path $TempDir 'ffmpeg-full.7z'
    Write-Info "Download FFmpeg full build (~120MB, kan 1-2 min duren)..."
    Get-File 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-full.7z' $ff7z
    Write-Info "Uitpakken (kan even duren)..."
    $ffExt = Join-Path $TempDir 'ff-extract'
    & "$7zExe" x "$ff7z" "-o$ffExt" -y | Out-Null
    $sub = Get-ChildItem $ffExt -Directory | Select-Object -First 1
    if (-not $sub) { Abort "FFmpeg uitpakken mislukt" }
    Move-Item $sub.FullName (Join-Path $BinDir 'ffmpeg') -Force
    if (-not (Test-Path $FfExe)) { Abort "FFmpeg installatie mislukt" }
    Write-OK "FFmpeg geinstalleerd"
}
$env:Path = "$(Join-Path $BinDir 'ffmpeg\bin');$env:Path"
Write-Bar 4 6 "FFmpeg OK"

# ============================================================
# STAP 5: MediaInfo CLI
# ============================================================
Write-Banner "Stap 5/6 - MediaInfo CLI"
Write-Bar 4 6 "MediaInfo ophalen..."

$MiExe = Join-Path $BinDir 'mediainfo\MediaInfo.exe'
if (Test-Path $MiExe) {
    Write-OK "Al aanwezig, skip"
} else {
    $miUrl = 'https://mediaarea.net/download/binary/mediainfo/24.11/MediaInfo_CLI_24.11_Windows_x64.zip'
    try {
        $pg   = Invoke-WebRequest 'https://mediaarea.net/en/MediaInfo/Download/Windows' -UseBasicParsing -TimeoutSec 10
        $href = ($pg.Links | Where-Object { $_.href -match 'CLI.*x64.*\.zip' })[0].href
        if ($href) {
            $miUrl = if ($href -match '^https?:')   { $href }
                     elseif ($href -match '^//')    { "https:$href" }
                     else                           { "https://mediaarea.net$href" }
        }
    } catch { Write-Warn "Versie check mislukt, gebruik fallback" }
    $miZip = Join-Path $TempDir 'mediainfo.zip'
    $miDir = Join-Path $BinDir 'mediainfo'
    if (-not (Test-Path $miDir)) { New-Item -ItemType Directory -Path $miDir -Force | Out-Null }
    Get-File $miUrl $miZip
    Write-Info "Uitpakken..."
    Expand-Archive -Path $miZip -DestinationPath $miDir -Force
    if (-not (Test-Path $MiExe)) { Abort "MediaInfo installatie mislukt" }
    Write-OK "MediaInfo geinstalleerd"
}
$env:Path = "$(Join-Path $BinDir 'mediainfo');$env:Path"
Write-Bar 5 6 "MediaInfo OK"

# ============================================================
# STAP 6: dynamic-crf bouwen
# ============================================================
Write-Banner "Stap 6/6 - dynamic-crf compileren"
Write-Bar 5 6 "Bouwen..."

$DcrfExe = Join-Path $InstallDir 'dynamic-crf.exe'
if (Test-Path $DcrfExe) {
    Write-OK "dynamic-crf.exe al aanwezig (verwijder om opnieuw te bouwen)"
} else {
    $repo = Join-Path $TempDir 'dynamic-crf-src'
    if (Test-Path $repo) { Remove-Item $repo -Recurse -Force }
    Write-Info "Clone repository van GitHub..."
    $gitOut = & git clone https://github.com/terranvigil/dynamic-crf.git "$repo" 2>&1
    if ($LASTEXITCODE -ne 0) { Abort "git clone mislukt: $gitOut" }
    Write-OK "Repository gecloned"

    # Windows-patch: cambi.go gebruikt syscall.Mkfifo (Unix-only).
    # Voeg build tag toe zodat dit bestand op Windows wordt overgeslagen,
    # en plaats een stub zodat NewCambi() blijft compileren.
    $cambiSrc = Join-Path $repo 'commands\cambi.go'
    if (Test-Path $cambiSrc) {
        Write-Info "Patch cambi.go voor Windows (geen mkfifo)..."
        $first = (Get-Content $cambiSrc -TotalCount 1)
        if ($first -notmatch '^//go:build') {
            $body = Get-Content $cambiSrc -Raw
            Set-Content -Path $cambiSrc -Value "//go:build !windows`r`n`r`n$body" -Encoding UTF8
        }
        $stub = @'
//go:build windows

package commands

import (
	"context"
	"errors"
	"log/slog"
)

type Cambi struct{}

func NewCambi(_ *slog.Logger, _ string, _ string) *Cambi { return &Cambi{} }

func (c *Cambi) Run(_ context.Context) (float64, float64, error) {
	return 0, 0, errors.New("cambi action is not supported on Windows (requires named pipes)")
}
'@
        Set-Content -Path (Join-Path $repo 'commands\cambi_windows.go') -Value $stub -Encoding UTF8
    }

    # Scene-detection path fix voor Windows: ffprobe's movie= filter ziet
    # de ':' in 'C:\' als option-separator en '\' als escape. Fix:
    # backslashes -> forward slashes, en escape de drive-letter colon.
    $scenesSrc = Join-Path $repo 'commands\ffprobe_scenes.go'
    if (Test-Path $scenesSrc) {
        Write-Info "Patch ffprobe_scenes.go: Windows path escaping..."
        $body = Get-Content $scenesSrc -Raw

        # Voeg "strings" import toe als nog niet aanwezig
        if (-not ($body -match '"strings"')) {
            $body = $body.Replace('"os/exec"', "`"os/exec`"`r`n`t`"strings`"")
            Write-OK "  - strings import toegevoegd"
        }

        # Simpele oplossing: wrap path in single quotes. ffmpeg lavfi parser
        # behandelt content tussen '...' als literal. We escapen alleen
        # interne single quotes (zelden in filenames).
        $oldS = '"movie=" + f.source.Name() + ",select=gt(scene\\,0.3)"'
        $newBlock = @'
escPath := strings.ReplaceAll(f.source.Name(), "\\", "\\\\")
	escPath = strings.ReplaceAll(escPath, "'", "\\'")
	movieFilter := "movie='" + escPath + "',select=gt(scene\\,0.3)"
'@
        if ($body.Contains($oldS)) {
            $argLineNeedle = "args := []string{"
            $argLineReplace = $newBlock + "`r`n`t" + "args := []string{"
            $body = $body.Replace($argLineNeedle, $argLineReplace)
            $body = $body.Replace($oldS, 'movieFilter')
            Set-Content -Path $scenesSrc -Value $body -Encoding UTF8 -NoNewline
            Write-OK "ffprobe_scenes.go: pad in single-quotes gewrapped"
        } else {
            Write-Warn "ffprobe_scenes.go: movie= patroon niet gevonden (al gepatched?)"
        }
    }

    # Duration-heuristic patch: MediaInfo geeft voor sommige MKV-containers de
    # duration in seconden (bv. 1420) ipv milliseconden. dynamic-crf's check
    # 'if durationMs < 1000' triggert dan niet, en hij denkt dat de video
    # 1.4s is. Threshold opkrikken naar 60000 zodat lange videos correct
    # worden gedetecteerd.
    $searchSrc = Join-Path $repo 'actions\crf_search.go'
    if (Test-Path $searchSrc) {
        Write-Info "Patch crf_search.go: duration heuristic + log raw value..."
        $body = Get-Content $searchSrc -Raw
        $oldT = "durationMs := metadata.GetContainer().Duration`r`n`t`tif durationMs < 1000 {"
        if (-not $body.Contains($oldT)) {
            # Probeer LF variant
            $oldT = "durationMs := metadata.GetContainer().Duration`n`t`tif durationMs < 1000 {"
        }
        $newT = "durationMs := metadata.GetContainer().Duration`r`n`t`tc.logger.Info(`"raw mediainfo duration`", `"value`", durationMs)`r`n`t`tif durationMs < 60000 { // patched threshold for MKV in seconds"
        if ($body.Contains($oldT)) {
            $body = $body.Replace($oldT, $newT)
            Set-Content -Path $searchSrc -Value $body -Encoding UTF8 -NoNewline
            Write-OK "crf_search.go duration-fix + logging toegepast"
        } else {
            # fallback: alleen threshold
            $simple = 'if durationMs < 1000 {'
            if ($body.Contains($simple)) {
                $body = $body.Replace($simple, 'if durationMs < 60000 {')
                Set-Content -Path $searchSrc -Value $body -Encoding UTF8 -NoNewline
                Write-OK "crf_search.go duration threshold gefixt (zonder log)"
            } else {
                Write-Warn "crf_search.go: duration-check patroon niet gevonden"
            }
        }
    }

    # Hardware-encoder patch: dynamic-crf gebruikt onvoorwaardelijk -crf.
    # AMD AMF negeert -crf (-> default kwaliteit), Intel QSV gebruikt -global_quality.
    # We vervangen de -crf append met codec-aware logica zodat AMD/QSV native werken.
    $encSrc = Join-Path $repo 'commands\ffmpeg_encode.go'
    if (Test-Path $encSrc) {
        Write-Info "Patch ffmpeg_encode.go: hardware codecs + live progress..."
        $body = Get-Content $encSrc -Raw

        # Patch 1: -crf vervangen door codec-aware logica (AMD/QSV)
        $needle = "args = append(args, `"-crf`", strconv.Itoa(e.cfg.VideoCRF))"
        $replace = @'
crfVal := strconv.Itoa(e.cfg.VideoCRF)
			switch e.cfg.VideoCodec {
			case "av1_amf":
				// AV1 AMF qp range = 0-255. Scale CRF * 5 voor reasonable quality.
				// (qvbr werkt niet op alle drivers, valt terug op CPU - cqp werkt altijd op GPU)
				args = append(args, "-rc", "cqp", "-quality", "speed",
					"-qp_i", strconv.Itoa((e.cfg.VideoCRF-1)*5),
					"-qp_p", strconv.Itoa((e.cfg.VideoCRF+1)*5),
					"-qp_b", strconv.Itoa((e.cfg.VideoCRF+3)*5))
			case "hevc_amf", "h264_amf":
				// HEVC/H264 AMF: qvbr werkt goed (gebruiker meldt: works perfect)
				args = append(args, "-rc", "qvbr", "-qvbr_quality_level", crfVal)
			case "av1_nvenc":
				args = append(args, "-cq", crfVal)
			case "hevc_qsv", "h264_qsv":
				args = append(args, "-global_quality", crfVal)
			case "av1_qsv":
				args = append(args, "-global_quality", strconv.Itoa(e.cfg.VideoCRF*5))
			default:
				args = append(args, "-crf", crfVal)
			}
'@
        if ($body.Contains($needle)) {
            $body = $body.Replace($needle, $replace)
            Write-OK "  - codec-aware quality flags (AMF -> qp, QSV -> global_quality)"
        }

        # Patch 2: ffmpeg progress doorgeven via stdout (live progress bar mogelijk)
        $argsNeedle = '"-hide_banner",' + "`r`n`t`t" + '"-i", e.sourcePath,'
        if (-not $body.Contains($argsNeedle)) {
            $argsNeedle = '"-hide_banner",' + "`n`t`t" + '"-i", e.sourcePath,'
        }
        $argsReplace = '"-hide_banner",' + "`r`n`t`t" + '"-progress", "pipe:1",' + "`r`n`t`t" + '"-stats_period", "1",' + "`r`n`t`t" + '"-i", e.sourcePath,'
        if ($body.Contains($argsNeedle)) {
            $body = $body.Replace($argsNeedle, $argsReplace)
            Write-OK "  - ffmpeg -progress pipe:1 toegevoegd"
        }

        # Patch 3: stderr forwarden naar dynamic-crf stderr (zien errors live)
        # en stdout van ffmpeg ontvangen voor progress
        $stderrNeedle = 'cmd.Stderr = &stderr'
        $stderrReplace = "cmd.Stderr = io.MultiWriter(&stderr, os.Stderr)`r`n`tcmd.Stdout = os.Stdout"
        if ($body.Contains($stderrNeedle)) {
            $body = $body.Replace($stderrNeedle, $stderrReplace)
            Write-OK "  - stderr/stdout forwarding (live ffmpeg output)"
        }

        # Patch 4: imports toevoegen voor io en os
        $importNeedle = "`"os/exec`""
        $importReplace = "`"io`"`r`n`t`"os`"`r`n`t`"os/exec`""
        if ($body.Contains($importNeedle) -and -not $body.Contains("`"io`"`r`n")) {
            $body = $body.Replace($importNeedle, $importReplace)
            Write-OK "  - imports (io, os) toegevoegd"
        }

        Set-Content -Path $encSrc -Value $body -Encoding UTF8 -NoNewline
    }

    Write-Info "Compileer dynamic-crf.exe (kan 1-2 min duren)..."
    Push-Location $repo
    $buildOut  = & go build -o "$DcrfExe" ./cmd/... 2>&1
    $buildCode = $LASTEXITCODE
    Pop-Location
    Remove-Item $repo -Recurse -Force -ErrorAction SilentlyContinue
    if ($buildCode -ne 0 -or -not (Test-Path $DcrfExe)) {
        Abort "Build mislukt (code $buildCode): $buildOut"
    }
    Write-OK "dynamic-crf.exe succesvol gebouwd!"
}

# --- run.bat wrapper aanmaken ---
$runBat = Join-Path $InstallDir 'run.bat'
$rc = @'
@echo off
set "BASE=%~dp0"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"
set "PATH=%BASE%\bin\ffmpeg\bin;%BASE%\bin\mediainfo;%BASE%\bin\go\bin;%BASE%\bin\git\bin;%BASE%\bin\git\cmd;%PATH%"
"%BASE%\dynamic-crf.exe" %*
'@
[System.IO.File]::WriteAllText($runBat, $rc, [System.Text.Encoding]::ASCII)
Write-OK "run.bat wrapper aangemaakt"

# --- Temp opruimen ---
Remove-Item $TempDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Bar 6 6 "Klaar!"

# ============================================================
# VERIFICATIE
# ============================================================
Write-Banner "Verificatie"

$allOk  = $true
$checks = @(
    [PSCustomObject]@{N='ffmpeg.exe';      P=(Join-Path $BinDir 'ffmpeg\bin\ffmpeg.exe')}
    [PSCustomObject]@{N='ffprobe.exe';     P=(Join-Path $BinDir 'ffmpeg\bin\ffprobe.exe')}
    [PSCustomObject]@{N='MediaInfo.exe';   P=(Join-Path $BinDir 'mediainfo\MediaInfo.exe')}
    [PSCustomObject]@{N='go.exe';          P=(Join-Path $BinDir 'go\bin\go.exe')}
    [PSCustomObject]@{N='git.exe';         P=(Join-Path $BinDir 'git\bin\git.exe')}
    [PSCustomObject]@{N='dynamic-crf.exe'; P=$DcrfExe}
    [PSCustomObject]@{N='run.bat';         P=(Join-Path $InstallDir 'run.bat')}
)
foreach ($c in $checks) {
    if (Test-Path $c.P) { Write-OK $c.N }
    else { Write-Err "$($c.N) ONTBREEKT"; $allOk = $false }
}

Write-Info "libvmaf check..."
$vmaf = & (Join-Path $BinDir 'ffmpeg\bin\ffmpeg.exe') -filters 2>&1 | Select-String 'libvmaf'
if ($vmaf) { Write-OK "libvmaf aanwezig in FFmpeg - scoring werkt!" }
else { Write-Err "libvmaf NIET gevonden in FFmpeg - scoring werkt niet!"; $allOk = $false }

Write-Host ""
if ($allOk) {
    Write-Host "  +------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |        INSTALLATIE GESLAAGD!                   |" -ForegroundColor Green
    Write-Host "  +------------------------------------------------+" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Gebruik via run.bat:" -ForegroundColor Yellow
    Write-Host "    run.bat -a search   -i video.mp4" -ForegroundColor White
    Write-Host "    run.bat -a search   -i video.mp4 -targetvmaf 93 -h 1080" -ForegroundColor White
    Write-Host "    run.bat -a optimize -i video.mp4 -o output.mp4 -h 1080" -ForegroundColor White
    Write-Host "    run.bat -a encode   -i video.mp4 -o output.mp4 -crf 18" -ForegroundColor White
    Write-Host "    run.bat -a vmaf     -i source.mp4 -o encoded.mp4" -ForegroundColor White
    Write-Host ""
    Write-Host "  VMAF targets:" -ForegroundColor Yellow
    Write-Host "    95 = near-transparent (archief)"
    Write-Host "    93 = hoge kwaliteit   (aanbevolen default)"
    Write-Host "    90 = goed             (kleinere bestanden)"
    Write-Host ""
} else {
    Write-Host "  +------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |        INSTALLATIE HAD FOUTEN!                 |" -ForegroundColor Red
    Write-Host "  +------------------------------------------------+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Check: $logFile" -ForegroundColor Yellow
    Write-Host ""
}

Read-Host "  Druk Enter om te sluiten"
