# Check admin rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
   Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://go.bibica.net/dns-bibica-net | iex`"" -Verb RunAs
   exit
}
Clear-Host

# Configuration
$installPath = "C:\dns-bibica-net-doh"
$dnsproxyPath = "$installPath\dnsproxy"
$zapretPath = "$installPath\zapret"
$tempPath = "$env:TEMP\dnsproxy-setup"
$backupFile = "$installPath\dns-backup.txt"
$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = "$startupPath\dns-bibica-net.lnk"

Write-Host "dns.bibica.net DoH & DPI bypass - Auto Installer" -ForegroundColor Cyan
Write-Host ""

# ==================== Functions ====================

function Stop-AllServices {
    @("dnsproxy", "winws", "goodbyedpi") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Get-WmiObject Win32_Process | Where-Object {
        $_.Name -eq "wscript.exe" -and $_.CommandLine -like "*dns-bibica-net-startup.vbs*"
    } | ForEach-Object { $_.Terminate() }
}

function Wait-ProcessStopped {
    param([string[]]$ProcessNames, [int]$TimeoutSeconds = 3)
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $running = Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue
        if (-not $running) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}

function Wait-ProcessStarted {
    param([string[]]$ProcessNames, [int]$TimeoutSeconds = 5)
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $allRunning = $true
        foreach ($name in $ProcessNames) {
            if (-not (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
                $allRunning = $false
                break
            }
        }
        if ($allRunning) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return $false
}

function Test-LocalDNS {
    param([int]$TimeoutSeconds = 5)
    
    try {
        $result = Resolve-DnsName -Name "google.com" -Server "127.0.0.1" -DnsOnly -ErrorAction Stop -QuickTimeout
        return ($null -ne $result)
    } catch {
        return $false
    }
}

function Unload-WinDivertDriver {
    Get-Service -Name "WinDivert*" -ErrorAction SilentlyContinue | ForEach-Object {
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>$null | Out-Null
    }
    sc.exe stop WinDivert 2>$null | Out-Null
    sc.exe delete WinDivert 2>$null | Out-Null
}

function Get-AllAdapters {
    Get-NetAdapter | Where-Object { $_.InterfaceDescription -notlike "*Loopback*" }
}

function Set-FallbackDNS {
    Write-Host "  Setting fallback DNS (Google 8.8.8.8 & Cloudflare 1.1.1.1)..." -ForegroundColor Yellow
    $adapters = Get-AllAdapters
    foreach ($adapter in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("8.8.8.8", "1.1.1.1") -ErrorAction Stop
        } catch {}
    }
}

function Restore-DNSFromBackup {
    param([string]$BackupFilePath)
    
    if (-not (Test-Path $BackupFilePath)) {
        return $false
    }
    
    try {
        $backup = Import-Csv -Path $BackupFilePath -Encoding UTF8
        foreach ($item in $backup) {
            try {
                # Restore IPv4
                $dnsServersV4 = $item.DNSv4 -split ','
                if ($dnsServersV4[0] -eq 'DHCP' -or $dnsServersV4[0] -eq '') {
                    Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                } else {
                    Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $dnsServersV4 -ErrorAction Stop
                }
                
                # Restore IPv6
                if ($item.DNSv6 -and $item.DNSv6 -ne '') {
                    $dnsServersV6 = $item.DNSv6 -split ','
                    if ($dnsServersV6[0] -eq 'DHCP' -or $dnsServersV6[0] -eq '') {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -AddressFamily IPv6 -ResetServerAddresses -ErrorAction SilentlyContinue
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -AddressFamily IPv6 -ServerAddresses $dnsServersV6 -ErrorAction SilentlyContinue
                    }
                }
            } catch {}
        }
        return $true
    } catch {
        return $false
    }
}

function Download-GitHubRelease {
    param(
        [string]$Repo,
        [string]$AssetPattern,
        [string]$DestPath,
        [string]$DisplayName,
        [switch]$IncludePreRelease
    )
    
    Write-Host "Downloading $DisplayName..." -ForegroundColor Gray
    try {
        if ($IncludePreRelease) {
            $releases = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases" -ErrorAction Stop
            $release = $releases | Select-Object -First 1
            Write-Host "  Version: $($release.tag_name) $(if($release.prerelease){'(Pre-release)'})" -ForegroundColor DarkGray
        } else {
            $release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/latest" -ErrorAction Stop
            Write-Host "  Version: $($release.tag_name)" -ForegroundColor DarkGray
        }
        
        $asset = $release.assets | Where-Object { $_.name -like $AssetPattern } | Select-Object -First 1
        if (-not $asset) { throw "Asset not found: $AssetPattern" }
        
        $zipPath = "$tempPath\$DisplayName.zip"
        (New-Object System.Net.WebClient).DownloadFile($asset.browser_download_url, $zipPath)
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, "$tempPath\$DisplayName")
        
        return "$tempPath\$DisplayName"
    } catch {
        throw "Failed to download $DisplayName`: $_"
    }
}

