@echo off
set "BASE=%~dp0"
if "%BASE:~-1%"=="\" set "BASE=%BASE:~0,-1%"
set "PATH=%BASE%\bin\ffmpeg\bin;%BASE%\bin\mediainfo;%BASE%\bin\go\bin;%BASE%\bin\git\bin;%BASE%\bin\git\cmd;%PATH%"
"%BASE%\dynamic-crf.exe" %*