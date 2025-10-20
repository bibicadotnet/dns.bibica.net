# ========================================
# DNS DoH BENCHMARK - REALISTIC TESTS
# ========================================
clear
$DOH_SERVER     = "https://dns.bibica.net/dns-query"
$DOH_SERVER_CF  = "https://1.1.1.1/dns-query"
$DURATION       = "5s"
$INSTALL_DIR    = "C:\dns-bibica-net"
$OUTPUT_DIR     = "$INSTALL_DIR\results"
$TIMESTAMP      = Get-Date -Format "yyyyMMdd_HHmmss"

# ========================================
# CREATE OUTPUT DIRECTORY
# ========================================
if (-not (Test-Path $OUTPUT_DIR)) {
    New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
}

# ========================================
# INSTALL DNSPYRE
# ========================================
function Install-Dnspyre {
    if (Test-Path $INSTALL_DIR) { 
        if (-not (Test-Path "$INSTALL_DIR\dnspyre.exe")) {
            Remove-Item -Path $INSTALL_DIR -Recurse -Force 
        }
    }
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

# ========================================
# DEFINE TEST SCENARIOS
# ========================================
$Tests = @(
    @{Name="DoH HTTP/1.1"; Protocol="1.1"; Concurrency=1; Color="Cyan"},
    @{Name="DoH HTTP/2"; Protocol="2"; Concurrency=1; Color="Yellow"},
    @{Name="DoH HTTP/3"; Protocol="3"; Concurrency=1; Color="Magenta"}
)

# ========================================
# RESULTS STORAGE
# ========================================
$Results = @()

# ========================================
# STRIP ANSI COLOR CODES
# ========================================
function Strip-AnsiCodes {
    param ([string]$Text)
    return $Text -replace '\x1b\[[0-9;]*m', '' -replace '\[0m', '' -replace '\[[0-9]+m', ''
}

# ========================================
# PARSE FUNCTION
# ========================================
function Parse-DnspyreOutput {
    param (
        [string]$OutputFile,
        [string]$TestName,
        [string]$Server
    )

    $qps = "N/A"
    $mean = "N/A"
    $p50 = "N/A"
    $p95 = "N/A"
    $p99 = "N/A"
    $errors = "0"

    if (-not (Test-Path $OutputFile)) {
        Write-Host "ERROR: Output file does not exist: $OutputFile" -ForegroundColor Red
        return $null
    }

    $content = Get-Content -Path $OutputFile -Raw -ErrorAction SilentlyContinue

    if ([string]::IsNullOrEmpty($content)) {
        Write-Host "ERROR: Cannot read output file: $OutputFile" -ForegroundColor Red
        return $null
    }

    $cleanContent = Strip-AnsiCodes -Text $content
    $lines = $cleanContent -split "`r?`n"

    foreach ($line in $lines) {
        $line = $line.Trim()
        
        if ($line -match 'Questions\s+per\s+second:\s+([0-9.]+)') {
            $qps = $matches[1]
            continue
        }
        
        if ($line -match 'mean:\s+([0-9.]+)(ms|s|µs)') {
            $mean = $matches[1] + $matches[2]
            continue
        }
        
        if ($line -match 'p50:\s+([0-9.]+)(ms|s|µs)') {
            $p50 = $matches[1] + $matches[2]
            continue
        }
        
        if ($line -match 'p95:\s+([0-9.]+)(ms|s|µs)') {
            $p95 = $matches[1] + $matches[2]
            continue
        }
        
        if ($line -match 'p99:\s+([0-9.]+)(ms|s|µs)') {
            $p99 = $matches[1] + $matches[2]
            continue
        }
        
        if ($line -match 'Total\s+Errors:\s+([0-9]+)') {
            $errors = $matches[1]
            continue
        }
    }

    return [PSCustomObject]@{
        TestName = $TestName
        Server = $Server
        QPS = $qps
        Mean = $mean
        P50 = $p50
        P95 = $p95
        P99 = $p99
        Errors = $errors
    }
}

# ========================================
# RUN TEST FUNCTION
# ========================================
function Run-Test {
    param ($Server, $Protocol, $Concurrency, $TestName)

    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $random = Get-Random -Minimum 100000 -Maximum 999999
    $domain = "${timestamp}${random}.dns.bibica.net"

	
    $serverName = ($Server -split '/')[2]

    # Sanitize filename - remove ALL special characters including dots
    $sanitizedTestName = $TestName -replace '[^a-zA-Z0-9]', '_'
    $sanitizedServer = $serverName -replace '[^a-zA-Z0-9]', '_'
    $fileTimestamp = Get-Date -Format "yyyyMMdd_HHmmss_fff"
    $outputFile = "$OUTPUT_DIR\${fileTimestamp}_${sanitizedTestName}_${sanitizedServer}.txt"

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "[TEST] $TestName - $serverName" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    
    $cmd = "$dnspyreExe --server $Server --doh-protocol $Protocol --duration $DURATION --concurrency $Concurrency --no-progress --no-distribution $domain"
    Write-Host "Command: $cmd" -ForegroundColor DarkGray
    Write-Host ""

    $output = & $dnspyreExe --server $Server --doh-protocol $Protocol --duration $DURATION --concurrency $Concurrency --no-progress --no-distribution $domain 2>&1
    
    # Ensure output directory exists before writing
    if (-not (Test-Path $OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    }
    
    $output | Out-File -FilePath $outputFile -Encoding UTF8 -Force

    $output | ForEach-Object { Write-Host $_ }

    $result = Parse-DnspyreOutput -OutputFile $outputFile -TestName $TestName -Server $serverName

    if ($null -eq $result) {
        Write-Host "ERROR: Failed to parse output" -ForegroundColor Red
        return $null
    }

    Write-Host "`nParsed: QPS=$($result.QPS) Mean=$($result.Mean) p50=$($result.P50) p95=$($result.P95) p99=$($result.P99) Errors=$($result.Errors)" -ForegroundColor Yellow

    return $result
}

# ========================================
# RUN ALL TESTS
# ========================================
Write-Host "`n========================================" -ForegroundColor Yellow
Write-Host "STARTING DoH BENCHMARK TESTS" -ForegroundColor Yellow
Write-Host "========================================`n" -ForegroundColor Yellow

foreach ($test in $Tests) {
    # Test against bibica.net
    $result1 = Run-Test -Server $DOH_SERVER -Protocol $test.Protocol -Concurrency $test.Concurrency -TestName $test.Name
    if ($null -ne $result1) {
        # Add color metadata
        $result1 | Add-Member -MemberType NoteProperty -Name "Color" -Value $test.Color -Force
        $Results += $result1
    }
    Start-Sleep -Seconds 2

    # Test against Cloudflare
    $result2 = Run-Test -Server $DOH_SERVER_CF -Protocol $test.Protocol -Concurrency $test.Concurrency -TestName $test.Name
    if ($null -ne $result2) {
        # Add color metadata
        $result2 | Add-Member -MemberType NoteProperty -Name "Color" -Value $test.Color -Force
        $Results += $result2
    }
    Start-Sleep -Seconds 2
}

# ========================================
# EXPORT TO CSV
# ========================================
if ($Results.Count -eq 0) {
    Write-Host "`nWARNING: No results to export!" -ForegroundColor Yellow
} else {
    # Ensure output directory exists
    if (-not (Test-Path $OUTPUT_DIR)) {
        New-Item -ItemType Directory -Path $OUTPUT_DIR -Force | Out-Null
    }
    
    $csvFile = "$OUTPUT_DIR\benchmark_results_${TIMESTAMP}.csv"
    
    try {
        # Export all fields including Errors to CSV
        $Results | Select-Object TestName, Server, QPS, Mean, P50, P95, P99, Errors | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
    }
    catch {
        Write-Host "`nERROR: Failed to export CSV" -ForegroundColor Red
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ========================================
# DISPLAY RESULTS TABLE
# ========================================
if ($Results.Count -gt 0) {
    Write-Host "`n========================================" -ForegroundColor Yellow
    Write-Host "BENCHMARK RESULTS SUMMARY" -ForegroundColor Yellow
    Write-Host "========================================`n" -ForegroundColor Yellow

    # Optimized column widths: Test=15, Server=15, Numbers=9 each
    $tableHeader = "{0,-15} {1,-15} {2,9} {3,9} {4,9} {5,9} {6,9}" -f "Test Scenario", "Server", "QPS", "Mean", "p50", "p95", "p99"
    $tableSeparator = "-" * 81

    Write-Host $tableHeader -ForegroundColor White
    Write-Host $tableSeparator -ForegroundColor DarkGray

    foreach ($result in $Results) {
        # Use the color assigned to this test scenario
        $color = if ($result.Color) { $result.Color } else { "White" }
        
        # Display row with optimized spacing
        $row = "{0,-15} {1,-15} {2,9} {3,9} {4,9} {5,9} {6,9}" -f `
            $result.TestName, $result.Server, $result.QPS, $result.Mean, $result.P50, $result.P95, $result.P99
        Write-Host $row -ForegroundColor $color
    }

    Write-Host $tableSeparator -ForegroundColor DarkGray

    Write-Host "`n=============================================================" -ForegroundColor Cyan
    Write-Host "METRICS EXPLANATION:" -ForegroundColor Cyan
    Write-Host "=============================================================" -ForegroundColor Cyan
    Write-Host "QPS: HIGHER = BETTER | Latency (Mean/p50/p95/p99): LOWER = BETTER" -ForegroundColor Yellow
    Write-Host "Note: Errors data is saved in CSV file but hidden from table display" -ForegroundColor DarkGray
    Write-Host "=============================================================`n" -ForegroundColor Cyan
} else {
    Write-Host "`nNo valid results to display." -ForegroundColor Yellow
}

# ========================================
# CLEANUP - DELETE INSTALL_DIR
# ========================================
if (Test-Path $INSTALL_DIR) {
    try {
        # Wait a bit to ensure all file handles are released
        Start-Sleep -Seconds 1
        Remove-Item -Path $INSTALL_DIR -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Host "WARNING: Could not delete $INSTALL_DIR" -ForegroundColor Yellow
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "BENCHMARK COMPLETED!" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green
