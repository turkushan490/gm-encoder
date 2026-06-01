#requires -Version 5.1
<#
  generate-handover.ps1
  Bouwt PROJECT-HANDOVER.md met alle source + project context.
  -Compact: strip comments/blank lines/XAML voor minder tokens.
#>
param([switch]$Compact)

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Out  = if ($Compact) { Join-Path $Root 'PROJECT-HANDOVER-COMPACT.md' } else { Join-Path $Root 'PROJECT-HANDOVER.md' }

# Compactor: strip PowerShell comments + blank lines + XAML here-string
function Compact-Source {
    param([string]$Content, [string]$Lang)
    if ($Lang -eq 'powershell') {
        # Strip block comments <# ... #>
        $Content = [regex]::Replace($Content, '(?s)<#.*?#>', '')
        # Replace XAML here-string ($xaml = @' ... '@) with placeholder
        $Content = [regex]::Replace($Content, "(?s)(\`$xaml\s*=\s*@')(.*?)('@)",
            '$xaml = @''<!-- XAML stripped for brevity, ~400 lines: Window with 4-row Grid (Setup panel / 3-col main / progress bars / console). See header for layout. -->''@')
        # Strip line comments (# at start or after whitespace, not in strings)
        $Content = [regex]::Replace($Content, '(?m)^\s*#.*$', '')
        # Strip trailing line comments (heuristic - keep simple)
        $Content = [regex]::Replace($Content, '(?m)(\s+)#[^"''`]*$', '')
    } elseif ($Lang -eq 'batch') {
        # Strip REM/:: lines and empty lines
        $Content = [regex]::Replace($Content, '(?m)^\s*REM\b.*$', '')
        $Content = [regex]::Replace($Content, '(?m)^\s*::.*$', '')
    }
    # Collapse 3+ blank lines -> 1
    $Content = [regex]::Replace($Content, '(\r?\n){3,}', "`n`n")
    return $Content.Trim()
}

$header = @'
# GM Encoder — Project Handover

## What this is

