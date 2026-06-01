@echo off
REM GM Encoder launcher - start GUI zonder console window
REM Gebruik dit als gm-encoder.exe nog niet gebouwd is.
@powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0gm-encoder.ps1"
