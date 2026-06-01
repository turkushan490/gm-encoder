#requires -Version 5.1
<#
  test-encoder.ps1
  CLI smoke test voor Encoder.psm1 - verifieert dat alle helpers werken
  zonder de GUI. Vraagt geen folder; gebruikt default input\ en output\.
#>

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $Root 'gui\Encoder.psm1') -Force

Write-Host ""
Write-Host "=== Encoder module smoke test ===" -ForegroundColor Cyan
$paths = Get-AsaPaths -BaseDir $Root
Write-Host " Base: $($paths.Base)"
Write-Host " Ffmpeg present: $([System.IO.File]::Exists($paths.Ffmpeg))"
Write-Host " Dcrf present:   $([System.IO.File]::Exists($paths.Dcrf))"

Write-Host ""
Write-Host "Codec lijst (12):"
foreach ($c in Get-CodecList) {
    Write-Host ("  {0,2}) {1,-25} {2}" -f $c.Id, $c.Display, $c.Codec)
}

Write-Host ""
Write-Host "Encoder beschikbaarheid:"
$enc = Get-AvailableEncoders -FfmpegPath $paths.Ffmpeg
foreach ($k in $enc.Keys | Sort-Object) {
    $mark = if ($enc[$k]) { '[OK]' } else { '[--]' }
    Write-Host "  $mark $k"
}

Write-Host ""
Write-Host "Input files:"
$files = Get-InputFiles -InputDir $paths.Input
if ($files.Count -eq 0) {
    Write-Host "  (leeg)" -ForegroundColor Yellow
} else {
    foreach ($f in $files) {
        Write-Host "  - $($f.Name) ($([Math]::Round($f.Length/1MB,1)) MB)"
    }
}

Write-Host ""
Write-Host "[OK] Smoke test klaar - module laadt correct" -ForegroundColor Green
