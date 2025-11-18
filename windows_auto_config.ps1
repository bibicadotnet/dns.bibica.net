# Check admin rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
   Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://go.bibica.net/dns-bibica-net | iex`"" -Verb RunAs
   exit
}
Clear-Host

# Configuration
$installPath = "C:\dns-bibica-net-doh"
$dnsproxyPath = "$installPath\dnsproxy"
$goodbyedpiPath = "$installPath\GoodbyeDPI"
$tempPath = "$env:TEMP\dnsproxy-setup"
$backupFile = "$installPath\dns-backup.txt"
$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = "$startupPath\dns-bibica-net.lnk"

Write-Host "dns.bibica.net DoH & DPI bypass - Auto Installer" -ForegroundColor Cyan
Write-Host ""

# ==================== Functions ====================

function Stop-AllServices {
    @("dnsproxy", "goodbyedpi") | ForEach-Object {
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

# ==================== Check Existing Installation ====================

$isReinstall = Test-Path $installPath

if ($isReinstall) {
    Write-Host "Found existing installation, restoring DNS..." -ForegroundColor Gray
    
    # Thử restore từ backup file
    $dnsRestored = $false
    if (Test-Path $backupFile) {
        try {
            $existingBackup = Import-Csv -Path $backupFile -Encoding UTF8
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
            $dnsRestored = $true
            Write-Host "  DNS restored from backup" -ForegroundColor Green
        } catch {
            Write-Host "  WARNING: Could not restore DNS from backup file" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  WARNING: Backup file not found" -ForegroundColor Yellow
    }
    
    # Nếu không restore được, set DNS fallback
    if (-not $dnsRestored) {
        Set-FallbackDNS
    }
}

# ==================== Complete Cleanup ====================

$needCleanup = (Test-Path $installPath) -or (Test-Path $startupShortcut) -or (Get-Process -Name @("dnsproxy", "goodbyedpi") -ErrorAction SilentlyContinue)

if ($needCleanup) {
    Write-Host "Cleaning up previous installation..." -ForegroundColor Gray
}

Stop-AllServices
if (Test-Path $startupShortcut) { Remove-Item $startupShortcut -Force -ErrorAction SilentlyContinue }

Wait-ProcessStopped -ProcessNames @("dnsproxy", "goodbyedpi") | Out-Null
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
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    $dnsString = if ($null -eq $dnsServers -or $dnsServers.Count -eq 0) { "DHCP" } else { ($dnsServers -join ",") }
    $dnsBackup += [PSCustomObject]@{
        Name = $adapter.Name
        InterfaceIndex = $adapter.ifIndex
        DNS = $dnsString
    }
}

# ==================== Prepare Directories ====================

if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $dnsproxyPath -Force | Out-Null
New-Item -ItemType Directory -Path $goodbyedpiPath -Force | Out-Null
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
    
    # Download GoodbyeDPI
    $goodbyedpiTemp = Download-GitHubRelease `
        -Repo "ValdikSS/GoodbyeDPI" `
        -AssetPattern "*.zip" `
        -DestPath $tempPath `
        -DisplayName "GoodbyeDPI" `
        -IncludePreRelease
    
    $goodbyeExe = Get-ChildItem -Path $goodbyedpiTemp -Filter "goodbyedpi.exe" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    $winDivertDll = Get-ChildItem -Path $goodbyedpiTemp -Filter "WinDivert.dll" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    $winDivertSys = Get-ChildItem -Path $goodbyedpiTemp -Filter "WinDivert64.sys" -Recurse | Where-Object { $_.Directory.Name -eq "x86_64" } | Select-Object -First 1
    
    if (-not $goodbyeExe -or -not $winDivertDll -or -not $winDivertSys) {
        throw "GoodbyeDPI files not found"
    }
    
    Copy-Item $goodbyeExe.FullName "$goodbyedpiPath\goodbyedpi.exe" -Force
    Copy-Item $winDivertDll.FullName "$goodbyedpiPath\WinDivert.dll" -Force
    Copy-Item $winDivertSys.FullName "$goodbyedpiPath\WinDivert64.sys" -Force
    
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

# Create GoodbyeDPI blacklist
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
"@ | Out-File "$goodbyedpiPath\blacklist.txt" -Encoding UTF8

# VBS startup launcher
@"
Set ws = CreateObject("WScript.Shell")
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")

On Error Resume Next
Set colProcesses = objWMIService.ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'dnsproxy.exe' OR Name = 'goodbyedpi.exe'")
For Each objProcess in colProcesses
    objProcess.Terminate()
Next
On Error GoTo 0

WScript.Sleep 1000

ws.CurrentDirectory = "$goodbyedpiPath"
ws.Run "goodbyedpi.exe -9 --blacklist blacklist.txt", 0, False

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
taskkill /F /IM goodbyedpi.exe >nul 2>&1
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
    powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Import-Csv '$backupFile' -Encoding UTF8 | ForEach-Object { try { `$dns = `$_.DNS -split ','; if (`$dns[0] -eq 'DHCP' -or `$dns[0] -eq '') { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; Write-Host '  ' `$_.Name ': DHCP' } else { Set-DnsClientServerAddress -InterfaceIndex `$_.InterfaceIndex -ServerAddresses `$dns -ErrorAction Stop; Write-Host '  ' `$_.Name ': ' (`$dns -join ', ') } } catch {} } } catch { Write-Host '  Backup file error, setting fallback DNS...' -ForegroundColor Yellow; Get-NetAdapter | Where-Object { `$_.InterfaceDescription -notlike '*Loopback*' } | ForEach-Object { try { Set-DnsClientServerAddress -InterfaceIndex `$_.ifIndex -ServerAddresses @('8.8.8.8', '1.1.1.1') -ErrorAction Stop; Write-Host '  ' `$_.Name ': 8.8.8.8, 1.1.1.1' } catch {} } }"
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

# ==================== Start Services ====================

Write-Host "Starting services..." -ForegroundColor Gray
Start-Process "wscript.exe" -ArgumentList "`"$installPath\dns-bibica-net-startup.vbs`"" -WindowStyle Hidden

# ==================== Verify Services ====================

Write-Host "Verifying services..." -ForegroundColor Gray
if (-not (Wait-ProcessStarted -ProcessNames @("dnsproxy", "goodbyedpi") -TimeoutSeconds 5)) {
    Write-Host ""
    Write-Host "ERROR: Services failed to start" -ForegroundColor Red
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow

    if (Test-Path $backupFile) {
        try {
            $backup = Import-Csv -Path $backupFile -Encoding UTF8
            foreach ($item in $backup) {
                try {
                    $dnsServers = $item.DNS -split ','
                    if ($dnsServers[0] -eq 'DHCP' -or $dnsServers[0] -eq '') {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction Stop
                    }
                } catch {}
            }
            Write-Host "DNS restored successfully" -ForegroundColor Green
        } catch {
            Set-FallbackDNS
        }
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

#Write-Host "Testing DNS service..." -ForegroundColor Gray
if (-not (Test-LocalDNS -TimeoutSeconds 5)) {
    Write-Host ""
    Write-Host "ERROR: DNS service not responding" -ForegroundColor Red
    Write-Host "Restoring DNS settings..." -ForegroundColor Yellow
    
    Stop-AllServices

    if (Test-Path $backupFile) {
        try {
            $backup = Import-Csv -Path $backupFile -Encoding UTF8
            foreach ($item in $backup) {
                try {
                    $dnsServers = $item.DNS -split ','
                    if ($dnsServers[0] -eq 'DHCP' -or $dnsServers[0] -eq '') {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
                    } else {
                        Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction Stop
                    }
                } catch {}
            }
            Write-Host "DNS restored successfully" -ForegroundColor Green
        } catch {
            Set-FallbackDNS
        }
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
    try {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "127.0.0.1" -ErrorAction Stop
    } catch {}
}

# ==================== Success ====================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "System DNS: 127.0.0.1 (dns.bibica.net DoH + DPI bypass)" -ForegroundColor White
Write-Host "Services: Running and auto-start enabled" -ForegroundColor Green
Write-Host ""
Write-Host "Install location: $installPath" -ForegroundColor Gray
Write-Host "To uninstall: $installPath\uninstall.bat" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
