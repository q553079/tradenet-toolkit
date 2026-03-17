@echo off
chcp 65001 >nul
powershell -ExecutionPolicy Bypass -File "%~dp0start-tradenet.ps1"
pause
