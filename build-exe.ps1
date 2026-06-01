#requires -Version 5.1
<#
  build-exe.ps1
  Bundle gui\Encoder.psm1 + gui\_job-kill-on-close.ps1 inline in gm-encoder.ps1
  en compileer naar single self-contained gm-encoder.exe via ps2exe.
#>

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== GM build-exe (bundled) ===" -ForegroundColor Cyan
Write-Host ""

# Kill running instances
Get-Process -Name 'gm-encoder' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "Stoppen running gm-encoder (PID $($_.Id))..." -ForegroundColor Yellow
    $_.Kill()
    $_.WaitForExit(2000) | Out-Null
}

# Paths
$src        = Join-Path $Root 'gm-encoder.ps1'
$encoderMod = Join-Path $Root 'gui\Encoder.psm1'
$jobKill    = Join-Path $Root 'gui\_job-kill-on-close.ps1'
$bundled    = Join-Path $Root 'gm-encoder-bundled.ps1'
$exe        = Join-Path $Root 'gm-encoder.exe'

foreach ($f in @($src, $encoderMod, $jobKill)) {
    if (-not (Test-Path $f)) {
        Write-Host "[!!] Missing: $f" -ForegroundColor Red
        exit 1
    }
}

if (Test-Path $exe) {
    try { Remove-Item $exe -Force -ErrorAction Stop } catch {
        Write-Host "[!!] Kon oude gm-encoder.exe niet verwijderen: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "     Sluit eerst de GUI handmatig." -ForegroundColor Yellow
        exit 1
    }
}

# ----- Bundle samenstellen -----
Write-Host "Bundling modules inline..." -ForegroundColor Cyan
$mainContent = Get-Content -Raw -LiteralPath $src
$jobKillContent = Get-Content -Raw -LiteralPath $jobKill
$encoderContent = Get-Content -Raw -LiteralPath $encoderMod

# Verwijder Export-ModuleMember en alle continuation lines tot eind van bestand
# (Export-ModuleMember is altijd de laatste statement in .psm1)
$exportIdx = $encoderContent.IndexOf('Export-ModuleMember')
if ($exportIdx -ge 0) {
    $encoderContent = $encoderContent.Substring(0, $exportIdx) + "# (Export-ModuleMember removed for bundled exe)"
}

# Remove `. $jobKill` dot-source (we voegen die inline toe)
$encoderContent = $encoderContent -replace '(?m)^\s*\.\s+\$jobKill\s*$', '# (jobKill inlined)'

# Vervang Encoder.psm1 dot-source / Import-Module met inline definitie
# Embed install-dynamic-crf.bat als base64 (zodat .exe self-contained installer heeft)
$installBat = Join-Path $Root 'install-dynamic-crf.bat'
$installBatB64 = ''
if (Test-Path -LiteralPath $installBat) {
    $bytes = [System.IO.File]::ReadAllBytes($installBat)
    $installBatB64 = [Convert]::ToBase64String($bytes)
    Write-Host "Embedded install-dynamic-crf.bat ($([Math]::Round($bytes.Length/1KB,1)) KB)" -ForegroundColor DarkGray
}

$bundlePreamble = @"
# =============================================================
# BUNDLED HELPERS - inlined from gui\_job-kill-on-close.ps1
# =============================================================
$jobKillContent

# =============================================================
# BUNDLED ENCODER - inlined from gui\Encoder.psm1
# =============================================================
$encoderContent

# =============================================================
# BUNDLED INSTALLER - base64 van install-dynamic-crf.bat
# =============================================================
`$script:InstallBatBase64 = '$installBatB64'

# =============================================================
# END OF BUNDLED MODULES
# =============================================================

"@

# In main script: vervang de Import-Module + path checks met een no-op
# zodat we niet meer afhankelijk zijn van gui\ map
$mainPatched = $mainContent

# Vervang het hele Import-Module block met een marker comment
$importPattern = '(?s)Get-ChildItem -Path \(Join-Path \$Root ''gui''\).*?Import-Module \$encoderModulePath -Force'
$mainPatched = $mainPatched -replace $importPattern, '# Bundled mode: modules zijn inline geladen'

# Compose final bundled script:
# 1. Header (param + execution policy + WPF assemblies + Resolve-ScriptRoot + trap)
# 2. Bundled modules (jobKill + Encoder)
# 3. Rest of main (XAML, event wiring, ShowDialog)

# Splits gm-encoder.ps1 op de "Bundled mode" marker (waar Import-Module zat)
$splitMarker = '# Bundled mode: modules zijn inline geladen'
$parts = $mainPatched -split [regex]::Escape($splitMarker), 2
if ($parts.Count -ne 2) {
    Write-Host "[!!] Kon splitsen niet uitvoeren - import marker niet gevonden" -ForegroundColor Red
    exit 2
}

$finalContent = $parts[0] + "`n" + $bundlePreamble + "`n" + $parts[1]
Set-Content -LiteralPath $bundled -Value $finalContent -Encoding UTF8

Write-Host "Bundled script: $bundled ($([Math]::Round((Get-Item $bundled).Length/1KB,1)) KB)" -ForegroundColor DarkGray

# ----- ps2exe check + install -----
if (-not (Get-Module ps2exe -ListAvailable)) {
    Write-Host "ps2exe ontbreekt - installeren..." -ForegroundColor Yellow
    try { Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber -Confirm:$false }
    catch { Write-Host "[!!] Install-Module faalde" -ForegroundColor Red; exit 3 }
}
Import-Module ps2exe -ErrorAction Stop

# ----- Compile -----
Write-Host "Compileren $bundled -> $exe ..." -ForegroundColor Cyan
try {
    Invoke-PS2EXE -inputFile $bundled -outputFile $exe `
        -noConsole `
        -title 'GM Encoder' `
        -company 'Turkushan' `
        -product 'GM Encoder' `
        -version '1.0.0.0' `
        -requireAdmin:$false `
        -DPIAware

    if (Test-Path $exe) {
        $size = [Math]::Round((Get-Item $exe).Length / 1KB, 1)
        Write-Host ""
        Write-Host "[OK] gm-encoder.exe gebouwd ($size KB, self-contained)" -ForegroundColor Green
        Write-Host ""
        Write-Host " Run met: $exe" -ForegroundColor Cyan
        Write-Host " De gui\ map is NIET meer nodig naast de exe."
    } else {
        Write-Host "[!!] Build leek te slagen maar exe ontbreekt" -ForegroundColor Red
        exit 4
    }
} catch {
    Write-Host "[!!] Build mislukt: $($_.Exception.Message)" -ForegroundColor Red
    exit 5
} finally {
    # Cleanup bundled script (alleen .exe bewaren)
    if (Test-Path $bundled) {
        Remove-Item $bundled -Force -ErrorAction SilentlyContinue
    }
}
