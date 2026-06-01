param(
    [int]$Height = 0,        # 0 = origineel resolutie
    [double]$TargetVmaf = 93,
    [double]$Tolerance = 1.5,
    [int]$MinCrf = 28,
    [int]$MaxCrf = 18,
    [int]$InitialCrf = 22,
    [string]$Tune = '',
    [string]$Codec = '',               # leeg = vraag interactief
    [switch]$Remux,
    [string]$InputDir,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$Base    = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Base '_job-kill-on-close.ps1')
if (-not $InputDir)  { $InputDir  = Join-Path $Base 'input' }
if (-not $OutputDir) { $OutputDir = Join-Path $Base 'output' }
$Ffprobe = Join-Path $Base 'bin\ffmpeg\bin\ffprobe.exe'
$RunBat  = Join-Path $Base 'run.bat'
$Dcrf    = Join-Path $Base 'dynamic-crf.exe'

$Ffmpeg = Join-Path $Base 'bin\ffmpeg\bin\ffmpeg.exe'

foreach ($p in @($Ffmpeg, $Ffprobe, $RunBat, $Dcrf)) {
    if (-not (Test-Path $p)) {
        Write-Host "[!!] Niet gevonden: $p" -ForegroundColor Red
        Write-Host "     Run eerst install-dynamic-crf.bat" -ForegroundColor Red
        exit 1
    }
}

# --- Beschikbare encoders detecteren ---
$encList = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
function Has-Enc($name) { return $encList -match "\b$name\b" }

# --- Interactieve codec keuze als geen $Codec opgegeven ---
if (-not $Codec) {
    Write-Host ""
    Write-Host "=== Kies codec ===" -ForegroundColor Cyan
    Write-Host ""
    function Mark($name) { if (Has-Enc $name) { '[OK]' } else { '[--]' } }
    Write-Host "  H.264 (oudste, breedst compatibel)" -ForegroundColor Yellow
    Write-Host ("    1) NVIDIA NVENC H.264   $(Mark 'h264_nvenc')")
    Write-Host ("    2) AMD AMF H.264        $(Mark 'h264_amf')")
    Write-Host ("    3) Intel QSV H.264      $(Mark 'h264_qsv')")
    Write-Host  "    4) CPU libx264          [OK]   (kleinste H.264, traagst)"
    Write-Host ""
    Write-Host "  HEVC/H.265 (~40% kleiner dan H.264)" -ForegroundColor Yellow
    Write-Host ("    5) NVIDIA NVENC HEVC    $(Mark 'hevc_nvenc')")
    Write-Host ("    6) AMD AMF HEVC         $(Mark 'hevc_amf')")
    Write-Host ("    7) Intel QSV HEVC       $(Mark 'hevc_qsv')")
    Write-Host  "    8) CPU libx265          [OK]   (kleinste HEVC, traagst - aanbevolen voor anime)"
    Write-Host ""
    Write-Host "  AV1 (~30% kleiner dan HEVC, modern)" -ForegroundColor Yellow
    Write-Host ("    9) NVIDIA NVENC AV1     $(Mark 'av1_nvenc')   (alleen RTX 40+)")
    Write-Host ("   10) AMD AMF AV1          $(Mark 'av1_amf')   (alleen RX 7000+)")
    Write-Host ("   11) Intel QSV AV1        $(Mark 'av1_qsv')   (alleen Arc/Battlemage)")
    Write-Host ("   12) CPU SVT-AV1          $(Mark 'libsvtav1')   (snel CPU AV1)")
    Write-Host ""
    Write-Host "  [OK] = werkt op deze machine    [--] = niet beschikbaar" -ForegroundColor DarkGray
    Write-Host ""
    do {
        $choice = Read-Host "Kies nummer (1-12, default: 8=libx265)"
        if (-not $choice) { $choice = '8' }
    } while ($choice -notmatch '^([1-9]|1[0-2])$')

    $Codec = switch ($choice) {
        '1'  { 'h264_nvenc' }
        '2'  { 'h264_amf' }
        '3'  { 'h264_qsv' }
        '4'  { 'libx264' }
        '5'  { 'hevc_nvenc' }
        '6'  { 'hevc_amf' }
        '7'  { 'hevc_qsv' }
        '8'  { 'libx265' }
        '9'  { 'av1_nvenc' }
        '10' { 'av1_amf' }
        '11' { 'av1_qsv' }
        '12' { 'libsvtav1' }
    }
    Write-Host "  -> Geselecteerd: $Codec" -ForegroundColor Green
    Write-Host ""
}

