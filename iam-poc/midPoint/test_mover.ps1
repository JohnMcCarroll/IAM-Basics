# ==============================================================================
# test_mover.ps1 - Role Transition / Mover Process
# ==============================================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$targetUsername,

    [Parameter(Mandatory = $true)]
    [string]$newRoleName
)

$roleOidMap = @{
    "developer"       = "10000000-0000-0000-0000-000000000001"
    "trader"          = "10000000-0000-0000-0000-000000000002"
    "manager"         = "10000000-0000-0000-0000-000000000003"
    "human_resources" = "10000000-0000-0000-0000-000000000004"
}

$accessMatrix = @{
    "developer"       = @{ RCChannels = @("dev", "general");              GiteaTeam = "Developers" }
    "trader"          = @{ RCChannels = @("trades", "general");           GiteaTeam = "Traders" }
    "manager"         = @{ RCChannels = @("trade-approvals", "managers", "general"); GiteaTeam = "Managers" }
    "human_resources" = @{ RCChannels = @("hr", "general");               GiteaTeam = $null }
}

# ------------------------------------------------------------------------------
# 1. Update & Verify Role Assignment in midPoint
# ------------------------------------------------------------------------------
Write-Host "--- Step 1: Updating Role to '$newRoleName' in midPoint ---" -ForegroundColor Cyan

$logMatch = (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")[-1]
$adminPassword = if ($logMatch) { ($logMatch -split ":")[-1].Trim().Trim('"') } else { "5ecr3t" }
$mpAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("administrator:$adminPassword"))
$mpHeaders = @{ "Authorization" = "Basic $mpAuth"; "Accept" = "application/xml" }

$devanOid = $null
$usersXml = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users" -Method Get -Headers $mpHeaders

foreach ($uNode in $usersXml.SelectNodes("//*[local-name()='object']")) {
    $oid = $uNode.oid
    if ($oid) {
        $uDetail = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$oid" -Method Get -Headers $mpHeaders
        $nameNode = $uDetail.SelectSingleNode("//*[local-name()='name']")
        if ($nameNode -and $nameNode.InnerText.Trim() -ieq $targetUsername) {
            $devanOid = $oid
            break
        }
    }
}

if (-not $devanOid) {
    Write-Host "Error: Target user '$targetUsername' not found in midPoint." -ForegroundColor Red
    exit
}

$newRoleOid = $roleOidMap[$newRoleName]
$modifyXml = @"
<objectModification xmlns="http://midpoint.evolveum.com/xml/ns/public/common/api-types-3"
                    xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
                    xmlns:t="http://prism.evolveum.com/xml/ns/public/types-3">
    <itemDelta>
        <t:modificationType>replace</t:modificationType>
        <t:path>c:assignment</t:path>
        <t:value>
            <c:targetRef oid="$newRoleOid" type="c:RoleType"/>
        </t:value>
    </itemDelta>
</objectModification>
"@

try {
    $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$devanOid" `
        -Method Post -Headers @{ "Authorization" = "Basic $mpAuth"; "Content-Type" = "application/xml" } -Body $modifyXml
    Write-Host "Successfully assigned role '$newRoleName' ($newRoleOid) in midPoint." -ForegroundColor Green
} catch {
    Write-Host "Failed to update midPoint role: $_" -ForegroundColor Red
    exit
}

# ------------------------------------------------------------------------------
# 2. Reconcile Keycloak Role Mappings
# ------------------------------------------------------------------------------
Write-Host "`n--- Step 2: Reconciling Keycloak Roles ---" -ForegroundColor Cyan

$kcTokenResp = Invoke-RestMethod -Uri "http://localhost:8080/realms/master/protocol/openid-connect/token" `
    -Method Post -Body @{ client_id = "admin-cli"; grant_type = "password"; username = "admin"; password = "admin" }
$kcHeaders = @{ "Authorization" = "Bearer $($kcTokenResp.access_token)"; "Content-Type" = "application/json" }

$kcUser = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users?username=$targetUsername" -Method Get -Headers $kcHeaders

if ($kcUser -and $kcUser.Count -gt 0) {
    $kcUserId = $kcUser[0].id
    
    # Revoke legacy realm roles
    $userRoles = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$kcUserId/role-mappings/realm" -Method Get -Headers $kcHeaders
    $rolesToRemove = $userRoles | Where-Object { $roleOidMap.ContainsKey($_.name) -and $_.name -ne $newRoleName }

    # Reconcile Keycloak Role Mappings
    if ($rolesToRemove) {
        # Convert roles to array and ensure JSON wrapping []
        $roleList = @($rolesToRemove | ForEach-Object { @{ id = $_.id; name = $_.name } })
        $removePayload = ConvertTo-Json -InputObject $roleList -Depth 3
        
        # Enforce array syntax for single-item results (PowerShell 5.1 workaround)
        if (-not $removePayload.Trim().StartsWith("[")) { 
            $removePayload = "[$removePayload]" 
    }

    Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$kcUserId/role-mappings/realm" `
        -Method Delete -Headers $kcHeaders -Body $removePayload
    Write-Host "Revoked legacy Keycloak roles: $(($rolesToRemove.name) -join ', ')" -ForegroundColor Yellow
}

    # Grant new realm role
    $kcRole = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles/$newRoleName" -Method Get -Headers $kcHeaders
    $rolePayload = "[{`"id`":`"$($kcRole.id)`",`"name`":`"$($kcRole.name)`"}]"
    $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$kcUserId/role-mappings/realm" `
        -Method Post -Headers $kcHeaders -Body $rolePayload
    Write-Host "Assigned Keycloak role '$newRoleName'." -ForegroundColor Green
}

