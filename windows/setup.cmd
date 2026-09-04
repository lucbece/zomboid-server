@echo off
rem Double-click entry point: first configuration, install and start of the server.
rem No execution-policy change is made outside this one process.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
pause
