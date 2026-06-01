param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('nvenc','amf','cpu')]
    [string]$Encoder,

    [int]$Height = 0,        # 0 = origineel resolutie (geen scaling)
    [int]$Quality = 23,
    [string]$InputDir,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

# --- Paden ---
$Base    = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Base '_job-kill-on-close.ps1')
if (-not $InputDir)  { $InputDir  = Join-Path $Base 'input' }
if (-not $OutputDir) { $OutputDir = Join-Path $Base 'output' }
$Ffmpeg  = Join-Path $Base 'bin\ffmpeg\bin\ffmpeg.exe'
$Ffprobe = Join-Path $Base 'bin\ffmpeg\bin\ffprobe.exe'

# --- Sanity checks ---
if (-not (Test-Path $Ffmpeg) -or -not (Test-Path $Ffprobe)) {
    Write-Host "[!!] ffmpeg/ffprobe niet gevonden in $Base\bin\ffmpeg\bin\" -ForegroundColor Red
    Write-Host "     Run eerst de installer (install-dynamic-crf (4).bat)." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $InputDir))  { New-Item -ItemType Directory -Path $InputDir  -Force | Out-Null }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$LocalTemp = Join-Path $Base 'temp'
if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
$env:TEMP = $LocalTemp
$env:TMP  = $LocalTemp

# --- Encoder check ---
$encoders = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
function Test-Encoder($name) { return $encoders -match "\b$name\b" }

switch ($Encoder) {
    'nvenc' {
        if (-not (Test-Encoder 'hevc_nvenc')) {
            Write-Host "[!!] hevc_nvenc niet beschikbaar in deze ffmpeg build (NVIDIA driver/GPU ontbreekt?)." -ForegroundColor Red
            exit 2
        }
        $codecArgs = @(
            '-c:v','hevc_nvenc',
            '-preset','p6',
            '-tune','hq',
            '-rc','vbr',
            '-cq', "$Quality",
            '-b:v','0',
            '-multipass','fullres',
            '-spatial_aq','1'
        )
        $label = "NVIDIA NVENC HEVC (cq=$Quality)"
    }
    'amf' {
        if (-not (Test-Encoder 'hevc_amf')) {
            Write-Host "[!!] hevc_amf niet beschikbaar in deze ffmpeg build (AMD driver/GPU ontbreekt?)." -ForegroundColor Red
            exit 2
        }
        $qpI = $Quality - 1; $qpP = $Quality + 1; $qpB = $Quality + 3
        $codecArgs = @(
            '-c:v','hevc_amf',
            '-quality','quality',
            '-usage','transcoding',
            '-rc','cqp',
            '-qp_i', "$qpI",
            '-qp_p', "$qpP",
            '-qp_b', "$qpB"
        )
        $label = "AMD AMF HEVC (qp=$Quality)"
    }
    'cpu' {
        $codecArgs = @(
            '-c:v','libx265',
            '-preset','medium',
            '-crf', "$Quality"
        )
        $label = "CPU libx265 (crf=$Quality)"
    }
}

# --- Verzamel input bestanden ---
$exts = @('*.mp4','*.mkv','*.mov','*.avi','*.m4v','*.webm','*.ts')
$files = @()
foreach ($e in $exts) { $files += Get-ChildItem -Path $InputDir -Filter $e -File -ErrorAction SilentlyContinue }
$files = $files | Sort-Object FullName -Unique

Write-Host ""
$resTxt = if ($Height -gt 0) { "${Height}p" } else { "origineel" }
Write-Host "=== Batch encode -> $resTxt ===" -ForegroundColor Cyan
Write-Host " Encoder : $label"
Write-Host " Input   : $InputDir"
Write-Host " Output  : $OutputDir"
Write-Host " Aantal  : $($files.Count) bestand(en)"
Write-Host ""

if ($files.Count -eq 0) {
    Write-Host "[!!] Geen video's gevonden in $InputDir" -ForegroundColor Yellow
    Write-Host "     Plaats .mp4/.mkv/.mov/.avi/.m4v/.webm/.ts en run opnieuw."
    exit 0
}

