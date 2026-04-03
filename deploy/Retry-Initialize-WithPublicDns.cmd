@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Retry-Initialize-WithPublicDns.ps1"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo Retry initialization failed with exit code %EXITCODE%.
)

echo.
pause
exit /b %EXITCODE%
