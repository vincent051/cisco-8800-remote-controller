@echo off
:: build-installer.bat — Lance build-installer.ps1 en tant qu'Administrateur
:: Double-cliquer ou "Executer en tant qu'administrateur"

NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    echo Elevation des privileges en cours...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Deja admin — lancer le script PowerShell
cd /d "%~dp0"
powershell -ExecutionPolicy Bypass -File "%~dp0build-installer.ps1"
pause
