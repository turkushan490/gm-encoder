#requires -Version 5.1
<#
  Encoder.psm1
  Geherstructureerde encoding-engine, callable vanuit GUI of CLI.
  Hoofdfunctie: Invoke-FileEncode.
  Hergebruikt: hardlink-trick (CWD=temp + src.mkv),
  Job Object cleanup, post-mux met +genpts/make_zero, ffprobe verificatie.
#>

# Dot-source de Job Object cleanup helper als die nog niet geladen is.
if ($PSScriptRoot) {
    $script:ModuleRoot = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $script:ModuleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    # ps2exe-context: zoek gui\ map relatief aan exe locatie
    try {
        $exeDir = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $script:ModuleRoot = Join-Path $exeDir 'gui'
    } catch {
        $script:ModuleRoot = (Get-Location).Path
    }
}
$jobKill = Join-Path $script:ModuleRoot '_job-kill-on-close.ps1'
if (Test-Path -LiteralPath $jobKill) {
    . $jobKill
}

# =============================================================
# Pad-helpers
# =============================================================
function Get-AsaPaths {
    param([string]$BaseDir)
    if (-not $BaseDir) {
        # Module zit in gui\ → BaseDir is parent.
        $BaseDir = Split-Path -Parent $script:ModuleRoot
    }
    return @{
        Base    = $BaseDir
        Ffmpeg  = Join-Path $BaseDir 'bin\ffmpeg\bin\ffmpeg.exe'
        Ffprobe = Join-Path $BaseDir 'bin\ffmpeg\bin\ffprobe.exe'
        RunBat  = Join-Path $BaseDir 'run.bat'
        Dcrf    = Join-Path $BaseDir 'dynamic-crf.exe'
        Input   = Join-Path $BaseDir 'input'
        Output  = Join-Path $BaseDir 'output'
        Temp    = Join-Path $BaseDir 'temp'
    }
}

# =============================================================
# Codec helpers
# =============================================================
function Get-CodecList {
    @(
        @{ Id=1;  Display='NVIDIA NVENC H.264';  Codec='h264_nvenc';  Family='H.264' }
        @{ Id=2;  Display='AMD AMF H.264';        Codec='h264_amf';    Family='H.264' }
        @{ Id=3;  Display='Intel QSV H.264';      Codec='h264_qsv';    Family='H.264' }
        @{ Id=4;  Display='CPU libx264';          Codec='libx264';     Family='H.264' }
        @{ Id=5;  Display='NVIDIA NVENC HEVC';    Codec='hevc_nvenc';  Family='HEVC' }
        @{ Id=6;  Display='AMD AMF HEVC';         Codec='hevc_amf';    Family='HEVC' }
        @{ Id=7;  Display='Intel QSV HEVC';       Codec='hevc_qsv';    Family='HEVC' }
        @{ Id=8;  Display='CPU libx265';          Codec='libx265';     Family='HEVC' }
        @{ Id=9;  Display='NVIDIA NVENC AV1';     Codec='av1_nvenc';   Family='AV1' }
        @{ Id=10; Display='AMD AMF AV1';          Codec='av1_amf';     Family='AV1' }
        @{ Id=11; Display='Intel QSV AV1';        Codec='av1_qsv';     Family='AV1' }
        @{ Id=12; Display='CPU SVT-AV1';          Codec='libsvtav1';   Family='AV1' }
    )
}

function Test-EncoderAvailable {
    param([string]$Codec, [string]$FfmpegPath)
    # CPU codecs zijn altijd aanwezig
    if ($Codec -in @('libx264','libx265','libsvtav1','libvpx-vp9')) { return $true }
    try {
        $list = & $FfmpegPath -hide_banner -encoders 2>&1 | Out-String
        return ($list -match "\b$Codec\b")
    } catch {
        return $false
    }
}

