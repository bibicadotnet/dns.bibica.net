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
$nssmPath = "$installPath\nssm.exe"
$tempPath = "$env:TEMP\dnsproxy-setup"
$backupFile = "$installPath\dns-backup.txt"
$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = "$startupPath\dns-bibica-net.lnk"
$taskName = "dns-bibica-net-startup"
$dnsproxyServiceName = "dnsproxy-service"
$winwsServiceName = "winws-service"

Write-Host ""
Write-Host "dns.bibica.net DoH & DPI bypass - Auto Installer" -ForegroundColor Cyan
Write-Host ""

# ==================== Functions ====================

function Stop-AllServices {
    # Stop services if exist
    Get-Service -Name $dnsproxyServiceName -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    Get-Service -Name $winwsServiceName -ErrorAction SilentlyContinue | Stop-Service -Force -ErrorAction SilentlyContinue
    
    # Stop processes
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

function Wait-ServiceStarted {
    param([string[]]$ServiceNames, [int]$TimeoutSeconds = 10)
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $allRunning = $true
        foreach ($name in $ServiceNames) {
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            if (-not $service -or $service.Status -ne 'Running') {
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
        
        # Check if backup contains localhost DNS (corrupted backup)
        $hasLocalhost = $false
        foreach ($item in $backup) {
            if ($item.DNSv4 -match '127\.0\.0\.1') {
                $hasLocalhost = $true
                break
            }
        }
        
        # If backup has localhost, it's corrupted - don't restore
        if ($hasLocalhost) {
            Write-Host "  Backup contains localhost DNS (corrupted), using fallback DNS instead" -ForegroundColor Yellow
            return $false
        }
        
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
                $dnsServersV6 = $item.DNSv6 -split ','
                if ($item.DNSv6 -and $item.DNSv6 -ne '') {
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
    
    try {
        # Get latest commit info for zapret-winws folder
        $commitInfo = Invoke-RestMethod "https://api.github.com/repos/bol-van/zapret-win-bundle/commits?path=zapret-winws&per_page=1" -ErrorAction Stop
         $commitDate = if ($commitInfo[0].commit.author.date) { 
             $commitInfo[0].commit.author.date.Substring(0, 10) 
         } else { 
             "unknown" 
         }
        $commitHash = $commitInfo[0].sha.Substring(0, 7)
        Write-Host "  Build: $commitDate ($commitHash)" -ForegroundColor DarkGray
        
        $baseUrl = "https://raw.githubusercontent.com/bol-van/zapret-win-bundle/master/zapret-winws"
        $files = @("cygwin1.dll", "WinDivert.dll", "WinDivert64.sys", "winws.exe")
        
        foreach ($file in $files) {
            $url = "$baseUrl/$file"
            $destPath = "$zapretPath\$file"
            (New-Object System.Net.WebClient).DownloadFile($url, $destPath)
        }
    } catch {
        throw "Failed to download Zapret files: $_"
    }
}

function Download-NSSM {
    Write-Host "Downloading NSSM..." -ForegroundColor Gray
    
    try {
        $nssmZip = "$tempPath\nssm.zip"
        $nssmUrl = "https://load.bibica.net/nssm-2.24.zip"
        
        (New-Object System.Net.WebClient).DownloadFile($nssmUrl, $nssmZip)
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($nssmZip, "$tempPath\nssm-extract")
        
        # Get nssm.exe from win64 folder
        $nssmExe = Get-ChildItem -Path "$tempPath\nssm-extract" -Filter "nssm.exe" -Recurse | Where-Object { $_.FullName -like "*win64*" } | Select-Object -First 1
        
        if (-not $nssmExe) { throw "nssm.exe not found in package" }
        
        Copy-Item $nssmExe.FullName $nssmPath -Force
        Write-Host "  Version: 2.24" -ForegroundColor DarkGray
    } catch {
        throw "Failed to download NSSM: $_"
    }
}

function Remove-OldStartupMethods {
    # Remove old shortcut
    if (Test-Path $startupShortcut) {
        Write-Host "  Removing old startup shortcut..." -ForegroundColor Gray
        Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue
    }
    
    # Remove old scheduled task
    $taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskExists) {
        Write-Host "  Removing old scheduled task..." -ForegroundColor Gray
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Remove-OldServices {
    # Remove old services
    $servicesToRemove = @($dnsproxyServiceName, $winwsServiceName)
    
    foreach ($serviceName in $servicesToRemove) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            Write-Host "  Removing old service: $serviceName..." -ForegroundColor Gray
            
            if ($service.Status -eq 'Running') {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
            
            & $nssmPath remove $serviceName confirm 2>$null | Out-Null
            sc.exe delete $serviceName 2>$null | Out-Null
        }
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

# Corrected cleanup check
$taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
$needCleanup = (Test-Path $installPath) -or (Test-Path $startupShortcut) -or $taskExists -or (Get-Service -Name @($dnsproxyServiceName, $winwsServiceName) -ErrorAction SilentlyContinue) -or (Get-Process -Name @("dnsproxy", "winws") -ErrorAction SilentlyContinue)

if ($needCleanup) {
    Write-Host "Cleaning up previous installation..." -ForegroundColor Gray
}

Stop-AllServices
Remove-OldStartupMethods

Wait-ProcessStopped -ProcessNames @("dnsproxy", "winws") | Out-Null
Unload-WinDivertDriver
Start-Sleep -Milliseconds 500

if (Test-Path $installPath) {
    # Need to save NSSM before removal if exists
    $tempNSSM = "$env:TEMP\nssm-temp.exe"
    if (Test-Path $nssmPath) {
        Copy-Item $nssmPath $tempNSSM -Force -ErrorAction SilentlyContinue
    }
    
    # Remove old services using existing NSSM
    if (Test-Path $tempNSSM) {
        $servicesToRemove = @($dnsproxyServiceName, $winwsServiceName)
        foreach ($serviceName in $servicesToRemove) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service) {
                if ($service.Status -eq 'Running') {
                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                }
                & $tempNSSM remove $serviceName confirm 2>$null | Out-Null
                sc.exe delete $serviceName 2>$null | Out-Null
            }
        }
        Remove-Item $tempNSSM -Force -ErrorAction SilentlyContinue
    }
    
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
    # Download NSSM
    Download-NSSM
    
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
  - quic://dns.bibica.net
fallback:
  - h3://dns.bibica.net/dns-query
  - https://dns.bibica.net/dns-query
bootstrap:  
  - 1.1.1.1:53
  - 8.8.8.8:53
timeout: 1s
cache: false
"@ | Out-File "$dnsproxyPath\config.yaml" -Encoding UTF8

New-Item -ItemType File -Path "$dnsproxyPath\dnsproxy.log" -Force | Out-Null

# Create Zapret blacklist
@"
pornhub.com
www.pornhub.com
vn.linkedin.com
medium.com
bilibili.tv
www.bilibili.tv
www.bbc.com
bbc.com
www.bbc.co.uk
bbc.co.uk
steamcommunity.com
www.steamcommunity.com
steampowered.com
www.steampowered.com
store.steampowered.com
help.steampowered.com
rsload.net
www.xvideos.com
xvideos.com
nyaa.si
lrepacks.net
voa.gov
rfa.org
amnesty.org
pastebin.com
paste.ee
xnxx.com
xhamster.com
javhd.today
javhd.com
spankbang.com
xvideos2.com
xvideos3.com
javmost.com
beeg.com
sextop1.net
sextop1.sale
youporn.com
"@ | Out-File "$zapretPath\blacklist.txt" -Encoding UTF8

# VBS restart script (for manual restart after config changes)
@"
Set ws = CreateObject("WScript.Shell")

On Error Resume Next
ws.Run "net stop $winwsServiceName", 0, True
ws.Run "net stop $dnsproxyServiceName", 0, True
On Error GoTo 0

WScript.Sleep 500
ws.Run "ipconfig /flushdns", 0, True
WScript.Sleep 200

ws.Run "net start $winwsServiceName", 0, True
WScript.Sleep 300
ws.Run "net start $dnsproxyServiceName", 0, True
"@ | Out-File "$installPath\dns-bibica-net-restart.vbs" -Encoding ASCII

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

echo Stopping and removing services...
net stop $dnsproxyServiceName >nul 2>&1
net stop $winwsServiceName >nul 2>&1
timeout /t 1 /nobreak >nul

"$nssmPath" remove $dnsproxyServiceName confirm >nul 2>&1
"$nssmPath" remove $winwsServiceName confirm >nul 2>&1
sc delete $dnsproxyServiceName >nul 2>&1
sc delete $winwsServiceName >nul 2>&1

echo Stopping remaining processes...
taskkill /F /IM dnsproxy.exe >nul 2>&1
taskkill /F /IM winws.exe >nul 2>&1
timeout /t 2 /nobreak >nul

echo Unloading WinDivert driver...
for /f "tokens=2" %%s in ('sc query type^= driver ^| findstr /i "WinDivert"') do (
    sc stop %%s >nul 2>&1
    sc delete %%s >nul 2>&1
)
sc stop WinDivert >nul 2>&1
sc delete WinDivert >nul 2>&1
timeout /t 1 /nobreak >nul

echo Removing startup methods...
del "$startupShortcut" >nul 2>&1
schtasks /delete /tn "$taskName" /f >nul 2>&1

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

# ==================== Create Windows Services ====================

Write-Host "Creating Windows Services..." -ForegroundColor Gray

try {
    # Create winws service
    Write-Host "  Creating $winwsServiceName..." -ForegroundColor Gray
    & $nssmPath install $winwsServiceName "$zapretPath\winws.exe" 2>$null | Out-Null
    & $nssmPath set $winwsServiceName AppDirectory "$zapretPath" 2>$null | Out-Null
    & $nssmPath set $winwsServiceName AppParameters "--wf-tcp=80,443 --wf-udp=443 --hostlist=blacklist.txt --dpi-desync=fake,disorder2 --dpi-desync-fooling=badseq --dpi-desync-repeats=6" 2>$null | Out-Null
    & $nssmPath set $winwsServiceName DisplayName "Zapret WinWS DPI Bypass" 2>$null | Out-Null
    & $nssmPath set $winwsServiceName Description "DPI bypass service for blocked websites" 2>$null | Out-Null
    & $nssmPath set $winwsServiceName Start SERVICE_AUTO_START 2>$null | Out-Null
    
    # Set dependency to Tcpip for early startup
    sc.exe config $winwsServiceName depend= Tcpip 2>$null | Out-Null
    
    # Create dnsproxy service
    Write-Host "  Creating $dnsproxyServiceName..." -ForegroundColor Gray
    & $nssmPath install $dnsproxyServiceName "$dnsproxyPath\dnsproxy.exe" 2>$null | Out-Null
    & $nssmPath set $dnsproxyServiceName AppDirectory "$dnsproxyPath" 2>$null | Out-Null
    & $nssmPath set $dnsproxyServiceName AppParameters "--config-path=config.yaml --output=dnsproxy.log" 2>$null | Out-Null
    & $nssmPath set $dnsproxyServiceName DisplayName "DNSProxy DoH Service" 2>$null | Out-Null
    & $nssmPath set $dnsproxyServiceName Description "DNS over HTTPS proxy using dns.bibica.net" 2>$null | Out-Null
    & $nssmPath set $dnsproxyServiceName Start SERVICE_AUTO_START 2>$null | Out-Null
    
    # Set dependency to Tcpip and winws service
    sc.exe config $dnsproxyServiceName depend= Tcpip/$winwsServiceName 2>$null | Out-Null
    
    Write-Host "  Services created successfully" -ForegroundColor Green
    
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to create services: $_" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== StartServices ====================
Write-Host "Starting services..." -ForegroundColor Gray
try {
    Start-Service -Name $winwsServiceName -ErrorAction Stop
    Start-Sleep -Milliseconds 500
    Start-Service -Name $dnsproxyServiceName -ErrorAction Stop
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to start services: $_" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Verify Services ====================
Write-Host "Verifying services..." -ForegroundColor Gray
Start-Sleep -Seconds 3
$serviceStarted = Wait-ServiceStarted -ServiceNames @($dnsproxyServiceName, $winwsServiceName) -TimeoutSeconds 10

if (-not $serviceStarted) {
    Write-Host ""
    Write-Host "ERROR: Services failed to start" -ForegroundColor Red
    $dnsproxyService = Get-Service -Name $dnsproxyServiceName -ErrorAction SilentlyContinue
    $winwsService = Get-Service -Name $winwsServiceName -ErrorAction SilentlyContinue

    if ($dnsproxyService) {
        Write-Host "  $dnsproxyServiceName`: $($dnsproxyService.Status)" -ForegroundColor $(if($dnsproxyService.Status -eq 'Running'){'Yellow'}else{'Red'})
    } else {
        Write-Host "  $dnsproxyServiceName`: Not found" -ForegroundColor Red
    }

    if ($winwsService) {
        Write-Host "  $winwsServiceName`: $($winwsService.Status)" -ForegroundColor $(if($winwsService.Status -eq 'Running'){'Yellow'}else{'Red'})
    } else {
        Write-Host "  $winwsServiceName`: Not found" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow
    if (Restore-DNSFromBackup -BackupFilePath $backupFile) {
        Write-Host "DNS restored successfully" -ForegroundColor Green
    } else {
        Set-FallbackDNS
    }

    Write-Host ""
    Write-Host "Check log: $dnsproxyPath\dnsproxy.log" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to exit"
    exit
}

# ==================== Test DNS ====================
if (-not (Test-LocalDNS -TimeoutSeconds 5)) {
    Write-Host ""
    Write-Host "ERROR: DNS service not responding" -ForegroundColor Red
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow
    Stop-Service -Name $dnsproxyServiceName -Force -ErrorAction SilentlyContinue
    Stop-Service -Name $winwsServiceName -Force -ErrorAction SilentlyContinue

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

# ==================== Verify Performance ====================
Write-Host "Verifying CDN Vietnam Optimization..." -ForegroundColor Gray
Write-Host ""
function Get-UserLocation {
    try {
        $response = Invoke-RestMethod -Uri "https://ipinfo.io/json" -TimeoutSec 5 -ErrorAction Stop
        return @{
            IP = $response.ip
            City = $response.city
            Country = $response.country
            Org = $response.org
        }
    } catch {
        return $null
    }
}
function Get-IPLocation {
    param([string]$IP)
    try {
        $response = Invoke-RestMethod -Uri "https://ipinfo.io/$IP/json" -TimeoutSec 5 -ErrorAction Stop
        return @{
            City = $response.city
            Country = $response.country
            Org = $response.org
        }
    } catch {
        return $null
    }
}
$userLoc = Get-UserLocation
if ($userLoc) {
    Write-Host "Your Location: $($userLoc.City), $($userLoc.Country)" -ForegroundColor Cyan
    Write-Host "Your ISP: $($userLoc.Org)" -ForegroundColor Cyan
    Write-Host ""
}

$targets = @(
    @{ Name = "Tiktok.com";    Domain = "v16-webapp-prime.tiktok.com" }
    @{ Name = "Bilibili.com"; Domain = "upos-hz-mirrorakam.akamaized.net" }
    @{ Name = "Apple.com";     Domain = "www.apple.com" }
    @{ Name = "Amazon.com";     Domain = "www.amazon.com" }
    @{ Name = "Ebay.com";     Domain = "www.ebay.com" }
    @{ Name = "Douyin.com";    Domain = "v3-dy-o.zjcdn.com" }
    @{ Name = "Bilibili.tv";  Domain = "www.bilibili.tv" }
    @{ Name = "Shopee.vn";  Domain = "cf.shopee.vn" }
    @{ Name = "Lazada.vn";  Domain = "img.lazcdn.com" }
)
foreach ($t in $targets) {
    $pName = $t.Name.PadRight(15)
    try {
        $resolvedIP = [System.Net.Dns]::GetHostAddresses($t.Domain)[0].IPAddressToString
        $ping = Test-Connection -ComputerName $t.Domain -Count 1 -ErrorAction Stop
        $ms = $ping.ResponseTime
        
        $cdnLoc = Get-IPLocation -IP $resolvedIP
        
        $statusText = "($($ms)ms)"
        $locationInfo = if ($cdnLoc) { " ($($cdnLoc.City), $($cdnLoc.Org))" } else { "" }
        
        # Check both city and ISP match
        $cityMatch = $userLoc -and $cdnLoc -and $cdnLoc.City -eq $userLoc.City
        $ispMatch = $userLoc -and $cdnLoc -and $cdnLoc.Org -eq $userLoc.Org
        
        if ($cityMatch -and $ispMatch) {
            $color = "Green"  # Perfect: same city + same ISP
        } elseif ($cityMatch) {
            $color = "Cyan"   # Good: same city, different ISP
        } elseif ($ms -lt 10) {
            $color = "Yellow" # OK: low latency but different location
        } else {
            $color = "Red"    # Bad: different location + high latency
        }
        
        Write-Host "  $pName $statusText$locationInfo" -ForegroundColor $color
        
    } catch {
        Write-Host "  $pName Error" -ForegroundColor Red
    }
}

# ==================== Success ====================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "System DNS: 127.0.0.1 (dns.bibica.net DoH + Zapret DPI bypass)" -ForegroundColor White
Write-Host "Services: Running and will auto-start on boot" -ForegroundColor Green
Write-Host ""
Write-Host "Install location: $installPath" -ForegroundColor Gray
Write-Host "To restart services: $installPath\dns-bibica-net-restart.vbs" -ForegroundColor Gray
Write-Host "To uninstall: $installPath\uninstall.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
