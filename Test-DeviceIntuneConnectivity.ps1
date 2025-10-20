<#
.SYNOPSIS
    Test-DeviceIntuneConnectivity v1.1 - PowerShell script to validate Microsoft Intune connectivity.

.DESCRIPTION
    This PowerShell script tests Internet connectivity to Microsoft Intune required endpoints
    under the current user's context. It validates connection status for devices that need
    to be connected to Microsoft Intune as MDM-managed devices (Azure AD Joined/Hybrid Azure AD Joined).
    
    The script automatically retrieves the latest endpoint URLs from Microsoft's official
    endpoint service and tests connectivity to each required endpoint based on current
    proxy configuration.

.PARAMETER None
    This script does not accept parameters.

.NOTES
    File Name      : Test-DeviceIntuneConnectivity.ps1
    Author         : Dionisio Rocha
    Version        : 1.1
    Prerequisite   : PowerShell 5.0 or higher
    
.EXAMPLE
    .\Test-DeviceIntuneConnectivity.ps1
    Runs the connectivity test for all Microsoft Intune endpoints.

.LINK
    https://endpoints.office.com/endpoints/WorldWide?ServiceAreas=MEM

#>

function Get-ProxyConfiguration {
    <#
    .SYNOPSIS
        Retrieves and formats the current WinHTTP proxy configuration.
    
    .DESCRIPTION
        Checks the system's WinHTTP proxy settings and returns the proxy server
        information in a standardized format for use in connectivity tests.
    
    .OUTPUTS
        String - Returns "NoProxy" for direct access or formatted proxy server URL
    #>
    
    Write-Host "Checking WinHTTP proxy settings..." -ForegroundColor Yellow
    
    # Initialize proxy server variable
    $proxyServer = "NoProxy"
    
    try {
        # Get WinHTTP proxy configuration
        $winHttpOutput = netsh winhttp show proxy
        $proxyLine = $winHttpOutput | Select-String "server"
        
        if ($proxyLine) {
            $proxyServer = $proxyLine.ToString().TrimStart("Proxy Server(s) :  ")
        }
        
        # Handle direct access scenario
        if ($proxyServer -eq "Direct access (no proxy server).") {
            $proxyServer = "NoProxy"
            Write-Host "Access Type: DIRECT" -ForegroundColor Cyan
            return $proxyServer
        }
        
        # Format proxy server URL if proxy is configured
        if (($proxyServer -ne "NoProxy") -and (-not $proxyServer.StartsWith("http://"))) {
            Write-Host "Access Type: PROXY" -ForegroundColor Cyan
            Write-Host "Proxy Server List: $proxyServer" -ForegroundColor Cyan
            $proxyServer = "http://$proxyServer"
        }
        
        return $proxyServer
    }
    catch {
        Write-Warning "Failed to retrieve proxy configuration: $($_.Exception.Message)"
        return "NoProxy"
    }
}

function Get-IntuneEndpointList {
    <#
    .SYNOPSIS
        Retrieves and categorizes Microsoft Intune endpoint URLs for connectivity testing.
    
    .DESCRIPTION
        Fetches the latest Microsoft Intune endpoint URLs from the official Microsoft
        endpoint service and categorizes them by functionality for better reporting.
        Processes wildcard URLs and removes duplicates.
    
    .OUTPUTS
        Array of PSCustomObject containing endpoint ID, category, and URLs
    #>
    
    try {
        Write-Host "Retrieving latest Microsoft Intune endpoint list..." -ForegroundColor Yellow
        
        # Generate unique client request ID for tracking
        $clientRequestId = [GUID]::NewGuid().Guid
        $endpointUri = "https://endpoints.office.com/endpoints/WorldWide?ServiceAreas=MEM&clientrequestid=$clientRequestId"
        
        # Retrieve endpoint data from Microsoft service
        $allEndpoints = Invoke-RestMethod -Uri $endpointUri
        
        # Filter specifically for MEM service area endpoints that have URLs
        $endpointList = $allEndpoints | Where-Object { 
            $_.ServiceArea -eq "MEM" -and 
            $_.urls -and 
            $_.urls.Count -gt 0
        }
        
        # Debug: Show count of endpoints found
        # Write-Host "Found $($allEndpoints.Count) total endpoints, filtered to $($endpointList.Count) MEM endpoints." -ForegroundColor Cyan
        
        # Debug: Show which endpoint IDs we're getting
        # $endpointIds = $endpointList | ForEach-Object { $_.id } | Sort-Object -Unique
        # Write-Host "Endpoint IDs found: $($endpointIds -join ', ')" -ForegroundColor DarkGray
        
        # Define endpoint categories for better understanding of test results
        $endpointCategories = @{
            163 = 'Global - Intune Client and Host Service'
            164 = 'Delivery Optimization & Windows Update'
            165 = 'NTP Sync'
            169 = 'Windows Notifications & Store'
            170 = 'Scripts & Win32 Apps'
            171 = 'Push Notifications'
            173 = 'Autopilot Self-deploy'
            179 = 'Android (AOSP) Device Management'
            181 = 'Remote Help'
            182 = 'Collect Diagnostics - Diagnostic Data Upload'
            186 = 'Microsoft Azure Attestation'
            187 = 'Dependency - Remote Help Web PubSub'
            188 = 'Remote Help Dependency for GCC Customers'
            189 = 'Dependency - Feature Deployment'
            192 = 'Organizational Messages'
            193 = 'Mobile Application Management (MAM)'
        }
        
        # Process endpoint data and create structured output
        $processedEndpoints = foreach ($endpoint in $endpointList) {
            # Clean and process URLs (remove wildcard prefixes)
            $cleanedUrls = foreach ($url in $endpoint.urls) {
                $url -replace '^\*\.', ''
            }
            
            # Ensure endpoint ID is treated as integer for hashtable lookup
            $endpointId = [int]$endpoint.id
            
            # Create endpoint object with category information
            [PSCustomObject]@{
                Id       = $endpointId
                Category = $endpointCategories[$endpointId]
                Urls     = ($cleanedUrls | Sort-Object -Unique)
            }
        }
        
        Write-Host "Successfully retrieved $($processedEndpoints.Count) endpoint categories." -ForegroundColor Green
        return $processedEndpoints
    }
    catch {
        Write-Error "Failed to retrieve endpoint list: $($_.Exception.Message)"
        throw
    }
}