function Get-AvailableEncoders {
    param([string]$FfmpegPath)
    $list = & $FfmpegPath -hide_banner -encoders 2>&1 | Out-String
    $result = @{}
    foreach ($e in (Get-CodecList).Codec) {
        if ($e -in @('libx264','libx265','libsvtav1','libvpx-vp9')) {
            $result[$e] = $true
        } else {
            $result[$e] = ($list -match "\b$e\b")
        }
    }
    return $result
}

# =============================================================
# Video info via ffprobe (gebruikt -LiteralPath via -- guard)
# =============================================================
function Get-VideoInfo {
    param([string]$File, [string]$FfprobePath)
    $info = @{
        Duration = 0.0; Width = 0; Height = 0; VideoCodec = ''
        SizeBytes = 0; BitrateMbps = 0.0
        AudioTracks = @(); SubTracks = @(); Attachments = 0
    }
    try {
        $j = & $FfprobePath -v error -show_format -show_streams -of json -- "$File" 2>$null | Out-String
        if (-not $j) { return $info }
        $obj = $j | ConvertFrom-Json
        $info.Duration = [double]$obj.format.duration
        $info.SizeBytes = [int64]$obj.format.size
        if ($obj.format.bit_rate) {
            $info.BitrateMbps = [Math]::Round([double]$obj.format.bit_rate / 1MB, 2)
        }
        $v = $obj.streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
        if ($v) {
            $info.Width  = [int]$v.width
            $info.Height = [int]$v.height
            $info.VideoCodec = "$($v.codec_name)"
        }
        $info.AudioTracks = @($obj.streams | Where-Object { $_.codec_type -eq 'audio' } | ForEach-Object {
            $lang = if ($_.tags -and $_.tags.language) { $_.tags.language } else { 'und' }
            @{ Codec = "$($_.codec_name)"; Lang = $lang }
        })
        $info.SubTracks = @($obj.streams | Where-Object { $_.codec_type -eq 'subtitle' } | ForEach-Object {
            $lang = if ($_.tags -and $_.tags.language) { $_.tags.language } else { 'und' }
            @{ Codec = "$($_.codec_name)"; Lang = $lang }
        })
        $info.Attachments = @($obj.streams | Where-Object { $_.codec_type -eq 'attachment' }).Count
    } catch {}
    return $info
}

# =============================================================
# Hardlink helper (val terug op copy bij failure of andere drive)
# =============================================================
function New-CleanHardlink {
    param([string]$Source, [string]$Target)
    if ([System.IO.File]::Exists($Target)) {
        Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue
    }
    & cmd /c mklink /H "`"$Target`"" "`"$Source`"" 2>&1 | Out-Null
    if (-not [System.IO.File]::Exists($Target)) {
        Copy-Item -LiteralPath $Source -Destination $Target -Force
    }
}

# =============================================================
# Time parsing helper
# =============================================================
function ConvertFrom-FfmpegTime {
    param([string]$Str)
    if ($Str -match '^(\d+):(\d+):([\d.]+)') {
        return [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [double]$Matches[3]
    }
    return 0.0
}

# =============================================================
# Async process runner met line callbacks
# =============================================================
function Invoke-StreamingProcess {
    param(
        [string]$FileName,
        [string]$Arguments,
        [string]$WorkingDirectory,
        [scriptblock]$OnLine,         # geroepen per regel (sync vanuit dispatcher thread caller)
        [int]$PollMs = 100
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $lines = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]@())
    $action = { if ($EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) } }
    $evt1 = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $action -MessageData $lines
    $evt2 = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action $action -MessageData $lines

    [void]$proc.Start()
    if (Get-Command Add-ToJob -ErrorAction SilentlyContinue) { Add-ToJob $proc }
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    while (-not $proc.HasExited -or $lines.Count -gt 0) {
        if ($lines.Count -gt 0) {
            $line = $lines[0]
            $lines.RemoveAt(0)
            if ($OnLine -and $line) {
                try { & $OnLine $line } catch {}
            }
        } else {
            Start-Sleep -Milliseconds $PollMs
        }
    }
    $proc.WaitForExit()
    Unregister-Event -SourceIdentifier $evt1.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $evt2.Name -ErrorAction SilentlyContinue
    return $proc.ExitCode
}

