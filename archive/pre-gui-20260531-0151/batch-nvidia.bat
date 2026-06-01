@echo off
REM Plain NVIDIA NVENC HEVC encode (geen search, vaste cq 23).
REM Origineel resolutie. Input: .\input\  Output: .\output\
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_encode-batch.ps1" -Encoder nvenc -Quality 23
pause
endlocal