# --- Codec beschikbaarheid checken in ffmpeg ---
if ($Codec -ne 'libx264' -and $Codec -ne 'libx265' -and $Codec -ne 'libsvtav1' -and $Codec -ne 'libvpx-vp9') {
    if ($encList -notmatch "\b$Codec\b") {
        Write-Host ""
        Write-Host "[!!] Codec '$Codec' is niet beschikbaar in deze ffmpeg build." -ForegroundColor Red
        if ($Codec -match 'nvenc')   { Write-Host "     -> Voor NVENC heb je een NVIDIA GPU + recente driver nodig." -ForegroundColor Yellow }
        if ($Codec -match 'amf')     { Write-Host "     -> Voor AMF heb je een AMD GPU + Adrenalin driver nodig." -ForegroundColor Yellow }
        if ($Codec -match 'qsv')     { Write-Host "     -> Voor QSV heb je een Intel CPU/GPU met Quick Sync nodig." -ForegroundColor Yellow }
        Write-Host ""
        Write-Host "  Beschikbare hardware encoders op deze machine:" -ForegroundColor Cyan
        ($encList -split "`n" | Where-Object { $_ -match '^\s*V\.\.\.\.\.\s+\S*(nvenc|amf|qsv|videotoolbox)' }) | ForEach-Object {
            Write-Host "    $_" -ForegroundColor Cyan
        }
        Write-Host ""
        Write-Host "  Geen GPU? Gebruik dan batch-optimize-cpu.bat (libx264)." -ForegroundColor Yellow
        exit 2
    }
}
if (-not (Test-Path $InputDir))  { New-Item -ItemType Directory -Path $InputDir  -Force | Out-Null }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

# Lokale temp folder voor dynamic-crf en ffmpeg (in plaats van %TEMP%).
# Hier komen sample.mp4, test-encodes en interim files - handig voor inspectie.
$LocalTemp = Join-Path $Base 'temp'
if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
$env:TEMP = $LocalTemp
$env:TMP  = $LocalTemp

$exts = @('*.mp4','*.mkv','*.mov','*.avi','*.m4v','*.webm','*.ts')
$files = @()
foreach ($e in $exts) { $files += Get-ChildItem -Path $InputDir -Filter $e -File -ErrorAction SilentlyContinue }
$files = $files | Sort-Object FullName -Unique

$isGpu = $Codec -match 'nvenc|amf|qsv|videotoolbox'
$strat = if ($isGpu) { "GPU search + full GPU encode ($Codec)" } else { "CPU search + full CPU encode ($Codec)" }
if ($Remux) { $strat += " + post-mux (behoud subs/audio)" }

Write-Host ""
$resTxt = if ($Height -gt 0) { "${Height}p" } else { "origineel" }
Write-Host "=== Optimize -> $resTxt (dynamic-crf, VMAF $TargetVmaf +/- $Tolerance) ===" -ForegroundColor Cyan
Write-Host " Strategie : $strat"
Write-Host " Search    : bisection in CRF $MaxCrf..$MinCrf (start $InitialCrf, tolerance $Tolerance)"
Write-Host " Input     : $InputDir"
Write-Host " Output    : $OutputDir"
Write-Host " Aantal    : $($files.Count) bestand(en)"
Write-Host ""

if ($files.Count -eq 0) {
    Write-Host "[!!] Geen video's gevonden in $InputDir" -ForegroundColor Yellow
    exit 0
}

