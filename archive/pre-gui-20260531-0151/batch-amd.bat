@echo off
REM Plain AMD AMF HEVC encode (geen search, vaste qp 23).
REM Origineel resolutie. Input: .\input\  Output: .\output\
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_encode-batch.ps1" -Encoder amf -Quality 23
pause
endlocal