## ------------------------------------------------------------------------------
# 3. Reconcile Rocket.Chat Channels & Account Activation
# ------------------------------------------------------------------------------
Write-Host "`n--- Step 3: Reconciling Rocket.Chat Channels ---" -ForegroundColor Cyan

$rcAdminPass = "AdminPassword123!"
$rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" -Method Post -ContentType "application/json" -Body (@{ user = "admin"; password = $rcAdminPass } | ConvertTo-Json)
$passBytes = [System.Text.Encoding]::UTF8.GetBytes($rcAdminPass)
$passHash  = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($passBytes) | ForEach-Object { $_.ToString("x2") })

$rcHeaders = @{
    "X-Auth-Token" = $rcAuth.data.authToken; "X-User-Id" = $rcAuth.data.userId
    "X-2fa-Code" = $passHash; "X-2fa-Method" = "password"; "Content-Type" = "application/json"
}

$rcUserResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.info?username=$targetUsername" -Method Get -Headers $rcHeaders

if ($rcUserResp -and $rcUserResp.user) {
    $rcUserId = $rcUserResp.user._id

    # FIX: Reactivate account if it was disabled during a previous leaver process
    if ($rcUserResp.user.active -eq $false) {
        $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.setActiveStatus" -Method Post -Headers $rcHeaders -Body (@{ userId = $rcUserId; activeStatus = $true } | ConvertTo-Json)
        Write-Host "Reactivated Rocket.Chat account for '$targetUsername'." -ForegroundColor Green
    }

    $targetChannels = $accessMatrix[$newRoleName].RCChannels
    $allManagedChannels = @("dev", "trades", "trade-approvals", "managers", "hr")

    foreach ($chan in $allManagedChannels) {
        try {
            $groupInfo = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.info?roomName=$chan" -Method Get -Headers $rcHeaders
            $roomId = $groupInfo.group._id

            if ($targetChannels -contains $chan) {
                $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.invite" -Method Post -Headers $rcHeaders -Body (@{ roomId = $roomId; userId = $rcUserId } | ConvertTo-Json)
                Write-Host "Added '$targetUsername' to Rocket.Chat #$chan" -ForegroundColor Green
            } else {
                $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.kick" -Method Post -Headers $rcHeaders -Body (@{ roomId = $roomId; userId = $rcUserId } | ConvertTo-Json)
                Write-Host "Kicked '$targetUsername' from Rocket.Chat #$chan" -ForegroundColor Yellow
            }
        } catch {}
    }
}

# ------------------------------------------------------------------------------
# 4. Reconcile Gitea Account & Team Access
# ------------------------------------------------------------------------------
Write-Host "`n--- Step 4: Reconciling Gitea Access ---" -ForegroundColor Cyan

$giteaHeaders = @{
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:Password123!"))
    "Content-Type"   = "application/json"
}

$targetGiteaTeam = $accessMatrix[$newRoleName].GiteaTeam

if (-not $targetGiteaTeam) {
    # FIX: If the new role has NO Gitea entitlement, purge the account completely
    try {
        $userOrgs = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/users/$targetUsername/orgs" -Method Get -Headers $giteaHeaders
        foreach ($org in $userOrgs) {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$($org.username)/members/$targetUsername" -Method Delete -Headers $giteaHeaders
        }
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/$targetUsername" -Method Delete -Headers $giteaHeaders
        Write-Host "Role '$newRoleName' has no Gitea entitlement. Purged Gitea account '$targetUsername'." -ForegroundColor Green
    } catch {
        Write-Host "Gitea account '$targetUsername' already deprovisioned or not found." -ForegroundColor Yellow
    }
} else {
    # Role has Gitea access: update team memberships
    $orgTeams = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/trading-org/teams" -Method Get -Headers $giteaHeaders
    foreach ($team in $orgTeams) {
        if ($team.name -eq $targetGiteaTeam) {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/teams/$($team.id)/members/$targetUsername" -Method Put -Headers $giteaHeaders
            Write-Host "Added '$targetUsername' to Gitea team '$($team.name)'." -ForegroundColor Green
        } else {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/teams/$($team.id)/members/$targetUsername" -Method Delete -Headers $giteaHeaders
            Write-Host "Removed '$targetUsername' from Gitea team '$($team.name)'." -ForegroundColor Yellow
        }
    }
}
