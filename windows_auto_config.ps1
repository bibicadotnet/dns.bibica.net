# Check admin rights
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
   Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -Command `"irm https://go.bibica.net/dns-bibica-net | iex`"" -Verb RunAs
   exit
}
Clear-Host

# Configuration
$installPath = "C:\dns-bibica-net-doh"
$tempPath = "$env:TEMP\dnscrypt-setup"
$startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$shortcutPath = Join-Path $startupPath "dnscrypt-proxy.lnk"
$backupFile = "$installPath\dns-backup.txt"
$tempBackupFile = "$env:TEMP\dns-backup-temp.txt"

Write-Host "Installing DNSCrypt-Proxy..." -ForegroundColor Cyan

# === Get ALL adapters (including Disconnected), but exclude Loopback ===
function Get-AllAdapters {
    Get-NetAdapter | Where-Object {
        $_.InterfaceDescription -notlike "*Loopback*"
    }
}

# Check if already installed and backup exists
$existingBackup = $null
$isReinstall = $false
if (Test-Path $backupFile) {
    $isReinstall = $true
    $existingBackup = Import-Csv -Path $backupFile -Encoding UTF8
    Copy-Item $backupFile $tempBackupFile -Force
    Write-Host "Restoring DNS to original settings..." -ForegroundColor Yellow
    foreach ($item in $existingBackup) {
        try {
            $dnsServers = $item.DNS -split ','
            if ($dnsServers[0] -eq 'DHCP' -or $dnsServers[0] -eq '') {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
            } else {
                Set-DnsClientServerAddress -InterfaceIndex $item.InterfaceIndex -ServerAddresses $dnsServers -ErrorAction Stop
            }
        } catch {
            # Silent fail
        }
    }
    Start-Sleep -Seconds 1
}

# Backup current DNS settings for ALL adapters (even Disconnected)
if (-not $isReinstall) {
    Write-Host "Backing up DNS for all network adapters (including disconnected)..." -ForegroundColor Green
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
        Write-Host "  Backed up: $($adapter.Name) ($($adapter.Status))" -ForegroundColor Gray
    }
    $dnsBackup | Export-Csv -Path $tempBackupFile -NoTypeInformation -Encoding UTF8
}

# Cleanup previous installation
Get-Process -Name "dnscrypt-proxy" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-WmiObject Win32_Process | Where-Object {$_.Name -eq "wscript.exe" -and $_.CommandLine -like "*dnscrypt-proxy.vbs*"} | ForEach-Object {$_.Terminate()}
Start-Sleep -Seconds 1

if (Test-Path $shortcutPath) { Remove-Item $shortcutPath -Force }
if (Test-Path $installPath) {
    $retryCount = 0
    $maxRetries = 5
    $removed = $false
    while (-not $removed -and $retryCount -lt $maxRetries) {
        try {
            Remove-Item $installPath -Recurse -Force -ErrorAction Stop
            $removed = $true
        } catch {
            $retryCount++
            if ($retryCount -ge $maxRetries) {
                Write-Host "WARNING: Could not remove old installation completely, will overwrite..." -ForegroundColor Yellow
            }
            Start-Sleep -Seconds 1
        }
    }
}
if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Path $installPath -Force | Out-Null
New-Item -ItemType Directory -Path $tempPath -Force | Out-Null
Move-Item $tempBackupFile $backupFile -Force

