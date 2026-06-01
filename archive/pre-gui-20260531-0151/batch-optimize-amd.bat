@echo off
REM Full-GPU optimize met AMD AMF (dynamic-crf native, search + encode).
REM Werkt na herinstall met de AMF-patch in install-dynamic-crf.bat.
REM Origineel resolutie. Post-mux behoudt subs/audio/attachments.
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_optimize-batch.ps1" -TargetVmaf 93 -Codec hevc_amf -Remux
pause
endlocal