function Test-EndpointConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to a specific endpoint URL.
    
    .DESCRIPTION
        Performs connectivity testing to an endpoint using either direct connection
        or proxy-based connection depending on system configuration.
    
    .PARAMETER Url
        The URL to test connectivity against
    
    .PARAMETER ProxyServer
        Proxy server configuration ("NoProxy" for direct connection)
    
    .OUTPUTS
        PSCustomObject with Success (Boolean) and ErrorDetails (String) properties
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $true)]
        [string]$ProxyServer
    )
    
    $result = [PSCustomObject]@{
        Success = $false
        ErrorDetails = ""
    }
    
    try {
        if ($ProxyServer -eq "NoProxy") {
            # Direct connection test using TCP
            $testConnection = Test-NetConnection -ComputerName $Url -Port 443 -WarningAction SilentlyContinue
            $result.Success = $testConnection.TcpTestSucceeded
            
            if (-not $result.Success) {
                if ($testConnection.NameResolutionSucceeded -eq $false) {
                    $result.ErrorDetails = "DNS resolution failed"
                }
                elseif ($testConnection.PingSucceeded -eq $false) {
                    $result.ErrorDetails = "Host unreachable (ping failed)"
                }
                else {
                    $result.ErrorDetails = "TCP connection to port 443 failed"
                }
            }
        }
        else {
            # Proxy connection test using HTTP request
            $response = Invoke-WebRequest -Uri "https://$Url" -UseBasicParsing -Proxy $ProxyServer -SkipHttpErrorCheck -TimeoutSec 30
            $result.Success = ($response.StatusCode -eq 200)
            
            if (-not $result.Success) {
                $result.ErrorDetails = "HTTP $($response.StatusCode) - $($response.StatusDescription)"
            }
        }
    }
    catch {
        $result.Success = $false
        
        # Parse common error types
        $errorMessage = $_.Exception.Message
        switch -Regex ($errorMessage) {
            "timeout|timed out" { $result.ErrorDetails = "Connection timeout" }
            "name resolution|could not be resolved|dns" { $result.ErrorDetails = "DNS resolution failed" }
            "network.*unreachable|no route" { $result.ErrorDetails = "Network unreachable" }
            "connection.*refused|actively refused" { $result.ErrorDetails = "Connection refused" }
            "proxy" { $result.ErrorDetails = "Proxy connection failed" }
            "ssl|tls|certificate" { $result.ErrorDetails = "SSL/TLS certificate error" }
            default { $result.ErrorDetails = "Connection error: $($errorMessage.Split('.')[0])" }
        }
    }
    
    return $result
}

