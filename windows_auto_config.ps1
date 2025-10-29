# Check admin rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
   Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://go.bibica.net/dns-bibica-net | iex`"" -Verb RunAs
   exit
}
Clear-Host

# Configuration
$installPath = "C:\dns-bibica-net-doh"
$dnscryptPath = "$installPath\dnscrypt-proxy"
$goodbyedpiPath = "$installPath\GoodbyeDPI"
$tempPath = "$env:TEMP\dnscrypt-setup"
$backupFile = "$installPath\dns-backup.txt"
$tempBackupFile = "$env:TEMP\dns-backup-temp.txt"

Write-Host "dns.bibica.net DoH & DPI bypass - Auto Installer" -ForegroundColor Cyan
Write-Host ""

# === Unload WinDivert Driver (để xóa được WinDivert64.sys) ===
function Unload-WinDivertDriver {
    param([string]$InstallPath)
    
    $sysFile = "$InstallPath\GoodbyeDPI\WinDivert64.sys"
    if (-not (Test-Path $sysFile)) { return }
    
    # Kill GoodbyeDPI process
    Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    
    # Stop và xóa tất cả WinDivert services
    Get-Service -Name "WinDivert*" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>$null | Out-Null
    }
    
    sc.exe stop WinDivert 2>$null | Out-Null
    sc.exe delete WinDivert 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
    
    # Thử xóa file
    for ($i = 1; $i -le 5; $i++) {
        try {
            Remove-Item $sysFile -Force -ErrorAction Stop
            break
        } catch {
            if ($i -lt 5) { Start-Sleep -Milliseconds 300 }
        }
    }
    
    # Mark để xóa lúc reboot nếu cần
    if (Test-Path $sysFile) {
        try {
            $pendingOps = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
            $currentValue = (Get-ItemProperty -Path $pendingOps -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
            if ($null -eq $currentValue) { $currentValue = @() }
            $currentValue += "\??\$sysFile"
            $currentValue += ""
            Set-ItemProperty -Path $pendingOps -Name "PendingFileRenameOperations" -Value $currentValue -Type MultiString -ErrorAction SilentlyContinue
        } catch {}
    }
}

# === Get ALL adapters (excluding Loopback) ===
function Get-AllAdapters {
    Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -notlike "*Loopback*"
    }
}

# Check if already installed
$existingBackup = $null
$isReinstall = $false
if (Test-Path $backupFile) {
    $isReinstall = $true
    $existingBackup = Import-Csv -Path $backupFile -Encoding UTF8
    Copy-Item $backupFile $tempBackupFile -Force
    
    Write-Host "Restoring original DNS settings..." -ForegroundColor Gray
    foreach ($item in $existingBackup) {
        try {
            $dnsServers = $item.DNS -split ','
            if ($dnsServers[0] -eq 'DHCP' -or $dnsServers[0] -eq '') {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction Stop
            }
        } catch {}
    }
    Start-Sleep -Seconds 1
}

# Backup current DNS settings
if (-not $isReinstall) {
    Write-Host "Backing up current DNS settings..." -ForegroundColor Gray
    $dnsBackup = @()
    $adapters = Get-AllAdapters
    foreach ($adapter in $adapters) {
        $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        $dnsString = if ($null -eq $dnsServers -or $dnsServers.Count -eq 0 -or $dnsServers[0] -eq "") {
            "DHCP"
        } else {
            ($dnsServers -join ",")
        }
        $dnsBackup += [PSCustomObject]@{
            Name = $adapter.Name
            InterfaceIndex = $adapter.ifIndex
            DNS = $dnsString
        }
    }
    $dnsBackup | Export-Csv -Path $tempBackupFile -NoTypeInformation -Encoding UTF8
}

# Cleanup previous installation
Write-Host "Removing previous installation..." -ForegroundColor Gray
Get-Process -Name "dnscrypt-proxy" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-WmiObject Win32_Process | Where-Object {$_.Name -eq "wscript.exe" -and $_.CommandLine -like "*dns-bibica-net-startup.vbs*"} | ForEach-Object {$_.Terminate()}

Stop-Service -Name "DNSCrypt-Proxy" -Force -ErrorAction SilentlyContinue
sc.exe delete "DNSCrypt-Proxy" 2>$null | Out-Null

Unload-WinDivertDriver -InstallPath $installPath

$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = "$startupPath\dns-bibica-net.lnk"
if (Test-Path $startupShortcut) { Remove-Item $startupShortcut -Force }

Start-Sleep -Seconds 2

if (Test-Path $installPath) {
    $retryCount = 0
    while ((Test-Path $installPath) -and $retryCount -lt 5) {
        try {
            Remove-Item $installPath -Recurse -Force -ErrorAction Stop
        } catch {
            $retryCount++
            if ($retryCount -ge 5) {
                Write-Host "  Some files are in use, will overwrite" -ForegroundColor Gray
            }
            Start-Sleep -Seconds 1
        }
    }
}
if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $dnscryptPath -Force | Out-Null
New-Item -ItemType Directory -Path $goodbyedpiPath -Force | Out-Null
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
if (Test-Path $tempBackupFile) {
    Move-Item $tempBackupFile $backupFile -Force
}