function Download-ZapretFiles {
    Write-Host "Downloading Zapret..." -ForegroundColor Gray
    
    $baseUrl = "https://raw.githubusercontent.com/bol-van/zapret-win-bundle/master/zapret-winws"
    $files = @("cygwin1.dll", "WinDivert.dll", "WinDivert64.sys", "winws.exe")
    
    try {
        foreach ($file in $files) {
            $url = "$baseUrl/$file"
            $destPath = "$zapretPath\$file"
            (New-Object System.Net.WebClient).DownloadFile($url, $destPath)
        }
    } catch {
        throw "Failed to download Zapret files: $_"
    }
}

# ==================== Check Existing Installation ====================

$isReinstall = Test-Path $installPath

if ($isReinstall) {
    Write-Host "Found existing installation, restoring DNS..." -ForegroundColor Gray
    
    if (Restore-DNSFromBackup -BackupFilePath $backupFile) {
        Write-Host "  DNS restored from backup (IPv4 & IPv6)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Could not restore DNS from backup file" -ForegroundColor Yellow
        Set-FallbackDNS
    }
}

# ==================== Complete Cleanup ====================

$needCleanup = (Test-Path $installPath) -or (Test-Path $startupShortcut) -or (Get-Process -Name @("dnsproxy", "winws") -ErrorAction SilentlyContinue)

if ($needCleanup) {
    Write-Host "Cleaning up previous installation..." -ForegroundColor Gray
}

Stop-AllServices
if (Test-Path $startupShortcut) { Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue }

Wait-ProcessStopped -ProcessNames @("dnsproxy", "winws") | Out-Null
Unload-WinDivertDriver
Start-Sleep -Milliseconds 500

if (Test-Path $installPath) {
    Remove-Item $installPath -Recurse -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    
    if (Test-Path $installPath) {
        Start-Sleep -Seconds 1
        Remove-Item $installPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    if (Test-Path $installPath) {
        Write-Host ""
        Write-Host "ERROR: Cannot remove existing installation" -ForegroundColor Red
        Write-Host "WinDivert driver may be locked. Please restart your computer and run installer again." -ForegroundColor Yellow
        Write-Host ""
        Read-Host "Press Enter to exit"
        exit
    }
}

# ==================== Backup Current DNS ====================

Write-Host "Backing up current DNS settings..." -ForegroundColor Gray
$dnsBackup = @()
$adapters = Get-AllAdapters
foreach ($adapter in $adapters) {
    # Backup IPv4 DNS
    $dnsServersV4 = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $dnsStringV4 = if ($null -eq $dnsServersV4 -or $dnsServersV4.Count -eq 0) { "DHCP" } else { ($dnsServersV4 -join ",") }
    
    # Backup IPv6 DNS
    $dnsServersV6 = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv6 -ErrorAction SilentlyContinue).ServerAddresses
    $dnsStringV6 = if ($null -eq $dnsServersV6 -or $dnsServersV6.Count -eq 0) { "DHCP" } else { ($dnsServersV6 -join ",") }
    
    $dnsBackup += [PSCustomObject]@{
        Name = $adapter.Name
        InterfaceIndex = $adapter.ifIndex
        DNSv4 = $dnsStringV4
        DNSv6 = $dnsStringV6
    }
}

# ==================== Prepare Directories ====================

if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $dnsproxyPath -Force | Out-Null
New-Item -ItemType Directory -Path $zapretPath -Force | Out-Null
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

# Save DNS backup
$dnsBackup | Export-Csv -Path $backupFile -NoTypeInformation -Encoding UTF8

# ==================== Download Components ====================

try {
    # Download DNSProxy
    $dnsproxyTemp = Download-GitHubRelease `
        -Repo "AdguardTeam/dnsproxy" `
        -AssetPattern "dnsproxy-windows-amd64-*.zip" `
        -DestPath $tempPath `
        -DisplayName "DNSProxy"
    
    $exePath = Get-ChildItem -Path $dnsproxyTemp -Filter "dnsproxy.exe" -Recurse | Select-Object -First 1
    if (-not $exePath) { throw "dnsproxy.exe not found" }
    Copy-Item $exePath.FullName "$dnsproxyPath\dnsproxy.exe" -Force
    
    # Download Zapret files
    Download-ZapretFiles
    
} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Create Config Files ====================

@"
listen-addrs:
  - 127.0.0.1
