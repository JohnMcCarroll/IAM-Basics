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
while (-not $ready) {
    try {
        # 1. Resolve Admin Password
        $logOutput = docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password"
        if ($logOutput) {
            $adminPassword = ($logOutput -split ":")[-1].Trim().Trim('"')
        } else {
            $adminPassword = "5ecr3t" # Fallback if database volume was reused
        }

        # 2. Query REST API
        $midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))
        $headers = @{ 
            "Authorization" = "Basic $midpointAuth"
            "Accept"        = "application/xml" 
        }

        $response = Invoke-WebRequest -Uri "http://localhost:8081/midpoint/ws/rest/connectors" -Headers $headers -UseBasicParsing -ErrorAction Stop
        [xml]$xml = $response.Content

        # 3. Count connector nodes using XPath
        $connectorNodes = $xml.SelectNodes("//*[local-name()='object']")
        $count = $connectorNodes.Count

        if ($count -gt 0) {
            Write-Host "midPoint is ready! Discovered $count connectors." -ForegroundColor Green
            $ready = $true
        }
    } catch {
        # midPoint still initializing
    }

    if (-not $ready) { Start-Sleep -Seconds 5 }
}

.\bootstrap.ps1

.\load_midpoint.ps1

# .\rbac.ps1

Write-Host (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")