# ==================== Download DNSCrypt-Proxy ====================
Write-Host "Downloading DNSCrypt-Proxy..." -ForegroundColor Gray
try {
    $release = Invoke-RestMethod "https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest" -ErrorAction Stop
    $asset = $release.assets | Where-Object { $_.name -like "dnscrypt-proxy-win64-*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Cannot find Windows 64-bit release" }
    
    $zipPath = "$tempPath\dnscrypt.zip"
    (New-Object System.Net.WebClient).DownloadFile($asset.browser_download_url, $zipPath)
    
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempPath)
    
    $exePath = Get-ChildItem -Path $tempPath -Filter "dnscrypt-proxy.exe" -Recurse | Select-Object -First 1
    if (-not $exePath) { throw "Cannot find dnscrypt-proxy.exe" }
    Copy-Item $exePath.FullName "$dnscryptPath\dnscrypt-proxy.exe" -Force
} catch {
    Write-Host "ERROR: Failed to download DNSCrypt-Proxy" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Download GoodbyeDPI ====================
Write-Host "Downloading GoodbyeDPI..." -ForegroundColor Gray
try {
    $goodbyeReleases = Invoke-RestMethod "https://api.github.com/repos/ValdikSS/GoodbyeDPI/releases" -ErrorAction Stop
    $goodbyeRelease = $goodbyeReleases | Select-Object -First 1
    if (-not $goodbyeRelease) { throw "Cannot find GoodbyeDPI releases" }
    
    $goodbyeAsset = $goodbyeRelease.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1
    if (-not $goodbyeAsset) { throw "Cannot find GoodbyeDPI package" }
    
    $goodbyeZipPath = "$tempPath\goodbyedpi.zip"
    (New-Object System.Net.WebClient).DownloadFile($goodbyeAsset.browser_download_url, $goodbyeZipPath)
    
    $goodbyeTempPath = "$tempPath\goodbyedpi"
    New-Item -ItemType Directory -Path $goodbyeTempPath -Force | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($goodbyeZipPath, $goodbyeTempPath)
    
    $goodbyeExe = Get-ChildItem -Path $goodbyeTempPath -Filter "goodbyedpi.exe" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    $winDivertDll = Get-ChildItem -Path $goodbyeTempPath -Filter "WinDivert.dll" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    $winDivertSys = Get-ChildItem -Path $goodbyeTempPath -Filter "WinDivert64.sys" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    
    if (-not $goodbyeExe -or -not $winDivertDll -or -not $winDivertSys) {
        throw "Cannot find required GoodbyeDPI files"
    }
    
    Copy-Item $goodbyeExe.FullName "$goodbyedpiPath\goodbyedpi.exe" -Force
    Copy-Item $winDivertDll.FullName "$goodbyedpiPath\WinDivert.dll" -Force
    Copy-Item $winDivertSys.FullName "$goodbyedpiPath\WinDivert64.sys" -Force
} catch {
    Write-Host "ERROR: Failed to download GoodbyeDPI" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Create Config Files ====================

# DNSCrypt-Proxy config
@"
listen_addresses = ['127.0.0.1:53']
server_names = ['dns-bibica-net']
ipv4_servers = true
doh_servers = true
require_nolog = true
require_nofilter = true
ignore_system_dns = true
require_dnssec = false
odoh_servers = false
ipv6_servers = false
dnscrypt_servers = false
cache = false
timeout = 5000
keepalive = 10
log_level = 6
bootstrap_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
netprobe_address = '1.1.1.1:53'
netprobe_timeout = 30
#edns_client_subnet = ['103.186.65.0/24', '38.60.253.0/24', '38.54.117.0/24']
[static]
  [static.dns-bibica-net]
  stamp = 'sdns://AgAAAAAAAAAAAAAOZG5zLmJpYmljYS5uZXQKL2Rucy1xdWVyeQ'
"@ | Out-File "$dnscryptPath\dnscrypt-proxy.toml" -Encoding UTF8

# Create VBS startup launcher
@"
Set ws = CreateObject("WScript.Shell")
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")

' Terminate existing processes
On Error Resume Next
Set colProcesses = objWMIService.ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'dnscrypt-proxy.exe' OR Name = 'goodbyedpi.exe'")
For Each objProcess in colProcesses
    objProcess.Terminate()
Next
On Error GoTo 0

WScript.Sleep 1000

' Start GoodbyeDPI first
ws.CurrentDirectory = "$goodbyedpiPath"
ws.Run "goodbyedpi.exe -9", 0, False

WScript.Sleep 2000

' Start DNSCrypt-Proxy
ws.CurrentDirectory = "$dnscryptPath"
ws.Run "dnscrypt-proxy.exe", 0, False
"@ | Out-File "$installPath\dns-bibica-net-startup.vbs" -Encoding ASCII

# Create uninstall.bat
@"
@echo off
setlocal enabledelayedexpansion
cls
echo dns-bibica-net uninstaller
echo.
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Administrator privileges required. Restarting...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo Stopping services...
taskkill /F /IM dnscrypt-proxy.exe >nul 2>&1
taskkill /F /IM goodbyedpi.exe >nul 2>&1
for /f "tokens=2" %%a in ('wmic process where "name='wscript.exe' and commandline like '%%dns-bibica-net-startup.vbs%%'" get processid 2^>nul ^| findstr /r "[0-9]"') do taskkill /F /PID %%a >nul 2>&1

echo Unloading WinDivert driver...
for /f "tokens=2" %%s in ('sc query type^= driver ^| findstr /i "WinDivert"') do (
    sc stop %%s >nul 2>&1
    sc delete %%s >nul 2>&1
)
sc stop WinDivert >nul 2>&1
sc delete WinDivert >nul 2>&1

timeout /t 2 /nobreak >nul

echo Removing startup shortcut...
del "$startupPath\dns-bibica-net.lnk" >nul 2>&1

echo Restoring DNS settings...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"`$backup = Import-Csv '$backupFile' -Encoding UTF8; ^
foreach (`$item in `$backup) { ^
    try { ^
        `$dnsServers = `$item.DNS -split ','; ^
        if (`$dnsServers[0] -eq 'DHCP' -or `$dnsServers[0] -eq '') { ^
            Set-DnsClientServerAddress -InterfaceIndex `$item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; ^
            Write-Host '  ' `$item.Name ': DHCP'; ^
        } else { ^
            Set-DnsClientServerAddress -InterfaceIndex `$item.InterfaceIndex -ServerAddresses `$dnsServers -ErrorAction Stop; ^
            Write-Host '  ' `$item.Name ': ' (`$dnsServers -join ', '); ^
        } ^
    } catch {} ^
}"

echo.
echo Removing installation...
cd /d "%TEMP%"

REM Xóa WinDivert64.sys
set sysfile=$goodbyedpiPath\WinDivert64.sys
set retries=0
:retry_delete
if exist "%sysfile%" (
    del /f /q "%sysfile%" >nul 2>&1
    if exist "%sysfile%" (
        set /a retries+=1
        if !retries! lss 5 (
            timeout /t 1 /nobreak >nul
            goto retry_delete
        ) else (
            echo WinDivert64.sys locked, will be deleted on reboot
        )
    )
)

timeout /t 1 /nobreak >nul
rmdir /s /q "$installPath" >nul 2>&1

if exist "$installPath" (
    echo Some files locked, will be deleted on reboot
) else (
    echo Installation removed
)

echo.
echo Uninstall complete
echo.
pause
"@ | Out-File "$installPath\uninstall.bat" -Encoding ASCII

# Create startup shortcut
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut($startupShortcut)
$shortcut.TargetPath = "$env:WINDIR\System32\wscript.exe"
$shortcut.Arguments = "`"$installPath\dns-bibica-net-startup.vbs`""
$shortcut.WorkingDirectory = $installPath
$shortcut.Save()

# Start services
Write-Host "Starting services..." -ForegroundColor Gray
Start-Process "wscript.exe" -ArgumentList "`"$installPath\dns-bibica-net-startup.vbs`"" -WindowStyle Hidden
Start-Sleep -Seconds 3

# Configure DNS
Write-Host "Configuring system DNS..." -ForegroundColor Gray
$adapters = Get-AllAdapters
$configuredCount = 0
foreach ($adapter in $adapters) {
    try {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "127.0.0.1" -ErrorAction Stop
        $configuredCount++
    } catch {}
}

Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue

# Verify services
Start-Sleep -Seconds 2
$dnscryptRunning = Get-Process -Name "dnscrypt-proxy" -ErrorAction SilentlyContinue
$goodbyedpiRunning = Get-Process -Name "goodbyedpi" -ErrorAction SilentlyContinue

# Display result
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($dnscryptRunning -and $goodbyedpiRunning) {
    Write-Host "System DNS changed to:" -ForegroundColor White
    Write-Host "  127.0.0.1 (dns.bibica.net DoH + DPI bypass)" -ForegroundColor White
    Write-Host ""
    Write-Host "Services are running and will auto-start on boot" -ForegroundColor Green
} else {
    Write-Host "WARNING: Services failed to start" -ForegroundColor Red
    Write-Host "Please restart your computer" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Install location: $installPath" -ForegroundColor Gray
Write-Host "To uninstall: $installPath\uninstall.bat" -ForegroundColor Gray
Write-Host "  (Your original DNS settings will be restored)" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
