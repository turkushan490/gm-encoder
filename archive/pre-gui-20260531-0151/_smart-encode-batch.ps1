param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('nvenc','amf')]
    [string]$Encoder,

    [int]$Height = 0,        # 0 = origineel resolutie
    [double]$TargetVmaf = 93,
    [int]$FallbackQuality = 23,
    [string]$InputDir,
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$Base    = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Base '_job-kill-on-close.ps1')
if (-not $InputDir)  { $InputDir  = Join-Path $Base 'input' }
if (-not $OutputDir) { $OutputDir = Join-Path $Base 'output' }
$Ffmpeg  = Join-Path $Base 'bin\ffmpeg\bin\ffmpeg.exe'
$Ffprobe = Join-Path $Base 'bin\ffmpeg\bin\ffprobe.exe'
$RunBat  = Join-Path $Base 'run.bat'
$Dcrf    = Join-Path $Base 'dynamic-crf.exe'

# --- Sanity checks ---
foreach ($p in @($Ffmpeg, $Ffprobe, $RunBat, $Dcrf)) {
    if (-not (Test-Path $p)) {
        Write-Host "[!!] Niet gevonden: $p" -ForegroundColor Red
        Write-Host "     Run eerst install-dynamic-crf (4).bat" -ForegroundColor Red
        exit 1
    }
}
if (-not (Test-Path $InputDir))  { New-Item -ItemType Directory -Path $InputDir  -Force | Out-Null }
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

$LocalTemp = Join-Path $Base 'temp'
if (-not (Test-Path $LocalTemp)) { New-Item -ItemType Directory -Path $LocalTemp -Force | Out-Null }
$env:TEMP = $LocalTemp
$env:TMP  = $LocalTemp

# --- Encoder check ---
$encList = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
$encName = if ($Encoder -eq 'nvenc') { 'hevc_nvenc' } else { 'hevc_amf' }
if ($encList -notmatch "\b$encName\b") {
    Write-Host "[!!] $encName niet beschikbaar in deze ffmpeg build." -ForegroundColor Red
    Write-Host "     Driver/GPU aanwezig? Voor NVENC heb je een NVIDIA GPU + driver nodig; voor AMF een AMD GPU + driver." -ForegroundColor Red
    exit 2
}

# --- Verzamel input bestanden ---
$exts = @('*.mp4','*.mkv','*.mov','*.avi','*.m4v','*.webm','*.ts')
$files = @()
foreach ($e in $exts) { $files += Get-ChildItem -Path $InputDir -Filter $e -File -ErrorAction SilentlyContinue }
$files = $files | Sort-Object FullName -Unique

$label = if ($Encoder -eq 'nvenc') { 'NVIDIA NVENC HEVC' } else { 'AMD AMF HEVC' }

Write-Host ""
$resTxt = if ($Height -gt 0) { "${Height}p" } else { "origineel" }
Write-Host "=== Smart batch encode -> $resTxt ===" -ForegroundColor Cyan
Write-Host " Encoder      : $label"
Write-Host " Strategie    : CPU search (VMAF $TargetVmaf) -> GPU encode"
Write-Host " Input        : $InputDir"
Write-Host " Output       : $OutputDir"
Write-Host " Aantal       : $($files.Count) bestand(en)"
Write-Host " Fallback CRF : $FallbackQuality (als search faalt)"
Write-Host ""

if ($files.Count -eq 0) {
    Write-Host "[!!] Geen video's gevonden in $InputDir" -ForegroundColor Yellow
    exit 0
}

