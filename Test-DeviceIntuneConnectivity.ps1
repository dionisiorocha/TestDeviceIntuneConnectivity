<# 
 
.SYNOPSIS
    Test-DeviceIntuneConnectivity v1.1 PowerShell script.

.DESCRIPTION
    Test-DeviceIntuneConnectivity is a PowerShell script that helps to test the Internet connectivity to the required Microsoft resources under the users context to validate the connection status between the device that needs to be connected to Microsoft Intune as MDM-managed devices (AADJ/HAADJ):
    All URLs automatically found via (invoke-restmethod -Uri ("https://endpoints.office.com/endpoints/WorldWide?ServiceAreas=MEM`&clientrequestid=" + ([GUID]::NewGuid()).Guid)) | ?{$_.ServiceArea -eq "MEM" -and $_.urls} | select -unique -ExpandProperty urls


.AUTHOR:
    Dionisio Rocha

.EXAMPLE
    .\Test-DeviceIntuneConnectivity
    
#>

Function checkProxy {
    # Check Proxy settings
    Write-Host "Checking winHTTP proxy settings..." -ForegroundColor Yellow
    $ProxyServer = "NoProxy"
    $winHTTP = netsh winhttp show proxy
    $Proxy = $winHTTP | Select-String server
    $ProxyServer = $Proxy.ToString().TrimStart("Proxy Server(s) :  ")

    if ($ProxyServer -eq "Direct access (no proxy server).") {
        $ProxyServer = "NoProxy"
        Write-Host "Access Type : DIRECT"
    }

    if ( ($ProxyServer -ne "NoProxy") -and (-not($ProxyServer.StartsWith("http://")))) {
        Write-Host "      Access Type : PROXY"
        Write-Host "Proxy Server List :" $ProxyServer
        $ProxyServer = "http://" + $ProxyServer
    }
    return $ProxyServer
}

Function getEndpointList {
    # Get up-to-date URLs
    $endpointList = (invoke-restmethod -Uri ("https://endpoints.office.com/endpoints/WorldWide?ServiceAreas=MEM`&clientrequestid=" + ([GUID]::NewGuid()).Guid)) | Where-Object { $_.ServiceArea -eq "MEM" -and $_.urls }

    # Create categories to better understand what is being tested
    [PsObject[]]$endpointListCategories = @()
    $endpointListCategories += [PsObject]@{id = 163; category = 'Global' }
    $endpointListCategories += [PsObject]@{id = 164; category = 'Delivery Optimization' }
    $endpointListCategories += [PsObject]@{id = 165; category = 'NTP Sync' }
    $endpointListCategories += [PsObject]@{id = 169; category = 'Windows Notifications & Store' }
    $endpointListCategories += [PsObject]@{id = 170; category = 'Scripts & Win32 Apps' }
    $endpointListCategories += [PsObject]@{id = 171; category = 'Push Notifications' }
    $endpointListCategories += [PsObject]@{id = 172; category = 'Delivery Optimization' }
    $endpointListCategories += [PsObject]@{id = 173; category = 'Autopilot Self-deploy' }
    $endpointListCategories += [PsObject]@{id = 178; category = 'Apple Device Management' }
    $endpointListCategories += [PsObject]@{id = 179; category = 'Android (AOSP) Device Management' }
    $endpointListCategories += [PsObject]@{id = 181; category = 'Remote Help' }
    $endpointListCategories += [PsObject]@{id = 182; category = 'Collect Diagnostics' }
    $endpointListCategories += [PsObject]@{id = 186; category = 'Microsoft Azure Attestation' }
    $endpointListCategories += [PsObject]@{id = 187; category = 'Dependency - Remote Help web pubsub' }
    $endpointListCategories += [PsObject]@{id = 188; category = 'Remote Help Dependancy for GCC customers' }
    $endpointListCategories += [PsObject]@{id = 189; category = 'Feature flighting (opt in/out) may not function if this is not included' }
    
    # Create new output object and extract relevant test information (ID, category, URLs only)
    [PsObject[]]$endpointRequestList = @()
    for ($i = 0; $i -lt $endpointList.Count; $i++) {
        $endpointRequestList += [PsObject]@{ id = $endpointList[$i].id; category = ($endpointListCategories | Where-Object { $_.id -eq $endpointList[$i].id }).category; urls = $endpointList[$i].urls }
    }

    # Remove all *. from URL list (not useful)
    for ($i = 0; $i -lt $endpointRequestList.Count; $i++) {
        for ($j = 0; $j -lt $endpointRequestList[$i].urls.Count; $j++) {
            $targetUrl = $endpointRequestList[$i].urls[$j].replace('*.', '')
            $endpointRequestList[$i].urls[$j] = $targetURL
        }
        $endpointRequestList[$i].urls = $endpointRequestList[$i].urls | Sort-Object -Unique
    }
    
    return $endpointRequestList
}

