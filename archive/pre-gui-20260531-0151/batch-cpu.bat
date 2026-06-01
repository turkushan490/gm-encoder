@echo off
REM Plain CPU libx265 encode (preset medium, crf 23). Geen search.
REM Origineel resolutie. Input: .\input\  Output: .\output\
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%BASE%\_encode-batch.ps1" -Encoder cpu -Quality 23
pause
endlocal
