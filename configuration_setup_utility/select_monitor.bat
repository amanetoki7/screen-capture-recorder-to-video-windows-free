@echo off
rem visual monitor selector for screen-capture-recorder, see select_monitor.ps1 (needs no java, just windows powershell)
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0select_monitor.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0select_monitor.ps1" %*
)