# --- Helper: toon bron-info via ffprobe ---
function Show-VideoInfo($file) {
    $j = & $Ffprobe -v error -show_format -show_streams -of json -- "$file" 2>$null | Out-String
    try { $info = $j | ConvertFrom-Json } catch { return }

    $v = $info.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = @($info.streams | Where-Object { $_.codec_type -eq 'audio' })
    $s = @($info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
    $t = @($info.streams | Where-Object { $_.codec_type -eq 'attachment' })
    $dur = [double]$info.format.duration
    $sizeMB = [Math]::Round([double]$info.format.size / 1MB, 1)
    $bitMbps = if ($dur -gt 0) { [Math]::Round(([double]$info.format.bit_rate) / 1MB, 2) } else { 0 }

    Write-Host ("  bron : {0}x{1} {2} @ {3:N0}s, {4} MB, {5} Mbps" -f $v.width, $v.height, $v.codec_name, $dur, $sizeMB, $bitMbps) -ForegroundColor DarkCyan
    if ($a.Count -gt 0) {
        $langs = ($a | ForEach-Object { $l = $_.tags.language; if (-not $l) { 'und' } else { $l } }) -join ','
        Write-Host ("  audio: $($a.Count) track(s) [$langs] -> wordt gekopieerd") -ForegroundColor DarkCyan
    }
    if ($s.Count -gt 0) {
        $langs = ($s | ForEach-Object { $l = $_.tags.language; if (-not $l) { 'und' } else { $l } }) -join ','
        Write-Host ("  subs : $($s.Count) track(s) [$langs] -> wordt gekopieerd") -ForegroundColor DarkCyan
    }
    if ($t.Count -gt 0) {
        Write-Host ("  attach: $($t.Count) (fonts/covers) -> wordt gekopieerd") -ForegroundColor DarkCyan
    }
}

# --- Helper: duration in seconds via ffprobe ---
function Get-Duration($file) {
    $out = & $Ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>$null
    if ($out -match '^\s*([\d.]+)') { return [double]$Matches[1] }
    return 0
}

# --- Helper: parse HH:MM:SS.xx naar seconden ---
function Parse-Time($s) {
    if ($s -match '^(\d+):(\d+):([\d.]+)') {
        return [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [double]$Matches[3]
    }
    return 0
}

$ok = 0; $fail = 0; $skip = 0; $idx = 0

foreach ($f in $files) {
    $idx++
    $suffix = if ($Height -gt 0) { "_${Height}p" } else { "_re" }
    $out = Join-Path $OutputDir ("{0}{1}.mkv" -f $f.BaseName, $suffix)

    Write-Host ("-" * 60)
    Write-Host ("[$idx/$($files.Count)] {0}" -f $f.Name) -ForegroundColor Cyan
    Write-Host ("           -> {0}" -f (Split-Path -Leaf $out))

    if ([System.IO.File]::Exists($out)) {
        Write-Host "  [skip] output bestaat al." -ForegroundColor Yellow
        $skip++; continue
    }

    Show-VideoInfo $f.FullName

    $duration = Get-Duration $f.FullName
    if ($duration -le 0) {
        Write-Host "  [warn] duur onbekend, progress bar wordt benaderd." -ForegroundColor Yellow
        $duration = 1
    }

    $ffArgs = @(
        '-hide_banner','-loglevel','error','-nostats',
        '-progress','pipe:1',
        '-y',
        '-i', $f.FullName,
        '-map','0:v:0',
        '-map','0:a?',
        '-map','0:s?',
        '-map','0:t?',
        '-map_metadata','0',
        '-map_chapters','0',
        '-pix_fmt','yuv420p10le'
    )
    if ($Height -gt 0) { $ffArgs += @('-vf', "scale=-2:$Height") }
    $ffArgs += $codecArgs + @(
        '-c:a','copy',
        '-c:s','copy',
        $out
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPct = -1
    $status  = 'starting...'
    $ffLog   = New-Object System.Text.StringBuilder

    try {
        & $Ffmpeg @ffArgs 2>&1 | ForEach-Object {
            $line = "$_"
            [void]$ffLog.AppendLine($line)
            if ($line -match '^out_time=([\d:.]+)') {
                $sec = Parse-Time $Matches[1]
                $pct = [Math]::Min(100, [int](($sec / $duration) * 100))
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    $elapsed = $sw.Elapsed.TotalSeconds
                    $eta = if ($pct -gt 0) { [int](($elapsed / $pct) * (100 - $pct)) } else { 0 }
                    Write-Progress -Activity ("[$idx/$($files.Count)] " + $f.Name) `
                                   -Status ("$pct%  (verstreken {0:N0}s, ETA {1:N0}s)  $status" -f $elapsed, $eta) `
                                   -PercentComplete $pct
                }
            }
            elseif ($line -match '^speed=(.+)$')   { $status = "speed=$($Matches[1].Trim())" }
            elseif ($line -match '^(frame|fps|bitrate|total_size|out_time|out_time_us|out_time_ms|dup_frames|drop_frames|progress|stream_\d+_\d+_q)=') { }
            else {
                # Alles wat geen progress-key is, is potentieel info/warning/error
                Write-Host "  ffmpeg> $line" -ForegroundColor DarkGray
            }
        }
        $exit = $LASTEXITCODE
    } catch {
        $exit = 1
        Write-Host "  [exception] $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Progress -Activity ("[$idx/$($files.Count)] " + $f.Name) -Completed
    $sw.Stop()

    if (($exit -ne 0) -or -not ([System.IO.File]::Exists($out))) {
        Write-Host "  [debug] ffmpeg exit=$exit, output exists=$([System.IO.File]::Exists($out))" -ForegroundColor Yellow
        Write-Host "  [debug] full ffmpeg log:" -ForegroundColor Yellow
        $ffLog.ToString().Split("`n") | ForEach-Object { if ($_.Trim()) { Write-Host "    $_" -ForegroundColor DarkGray } }
    }

    if ($exit -eq 0 -and ([System.IO.File]::Exists($out))) {
        $sizeIn  = [Math]::Round($f.Length / 1MB, 1)
        $sizeOut = [Math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
        $ratio   = if ($sizeIn -gt 0) { [Math]::Round(($sizeOut / $sizeIn) * 100, 0) } else { 0 }
        Write-Host ("  [OK] {0:N0}s   {1} MB -> {2} MB ({3}%)" -f $sw.Elapsed.TotalSeconds, $sizeIn, $sizeOut, $ratio) -ForegroundColor Green
        $ok++
    } else {
        Write-Host "  [FAIL] exit $exit" -ForegroundColor Red
        if ([System.IO.File]::Exists($out)) { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
        $fail++
    }
}

Write-Host ("=" * 60)
Write-Host " Klaar.  OK: $ok   FAIL: $fail   SKIP: $skip   Totaal: $($files.Count)" -ForegroundColor Cyan
Write-Host " Output: $OutputDir"
Write-Host ("=" * 60)