listen-ports:
  - 53
upstream:
  - https://dns.bibica.net/dns-query
bootstrap:
  - 1.1.1.1:53
  - 8.8.8.8:53
cache: true
cache-size: 134217728
cache-optimistic: true
"@ | Out-File "$dnsproxyPath\config.yaml" -Encoding UTF8

New-Item -ItemType File -Path "$dnsproxyPath\dnsproxy.log" -Force | Out-Null

# Create Zapret blacklist
@"
pornhub.com
www.pornhub.com
rsload.net
vn.linkedin.com
medium.com
steamcommunity.com
bilibili.tv
www.bilibili.tv
www.bbc.com
bbc.com
www.bbc.co.uk
bbc.co.uk
www.xvideos.com
xvideos.com
nyaa.si
"@ | Out-File "$zapretPath\blacklist.txt" -Encoding UTF8

# VBS startup launcher
@"
Set ws = CreateObject("WScript.Shell")
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")

On Error Resume Next
Set colProcesses = objWMIService.ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'dnsproxy.exe' OR Name = 'winws.exe'")
For Each objProcess in colProcesses
    objProcess.Terminate()
Next
On Error GoTo 0

WScript.Sleep 1000

ws.CurrentDirectory = "$zapretPath"
ws.Run "winws.exe --wf-tcp=80,443 --wf-udp=443 --hostlist=blacklist.txt --dpi-desync=fake,disorder2 --dpi-desync-fooling=md5sig,badseq --dpi-desync-repeats=6", 0, False

WScript.Sleep 2000

ws.CurrentDirectory = "$dnsproxyPath"
ws.Run "dnsproxy.exe --config-path=config.yaml --output=dnsproxy.log", 0, False
"@ | Out-File "$installPath\dns-bibica-net-startup.vbs" -Encoding ASCII

# Uninstall script
@"
@echo off
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
cls
echo dns-bibica-net uninstaller
echo.

echo Stopping services...
taskkill /F /IM dnsproxy.exe >nul 2>&1
taskkill /F /IM winws.exe >nul 2>&1
for /f "tokens=2" %%a in ('wmic process where "name='wscript.exe' and commandline like '%%dns-bibica-net-startup.vbs%%'" get processid 2^>nul ^| findstr /r "[0-9]"') do taskkill /F /PID %%a >nul 2>&1
timeout /t 2 /nobreak >nul

echo Unloading WinDivert driver...
for /f "tokens=2" %%s in ('sc query type^= driver ^| findstr /i "WinDivert"') do (
    sc stop %%s >nul 2>&1
    sc delete %%s >nul 2>&1
)
sc stop WinDivert >nul 2>&1
sc delete WinDivert >nul 2>&1
timeout /t 1 /nobreak >nul

echo Removing startup...
del "$startupShortcut" >nul 2>&1

echo Restoring DNS...
if exist "$backupFile" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Import-Csv '$backupFile' -Encoding UTF8 | ForEach-Object { try { `$dnsV4 = `$_.DNSv4 -split ','; if (`$dnsV4[0] -eq 'DHCP' -or `$dnsV4[0] -eq '') { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; Write-Host '  ' `$_.Name ' (IPv4): DHCP' } else { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -ServerAddresses `$dnsV4 -ErrorAction Stop; Write-Host '  ' `$_.Name ' (IPv4): ' (`$dnsV4 -join ', ') }; if (`$_.DNSv6 -and `$_.DNSv6 -ne '') { `$dnsV6 = `$_.DNSv6 -split ','; if (`$dnsV6[0] -eq 'DHCP' -or `$dnsV6[0] -eq '') { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -AddressFamily IPv6 -ResetServerAddresses -ErrorAction SilentlyContinue; Write-Host '  ' `$_.Name ' (IPv6): DHCP' } else { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -AddressFamily IPv6 -ServerAddresses `$dnsV6 -ErrorAction SilentlyContinue; Write-Host '  ' `$_.Name ' (IPv6): ' (`$dnsV6 -join ', ') } } } catch {} } } catch { Write-Host '  Backup file error, setting fallback DNS...' -ForegroundColor Yellow; Get-NetAdapter | Where-Object { `$_.InterfaceDescription -notlike '*Loopback*' } | ForEach-Object { try { Set-DnsClientServerAddress -InterfaceIndex `$_.ifIndex -ServerAddresses @('8.8.8.8', '1.1.1.1') -ErrorAction Stop; Write-Host '  ' `$_.Name ': 8.8.8.8, 1.1.1.1' } catch {} } }"
) else (
    echo   No backup file found, setting fallback DNS...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetAdapter | Where-Object { `$_.InterfaceDescription -notlike '*Loopback*' } | ForEach-Object { try { Set-DnsClientServerAddress -InterfaceIndex `$_.ifIndex -ServerAddresses @('8.8.8.8', '1.1.1.1') -ErrorAction Stop; Write-Host '  ' `$_.Name ': 8.8.8.8, 1.1.1.1' } catch {} }"
)

