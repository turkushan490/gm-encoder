@echo off
REM ASA Encoder launcher - start GUI zonder console window
REM Gebruik dit als asa-gui.exe nog niet gebouwd is.
@powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0asa-gui.ps1"
