@echo off
setlocal
cd /d "%~dp0"
title Network Backup Manager
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0BackupManager.ps1"
if errorlevel 1 (
  echo.
  echo Network Backup Manager failed to start.
  pause
)
