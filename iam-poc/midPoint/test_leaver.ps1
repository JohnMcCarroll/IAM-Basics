# ==============================================================================
# test_leaver.ps1 - Offboarding & Deprovisioning Process
# ==============================================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$targetUsername
)

# ------------------------------------------------------------------------------
# 1. Discover & Remove User in midPoint
# ------------------------------------------------------------------------------
Write-Host "--- Searching for '$targetUsername' in midPoint ---" -ForegroundColor Cyan

$logMatch = (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")[-1]
$adminPassword = if ($logMatch) { ($logMatch -split ":")[-1].Trim().Trim('"') } else { "5ecr3t" }
$mpAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("administrator:$adminPassword"))
$mpHeaders = @{ "Authorization" = "Basic $mpAuth"; "Accept" = "application/xml" }

$devanOid = $null
try {
    $usersXml = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users" -Method Get -Headers $mpHeaders
    foreach ($uNode in $usersXml.SelectNodes("//*[local-name()='object']")) {
        $oid = $uNode.oid
        if ($oid) {
            $uDetail = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$oid" -Method Get -Headers $mpHeaders
            # Fixed variable evaluation: added missing $ before uDetail
            if ("$($uDetail.user.name)" -eq $targetUsername) {
                $devanOid = $oid
                break
            }
        }
    }
} catch {
    Write-Host "Error querying midPoint users: $_" -ForegroundColor Red
}

if ($devanOid) {
    Write-Host "Found '$targetUsername' in midPoint with OID: $devanOid" -ForegroundColor Green
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$devanOid" -Method Delete -Headers $mpHeaders
        Write-Host "Successfully deleted '$targetUsername' from midPoint." -ForegroundColor Green
    } catch {
        Write-Host "Failed to delete user from midPoint: $_" -ForegroundColor Red
    }
} else {
    Write-Host "User '$targetUsername' not found in midPoint." -ForegroundColor Yellow
}

# ------------------------------------------------------------------------------
# 2. Revoke Keycloak Account & Session
# ------------------------------------------------------------------------------
Write-Host "`n--- Revoking Keycloak Identity ---" -ForegroundColor Cyan

try {
    $kcTokenResp = Invoke-RestMethod -Uri "http://localhost:8080/realms/master/protocol/openid-connect/token" `
        -Method Post -Body @{ client_id = "admin-cli"; grant_type = "password"; username = "admin"; password = "admin" }
    $kcHeaders = @{ "Authorization" = "Bearer $($kcTokenResp.access_token)"; "Content-Type" = "application/json" }

    $kcUser = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users?username=$targetUsername" -Method Get -Headers $kcHeaders
    if ($kcUser -and $kcUser.Count -gt 0) {
        $kcUserId = $kcUser[0].id
        # Revoke active user sessions before deletion
        try { Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$kcUserId/logout" -Method Post -Headers $kcHeaders } catch {}
        $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$kcUserId" -Method Delete -Headers $kcHeaders
        Write-Host "Deleted user '$targetUsername' from Keycloak." -ForegroundColor Green
    } else {
        Write-Host "User '$targetUsername' not found in Keycloak." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error during Keycloak cleanup: $_" -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# 3. Deprovision from Rocket.Chat
# ------------------------------------------------------------------------------
Write-Host "`n--- Deprovisioning Rocket.Chat Access ---" -ForegroundColor Cyan

$rcAdminPass = "AdminPassword123!"
try {
    $rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" -Method Post -ContentType "application/json" -Body (@{ user = "admin"; password = $rcAdminPass } | ConvertTo-Json)
    $passBytes = [System.Text.Encoding]::UTF8.GetBytes($rcAdminPass)
    $passHash  = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($passBytes) | ForEach-Object { $_.ToString("x2") })

    $rcHeaders = @{
        "X-Auth-Token" = $rcAuth.data.authToken; "X-User-Id" = $rcAuth.data.userId
        "X-2fa-Code" = $passHash; "X-2fa-Method" = "password"; "Content-Type" = "application/json"
    }

    $rcUserResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.info?username=$targetUsername" -Method Get -Headers $rcHeaders

    # Fixed property navigation: $rcUserResp.user._id
    if ($rcUserResp -and $rcUserResp.user) {
        $rcUserId = $rcUserResp.user._id
        try {
            $deactiveBody = @{ userId = $rcUserId; activeStatus = $false } | ConvertTo-Json
            $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.setActiveStatus" -Method Post -Headers $rcHeaders -Body $deactiveBody
            Write-Host "Deactivated Rocket.Chat account for '$targetUsername'." -ForegroundColor Green
        } catch {
            $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.delete" -Method Post -Headers $rcHeaders -Body (@{ userId = $rcUserId } | ConvertTo-Json)
            Write-Host "Deleted Rocket.Chat account for '$targetUsername'." -ForegroundColor Green
        }
    } else {
        Write-Host "User '$targetUsername' not found in Rocket.Chat." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Error during Rocket.Chat cleanup: $_" -ForegroundColor Red
}

# ------------------------------------------------------------------------------
# 4. Deprovision from Gitea
# ------------------------------------------------------------------------------
Write-Host "`n--- Deprovisioning Gitea Access ---" -ForegroundColor Cyan

$giteaHeaders = @{
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:Password123!"))
    "Content-Type"   = "application/json"
}

try {
    # Dynamically locate user record
    $allGiteaUsers = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users" -Method Get -Headers $giteaHeaders
    $matchedGiteaUser = $allGiteaUsers | Where-Object { $_.username -eq $targetUsername -or $_.login_name -eq $targetUsername }

    if ($matchedGiteaUser) {
        $actualName = $matchedGiteaUser.username

        # Step 1: Query all organizations the user belongs to
        $userOrgs = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/users/$actualName/orgs" -Method Get -Headers $giteaHeaders

        # Step 2: Remove user from each organization
        foreach ($org in $userOrgs) {
            try {
                $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$($org.username)/members/$actualName" -Method Delete -Headers $giteaHeaders
                Write-Host "Removed '$actualName' from Gitea organization '$($org.username)'." -ForegroundColor Green
            } catch {
                Write-Host "Warning: Failed to remove '$actualName' from org '$($org.username)': $_" -ForegroundColor Yellow
            }
        }

        # Step 3: Delete user account after organization memberships are cleared
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/$actualName" -Method Delete -Headers $giteaHeaders
        Write-Host "Successfully deleted Gitea account '$actualName'." -ForegroundColor Green
    } else {
        Write-Host "User '$targetUsername' not found in Gitea." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Gitea Error Status: $($_.Exception.Response.StatusCode.value__)" -ForegroundColor Red
    Write-Host "Gitea Error Detail: $_" -ForegroundColor Red
}