# --- Helpers ---
function Get-Duration($file) {
    $out = & $Ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>$null
    if ($out -match '^\s*([\d.]+)') { return [double]$Matches[1] }
    return 0
}
function Parse-Time($s) {
    if ($s -match '^(\d+):(\d+):([\d.]+)') {
        return [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [double]$Matches[3]
    }
    return 0
}

$script:DurCache = @{}
function Show-VideoInfoDur($file) {
    if ($script:DurCache.ContainsKey($file)) { return $script:DurCache[$file] }
    $out = & $Ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 -- "$file" 2>$null
    $d = 0
    if ($out -match '^\s*([\d.]+)') { $d = [double]$Matches[1] }
    $script:DurCache[$file] = $d
    return $d
}

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

    Write-Host ("        bron : {0}x{1} {2} @ {3:N0}s, {4} MB, {5} Mbps" -f $v.width, $v.height, $v.codec_name, $dur, $sizeMB, $bitMbps) -ForegroundColor DarkCyan
    if ($a.Count -gt 0) {
        $langs = ($a | ForEach-Object { $l = $_.tags.language; if (-not $l) { 'und' } else { $l } }) -join ','
        Write-Host ("        audio: $($a.Count) track(s) [$langs]") -ForegroundColor DarkCyan
    }
    if ($s.Count -gt 0) {
        $langs = ($s | ForEach-Object { $l = $_.tags.language; if (-not $l) { 'und' } else { $l } }) -join ','
        Write-Host ("        subs : $($s.Count) track(s) [$langs]") -ForegroundColor DarkCyan
    }
    if ($t.Count -gt 0) {
        Write-Host ("        attach: $($t.Count) (fonts/covers)") -ForegroundColor DarkCyan
    }
}