# Download latest release
Write-Host "Downloading latest release..." -ForegroundColor Green
try {
    $release = Invoke-RestMethod "https://api.github.com/repos/DNSCrypt/dnscrypt-proxy/releases/latest" -ErrorAction Stop
    $asset = $release.assets | Where-Object { $_.name -like "dnscrypt-proxy-win64-*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "Cannot find Windows 64-bit release" }
    $zipPath = "$tempPath\dnscrypt.zip"
    (New-Object System.Net.WebClient).DownloadFile($asset.browser_download_url, $zipPath)
} catch {
    Write-Host "ERROR: Failed to download dnscrypt-proxy!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "`nPlease check your internet connection and try again." -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}

# Extract
try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $tempPath)
} catch {
    Write-Host "ERROR: Failed to extract files!" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit
}

$exePath = Get-ChildItem -Path $tempPath -Filter "dnscrypt-proxy.exe" -Recurse | Select-Object -First 1
if (-not $exePath) {
    Write-Host "ERROR: Cannot find dnscrypt-proxy.exe in extracted files!" -ForegroundColor Red
    Write-Host "Extracted to: $tempPath" -ForegroundColor Yellow
    Read-Host "Press Enter to exit"
    exit
}
Copy-Item $exePath.FullName "$installPath\dnscrypt-proxy.exe" -Force

# Create config file
@"
listen_addresses = ['127.0.0.1:53']
server_names = ['dns-bibica-net']
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
odoh_servers = false
require_nolog = true
require_nofilter = true
require_dnssec = false
timeout = 5000
keepalive = 30
http3 = true
http3_probe = true
cache = false
log_level = 6
bootstrap_resolvers = ['1.1.1.1:53']
ignore_system_dns = true
netprobe_timeout = 30
netprobe_address = '1.1.1.1:53'
#edns_client_subnet = ['103.186.65.0/24', '38.60.253.0/24', '38.54.117.0/24']
[static]
  [static.dns-bibica-net]
  stamp = 'sdns://AgAAAAAAAAAAAAAOZG5zLmJpYmljYS5uZXQKL2Rucy1xdWVyeQ'
[sources]
"@ | Out-File "$installPath\dnscrypt-proxy.toml" -Encoding UTF8

# Create VBS launcher
@"
Set ws = CreateObject("WScript.Shell")
Set objWMIService = GetObject("winmgmts:\\.\root\cimv2")
On Error Resume Next
Set colProcesses = objWMIService.ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'dnscrypt-proxy.exe'")
For Each objProcess in colProcesses
    objProcess.Terminate()
Next
On Error GoTo 0
WScript.Sleep 1000
ws.CurrentDirectory = "$installPath"
ws.Run "dnscrypt-proxy.exe", 0, False
"@ | Out-File "$installPath\dnscrypt-proxy.vbs" -Encoding ASCII

# Create uninstall.bat
@"
@echo off
echo Uninstalling DNSCrypt-Proxy...
echo.
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Requires administrator privileges. Restarting...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)
taskkill /F /IM dnscrypt-proxy.exe 2>nul
for /f "tokens=2" %%a in ('wmic process where "name='wscript.exe' and commandline like '%%dnscrypt-proxy.vbs%%'" get processid ^| findstr /r "[0-9]"') do taskkill /F /PID %%a 2>nul
timeout /t 2 /nobreak >nul
del "$shortcutPath" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
"`$backup = Import-Csv '$backupFile' -Encoding UTF8; ^
foreach (`$item in `$backup) { ^
    try { ^
        `$dnsServers = `$item.DNS -split ','; ^
        if (`$dnsServers[0] -eq 'DHCP' -or `$dnsServers[0] -eq '') { ^
            Set-DnsClientServerAddress -InterfaceIndex `$item.InterfaceIndex -ResetServerAddresses -ErrorAction Stop; ^
            Write-Host '  Restored: ' `$item.Name ' (DHCP)'; ^
        } else { ^
            Set-DnsClientServerAddress -InterfaceIndex `$item.InterfaceIndex -ServerAddresses `$dnsServers -ErrorAction Stop; ^
            Write-Host '  Restored: ' `$item.Name ' - DNS: ' (`$dnsServers -join ', '); ^
        } ^
    } catch { ^
        Write-Host '  Failed: ' `$item.Name; ^
    } ^
}"
echo.
echo DNSCrypt-Proxy has been uninstalled.
echo DNS settings have been restored to original configuration.
echo.
cd /d "%TEMP%"
timeout /t 2 /nobreak >nul
rmdir /s /q "$installPath" 2>nul
exit
"@ | Out-File "$installPath\uninstall.bat" -Encoding ASCII

# Create startup shortcut
$WshShell = New-Object -ComObject WScript.Shell
$shortcut = $WshShell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$env:WINDIR\System32\wscript.exe"
$shortcut.Arguments = "`"$installPath\dnscrypt-proxy.vbs`""
$shortcut.WorkingDirectory = $installPath
$shortcut.Save()

# Start service
Write-Host "Starting DNSCrypt-Proxy..." -ForegroundColor Green
Start-Process $shortcutPath
Start-Sleep -Seconds 2

# Configure DNS on ALL adapters (including Disconnected)
Write-Host "Configuring system DNS on all adapters..." -ForegroundColor Green
$adapters = Get-AllAdapters
$updatedAdapters = @()
foreach ($adapter in $adapters) {
    try {
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses "127.0.0.1", "9.9.9.11" -ErrorAction Stop
        $updatedAdapters += $adapter.Name
    } catch {
        # Silent fail
    }
}

Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue

# Display info
Write-Host "`n========================================" -ForegroundColor Cyan
if ($isReinstall) {
    Write-Host "DNSCrypt-Proxy reinstalled successfully!" -ForegroundColor Green
} else {
    Write-Host "DNSCrypt-Proxy installed successfully!" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nDNS Server: 127.0.0.1:53"
Write-Host "Primary: dns.bibica.net DoH"
Write-Host "Backup: Quad9 (9.9.9.11)"
Write-Host "`nInstall path: $installPath"
Write-Host "Config file: $installPath\dnscrypt-proxy.toml"
Write-Host "Backup file: $backupFile"
if ($isReinstall) {
    Write-Host "Backup status: Using original DNS backup" -ForegroundColor Cyan
}
Write-Host "Uninstall: $installPath\uninstall.bat"
Write-Host "Startup: Auto-start enabled"

if ($updatedAdapters.Count -eq 0) {
    Write-Host "`nSystem DNS configured: no adapters found" -ForegroundColor Yellow
} else {
    Write-Host "`nSystem DNS configured on $($updatedAdapters.Count) adapter(s):" -ForegroundColor Yellow
    $updatedAdapters | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
}
Write-Host "Using dns.bibica.net as primary DNS resolver" -ForegroundColor Green
Write-Host "`nTo uninstall, run: $installPath\uninstall.bat" -ForegroundColor Cyan
Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