# =============================================================
# Hoofdfunctie: encode één file
# =============================================================
function Invoke-FileEncode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$InputFile,
        [Parameter(Mandatory=$true)][string]$OutputDir,
        [Parameter(Mandatory=$true)][string]$Codec,
        [bool]$Optimize = $true,
        [double]$TargetVmaf = 93,
        [double]$Tolerance = 1.5,
        [int]$MinCrf = 28,
        [int]$MaxCrf = 18,
        [int]$InitialCrf = 22,
        [int]$ManualCrf = 23,
        [int]$Height = 0,
        [bool]$Remux = $true,
        [string]$BaseDir = '',
        [scriptblock]$LineCallback,
        [scriptblock]$StatusCallback,        # ($phase, $progressPct, $note)
        [scriptblock]$ProgressCallback       # ($pct, $speedTxt, $etaSec)
    )

    $paths = Get-AsaPaths -BaseDir $BaseDir

    # Output paden
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $finalExt = if ($Remux) { 'mkv' } else { 'mp4' }
    $finalOut = Join-Path $OutputDir ("{0}_re.{1}" -f $baseName, $finalExt)

    $result = @{
        Success    = $false
        InputPath  = $InputFile
        OutputPath = $finalOut
        SizeIn     = 0
        SizeOut    = 0
        Ratio      = 0
        Codec      = $Codec
        FoundCrf   = 0
        FoundVmaf  = 0.0
        ElapsedSec = 0
        Error      = ''
    }

    function Emit-Line($txt) {
        if ($LineCallback) { try { & $LineCallback $txt } catch {} }
    }
    function Emit-Status($phase, $pct, $note) {
        if ($StatusCallback) { try { & $StatusCallback $phase $pct $note } catch {} }
    }
    function Emit-Progress($pct, $speed, $eta) {
        if ($ProgressCallback) { try { & $ProgressCallback $pct $speed $eta } catch {} }
    }

    if (-not (Test-Path -LiteralPath $InputFile)) {
        $result.Error = 'Input file niet gevonden'
        return $result
    }
    if (-not [System.IO.Directory]::Exists($OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    if (-not [System.IO.Directory]::Exists($paths.Temp)) {
        New-Item -ItemType Directory -Path $paths.Temp -Force | Out-Null
    }

    # Probe input
    Emit-Status 'Probing' 0 'reading metadata'
    $info = Get-VideoInfo -File $InputFile -FfprobePath $paths.Ffprobe
    $result.SizeIn = [Math]::Round($info.SizeBytes / 1MB, 1)
    $duration = if ($info.Duration -gt 0) { $info.Duration } else { 1.0 }
    Emit-Line "[INFO] bron: $($info.Width)x$($info.Height) $($info.VideoCodec) @ $([Math]::Round($duration))s, $($result.SizeIn) MB, $($info.BitrateMbps) Mbps"
    Emit-Line "[INFO] audio: $($info.AudioTracks.Count) track(s), subs: $($info.SubTracks.Count), attach: $($info.Attachments)"

    # Force locale-safe env (NL locale interpreteert ffprobe duration met komma anders)
    [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture

    # Redirect TEMP/TMP naar local temp folder
    $env:TEMP = $paths.Temp
    $env:TMP  = $paths.Temp

    # Hardlink naar clean pad
    $cleanSrc = Join-Path $paths.Temp 'src.mkv'
    $tempOut  = Join-Path $paths.Temp 'out.mp4'
    if ([System.IO.File]::Exists($tempOut)) { Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue }
    New-CleanHardlink -Source $InputFile -Target $cleanSrc
    Emit-Line "[INFO] hardlink: temp\src.mkv (CWD=temp truc)"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($Optimize) {
        # ------- Modus 1: dynamic-crf optimize (search + encode) -------
        Emit-Status 'Searching' 5 "dynamic-crf optimize ($Codec, VMAF $TargetVmaf)"
        $args = @(
            '-a','optimize',
            '-i','src.mkv',
            '-o','out.mp4',
            '-targetvmaf',"$TargetVmaf",
            '-tolerance',"$Tolerance",
            '-initialcrf',"$InitialCrf",
            '-mincrf',"$MinCrf",
            '-maxcrf',"$MaxCrf",
            '-codec',$Codec
        )
        if ($Height -gt 0) { $args += @('-h',"$Height") }
        $quoted = ($args | ForEach-Object { "`"$_`"" }) -join ' '
        $cmdArgs = "/c `"`"$($paths.RunBat)`" $quoted 2>&1`""

        # State hashtable voor closure-capture
        $state = @{
            Phase        = 'init'
            Iter         = 0
            MaxIter      = 6
            Duration     = $duration
            FoundCrf     = 0
            FoundVmaf    = 0.0
            LastCrf      = 0       # laatste crf gezien in log (iter of result)
            LastVmaf     = 0.0
            OverallBase  = 0
            OverallSpan  = 2
            EncodingMode = $false
        }
        # Capture callbacks + state in closure
        $onLineSb = {
            param($line)
            & $LineCallback $line

            # --- PHASE TRANSITIONS (zetten OverallBase + Span, advancen overall bar) ---

            # Universele crf=N vmaf=M capture (uit ALLE INFO regels: iter, search complete, found vmaf at min/max)
            # Track de laatste waarden zodat we ze hebben bij final encode start
            if ($line -match 'crf=(\d+)') { $state.LastCrf = [int]$Matches[1] }
            if ($line -match 'vmaf=([\d.]+)') { $state.LastVmaf = [double]$Matches[1] }

            # Final encode detect: "ffmpeg encode" args bevat "-i src.mkv" en output "out.mp4"
            if ($line -match 'ffmpeg encode.*-i\s+src\.mkv') {
                if (-not $state.EncodingMode) {
                    $state.EncodingMode = $true
                    $state.Phase = 'encoding'
                    $state.OverallBase = 55
                    $state.OverallSpan = 40
                    # Vergrendel CRF/VMAF op dit moment - de laatst geziene waarden zijn de gekozen
                    if ($state.LastCrf -gt 0) { $state.FoundCrf = $state.LastCrf }
                    if ($state.LastVmaf -gt 0) { $state.FoundVmaf = $state.LastVmaf }
                    & $ProgressCallback 55 '' 0
                    & $StatusCallback 'Encoding' 0 "final encode CRF=$($state.FoundCrf)"
                }
                return
            }
            # Expliciete "Found crf:" formaat
            if ($line -match 'Found crf:\s*(\d+)') {
                $state.FoundCrf = [int]$Matches[1]
                if ($line -match 'vmaf:\s*([\d.]+)') {
                    $state.FoundVmaf = [double]$Matches[1]
                }
                return
            }
            # "found vmaf at min/max crf" slog format
            if ($line -match 'found vmaf at (min|max) crf') {
                if ($state.LastCrf -gt 0) { $state.FoundCrf = $state.LastCrf }
                if ($state.LastVmaf -gt 0) { $state.FoundVmaf = $state.LastVmaf }
                return
            }
            # Search iter result (bracketed format: "[ 75.7s] iter 1 : CRF 18 -> VMAF 67.23")
            if (-not $state.EncodingMode -and ($line -match 'iter \d+ : CRF (\d+) -> VMAF ([\d.]+)' -or $line -match '\[\s*[\d.]+s\] iter \d+ : CRF (\d+) -> VMAF ([\d.]+)')) {
                $state.Iter++
                $state.Phase = 'search'
                $state.LastCrf = [int]$Matches[1]
                $state.LastVmaf = [double]$Matches[2]
                $itrBase = 25 + [Math]::Min(28, $state.Iter * 6)
                $state.OverallBase = $itrBase
                $state.OverallSpan = 6
                & $ProgressCallback $itrBase '' 0
                $stepPct = [Math]::Min(100, [int](100 * $state.Iter / $state.MaxIter))
                & $StatusCallback 'Searching' $stepPct "iter $($state.Iter): CRF $($Matches[1]) -> VMAF $($Matches[2])"
                return
            }
            # Sample build phase
            if ($line -match 'running ffmpeg sampler|extracting scene|created uniform samples') {
                if ($state.Phase -ne 'sample' -and -not $state.EncodingMode) {
                    $state.Phase = 'sample'
                    $state.OverallBase = 12
                    $state.OverallSpan = 13
                    & $ProgressCallback 12 '' 0
                    & $StatusCallback 'Sampling' 0 'building sample (15 scenes)'
                }
            }
            # Scene detection phase
            if ($line -match 'running ffprobe scene detection') {
                if ($state.Phase -ne 'scene' -and -not $state.EncodingMode) {
                    $state.Phase = 'scene'
                    $state.OverallBase = 2
                    $state.OverallSpan = 10
                    & $ProgressCallback 2 '' 0
                    & $StatusCallback 'SceneDetect' 0 'scene detection'
                }
            }
            # VMAF measurement na final encode
            if ($line -match 'running ffmpeg vmaf.*distorted=out\.mp4.*reference=src\.mkv') {
                $state.Phase = 'vmaf'
                $state.OverallBase = 95
                $state.OverallSpan = 4
                & $ProgressCallback 95 '' 0
                & $StatusCallback 'Verifying' 50 'measuring VMAF of output'
                return
            }

            # --- FFMPEG PROGRESS (out_time_us) ---
            # Scale lokaal pct (0-100% van current ffmpeg encode) naar overall bar bereik
            if ($line -match '^out_time_us=(\d+)') {
                $sec = [int64]$Matches[1] / 1000000.0
                if ($state.Duration -gt 0 -and $state.EncodingMode) {
                    $encPct = [Math]::Min(100, [int]($sec / $state.Duration * 100))
                    $overall = [Math]::Min(94, $state.OverallBase + [int]($state.OverallSpan * $encPct / 100))
                    & $ProgressCallback $overall '' 0
                    & $StatusCallback 'Encoding' $encPct "encoding: $sec`s / $($state.Duration)s"
                }
                # Tijdens test-encodes (search) negeren we ffmpeg out_time
                # om de overall bar monotoon te houden
            }
        }.GetNewClosure()

        $exit = Invoke-StreamingProcess `
            -FileName 'cmd.exe' `
            -Arguments $cmdArgs `
            -WorkingDirectory $paths.Temp `
            -OnLine $onLineSb
        $stopwatch.Stop()

        # Pull state back naar result, fallback naar LastCrf/LastVmaf
        $result.FoundCrf  = if ($state.FoundCrf -gt 0) { $state.FoundCrf } else { $state.LastCrf }
        $result.FoundVmaf = if ($state.FoundVmaf -gt 0) { $state.FoundVmaf } else { $state.LastVmaf }

        if ($exit -ne 0 -or -not [System.IO.File]::Exists($tempOut)) {
            $result.Error = "dynamic-crf exit=$exit"
            Emit-Line "[ERR] $($result.Error)"
            if ([System.IO.File]::Exists($cleanSrc)) { Remove-Item -LiteralPath $cleanSrc -Force -ErrorAction SilentlyContinue }
            return $result
        }
    }
    else {
        # ------- Modus 2: plain ffmpeg encode (manueel CRF/QP) -------
        Emit-Status 'Encoding' 5 "plain encode ($Codec, q=$ManualCrf)"
        $crfVal = $ManualCrf
        $vfArgs = @()
        if ($Height -gt 0) { $vfArgs = @('-vf', "scale=-2:$Height") }
        # Codec-specifieke rate-control mapping (mirror van install-dynamic-crf patch)
        $codecArgs = switch -Regex ($Codec) {
            'av1_amf'   { @('-c:v','av1_amf','-rc','qvbr','-qvbr_quality_level',"$crfVal") ; break }
            'h264_amf|hevc_amf' { @('-c:v',$Codec,'-rc','cqp','-qp_i',"$($crfVal-1)",'-qp_p',"$($crfVal+1)",'-qp_b',"$($crfVal+3)") ; break }
            'av1_nvenc' { @('-c:v','av1_nvenc','-preset','p6','-rc','vbr','-cq',"$crfVal",'-b:v','0','-multipass','fullres') ; break }
            'hevc_nvenc|h264_nvenc' { @('-c:v',$Codec,'-preset','p6','-tune','hq','-rc','vbr','-cq',"$crfVal",'-b:v','0','-multipass','fullres','-spatial_aq','1') ; break }
            'av1_qsv' { @('-c:v','av1_qsv','-global_quality',"$($crfVal*5)") ; break }
            'h264_qsv|hevc_qsv' { @('-c:v',$Codec,'-global_quality',"$crfVal") ; break }
            'libsvtav1' { @('-c:v','libsvtav1','-preset','6','-crf',"$crfVal") ; break }
            default { @('-c:v',$Codec,'-crf',"$crfVal") }
        }

        $ffArgs = @(
            '-hide_banner','-loglevel','error','-nostats',
            '-progress','pipe:1',
            '-y',
            '-i','src.mkv',
            '-map','0:v:0','-map','0:a?','-map','0:s?','-map','0:t?',
            '-map_metadata','0','-map_chapters','0',
            '-pix_fmt','yuv420p10le'
        ) + $vfArgs + $codecArgs + @(
            '-c:a','copy','-c:s','copy',
            'out.mp4'
        )

        $ffQuoted = ($ffArgs | ForEach-Object {
            if ($_ -match '\s') { "`"$_`"" } else { $_ }
        }) -join ' '

        $plainState = @{ Duration = $duration }
        $plainOnLine = {
            param($line)
            if ($line -match '^out_time_us=(\d+)') {
                $sec = [int64]$Matches[1] / 1000000.0
                if ($plainState.Duration -gt 0) {
                    $pct = [Math]::Min(99, [int]($sec / $plainState.Duration * 100))
                    & $ProgressCallback $pct '?' 0
                }
            } elseif ($line -match '^speed=\s*([\d.]+x|N/A)') {
                # tracked separately
            } elseif ($line -match '^(frame|fps|bitrate|total_size|out_time|out_time_ms|dup_frames|drop_frames|progress|stream_\d+_\d+_q)=') {
                # silently slik
            } else {
                & $LineCallback $line
            }
        }.GetNewClosure()

        $exit = Invoke-StreamingProcess `
            -FileName $paths.Ffmpeg `
            -Arguments $ffQuoted `
            -WorkingDirectory $paths.Temp `
            -OnLine $plainOnLine
        $stopwatch.Stop()

        if ($exit -ne 0 -or -not [System.IO.File]::Exists($tempOut)) {
            $result.Error = "ffmpeg exit=$exit"
            Emit-Line "[ERR] $($result.Error)"
            if ([System.IO.File]::Exists($cleanSrc)) { Remove-Item -LiteralPath $cleanSrc -Force -ErrorAction SilentlyContinue }
            return $result
        }
        $result.FoundCrf = $ManualCrf
    }

    # Cleanup: alle dynamic-crf intermediates uit temp folder
    # (sample_*.mp4, tst_encode*.mp4, smpl_*.ts, src.mkv, out.mp4, etc)
    try {
        Get-ChildItem -Path $paths.Temp -File -ErrorAction SilentlyContinue | ForEach-Object {
            # Behoud out.mp4 als die nog gemoxt moet worden
            if ($_.Name -ne 'out.mp4') {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -Path $paths.Temp -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    # ------- Post-mux: video uit tempOut + audio/subs uit origineel -------
    if ($Remux) {
        Emit-Status 'Muxing' 95 'remux: audio/subs/attachments uit origineel'
        $muxArgs = @(
            '-hide_banner','-loglevel','error','-y',
            '-fflags','+genpts',
            '-i', $tempOut,
            '-i', $InputFile,
            '-map','0:v:0',
            '-map','1:a?','-map','1:s?','-map','1:t?',
            '-map_chapters','1',
            '-c','copy',
            '-avoid_negative_ts','make_zero',
            '-max_interleave_delta','0',
            '-fps_mode','passthrough',
            $finalOut
        )
        try {
            & $paths.Ffmpeg @muxArgs 2>&1 | ForEach-Object {
                if ($_ -and $_ -notmatch '^(frame|out_time|bitrate|speed|progress|stream)') {
                    Emit-Line $_
                }
            }
            if ($LASTEXITCODE -eq 0 -and [System.IO.File]::Exists($finalOut)) {
                Remove-Item -LiteralPath $tempOut -Force -ErrorAction SilentlyContinue
            } else {
                Emit-Line "[WARN] remux mislukt, verplaats interim als output"
                Move-Item -LiteralPath $tempOut -Destination $finalOut -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Emit-Line "[WARN] remux exception: $($_.Exception.Message)"
            Move-Item -LiteralPath $tempOut -Destination $finalOut -Force -ErrorAction SilentlyContinue
        }
    } else {
        Move-Item -LiteralPath $tempOut -Destination $finalOut -Force -ErrorAction SilentlyContinue
    }

    if (-not [System.IO.File]::Exists($finalOut)) {
        $result.Error = 'Output bestand niet aangemaakt'
        return $result
    }

    $result.SizeOut = [Math]::Round((Get-Item -LiteralPath $finalOut).Length / 1MB, 1)
    if ($result.SizeIn -gt 0) {
        $result.Ratio = [Math]::Round($result.SizeOut / $result.SizeIn * 100, 0)
    }
    $result.ElapsedSec = [int]$stopwatch.Elapsed.TotalSeconds
    $result.Success = $true
    Emit-Status 'Completed' 100 "$($result.SizeIn)MB -> $($result.SizeOut)MB ($($result.Ratio)%) in $($result.ElapsedSec)s"
    Emit-Line "[OK] $($result.SizeIn) MB -> $($result.SizeOut) MB ($($result.Ratio)%) - $($result.ElapsedSec)s"

    # Volledige temp folder cleanup aan het einde - ook subfolders
    try {
        Get-ChildItem -Path $paths.Temp -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    return $result
}

# =============================================================
# Bestanden in input folder verzamelen
# =============================================================
function Get-InputFiles {
    param([string]$InputDir)
    $exts = @('*.mp4','*.mkv','*.mov','*.avi','*.m4v','*.webm','*.ts')
    $files = @()
    foreach ($e in $exts) {
        $files += Get-ChildItem -Path $InputDir -Filter $e -File -ErrorAction SilentlyContinue
    }
    return $files | Sort-Object FullName -Unique
}

# =============================================================
# Source disposal na succes
# =============================================================
function Remove-InputSource {
    param(
        [string]$InputFile,
        [bool]$Permanent = $false
    )
    if (-not [System.IO.File]::Exists($InputFile)) { return }
    $dir = Split-Path -Parent $InputFile
    if ($Permanent) {
        Remove-Item -LiteralPath $InputFile -Force -ErrorAction SilentlyContinue
    } else {
        $doneDir = Join-Path $dir 'done'
        if (-not [System.IO.Directory]::Exists($doneDir)) {
            New-Item -ItemType Directory -Path $doneDir -Force | Out-Null
        }
        $dst = Join-Path $doneDir ([System.IO.Path]::GetFileName($InputFile))
        Move-Item -LiteralPath $InputFile -Destination $dst -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Get-AsaPaths, Get-CodecList, Test-EncoderAvailable, Get-AvailableEncoders, `
    Get-VideoInfo, Invoke-FileEncode, Get-InputFiles, Remove-InputSource