Function Test-DeviceIntuneConnectivity {
    # Prepare variables
    $ErrorActionPreference = 'silentlycontinue'
    $TestFailed = $false

    # Get the proxy information
    $ProxyServer = checkProxy

    # Get the list of endpoints
    $endpointList = getEndpointList

    Write-Host "Checking Internet Connectivity..." -ForegroundColor Yellow
    # For each endpoint, check the connectivity
    foreach ($endpoint in $endpointList) {        
        Write-Host "Checking Category: ..." $endpoint.category -ForegroundColor Yellow
        foreach ($url in $endpoint.urls) {
            $TestResult = $null # Reset the test variable
            if ($ProxyServer -eq "NoProxy") {
                $TestResult = (Test-NetConnection -ComputerName $url -Port 443).TcpTestSucceeded            
            }
            else {
                $TestResult = (Invoke-WebRequest -uri $url -UseBasicParsing -Proxy $ProxyServer -SkipHttpErrorCheck).StatusCode
            }
            if (($ProxyServer -eq "NoProxy" -and $TestResult -eq $True) -or ($ProxyServer -ne "NoProxy" -and $TestResult -eq 200)) {
                if ($endpoint.id -eq 170 -and $url.StartsWith('approd')) {
                    Write-Host "Connection to " $url ".............. Succeeded (needed for Asia & Pacific tenants only)." -ForegroundColor Green 
                }
                elseif ($endpoint.id -eq 170 -and $url.StartsWith('euprod')) {
                    Write-Host "Connection to " $url ".............. Succeeded (needed for Europe tenants only)." -ForegroundColor Green 
                }
                elseif ($endpoint.id -eq 170 -and $url.StartsWith('naprod')) {
                    Write-Host "Connection to " $url ".............. Succeeded (needed for North America tenants only)." -ForegroundColor Green 
                }
                else {
                    Write-Host "Connection to " $url ".............. Succeeded." -ForegroundColor Green 
                }
            }
            else {
                $TestFailed = $true
                if ($endpoint.id -eq 170 -and $url.StartsWith('approd')) {
                    Write-Host "Connection to " $url ".............. Failed (needed for Asia & Pacific tenants only)." -ForegroundColor Red 
                }
                elseif ($endpoint.id -eq 170 -and $url.StartsWith('euprod')) {
                    Write-Host "Connection to " $url ".............. Failed (needed for Europe tenants only)." -ForegroundColor Red 
                }
                elseif ($endpoint.id -eq 170 -and $url.StartsWith('naprod')) {
                    Write-Host "Connection to " $url ".............. Failed (needed for North America tenants only)." -ForegroundColor Red 
                }
                else {
                    Write-Host "Connection to " $url ".............. Failed." -ForegroundColor Red 
                }
            }
        }
    }

    # If test failed
    if ($TestFailed) {
        ''
        ''
        Write-Host "Test failed: device is not able to communicate with MS endpoints under user account" -ForegroundColor red -BackgroundColor Black
        ''
        Write-Host "Recommended actions: " -ForegroundColor Yellow
        Write-Host "- Make sure that the device is able to communicate with the above MS endpoints successfully under the user account." -ForegroundColor Yellow
        Write-Host "- If the organization requires access to the internet via an outbound proxy, it is recommended to implement Web Proxy Auto-Discovery (WPAD)." -ForegroundColor Yellow
        Write-Host "- If you don't use WPAD, you can configure proxy settings with GPO by deploying WinHTTP Proxy Settings on your computers beginning with Windows 10 1709." -ForegroundColor Yellow
        Write-Host "- If the organization requires access to the internet via an authenticated outbound proxy, make sure that Windows 10 computers can successfully authenticate to the outbound proxy using the user context." -ForegroundColor Yellow
    }

    ''
    ''
    Write-Host "Script completed successfully." -ForegroundColor Green -BackgroundColor Black
    ''
}

Test-DeviceIntuneConnectivity
