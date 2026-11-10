@echo off
setlocal
cd /d "%~dp0"
title Network Backup Manager
where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo Windows PowerShell was not found.
  pause
  exit /b 1
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0BackupManager.ps1"
if errorlevel 1 (
  echo.
  echo Network Backup Manager failed to start. Check the error above.
  pause
)
