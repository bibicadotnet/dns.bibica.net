@echo off
REM Check for admin privileges
NET SESSION >nul 2>&1
IF %ERRORLEVEL% NEQ 0 (
    ECHO Requesting administrative privileges...
    powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
    EXIT /B
)
PowerShell.exe -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://go.bibica.net/dns-bibica-net | iex"
pause