echo.
echo Removing files...
cd /d "%TEMP%"
rmdir /s /q "$installPath" >nul 2>&1

if exist "$installPath" (
    echo   Some files locked, will be deleted on reboot
) else (
    echo   Installation removed
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

Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue

# ==================== Ensure hosts file exists ====================

$hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
if (-not (Test-Path $hostsPath)) {
    Write-Host "Hosts file not found, creating default..." -ForegroundColor Yellow
    try {
        $defaultHosts = @"
# Copyright (c) 1993-2009 Microsoft Corp.
#
# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.
#
# This file contains the mappings of IP addresses to host names. Each
# entry should be kept on an individual line. The IP address should
# be placed in the first column followed by the corresponding host name.
# The IP address and the host name should be separated by at least one
# space.
#
# Additionally, comments (such as these) may be inserted on individual
# lines or following the machine name denoted by a '#' symbol.
#
# For example:
#
#      102.54.94.97     rhino.acme.com          # source server
#       38.25.63.10     x.acme.com              # x client host

# localhost name resolution is handled within DNS itself.
#	127.0.0.1       localhost
#	::1             localhost
"@
        $defaultHosts | Out-File $hostsPath -Encoding ASCII -Force
        Write-Host "  Hosts file created successfully" -ForegroundColor Green
    } catch {
        Write-Host "  WARNING: Could not create hosts file: $_" -ForegroundColor Yellow
    }
}

# ==================== Start Services ====================

Write-Host "Starting services..." -ForegroundColor Gray
Start-Process "wscript.exe" -ArgumentList "`"$installPath\dns-bibica-net-startup.vbs`"" -WindowStyle Hidden

# ==================== Verify Services ====================

Write-Host "Verifying services..." -ForegroundColor Gray
if (-not (Wait-ProcessStarted -ProcessNames @("dnsproxy", "winws") -TimeoutSeconds 5)) {
    Write-Host ""
    Write-Host "ERROR: Services failed to start" -ForegroundColor Red
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow

    if (Restore-DNSFromBackup -BackupFilePath $backupFile) {
        Write-Host "DNS restored successfully" -ForegroundColor Green
    } else {
        Set-FallbackDNS
    }
    
    Write-Host ""
    Write-Host "Please check logs at: $dnsproxyPath\dnsproxy.log" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Test DNS ====================

if (-not (Test-LocalDNS -TimeoutSeconds 5)) {
    Write-Host ""
    Write-Host "ERROR: DNS service not responding" -ForegroundColor Red
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow
    
    Stop-AllServices

    if (Restore-DNSFromBackup -BackupFilePath $backupFile) {
        Write-Host "DNS restored successfully" -ForegroundColor Green
    } else {
        Set-FallbackDNS
    }
    
    Write-Host ""
    Write-Host "Services are running but DNS queries fail" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Configure System DNS ====================

Write-Host "Configuring system DNS..." -ForegroundColor Gray
$adapters = Get-AllAdapters
foreach ($adapter in $adapters) {
    $adapterName = $adapter.Name
    $ifIndex = $adapter.ifIndex
    
    try {
        # Set IPv4 DNS to 127.0.0.1
        Set-DnsClientServerAddress -InterfaceIndex $ifIndex -ServerAddresses "127.0.0.1" -ErrorAction Stop
        netsh interface ipv6 delete dnsserver name="$adapterName" all 2>$null | Out-Null
        netsh interface ipv6 delete dnsserver interface=$ifIndex all 2>$null | Out-Null
    } catch {
        Write-Host "  WARNING: Could not configure DNS for $adapterName" -ForegroundColor Yellow
    }
}

# ==================== Flush DNS Cache ====================

Write-Host "Flushing DNS cache..." -ForegroundColor Gray
try {
    Clear-DnsClientCache -ErrorAction Stop
    ipconfig /flushdns | Out-Null
} catch {
    Write-Host "  WARNING: Could not flush DNS cache: $_" -ForegroundColor Yellow
}

# ==================== Success ====================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "System DNS: 127.0.0.1 (dns.bibica.net DoH + Zapret DPI bypass)" -ForegroundColor White
Write-Host "Services: Running and auto-start enabled" -ForegroundColor Green
Write-Host ""
Write-Host "Install location: $installPath" -ForegroundColor Gray
Write-Host "To uninstall: $installPath\uninstall.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
