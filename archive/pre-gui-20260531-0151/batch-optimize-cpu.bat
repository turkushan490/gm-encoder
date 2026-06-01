@echo off
REM Full-CPU optimize met libx264 (dynamic-crf native, search + encode).
REM Origineel resolutie. Post-mux behoudt subs/audio/attachments.
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_optimize-batch.ps1" -TargetVmaf 93 -Codec libx264 -Remux
pause
endlocal
