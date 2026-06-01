@echo off
REM Force rebuild dynamic-crf.exe met alle patches.
REM Verwijdert eerst de bestaande exe zodat de installer de Go source
REM opnieuw kloont, patcht en compileert.

echo.
echo === Force rebuild dynamic-crf.exe ===
echo.

setlocal
set "BASE=%~dp0"
set "BASE=%BASE:~0,-1%"
set "DCRF=%BASE%\dynamic-crf.exe"

if exist "%DCRF%" (
    echo Verwijderen oude dynamic-crf.exe...
    del /f /q "%DCRF%"
    if exist "%DCRF%" (
        echo [!!] Kon dynamic-crf.exe niet verwijderen. Is hij in gebruik?
        echo      Sluit eerst alle batch scripts/cmd windows.
        pause
        exit /b 1
    )
    echo OK.
) else (
    echo Geen oude dynamic-crf.exe aanwezig - rechtstreeks builden.
)

echo.
echo Start installer voor patch + rebuild...
echo.
call "%BASE%\install-dynamic-crf.bat"
endlocal
