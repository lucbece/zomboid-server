@echo off
rem Operations entry point: zs start|stop|restart|status|logs|backup|update|render|rcon
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0zs.ps1" %*
