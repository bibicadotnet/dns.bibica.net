# ========================================
# SIMPLE DNS BENCHMARK - SHORT OUTPUT
# ========================================

$DOH_SERVER     = "https://dns.bibica.net/dns-query"
$DOH_SERVER_CF  = "https://1.1.1.1/dns-query"
$DNS_BIBICA     = "3.1.41.240:53"
$DNS_CF         = "1.1.1.1:53"
$DOMAIN         = "google.com"
$DURATION       = "10s"
$INSTALL_DIR    = "C:\dns-bibica-net"

function Install-Dnspyre {
    if (Test-Path $INSTALL_DIR) { Remove-Item -Path $INSTALL_DIR -Recurse -Force }
    New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/tantalor93/dnspyre/releases/latest" -Headers @{"User-Agent"="PowerShell"}
    $arch = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
    $asset = $release.assets | Where-Object { $_.name -eq "dnspyre_windows_${arch}.tar.gz" } | Select-Object -First 1

    $downloadPath = "$INSTALL_DIR\$($asset.name)"
    (New-Object System.Net.WebClient).DownloadFile($asset.browser_download_url, $downloadPath)
    tar -xzf $downloadPath -C $INSTALL_DIR 2>&1 | Out-Null

    $exePath = Get-ChildItem -Path $INSTALL_DIR -Filter "dnspyre.exe" -Recurse | Select-Object -First 1
    if ($exePath -and $exePath.DirectoryName -ne $INSTALL_DIR) {
        Move-Item -Path $exePath.FullName -Destination "$INSTALL_DIR\dnspyre.exe" -Force
    }

    return (Test-Path "$INSTALL_DIR\dnspyre.exe")
}

$dnspyreExe = "$INSTALL_DIR\dnspyre.exe"
if (-not (Test-Path $dnspyreExe)) {
    if (-not (Install-Dnspyre)) {
        Write-Host "Installation failed. Aborting." -ForegroundColor Red
        exit 1
    }
}

# ======================
# DEFINE TESTS
# ======================
$Tests = @(
    @{Name="DoH HTTP/1.1"; Protocol="1.1"; Concurrency="1"},
    @{Name="DoH HTTP/2"; Protocol="2"; Concurrency="1"},
    @{Name="DoH HTTP/3"; Protocol="3"; Concurrency="1"},
    @{Name="DoH HTTP/2 - 5 Concurrent"; Protocol="2"; Concurrency="5"},
    @{Name="DoH HTTP/2 - 10 Concurrent"; Protocol="2"; Concurrency="10"},
    @{Name="DoH HTTP/2 - 20 Concurrent"; Protocol="2"; Concurrency="20"},
    @{Name="Plain DNS UDP"; Protocol="udp"; Concurrency="1"}
)

# ======================
# RUN TESTS SEQUENTIALLY (SHORT OUTPUT)
# ======================
function Run-Short {
    param ($Server, $Protocol, $Concurrency, $Name, $Domain)

    # Build command line
    if ($Protocol -eq "udp") {
        $cmd = "$dnspyreExe --server $Server --duration $DURATION --concurrency $Concurrency $Domain"
    } else {
        $cmd = "$dnspyreExe --server $Server --doh-protocol $Protocol --duration $DURATION --concurrency $Concurrency $Domain"
    }

    Write-Host "`n[TEST] $Name" -ForegroundColor Cyan
    Write-Host "Command: $cmd" -ForegroundColor DarkGray

    # Run command
    $output = if ($Protocol -eq "udp") {
        & $dnspyreExe --server $Server --duration $DURATION --concurrency $Concurrency --no-progress --no-distribution $Domain 2>&1
    } else {
        & $dnspyreExe --server $Server --doh-protocol $Protocol --duration $DURATION --concurrency $Concurrency --no-progress --no-distribution $Domain 2>&1
    }

    # Extract essential lines
    $patterns = "Benchmarking|Total requests|Questions per second|DNS timings|min:|mean:|\+/-sd|max:|p99:|p95:|p50:"
    $filtered = $output | Select-String -Pattern $patterns
    $filtered -join "`n"
}

foreach ($test in $Tests) {
    # ===== BIBICA.NET =====
    $serverName = ($DOH_SERVER -split '/')[2]
    Write-Host "`n===== TEST $($test.Name) - $serverName =====" -ForegroundColor Yellow
    if ($test.Protocol -eq "udp") {
        Run-Short -Server $DNS_BIBICA -Protocol $test.Protocol -Concurrency $test.Concurrency -Name "$($test.Name) - $serverName" -Domain $DOMAIN
    } else {
        Run-Short -Server $DOH_SERVER -Protocol $test.Protocol -Concurrency $test.Concurrency -Name "$($test.Name) - $serverName" -Domain $DOMAIN
    }

    # ===== CLOUDFLARE =====
    $serverNameCF = ($DOH_SERVER_CF -split '/')[2]
    Write-Host "`n===== TEST $($test.Name) - $serverNameCF =====" -ForegroundColor Yellow
    if ($test.Protocol -eq "udp") {
        Run-Short -Server $DNS_CF -Protocol $test.Protocol -Concurrency $test.Concurrency -Name "$($test.Name) - $serverNameCF" -Domain $DOMAIN
    } else {
        Run-Short -Server $DOH_SERVER_CF -Protocol $test.Protocol -Concurrency $test.Concurrency -Name "$($test.Name) - $serverNameCF" -Domain $DOMAIN
    }
}

Write-Host "`nAll tests completed!" -ForegroundColor Green