function Find-OptimalCrf($origFile) {
    # Hardlink naar clean pad om filter-issues met spaties/brackets te omzeilen
    $file = Join-Path $LocalTemp "src_search.mkv"
    if ([System.IO.File]::Exists($file)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    & cmd /c mklink /H "`"$file`"" "`"$origFile`"" 2>&1 | Out-Null
    if (-not [System.IO.File]::Exists($file)) {
        Copy-Item -LiteralPath $origFile -Destination $file -Force
    }
    # Run dynamic-crf search met libx265 codec -> CRF schaalt goed naar HEVC GPU cq/qp.
    Write-Host "  [1/2] CPU search (VMAF $TargetVmaf op samples uit de video)" -ForegroundColor Cyan
    Write-Host "        > video >60s: 15 scenes worden geknipt en samengevoegd tot 1 sample.mp4 in temp" -ForegroundColor DarkGray
    Write-Host "        > bisection loop: 3-5 test-encodes van die sample bepalen de beste CRF" -ForegroundColor DarkGray
    Write-Host ""

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $heightArg = if ($Height -gt 0) { "-h $Height" } else { "" }
    # Snelle bisection: tolerance 1.5 + smalle range CRF 18..28 + start 22
    $psi.Arguments = "/c `"`"$RunBat`" -a search -i `"$file`" $heightArg -codec libx265 -targetvmaf $TargetVmaf -tolerance 1.5 -initialcrf 22 -mincrf 28 -maxcrf 18 2>&1`""
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    # Async output buffer - voorkomt dat ReadLine() blokkeert tijdens stille fases
    $lines = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]@())
    $outAction = { if ($EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) } }
    $evtOut = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $outAction -MessageData $lines
    $evtErr = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $outAction -MessageData $lines

    [void]$proc.Start()
    Add-ToJob $proc
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    $crf = 0; $vmaf = 0; $iter = 0
    $fullLog = New-Object System.Text.StringBuilder
    $phase = 'init'          # init -> scene -> sample -> bounds -> search -> done
    $maxIter = 6
    $lastTickPct = -1

    function Update-SearchProgress($pct, $status) {
        $pct = [Math]::Min(98, [Math]::Max(0, [int]$pct))
        Write-Progress -Id 1 -Activity ("[$idx/$($files.Count)] CPU search " + $f.Name) `
                       -Status $status -PercentComplete $pct
    }

    Update-SearchProgress 1 "starting..."

    while (-not $proc.HasExited -or $lines.Count -gt 0) {
        $line = $null
        if ($lines.Count -gt 0) {
            $line = $lines[0]
            $lines.RemoveAt(0)
        }
        if ($line) {
            [void]$fullLog.AppendLine($line)

            if ($line -match 'Found crf:\s*(\d+)') {
                $crf = [int]$Matches[1]
                if ($line -match 'vmaf:\s*([\d.]+)') { $vmaf = [double]$Matches[1] }
                Write-Host ("        => FOUND  CRF $crf  (VMAF {0:N2})" -f $vmaf) -ForegroundColor Green
                $phase = 'done'
                Update-SearchProgress 100 "FOUND CRF $crf"
            }
            elseif ($line -match 'crf=(\d+).*vmaf=([\d.]+)' -or $line -match 'crf:\s*(\d+).*vmaf:\s*([\d.]+)') {
                $iter++
                $phase = 'search'
                $ts = "{0,5:N1}s" -f $sw.Elapsed.TotalSeconds
                Write-Host ("        [$ts] iter $iter : CRF $($Matches[1])  ->  VMAF $($Matches[2])") -ForegroundColor Yellow
                $pct = 30 + [int](($iter / $maxIter) * 65)
                Update-SearchProgress $pct ("iter $iter/~$maxIter  CRF $($Matches[1]) VMAF $($Matches[2])  ({0:N0}s)" -f $sw.Elapsed.TotalSeconds)
            }
            elseif ($line -match 'detect|scene|select') {
                if ($phase -ne 'scene') {
                    Write-Host "        . scene detect (decodeert hele video, kan minuten duren)" -ForegroundColor DarkGray
                    $phase = 'scene'
                }
                Update-SearchProgress 5 ("scene detection (hele video decoderen)  ({0:N0}s)" -f $sw.Elapsed.TotalSeconds)
            }
            elseif ($line -match 'sample|extract|concat') {
                if ($phase -ne 'sample') {
                    Write-Host "        . sample build (15 scenes -> 1 sample.mp4)" -ForegroundColor DarkGray
                    $phase = 'sample'
                }
                Update-SearchProgress 15 ("building sample.mp4 (15 scenes)  ({0:N0}s)" -f $sw.Elapsed.TotalSeconds)
            }
            elseif ($line -match 'frame=\s*\d+.*time=(\d+):(\d+):([\d.]+)') {
                # ffmpeg progress (komt door als run.bat het doorzet)
                $t = [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [double]$Matches[3]
                if ($phase -eq 'scene' -or $phase -eq 'sample') {
                    $sourceDur = (Show-VideoInfoDur $f.FullName)
                    if ($sourceDur -gt 0) {
                        $progressFrac = [Math]::Min(1.0, $t / $sourceDur)
                        $pct = if ($phase -eq 'scene') { 5 + [int]($progressFrac * 15) } else { 18 + [int]($progressFrac * 7) }
                        Update-SearchProgress $pct ("$phase  ffmpeg time={0:N0}s/{1:N0}s  ({2:N0}s elapsed)" -f $t, $sourceDur, $sw.Elapsed.TotalSeconds)
                    }
                }
            }
            elseif ($line -match 'bound|min.*crf|max.*crf') {
                if ($phase -ne 'bounds') {
                    $phase = 'bounds'
                }
                Update-SearchProgress 25 ("scoring CRF bounds  ({0:N0}s)" -f $sw.Elapsed.TotalSeconds)
            }
            elseif ($line -match 'error|fail|panic' -and $line -notmatch 'tolerance') {
                Write-Host "        ! $line" -ForegroundColor Red
            }
        }
        else {
            # Geen nieuwe regel: heartbeat zodat de elapsed counter blijft tikken
            $elapsed = $sw.Elapsed.TotalSeconds
            $tickPct = switch ($phase) {
                'init'   { [Math]::Min(4,  [int]($elapsed / 2)) }
                'scene'  { [Math]::Min(20, 5  + [int]($elapsed / 6)) }
                'sample' { [Math]::Min(24, 18 + [int]($elapsed / 10)) }
                'bounds' { [Math]::Min(29, 25 + [int]($elapsed / 10)) }
                'search' { [Math]::Min(95, 30 + [int](($iter / $maxIter) * 60) + [int]($elapsed / 60)) }
                default  { 50 }
            }
            if ($tickPct -ne $lastTickPct -or ($elapsed -gt 0 -and ([int]$elapsed) % 2 -eq 0)) {
                $lastTickPct = $tickPct
                $statusMap = @{ 'init'='starting'; 'scene'='scene detection (hele video decoderen)';
                                'sample'='building sample.mp4'; 'bounds'='scoring CRF bounds';
                                'search'="iter $iter/~$maxIter"; 'done'='done' }
                Update-SearchProgress $tickPct ("$($statusMap[$phase])  ({0:N0}s)" -f $elapsed)
            }
            Start-Sleep -Milliseconds 500
        }
    }
    $proc.WaitForExit()
    Unregister-Event -SourceIdentifier $evtOut.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $evtErr.Name -ErrorAction SilentlyContinue
    $sw.Stop()
    Write-Progress -Id 1 -Activity ("CPU search " + $f.Name) -Completed

    Write-Host ""
    Write-Host ("        search klaar in {0:N1}s, $iter iteratie(s) zichtbaar" -f $sw.Elapsed.TotalSeconds)

    # Fallback parse: zoek nogmaals in volledige output voor "Found crf"
    if ($crf -eq 0) {
        $all = $fullLog.ToString()
        if ($all -match 'Found crf:\s*(\d+)') {
            $crf = [int]$Matches[1]
            if ($all -match 'vmaf:\s*([\d.]+)') { $vmaf = [double]$Matches[1] }
            Write-Host ("        => FOUND  CRF $crf  (VMAF {0:N2})" -f $vmaf) -ForegroundColor Green
        }
    }

    # Hardlink opruimen
    if ([System.IO.File]::Exists($file)) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }

    if ($crf -gt 0) {
        $orig = $crf
        if ($crf -lt 16) { $crf = 16 }
        if ($crf -gt 32) { $crf = 32 }
        if ($crf -ne $orig) {
            Write-Host "        (clamp: $orig -> $crf, GPU sweet spot)" -ForegroundColor DarkGray
        }
        return $crf
    }
    Write-Host "        -> search faalde, gebruik fallback CRF $FallbackQuality" -ForegroundColor Yellow
    Write-Host "        full log dump:" -ForegroundColor DarkGray
    $fullLog.ToString().Split("`n") | ForEach-Object { Write-Host "          $_" -ForegroundColor DarkGray }
    return $FallbackQuality
}

