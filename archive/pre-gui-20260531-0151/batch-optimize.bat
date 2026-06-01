@echo off
REM Interactieve optimize - vraagt aan het begin welke codec.
REM Origineel resolutie, post-mux (subs/audio behouden), temp wordt opgeruimd.
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_optimize-batch.ps1" -TargetVmaf 93 -Remux
pause
endlocal