function Show-VideoInfo($file) {
    $j = & $Ffprobe -v error -show_format -show_streams -of json -- "$file" 2>$null | Out-String
    try { $info = $j | ConvertFrom-Json } catch { return @{ Duration = 0 } }
    $v = $info.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    $a = @($info.streams | Where-Object { $_.codec_type -eq 'audio' })
    $s = @($info.streams | Where-Object { $_.codec_type -eq 'subtitle' })
    $dur = [double]$info.format.duration
    $sizeMB = [Math]::Round([double]$info.format.size / 1MB, 1)
    Write-Host ("  bron : {0}x{1} {2} @ {3:N0}s, {4} MB" -f $v.width, $v.height, $v.codec_name, $dur, $sizeMB) -ForegroundColor DarkCyan
    if ($a.Count -gt 0) { Write-Host ("  audio: $($a.Count) track(s)") -ForegroundColor DarkCyan }
    if ($s.Count -gt 0) { Write-Host ("  subs : $($s.Count) track(s)  (let op: dynamic-crf negeert subs in output)") -ForegroundColor DarkYellow }
    return @{ Duration = $dur }
}

$ok = 0; $fail = 0; $skip = 0; $idx = 0

foreach ($f in $files) {
    $idx++
    $finalExt = if ($Remux) { 'mkv' } else { 'mp4' }
    $suffix = if ($Height -gt 0) { "_${Height}p" } else { "_re" }
    $out = Join-Path $OutputDir ("{0}{1}.{2}" -f $f.BaseName, $suffix, $finalExt)
    # dynamic-crf schrijft altijd naar temp\out.mp4 (relatief, vanwege CWD=temp).
    # Daarna remuxen we naar $out OF verplaatsen we naar $out.

    Write-Host ("-" * 60)
    Write-Host ("[$idx/$($files.Count)] {0}" -f $f.Name) -ForegroundColor Cyan
    Write-Host ("           -> {0}" -f (Split-Path -Leaf $out))

    if ([System.IO.File]::Exists($out)) {
        Write-Host "  [skip] output bestaat al." -ForegroundColor Yellow
        $skip++; continue
    }

    $meta = Show-VideoInfo $f.FullName
    $duration = [double]$meta.Duration
    if ($duration -le 0) { $duration = 1 }

    Write-Host ""
    Write-Host "  dynamic-crf optimize (search + full encode, codec=$Codec)..." -ForegroundColor Cyan

    # --- Hardlink source naar temp\src.mkv ---
    # Dan draaien we dynamic-crf met CWD=temp en geven 'src.mkv' (zonder pad)
    # als input. Dat omzeilt ALLE pad-escape problemen met ffmpeg lavfi
    # (geen drive-letter colon, geen backslashes, geen spaties, geen brackets).
    $cleanSrc = Join-Path $LocalTemp "src.mkv"
    if ([System.IO.File]::Exists($cleanSrc)) { Remove-Item -LiteralPath $cleanSrc -Force -ErrorAction SilentlyContinue }
    Write-Host "  link: $($f.Name) -> temp\src.mkv (run dcrf met CWD=temp)" -ForegroundColor DarkGray
    & cmd /c mklink /H "`"$cleanSrc`"" "`"$($f.FullName)`"" 2>&1 | Out-Null
    if (-not [System.IO.File]::Exists($cleanSrc)) {
        Write-Host "  hardlink mislukt, kopieer ipv linken..." -ForegroundColor Yellow
        Copy-Item -LiteralPath $f.FullName -Destination $cleanSrc -Force
    }

    # Output ook in temp (relatief) en pas later verplaatsen
    $tempOutName = "out.mp4"
    $tempOut = Join-Path $LocalTemp $tempOutName
    # Stale tempOut van eventuele vorige run weghalen
    if ([System.IO.File]::Exists($tempOut)) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }

    $argList = @(
        '-a','optimize',
        '-i', 'src.mkv',                 # relatief - geen pad-issues
        '-o', $tempOutName,              # relatief - geen pad-issues
        '-targetvmaf', "$TargetVmaf",
        '-tolerance',  "$Tolerance",
        '-initialcrf', "$InitialCrf",
        '-mincrf',     "$MinCrf",
        '-maxcrf',     "$MaxCrf",
        '-codec', $Codec
    )
    if ($Height -gt 0) { $argList += @('-h', "$Height") }
    if ($Tune -and -not $isGpu) { $argList += @('-t', $Tune) }

    $quoted = ($argList | ForEach-Object { "`"$_`"" }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = "/c `"`"$RunBat`" $quoted 2>&1`""
    $psi.WorkingDirectory = $LocalTemp   # << HET BELANGRIJKE: CWD = temp folder
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $psi.RedirectStandardError = $true

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $lines = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]@())
    $outAction = { if ($EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) } }
    $evtOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction -MessageData $lines
    $evtErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $outAction -MessageData $lines

    [void]$proc.Start()
    Add-ToJob $proc
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $phase = 'init'
    $iter = 0
    $maxIter = 6
    $foundCrf = 0
    $foundVmaf = 0
    $lastTick = -1
    $log = New-Object System.Text.StringBuilder

    function Tick-Bar($pct, $status) {
        $pct = [Math]::Min(99, [Math]::Max(0, [int]$pct))
        Write-Progress -Id 2 -Activity ("[$idx/$($files.Count)] optimize " + $f.Name) `
                       -Status $status -PercentComplete $pct
    }

    Tick-Bar 1 "starting..."

    while (-not $proc.HasExited -or $lines.Count -gt 0) {
        $line = $null
        if ($lines.Count -gt 0) {
            $line = $lines[0]
            $lines.RemoveAt(0)
        }

        if ($line) {
            [void]$log.AppendLine($line)

            if ($line -match 'Found crf:\s*(\d+)') {
                $foundCrf = [int]$Matches[1]
                if ($line -match 'vmaf:\s*([\d.]+)') { $foundVmaf = [double]$Matches[1] }
                Write-Host ("        => FOUND CRF $foundCrf (VMAF {0:N2}) - start full encode" -f $foundVmaf) -ForegroundColor Green
                $phase = 'encode'
                Tick-Bar 60 "full encode (CRF $foundCrf)..."
            }
            elseif ($line -match 'crf=(\d+).*vmaf=([\d.]+)' -or $line -match 'crf:\s*(\d+).*vmaf:\s*([\d.]+)') {
                $iter++
                $phase = 'search'
                $ts = "{0,5:N1}s" -f $sw.Elapsed.TotalSeconds
                Write-Host ("        [$ts] iter $iter : CRF $($Matches[1]) -> VMAF $($Matches[2])") -ForegroundColor Yellow
                $pct = 15 + [int](($iter / $maxIter) * 40)
                Tick-Bar $pct ("search iter $iter/~$maxIter  CRF $($Matches[1]) VMAF $($Matches[2])  ({0:N0}s)" -f $sw.Elapsed.TotalSeconds)
            }
            elseif ($line -match 'detect|scene|select') {
                if ($phase -ne 'scene' -and $phase -ne 'sample' -and $phase -ne 'search') {
                    Write-Host "        . scene detect" -ForegroundColor DarkGray
                    $phase = 'scene'
                }
            }
            elseif ($line -match 'sample|extract|concat') {
                if ($phase -ne 'sample' -and $phase -ne 'search') {
                    Write-Host "        . sample build (HEVC bron decoderen + 15 scenes concat - PURE CPU, kan 2-5 min duren)" -ForegroundColor DarkGray
                    $phase = 'sample'
                }
                Write-Host "        > $line" -ForegroundColor DarkGray
            }
            elseif ($line -match 'final|writing|output' -and $phase -ne 'encode') {
                $phase = 'encode'
                Write-Host "        . writing final encode" -ForegroundColor DarkGray
            }
            elseif ($line -match 'error|fail|panic' -and $line -notmatch 'tolerance') {
                Write-Host "        ! $line" -ForegroundColor Red
            }
            # --- Live ffmpeg progress parsing (van patched dynamic-crf) ---
            elseif ($line -match '^out_time_us=(\d+)') {
                $sec = [int64]$Matches[1] / 1000000
                if ($duration -gt 0) {
                    $encPct = [Math]::Min(100, [int](($sec / $duration) * 100))
                    $speedTxt = if ($script:lastSpeed) { $script:lastSpeed } else { "?" }
                    Write-Progress -Id 3 -ParentId 2 `
                        -Activity "ffmpeg encode (current iter)" `
                        -Status ("{0}%  time={1:N0}s/{2:N0}s  speed={3}" -f $encPct, $sec, $duration, $speedTxt) `
                        -PercentComplete $encPct
                }
            }
            elseif ($line -match '^speed=\s*([\d.]+x|N/A)') {
                $script:lastSpeed = $Matches[1]
            }
            elseif ($line -match '^progress=end') {
                Write-Progress -Id 3 -ParentId 2 -Activity "ffmpeg encode (current iter)" -Completed
                $script:lastSpeed = $null
            }
            elseif ($line -match '^(frame|fps|bitrate|total_size|out_time|out_time_ms|dup_frames|drop_frames|progress|stream_\d+_\d+_q)=') {
                # andere progress keys: silently slik
            }
            else {
                if ($line.Trim().Length -gt 0) {
                    Write-Host "        > $line" -ForegroundColor DarkGray
                }
            }
        }
        else {
            $elapsed = $sw.Elapsed.TotalSeconds
            $pct = switch ($phase) {
                'init'   { [Math]::Min(4,  [int]$elapsed) }
                'scene'  { 5 + [Math]::Min(7, [int]($elapsed / 2)) }
                'sample' { 12 + [Math]::Min(2, [int]($elapsed / 4)) }
                'search' { [Math]::Min(58, 15 + [int](($iter / $maxIter) * 40) + [int]($elapsed / 60)) }
                'encode' {
                    # Tijdens full encode: schat op basis van verstreken tijd vs duration*2
                    # (libx264 medium ~0.5x realtime gemiddeld)
                    $enc = if ($foundCrf -gt 0) { $elapsed - 30 } else { $elapsed }
                    if ($enc -lt 0) { $enc = 0 }
                    $expected = $duration * 2
                    [Math]::Min(98, 60 + [int](($enc / $expected) * 38))
                }
                default  { 50 }
            }
            $statusMap = @{
                'init'='starting'; 'scene'='scene detect'; 'sample'='building sample';
                'search'="search iter $iter/~$maxIter"; 'encode'="full encode CRF $foundCrf"; 'done'='done'
            }
            if ($pct -ne $lastTick) {
                $lastTick = $pct
                Tick-Bar $pct ("$($statusMap[$phase])  ({0:N0}s)" -f $elapsed)
            }
            Start-Sleep -Milliseconds 500
        }
    }
    $proc.WaitForExit()
    Unregister-Event -SourceIdentifier $evtOut.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $evtErr.Name -ErrorAction SilentlyContinue
    $exit = $proc.ExitCode
    Write-Progress -Id 2 -Activity ("optimize " + $f.Name) -Completed
    $sw.Stop()

    # Hardlink opruimen
    if ([System.IO.File]::Exists($cleanSrc)) { Remove-Item -LiteralPath $cleanSrc -Force -ErrorAction SilentlyContinue }
    # Stale tempOut van vorige iter ook opruimen voor success-check correct werkt
    # (kan niet hier - tempOut bevat juist het resultaat van DEZE iter)

    # Bij FAIL: print de volledige log dump zodat we de error zien
    if ($exit -ne 0 -or -not [System.IO.File]::Exists($tempOut)) {
        Write-Host "  [debug] dynamic-crf exit=$exit, output exists=$([System.IO.File]::Exists($tempOut))" -ForegroundColor Yellow
        Write-Host "  [debug] laatste 30 regels van dynamic-crf output:" -ForegroundColor Yellow
        $logLines = $log.ToString().Split("`n")
        $start = [Math]::Max(0, $logLines.Count - 30)
        for ($i = $start; $i -lt $logLines.Count; $i++) {
            if ($logLines[$i].Trim()) { Write-Host "    $($logLines[$i])" -ForegroundColor DarkGray }
        }
    }

    if ($exit -eq 0 -and [System.IO.File]::Exists($tempOut)) {

        # --- Post-mux: behoud subs/extra audio uit origineel ---
        if ($Remux) {
            Write-Host "  remux: video uit encode + audio/subs/attachments uit origineel..." -ForegroundColor Cyan
            $muxArgs = @(
                '-hide_banner','-loglevel','error','-y',
                '-fflags','+genpts',                       # regenereer PTS voor consistente timestamps
                '-i', $tempOut,
                '-i', $f.FullName,
                '-map','0:v:0',
                '-map','1:a?',
                '-map','1:s?',
                '-map','1:t?',
                '-map_chapters','1',
                '-c','copy',
                '-avoid_negative_ts','make_zero',          # forceer audio + video start op 0
                '-max_interleave_delta','0',               # voorkom audio packet buffering issues
                '-fps_mode','passthrough',                 # behoud original fps
                $out
            )
            $muxOk = $false
            try {
                & $Ffmpeg @muxArgs
                $muxOk = ($LASTEXITCODE -eq 0 -and [System.IO.File]::Exists($out))
            } catch { $muxOk = $false }

            if ($muxOk) {
                Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
                Write-Host "  remux klaar." -ForegroundColor DarkGray

                # --- Verificatie: tel streams in output ---
                $probe = & $Ffprobe -v error -show_entries "stream=index,codec_type,codec_name:stream_tags=language" -of csv=p=0 -- "$out" 2>$null
                if ($probe) {
                    $vCount = 0; $aCount = 0; $sCount = 0; $tCount = 0
                    $aLangs = @(); $sLangs = @()
                    foreach ($line in $probe -split "`n") {
                        if ($line -match 'video')      { $vCount++ }
                        elseif ($line -match 'audio')    { $aCount++; if ($line -match 'audio,[^,]+,(\S+)') { $aLangs += $Matches[1] } }
                        elseif ($line -match 'subtitle') { $sCount++; if ($line -match 'subtitle,[^,]+,(\S+)') { $sLangs += $Matches[1] } }
                        elseif ($line -match 'attachment') { $tCount++ }
                    }
                    $audioInfo = if ($aLangs.Count -gt 0) { " [$($aLangs -join ',')]" } else { '' }
                    $subInfo   = if ($sLangs.Count -gt 0) { " [$($sLangs -join ',')]" } else { '' }
                    Write-Host "  verificatie output: video=$vCount  audio=$aCount$audioInfo  subs=$sCount$subInfo  attach=$tCount" -ForegroundColor DarkCyan
                    if ($aCount -eq 0) {
                        Write-Host "  [WARN] Output heeft GEEN audio! Iets ging mis tijdens remux." -ForegroundColor Red
                    }
                }
            } else {
                Write-Host "  [warn] remux mislukt, verplaats interim direct naar output" -ForegroundColor Yellow
                Move-Item -LiteralPath $tempOut -Destination $out -Force -ErrorAction SilentlyContinue
            }
        } else {
            # Geen remux: verplaats temp\out.mp4 naar definitief output pad
            Move-Item -LiteralPath $tempOut -Destination $out -Force -ErrorAction SilentlyContinue
        }

        $sizeIn  = [Math]::Round($f.Length / 1MB, 1)
        $sizeOut = [Math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
        $ratio   = if ($sizeIn -gt 0) { [Math]::Round(($sizeOut / $sizeIn) * 100, 0) } else { 0 }
        Write-Host ("  [OK] totaal {0:N0}s   {1} MB -> {2} MB ({3}%)   CRF $foundCrf" -f $sw.Elapsed.TotalSeconds, $sizeIn, $sizeOut, $ratio) -ForegroundColor Green
        $ok++
    } else {
        Write-Host "  [FAIL] exit $exit" -ForegroundColor Red
        if ([System.IO.File]::Exists($tempOut)) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }
        if ([System.IO.File]::Exists($out))     { Remove-Item -LiteralPath $out     -Force -ErrorAction SilentlyContinue }
        $fail++
    }
}

# --- Temp folder opruimen (NIET input/) ---
Write-Host ""
Write-Host "Temp folder opruimen..." -ForegroundColor DarkGray
if (Test-Path $LocalTemp) {
    Get-ChildItem -Path $LocalTemp -File -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch {}
    }
    # Verwijder ook subfolders die dynamic-crf maakt (dcrf-XXX)
    Get-ChildItem -Path $LocalTemp -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {}
    }
}
Write-Host "Temp leeg." -ForegroundColor DarkGray

Write-Host ("=" * 60)
Write-Host " Klaar.  OK: $ok   FAIL: $fail   SKIP: $skip   Totaal: $($files.Count)" -ForegroundColor Cyan
Write-Host " Output: $OutputDir"
Write-Host " Codec : $Codec"
Write-Host ("=" * 60)