function Get-CodecArgs($quality) {
    if ($Encoder -eq 'nvenc') {
        return @(
            '-c:v','hevc_nvenc',
            '-preset','p6',
            '-tune','hq',
            '-rc','vbr',
            '-cq', "$quality",
            '-b:v','0',
            '-multipass','fullres',
            '-spatial_aq','1'
        )
    } else {
        $qpI = [Math]::Max(0, $quality - 1)
        $qpP = $quality + 1
        $qpB = $quality + 3
        return @(
            '-c:v','hevc_amf',
            '-quality','quality',
            '-usage','transcoding',
            '-rc','cqp',
            '-qp_i', "$qpI",
            '-qp_p', "$qpP",
            '-qp_b', "$qpB"
        )
    }
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

    # --- Bron info ---
    Show-VideoInfo $f.FullName
    Write-Host ""

    # --- Stap 1: CPU search ---
    $crf = Find-OptimalCrf $f.FullName

    # --- Stap 2: GPU encode ---
    Write-Host "  [2/2] GPU encode met $label (q=$crf)..." -ForegroundColor Cyan

    $duration = Get-Duration $f.FullName
    if ($duration -le 0) { $duration = 1 }

    $codecArgs = Get-CodecArgs $crf
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

    try {
        & $Ffmpeg @ffArgs 2>&1 | ForEach-Object {
            $line = $_
            if ($line -match '^out_time=([\d:.]+)') {
                $sec = Parse-Time $Matches[1]
                $pct = [Math]::Min(100, [int](($sec / $duration) * 100))
                if ($pct -ne $lastPct) {
                    $lastPct = $pct
                    $elapsed = $sw.Elapsed.TotalSeconds
                    $eta = if ($pct -gt 0) { [int](($elapsed / $pct) * (100 - $pct)) } else { 0 }
                    Write-Progress -Activity ("[$idx/$($files.Count)] " + $f.Name) `
                                   -Status ("$pct%  (encode {0:N0}s, ETA {1:N0}s, q=$crf)  $status" -f $elapsed, $eta) `
                                   -PercentComplete $pct
                }
            }
            elseif ($line -match '^speed=(.+)$') { $status = "speed=$($Matches[1].Trim())" }
            elseif ($line -match '^(frame|fps|bitrate|total_size|out_time|out_time_us|out_time_ms|dup_frames|drop_frames|progress|stream_\d+_\d+_q)=') { }
            else {
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

    if ($exit -eq 0 -and ([System.IO.File]::Exists($out))) {
        $sizeIn  = [Math]::Round($f.Length / 1MB, 1)
        $sizeOut = [Math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)
        $ratio   = if ($sizeIn -gt 0) { [Math]::Round(($sizeOut / $sizeIn) * 100, 0) } else { 0 }
        Write-Host ("  [OK] encode {0:N0}s   {1} MB -> {2} MB ({3}%)   q=$crf" -f $sw.Elapsed.TotalSeconds, $sizeIn, $sizeOut, $ratio) -ForegroundColor Green
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
