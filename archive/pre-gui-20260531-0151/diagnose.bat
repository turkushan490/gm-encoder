@echo off
REM Diagnostische check - verifieert wat er nu eigenlijk werkt.
setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"

echo.
echo === Bestanden check ===
for %%F in (
    "%BASE%\dynamic-crf.exe"
    "%BASE%\run.bat"
    "%BASE%\bin\ffmpeg\bin\ffmpeg.exe"
    "%BASE%\bin\ffmpeg\bin\ffprobe.exe"
    "%BASE%\bin\mediainfo\MediaInfo.exe"
) do (
    if exist "%%~F" (
        echo   [OK] %%~nxF
    ) else (
        echo   [MISSING] %%~F
    )
)

echo.
echo === dynamic-crf direct testen ===
if exist "%BASE%\dynamic-crf.exe" (
    echo Test: dynamic-crf.exe (zonder argumenten - moet help tonen of error)
    "%BASE%\dynamic-crf.exe" 2>&1
    echo Exit code: %errorlevel%
) else (
    echo [FAIL] dynamic-crf.exe ontbreekt - reinstall vereist
)

echo.
echo === run.bat directe test ===
echo Test: run.bat -h (help via run.bat)
call "%BASE%\run.bat" -h 2>&1
echo Exit code: %errorlevel%

echo.
echo === ffmpeg encoders check ===
if exist "%BASE%\bin\ffmpeg\bin\ffmpeg.exe" (
    "%BASE%\bin\ffmpeg\bin\ffmpeg.exe" -hide_banner -encoders 2>nul | findstr /i "nvenc amf qsv libvmaf"
)

echo.
echo === Klaar ===
pause
endlocal
