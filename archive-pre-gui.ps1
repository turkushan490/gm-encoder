#requires -Version 5.1
<#
  archive-pre-gui.ps1
  Eenmalig: verplaats alle CLI-pipeline scripts en oude output naar
  archive\pre-gui-YYYYMMDD\, behoud essentiele runtime files in plaats.
  Kopieer eerst _job-kill-on-close.ps1 naar gui\ (die wordt hergebruikt
  door de nieuwe Encoder module).
#>

$ErrorActionPreference = 'Stop'
$Base   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmm'
$ArcRoot= Join-Path $Base 'archive'
$ArcDst = Join-Path $ArcRoot "pre-gui-$Stamp"
$GuiDst = Join-Path $Base 'gui'

Write-Host ""
Write-Host "=== ASA pre-GUI archive ===" -ForegroundColor Cyan
Write-Host " Base   : $Base"
Write-Host " Archive: $ArcDst"
Write-Host " GUI dir: $GuiDst"
Write-Host ""

# Maak archive + gui mappen
New-Item -ItemType Directory -Path $ArcDst -Force | Out-Null
New-Item -ItemType Directory -Path $GuiDst -Force | Out-Null

# --- Stap 1: kopieer _job-kill-on-close.ps1 naar gui\ (nog vóór move) ---
$jobKill = Join-Path $Base '_job-kill-on-close.ps1'
if (Test-Path -LiteralPath $jobKill) {
    Copy-Item -LiteralPath $jobKill -Destination (Join-Path $GuiDst '_job-kill-on-close.ps1') -Force
    Write-Host "  [copy] _job-kill-on-close.ps1 -> gui\" -ForegroundColor Green
}

# --- Stap 2: verplaats CLI scripts ---
$movedAny = $false

function Move-IfExists {
    param([string]$Path, [string]$Reason = '')
    if (Test-Path -LiteralPath $Path) {
        $name = Split-Path -Leaf $Path
        Move-Item -LiteralPath $Path -Destination (Join-Path $ArcDst $name) -Force
        Write-Host "  [move] $name $Reason" -ForegroundColor DarkCyan
        $script:movedAny = $true
    }
}

# batch-*.bat
Get-ChildItem -Path $Base -Filter 'batch-*.bat' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Move-IfExists -Path $_.FullName
}

# _*.ps1 (helpers, incl _job-kill-on-close.ps1 zelf — was net gekopieerd naar gui)
Get-ChildItem -Path $Base -Filter '_*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Move-IfExists -Path $_.FullName
}

# Losse helper bats
foreach ($f in @('reinstall-dynamic-crf.bat','diagnose.bat')) {
    Move-IfExists -Path (Join-Path $Base $f)
}

# --- Stap 3: leeg de output\ map (maar laat de map staan) ---
$outDir = Join-Path $Base 'output'
if (Test-Path -LiteralPath $outDir) {
    $outArc = Join-Path $ArcDst 'output'
    New-Item -ItemType Directory -Path $outArc -Force | Out-Null
    Get-ChildItem -Path $outDir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $rel = $_.FullName.Substring($outDir.Length).TrimStart('\')
            $dst = Join-Path $outArc $rel
            $dstDir = Split-Path -Parent $dst
            if ($dstDir -and -not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
            }
            Move-Item -LiteralPath $_.FullName -Destination $dst -Force
            Write-Host "  [move] output\$rel" -ForegroundColor DarkCyan
            $script:movedAny = $true
        } catch {}
    }
}

# --- Samenvatting ---
Write-Host ""
if ($movedAny) {
    Write-Host " Archive klaar in: $ArcDst" -ForegroundColor Green
} else {
    Write-Host " Niets om te archiveren (al schoon)." -ForegroundColor Yellow
}
Write-Host ""
Write-Host " Behouden in $Base :" -ForegroundColor Cyan
Write-Host "   dynamic-crf.exe, bin\, run.bat, install-dynamic-crf.bat"
Write-Host "   input\, output\ (leeg), temp\, gopath\"
Write-Host "   gui\ (nieuw)"
Write-Host ""