function Write-ConnectionResult {
    <#
    .SYNOPSIS
        Writes formatted connection test results to the console.
    
    .DESCRIPTION
        Displays connection test results with appropriate formatting and regional
        context information for specific endpoints.
    
    .PARAMETER Url
        The tested URL
    
    .PARAMETER TestResult
        PSCustomObject containing Success (Boolean) and ErrorDetails (String)
    
    .PARAMETER EndpointId
        The endpoint ID for special handling of regional endpoints
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$TestResult,
        
        [Parameter(Mandatory = $true)]
        [int]$EndpointId
    )
    
    # Determine regional context for specific endpoints
    $regionalContext = ""
    
    # Endpoint 170: Scripts & Win32 Apps
    if ($EndpointId -eq 170) {
        switch -Regex ($Url) {
            '^approd' { $regionalContext = " (needed for Asia & Pacific tenants only)" }
            '^euprod' { $regionalContext = " (needed for Europe tenants only)" }
            '^naprod' { $regionalContext = " (needed for North America tenants only)" }
            '^sw[d|i]' { $regionalContext = " (global endpoint for all tenants)" }
        }
    }
    
    # Endpoint 186: Microsoft Azure Attestation
    if ($EndpointId -eq 186) {
        switch -Regex ($Url) {
            '\.(eus|eus2|cus|wus|scus|ncus)\.attest\.azure\.net' { $regionalContext = " (needed for North America tenants only)" }
            '\.(neu|weu)\.attest\.azure\.net' { $regionalContext = " (needed for Europe tenants only)" }
            '\.jpe\.attest\.azure\.net' { $regionalContext = " (needed for Asia & Pacific tenants only)" }
        }
    }
    
    # Format connection result display
    $statusText = if ($TestResult.Success) { "Succeeded" } else { "Failed" }
    $statusColor = if ($TestResult.Success) { "Green" } else { "Red" }
    $dots = "." * (50 - $Url.Length)
    
    # Build the result line with optional error details
    $resultLine = "Connection to $Url$dots $statusText$regionalContext"
    
    if (-not $TestResult.Success -and $TestResult.ErrorDetails) {
        $resultLine += " ($($TestResult.ErrorDetails))"
    }
    
    Write-Host $resultLine -ForegroundColor $statusColor
}

function Show-RemediationGuidance {
    <#
    .SYNOPSIS
        Displays troubleshooting guidance when connectivity tests fail.
    
    .DESCRIPTION
        Shows comprehensive remediation steps and recommendations for resolving
        connectivity issues with Microsoft Intune endpoints.
    #>
    
    Write-Host ""
    Write-Host ""
    Write-Host "TEST FAILED: Device cannot communicate with Microsoft endpoints under user account" -ForegroundColor Red -BackgroundColor Black
    Write-Host ""
    Write-Host "RECOMMENDED ACTIONS:" -ForegroundColor Yellow
    Write-Host "• Verify device can communicate with Microsoft endpoints under the current user account" -ForegroundColor Yellow
    Write-Host "• If using an outbound proxy, implement Web Proxy Auto-Discovery (WPAD)" -ForegroundColor Yellow
    Write-Host "• Configure proxy settings via GPO using WinHTTP Proxy Settings (Windows 10 1709+)" -ForegroundColor Yellow
    Write-Host "• Ensure authenticated proxy allows user context authentication" -ForegroundColor Yellow
    Write-Host "• Verify firewall rules allow HTTPS (443) traffic to Microsoft endpoints" -ForegroundColor Yellow
    Write-Host "• Check network connectivity and DNS resolution" -ForegroundColor Yellow
}

function Test-DeviceIntuneConnectivity {
    <#
    .SYNOPSIS
        Main function to test Microsoft Intune connectivity for device enrollment.
    
    .DESCRIPTION
        Orchestrates the complete connectivity test process including proxy detection,
        endpoint retrieval, and connectivity testing for all Microsoft Intune endpoints.
    #>
    
    # Set error handling preference
    $ErrorActionPreference = 'SilentlyContinue'
    $testFailed = $false
    
    try {
        Write-Host "=== Microsoft Intune Device Connectivity Test ===" -ForegroundColor Cyan
        Write-Host "Testing connectivity to Microsoft Intune endpoints..." -ForegroundColor Cyan
        Write-Host ""
        
        # Get proxy configuration
        $proxyServer = Get-ProxyConfiguration
        
        # Retrieve endpoint list
        $endpointList = Get-IntuneEndpointList
        
        Write-Host ""
        Write-Host "Testing Internet connectivity to endpoints..." -ForegroundColor Yellow
        Write-Host ""
        
        # Test connectivity to each endpoint category
        foreach ($endpoint in $endpointList) {
            if ($endpoint.Category) {
                Write-Host "Testing Category: $($endpoint.Category)" -ForegroundColor Magenta
            }
            else {
                Write-Host "Testing Category: Uncategorized (ID: $($endpoint.Id))" -ForegroundColor Magenta
            }
            
            # Test each URL in the current endpoint category
            foreach ($url in $endpoint.Urls) {
                $testResult = Test-EndpointConnectivity -Url $url -ProxyServer $proxyServer
                Write-ConnectionResult -Url $url -TestResult $testResult -EndpointId $endpoint.Id
                
                # Track overall test status
                if (-not $testResult.Success) {
                    $testFailed = $true
                }
            }
            Write-Host ""
        }
        
        # Display results summary and guidance
        if ($testFailed) {
            Show-RemediationGuidance
        }
        else {
            Write-Host ""
            Write-Host "SUCCESS: All connectivity tests passed!" -ForegroundColor Green -BackgroundColor Black
            Write-Host "Device should be able to enroll and communicate with Microsoft Intune." -ForegroundColor Green
        }
    }
    catch {
        Write-Error "An error occurred during connectivity testing: $($_.Exception.Message)"
        return
    }
    finally {
        Write-Host ""
        Write-Host "Script execution completed." -ForegroundColor Cyan
        Write-Host ""
    }
}

# Execute the main connectivity test function
Test-DeviceIntuneConnectivity
