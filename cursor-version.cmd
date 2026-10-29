@echo off
chcp 65001 >nul 2>&1
setlocal
set "PS1=%~dp0cursor-version.ps1"

if not exist "%PS1%" (
    echo [ERROR] cursor-version.ps1 not found next to this file.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%ERRORLEVEL%"

if "%~1"=="" pause
endlocal & exit /b %RC%
