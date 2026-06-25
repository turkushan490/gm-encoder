$TOKEN = (cmd /c "echo protocol=https& echo host=github.com& echo." | git credential fill 2>$null |
    Select-String '^password=' | ForEach-Object { ($_ -split '=', 2)[1] })
if (-not $TOKEN) { Write-Host "[!!] no token"; exit 1 }

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe  = Join-Path $Root 'gm-gui.exe'
if (-not (Test-Path $exe)) { Write-Host "[!!] gm-gui.exe missing"; exit 2 }

# 1. Create new tag locally + push
Push-Location $Root
git tag -a v1.0.1 -m "v1.0.1 - GM Encoder branding + window icon"
git push origin v1.0.1
Pop-Location

# 2. Create release v1.0.1
$body = @'
<p align="center">
  <img src="https://raw.githubusercontent.com/turkushan490/gm-encoder/main/docs/logo.svg" width="160" alt="GM Encoder"/>
</p>

# v1.0.1 - GM Encoder branding + window icon

Branding and polish release. Same encoding engine + patches as v1.0.0, plus:

## Changes
- Window title shows **GM Encoder** (was ASA Encoder in v1.0.0 builds)
- New **logo as window icon** + .exe icon (taskbar shows the GM logo)
- README + release page consistent on `gm-gui.exe` asset name
- Multi-size icon (16, 32, 48, 64, 128, 256 px) for crisp display on every Windows scale

## Features (same as v1.0.0)
- 12 codecs: H.264 / HEVC / AV1 x CPU / NVIDIA NVENC / AMD AMF / Intel QSV
- VMAF search with phase-weighted monotonic progress
- Post-mux preserves all audio tracks, subtitles, and attachments
- Pause / Stop controls with Windows Job Object cleanup
- Live CPU + GPU usage bars
- Single self-contained .exe (~190 KB)
- Settings persistence (%APPDATA%\GmEncoder\settings.json)
- Embedded installer (downloads Go/ffmpeg/mediainfo + builds patched dynamic-crf.exe)

## Install
1. Download `gm-gui.exe` below
2. Place it in any folder
3. Run -> click **Install** in the header (~5 min, downloads ~500 MB)
4. Drop videos in `input\`, pick codec, click START

## Credits
Wraps and patches [terranvigil/dynamic-crf](https://github.com/terranvigil/dynamic-crf) (MIT). Built with help from Claude (Anthropic).
'@

$payload = @{ tag_name = 'v1.0.1'; name = 'v1.0.1 - Branding + window icon'; body = $body; draft = $false; prerelease = $false } | ConvertTo-Json

$headers = @{ Authorization = "Bearer $TOKEN"; Accept = 'application/vnd.github+json' }
$release = Invoke-RestMethod -Method Post -Uri 'https://api.github.com/repos/turkushan490/gm-encoder/releases' -Headers $headers -ContentType 'application/json' -Body $payload
Write-Host "[OK] Release created: $($release.html_url)"

# 3. Upload gm-gui.exe as asset
$uploadUrl = $release.upload_url -replace '\{\?.*\}', '?name=gm-gui.exe'
Write-Host "Uploading $exe ..."
$exeBytes = [System.IO.File]::ReadAllBytes($exe)
$uploadHeaders = @{ Authorization = "Bearer $TOKEN"; Accept = 'application/vnd.github+json' }
$asset = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $uploadHeaders -ContentType 'application/octet-stream' -Body $exeBytes
Write-Host "[OK] Asset uploaded: $($asset.browser_download_url)"
Write-Host "     Size: $([Math]::Round($asset.size/1KB,1)) KB"
