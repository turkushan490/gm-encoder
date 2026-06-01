@echo off
REM Full-GPU optimize met NVIDIA NVENC (dynamic-crf native, search + encode).
REM Origineel resolutie. Post-mux behoudt subs/audio/attachments.
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_optimize-batch.ps1" -TargetVmaf 93 -Codec hevc_nvenc -Remux
pause
endlocal
