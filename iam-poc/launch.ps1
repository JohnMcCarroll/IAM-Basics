Write-Host "Launching Docker multicontainer environment" -ForegroundColor Cyan

docker compose up -d

# Write-Host "Waiting for midPoint REST API and Connector discovery..." -ForegroundColor Yellow

# $ready = $false
# while (-not $ready) {
#     try {
#         $logOutput = docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password"
#         if ($logOutput) {
#             $adminPassword = ($logOutput -split ":")[-1].Trim().Trim('"')
#             $midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))
#             $headers = @{ "Authorization" = "Basic $midpointAuth"; "Accept" = "application/xml" }
            
#             $connectorsXml = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/connectors" -Headers $headers -ErrorAction Stop
#             $count = @($connectorsXml.objectList.connector).Count
#             if ($count -gt 0) {
#                 Write-Host "midPoint is ready! Discovered $count connectors." -ForegroundColor Green
#                 $ready = $true
#             }
#         }
#     } catch {
#         # midPoint still starting up
#     }
#     if (-not $ready) { Start-Sleep -Seconds 5 }
# }

Write-Host "Waiting for midPoint REST API and Connector discovery..." -ForegroundColor Yellow

$ready = $false
$timeoutSeconds = 300
$startTime = Get-Date

while (-not $ready) {
    # Check overall timeout limit
    if (((Get-Date) - $startTime).TotalSeconds -gt $timeoutSeconds) {
        Write-Host "Timed out waiting for midPoint to start." -ForegroundColor Red
        break
    }

    try {
        # 1. Resolve Admin Password
        $logOutput = docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password"
        if ($logOutput) {
            $adminPassword = ($logOutput -split ":")[-1].Trim().Trim('"')
        } else {
            $adminPassword = "5ecr3t"
        }

        # 2. Query REST API
        $midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))
        $headers = @{ 
            "Authorization" = "Basic $midpointAuth"
            "Accept"        = "application/xml" 
        }

        $response = Invoke-WebRequest -Uri "http://localhost:8081/midpoint/ws/rest/connectors" -Headers $headers -UseBasicParsing -ErrorAction Stop
        
        if ($response.StatusCode -eq 200) {
            [xml]$xml = $response.Content
            $connectorNodes = $xml.SelectNodes("//*[local-name()='object']")
            $count = if ($connectorNodes) { $connectorNodes.Count } else { 0 }

            if ($count -gt 0) {
                Write-Host "midPoint is ready! Discovered $count connectors." -ForegroundColor Green
                $ready = $true
            } else {
                Write-Host "midPoint REST API active, waiting for connector discovery..." -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "midPoint web server not reachable yet. Retrying in 10s..." -ForegroundColor DarkGray
    }

    if (-not $ready) { Start-Sleep -Seconds 10 }
}

.\bootstrap.ps1

.\load_midpoint.ps1

.\rbac.ps1

Write-Host (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")

cd midPoint
.\bot_listener.ps1
