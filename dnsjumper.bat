@echo off
chcp 65001 >nul
title DNS Jumper v1.0

:: Auto elevate to Admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:MENU
cls
echo ============================================
echo           DNS Jumper v1.0
echo ============================================
echo.
echo 1. dns.bibica.net (127.0.0.1)
echo 2. Google Public DNS (8.8.8.8, 8.8.4.4)
echo 3. Quad9 ECS (9.9.9.11, 149.112.112.11)
echo 4. OpenDNS (208.67.222.222, 208.67.220.220)
echo 5. Cloudflare DNS (1.1.1.1, 1.0.0.1)
echo 0. Exit
echo.
echo ============================================
set /p choice="Select DNS (0-5): "

if "%choice%"=="1" set dns1=127.0.0.1 & set dns2= & goto APPLY
if "%choice%"=="2" set dns1=8.8.8.8 & set dns2=8.8.4.4 & goto APPLY
if "%choice%"=="3" set dns1=9.9.9.11 & set dns2=149.112.112.11 & goto APPLY
if "%choice%"=="4" set dns1=208.67.222.222 & set dns2=208.67.220.220 & goto APPLY
if "%choice%"=="5" set dns1=1.1.1.1 & set dns2=1.0.0.1 & goto APPLY
if "%choice%"=="0" exit /b
goto MENU

:APPLY
echo.
echo Applying DNS to all network adapters...
echo.

for /f "skip=2 tokens=3*" %%i in ('netsh interface show interface') do (
    call :SETDNS "%%j"
)

echo.
echo Flushing DNS cache...
ipconfig /flushdns >nul

echo.
echo ============================================
echo DNS successfully changed!
echo ============================================
timeout /t 3 >nul
goto MENU

:SETDNS
echo Configuring: %~1
netsh interface ip set dns name=%1 static %dns1% primary >nul 2>&1
if not "%dns2%"=="" (
    netsh interface ip add dns name=%1 %dns2% index=2 >nul 2>&1
)
exit /b
