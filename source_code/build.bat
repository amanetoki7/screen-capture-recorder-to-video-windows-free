@echo off
rem builds both filter dlls, see build.ps1 for the requirements (Visual Studio 2019+ with the C++ workload)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