A Windows GUI app (PowerShell + WPF, compiled to single .exe via ps2exe) that wraps
the [terranvigil/dynamic-crf](https://github.com/terranvigil/dynamic-crf) tool plus
ffmpeg to do VMAF-targeted video encoding. Lets the user pick a codec (12 options
across H.264/HEVC/AV1 × CPU/NVIDIA/AMD/Intel), optimize via VMAF search or use
manual CRF, watch live progress, and preserves all audio tracks/subtitles/fonts
via a post-mux step.

## Repo layout

```
C:\ai code\asa\
├── gm-encoder.ps1                 # Main GUI (WPF inline XAML + event wiring)
├── gm-encoder.exe                 # Built artifact (ps2exe of bundled .ps1)
├── build-exe.ps1               # Bundler: concatenates gui\*.ps* + install bat into one .ps1, ps2exe to .exe
├── install-dynamic-crf.bat     # Installer: downloads Go/ffmpeg/mediainfo, patches dynamic-crf source, builds dynamic-crf.exe
├── run.bat                     # Sets PATH + invokes dynamic-crf.exe (legacy, used by some flows)
├── reinstall-dynamic-crf.bat   # Convenience: deletes dynamic-crf.exe + runs installer
├── dynamic-crf.exe             # Built Go binary
├── bin\                        # ffmpeg, ffprobe, mediainfo, git, go (installed by install bat)
├── gui\
│   ├── Encoder.psm1            # Encoding engine module (called from GUI or CLI)
│   └── _job-kill-on-close.ps1  # Win32 Job Object so child ffmpeg dies when GUI exits
├── input\ output\ temp\        # Working dirs
└── archive\                    # Old scripts/output from previous iterations
```

## Critical patches applied to dynamic-crf

The `install-dynamic-crf.bat` clones the Go source and applies these patches before building:

1. **`commands/cambi.go` Windows stub** — original uses `syscall.Mkfifo` (Unix-only). Patched: `//go:build !windows` tag + `commands/cambi_windows.go` stub that errors out for `cambi` action.
2. **`commands/ffmpeg_encode.go` codec-aware quality flags** — original hardcodes `-crf N` which only works for libx264/libx265/libsvtav1. Patched switch:
   - `av1_amf`: `-rc cqp -qp_i $((CRF-1)*5) -qp_p $((CRF+1)*5) -qp_b $((CRF+3)*5)` (AV1 AMF qp range is 0-255, not 0-51)
   - `hevc_amf`, `h264_amf`: `-rc qvbr -qvbr_quality_level $CRF`
   - `av1_nvenc`: `-cq $CRF`
   - `hevc_qsv`, `h264_qsv`: `-global_quality $CRF`
   - `av1_qsv`: `-global_quality $((CRF*5))`
   - default: `-crf $CRF`
3. **`actions/crf_search.go` duration heuristic** — original `if durationMs < 1000` is wrong for MKVs where MediaInfo reports seconds (e.g. 1420). Patched to `< 60000` so any source shorter than 60s in the reported value gets multiplied. Also adds an INFO log of the raw MediaInfo duration.
4. **`commands/ffprobe_scenes.go` Windows path escape** — original `movie=` filter chokes on `C:`, `\`, `[`, `]`. Patched to use forward slashes + escaped colon + escaped brackets. Adds `strings` import.

## GUI architecture

- **Inline XAML**: ~400-line XAML here-string parsed at startup via `XamlReader.Load`.
- **Background work**: runs in a PowerShell **Runspace** (not `Start-Job`). UI thread owns ObservableCollections (Pending, Completed) and timers.
- **Thread-safety**: worker NEVER calls `Dispatcher.Invoke` (causes thread-affinity errors with cross-runspace scriptblocks). Instead writes to a `Hashtable.Synchronized` (SharedState) + a `ConcurrentQueue` (UiActionQueue + LogQueue). UI thread has a `DispatcherTimer` (80ms) that reads these and applies updates.
- **Job Object** (`_job-kill-on-close.ps1`): main process is added to a Windows Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. When GUI closes (or crashes), Windows kills all child ffmpeg/dynamic-crf/mediainfo processes automatically.
- **Settings persistence**: `%APPDATA%\GmEncoder\settings.json` saves input/output dirs, codec selection, all toggles. Loaded at startup, saved on Start click + Closing.
- **Install/Reinstall buttons**: write `install-dynamic-crf.bat` to disk next to exe (embedded as base64 in bundled exe, else uses existing local file) and run it. Output streams to console.

## Encoding pipeline per file (in `Invoke-FileEncode`)

1. **Probing** — `ffprobe -show_format -show_streams -of json` to get width/height/codec/duration/audio/sub counts.
2. **Hardlink trick** — create `temp\src.mkv` as hardlink to input file. Run dynamic-crf with `WorkingDirectory = temp` and `-i src.mkv` (relative). This avoids ffmpeg lavfi filter problems with spaces/brackets/colons in paths.
3. **Set `$env:TEMP = temp\`** — dynamic-crf's internal `os.TempDir()` calls land here, not in user temp.
4. **Run dynamic-crf** — `cmd /c run.bat -a optimize -i src.mkv -o out.mp4 -codec X -targetvmaf 93 -tolerance 1.5 -mincrf 28 -maxcrf 18 -initialcrf 22`
5. **Stream stdout/stderr** via `Register-ObjectEvent OutputDataReceived` → enqueued into a `Synchronized ArrayList`. Main loop polls and calls a per-line callback that:
   - Detects phase transitions (scene detect / sampling / search iter / encoding / muxing)
   - Updates SharedState (overall pct, step pct, phase label)
   - Logs to LogQueue
6. **Phase-weighted progress** — overall pct is monotonic 0→100% across phases:
   - SceneDetect 2-12, Sampling 12-25, Searching 25-55 (+6 per iter), Encoding 55-95, Muxing 95-100.
7. **Detect final encode** — pattern `ffmpeg encode.*-i\s+src\.mkv` (vs test encodes which use `sample_*.mp4` input). When detected, lock in last seen CRF/VMAF and switch to encoding phase.
8. **Post-mux** — after dynamic-crf done, run `ffmpeg -i temp\out.mp4 -i <original> -map 0:v:0 -map 1:a? -map 1:s? -map 1:t? -map_chapters 1 -c copy -fflags +genpts -avoid_negative_ts make_zero <final.mkv>` to combine the encoded video with audio/subs/attachments from the original.
9. **Cleanup** — wipe `temp\` (sample.mp4, tst_encode*.mp4, src.mkv).
10. **Optional source disposal** — move to `input\done\` (default) or permanent delete (with confirm popup).

## Known issues / open work

- **AV1 AMF speed**: with cqp + scaled qp the encoder uses GPU (~10-15x), but the user has an RX 9070 XT (RDNA4) where ffmpeg's AMF AV1 support may need ffmpeg 7.0+ and Adrenalin 24.x+. If user reports 2x speed = CPU fallback, ffmpeg version is the issue.
- **AMD AMF on already-compressed sources**: file size can exceed original. This is inherent AMD AMF bit-inefficiency. Recommend CPU libx265 or SVT-AV1 for compression of pre-compressed content.
- **dynamic-crf's bisection**: can fail when target VMAF is unreachable; falls back to maxcrf (highest quality). Logged as "found vmaf at min/max crf".
- **No GUI for `Tune` flag** — possible enhancement (animation/film/grain tunes).
- **CPU/GPU bars use `PerformanceCounter`** — first sample after start is 0, second is correct. UI shows current value.

## Build instructions

```powershell
# Prerequisites: PowerShell 5.1+, internet access for first install
cd "C:\ai code\asa"

# Build .exe (bundles gui\*.ps* + install-dynamic-crf.bat as base64)
.\build-exe.ps1
# -> gm-encoder.exe (~160 KB)

# First-time setup: click Install in GUI, or run:
.\install-dynamic-crf.bat
# -> Downloads ~500 MB (Go, ffmpeg, mediainfo, git), patches dynamic-crf source, builds dynamic-crf.exe
```

## Recent change log (chronological)

1. Built initial multi-step CLI pipeline (batch-*.bat files calling _*.ps1 helpers, archived in `archive\pre-gui-*`).
2. Created WPF GUI replacing CLI bats.
3. Fixed Windows path issues in dynamic-crf (cambi stub + scene-detect escape).
4. Added codec-aware quality flags (AMF qp scaling, NVENC cq, QSV global_quality).
5. Added thread-safe runspace worker with shared-state polling.
6. Added pause/stop, CPU/GPU bars, settings persistence.
7. Removed wave animations (caused stutter).
8. Bundled all .psm1 + install bat into single self-contained .exe.

---

# Source files

'@

# Append source files
$files = if ($Compact) {
    # Skip install-dynamic-crf.bat (23 KB), run.bat, reinstall, archive script
    @(
        @{ Path = 'gm-encoder.ps1';                Lang = 'powershell' }
        @{ Path = 'gui/Encoder.psm1';           Lang = 'powershell' }
        @{ Path = 'gui/_job-kill-on-close.ps1'; Lang = 'powershell' }
        @{ Path = 'build-exe.ps1';              Lang = 'powershell' }
    )
} else {
    @(
        @{ Path = 'gm-encoder.ps1';                Lang = 'powershell' }
        @{ Path = 'gui/Encoder.psm1';           Lang = 'powershell' }
        @{ Path = 'gui/_job-kill-on-close.ps1'; Lang = 'powershell' }
        @{ Path = 'build-exe.ps1';              Lang = 'powershell' }
        @{ Path = 'install-dynamic-crf.bat';    Lang = 'batch' }
        @{ Path = 'run.bat';                    Lang = 'batch' }
        @{ Path = 'reinstall-dynamic-crf.bat';  Lang = 'batch' }
        @{ Path = 'archive-pre-gui.ps1';        Lang = 'powershell' }
    )
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append($header)

foreach ($f in $files) {
    $full = Join-Path $Root $f.Path
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host "[skip] $($f.Path) (not found)" -ForegroundColor Yellow
        continue
    }
    $content = Get-Content -Raw -LiteralPath $full
    $origSize = $content.Length
    if ($Compact) { $content = Compact-Source -Content $content -Lang $f.Lang }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## ``$($f.Path)``")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("``````$($f.Lang)")
    [void]$sb.AppendLine($content.TrimEnd())
    [void]$sb.AppendLine("``````")
    $msg = if ($Compact) {
        "[ok] $($f.Path) ($([Math]::Round($origSize/1KB,1))KB -> $([Math]::Round($content.Length/1KB,1))KB)"
    } else {
        "[ok] $($f.Path) ($([Math]::Round($content.Length/1KB,1))KB)"
    }
    Write-Host $msg
}

if ($Compact) {
    $installSummary = @'

## `install-dynamic-crf.bat` (summary - full file omitted in compact mode)

547-line .bat that contains a giant embedded PowerShell script. Workflow:

1. Sets `$InstallDir = "C:\ai code\asa"` (or `%~dp0` when invoked).
2. Downloads (if missing) into `$InstallDir\bin\`:
   - 7zip (for extracting other archives)
   - Go (from go.dev) → `bin\go\`
   - FFmpeg from gyan.dev `ffmpeg-release-full.7z` → `bin\ffmpeg\bin\ffmpeg.exe`, `ffprobe.exe`
   - MediaInfo CLI → `bin\mediainfo\MediaInfo.exe`
   - git portable → `bin\git\`
3. Validates downloads with byte-magic checks (PK for zip, MZ for exe, etc).
4. Clones `https://github.com/terranvigil/dynamic-crf.git` into a temp dir.
5. **Applies 4 patches** to the Go source before building:
   - `commands/cambi.go`: prepends `//go:build !windows`, writes companion `cambi_windows.go` stub that returns error for cambi action on Windows (mkfifo not available).
   - `commands/ffmpeg_encode.go`: replaces the unconditional `args = append(args, "-crf", strconv.Itoa(e.cfg.VideoCRF))` with a `switch e.cfg.VideoCodec` that maps to `-rc cqp -qp_i/-qp_p/-qp_b` (av1_amf, scaled *5), `-rc qvbr -qvbr_quality_level` (hevc_amf/h264_amf), `-cq` (av1_nvenc), `-global_quality` (qsv variants), default `-crf`.
   - `actions/crf_search.go`: changes `if durationMs < 1000 { durationMs *= 1000 }` to `< 60000` so MKVs that report seconds get scaled. Also logs raw MediaInfo duration value.
   - `commands/ffprobe_scenes.go`: adds `strings` import. Replaces `"movie=" + f.source.Name() + ",select=gt(scene\\,0.3)"` with code that builds `movieFilter` with forward-slashed + escaped path (`escPath = strings.ReplaceAll(f.source.Name(), "\\", "/")`, then escape `:`, `[`, `]`, `'`). Without this scene detection fails on Windows paths.
6. Runs `go build -o $InstallDir\dynamic-crf.exe ./cmd/...` → produces patched binary.
7. Writes `run.bat` (sets PATH for bin\ffmpeg, bin\mediainfo, bin\go) and self-test.
8. Logs to `$InstallDir\install.log`.

'@
    $finalContent = $sb.ToString() + $installSummary
} else {
    $finalContent = $sb.ToString()
}
Set-Content -LiteralPath $Out -Value $finalContent -Encoding UTF8
$size = [Math]::Round((Get-Item $Out).Length / 1KB, 1)
Write-Host ""
Write-Host "[OK] PROJECT-HANDOVER.md written ($size KB)" -ForegroundColor Green
Write-Host "     Path: $Out"
