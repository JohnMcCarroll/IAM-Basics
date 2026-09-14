# ==============================================================================
# 1. Discover Users & Assigned Roles from midPoint
# ==============================================================================
Write-Host "--- Discovering Users & Assigned Roles from midPoint ---" -ForegroundColor Cyan

$logMatch = (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")[-1]
$adminPassword = if ($logMatch) { ($logMatch -split ":")[-1].Trim().Trim('"') } else { "5ecr3t" }
$mpAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("administrator:$adminPassword"))
$mpHeaders = @{ "Authorization" = "Basic $mpAuth"; "Accept" = "application/xml" }

$roleOidMap = @{
    "10000000-0000-0000-0000-000000000001" = "developer"
    "10000000-0000-0000-0000-000000000002" = "trader"
    "10000000-0000-0000-0000-000000000003" = "manager"
    "10000000-0000-0000-0000-000000000004" = "human_resources"
}

try {
    $rolesXml = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/roles" -Method Get -Headers $mpHeaders
    foreach ($node in $rolesXml.SelectNodes("//*[local-name()='object']")) {
        if ($node.oid -and $node.name) { $roleOidMap[$node.oid] = $node.name }
    }
} catch {
    Write-Host "Notice: Using pre-seeded role OID mappings." -ForegroundColor Yellow
}

$usersXml = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users" -Method Get -Headers $mpHeaders
$discoveredUsers = @()

foreach ($uNode in $usersXml.SelectNodes("//*[local-name()='object']")) {
    $userOid = $uNode.oid
    if (-not $userOid) { continue }

    $uDetail = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$userOid" -Method Get -Headers $mpHeaders
    $uXml = $uDetail.user

    $username = $uXml.name
    if ($username -eq "administrator") { continue }

    $givenName  = $uXml.givenName
    $familyName = $uXml.familyName
    $fullName   = if ($givenName -and $familyName) { "$givenName $familyName" } else { $username }
    $email      = if ($uXml.emailAddress) { $uXml.emailAddress } else { "$username@company.local" }

    $assignedRoleName = $null
    $targetRefs = $uDetail.SelectNodes("//*[local-name()='targetRef']")
    foreach ($ref in $targetRefs) {
        if ($ref.oid -and $roleOidMap.ContainsKey($ref.oid)) {
            $assignedRoleName = $roleOidMap[$ref.oid]
            break
        }
    }

    $discoveredUsers += [PSCustomObject]@{
        Username = $username
        FullName = $fullName
        Email    = $email
        Role     = $assignedRoleName
    }
}

Write-Host "Discovered $($discoveredUsers.Count) users in midPoint:" -ForegroundColor Green
$discoveredUsers | Format-Table -AutoSize

$accessMatrix = @{
    "developer"       = @{ RCChannels = @("dev", "general");              GiteaTeam = "Developers" }
    "trader"          = @{ RCChannels = @("trades", "general");           GiteaTeam = "Traders" }
    "manager"         = @{ RCChannels = @("trade-approvals", "managers", "general"); GiteaTeam = "Managers" }
    "human_resources" = @{ RCChannels = @("hr", "general");               GiteaTeam = $null }
}


# ==============================================================================
# 2. Keycloak Roles & UserInfo Mapper Setup
# ==============================================================================
Write-Host "`n--- Syncing Keycloak Roles & Configuring Mappers ---" -ForegroundColor Cyan

$kcTokenResp = Invoke-RestMethod -Uri "http://localhost:8080/realms/master/protocol/openid-connect/token" `
    -Method Post -Body @{ client_id = "admin-cli"; grant_type = "password"; username = "admin"; password = "admin" }

$kcHeaders = @{ "Authorization" = "Bearer $($kcTokenResp.access_token)"; "Content-Type" = "application/json" }

foreach ($roleName in $accessMatrix.Keys) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles" `
            -Method Post -Headers $kcHeaders -Body (@{ name = $roleName } | ConvertTo-Json)
        Write-Host "Created Keycloak Realm Role: $roleName" -ForegroundColor Green
    } catch {}
}

foreach ($u in $discoveredUsers) {
    if (-not $u.Role) { continue }
    try {
        $kcUser = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users?username=$($u.Username)" -Method Get -Headers $kcHeaders
        $kcRole = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles/$($u.Role)" -Method Get -Headers $kcHeaders

        if ($kcUser -and $kcRole) {
            $rolePayload = "[{`"id`":`"$($kcRole.id)`",`"name`":`"$($kcRole.name)`"}]"
            $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$($kcUser[0].id)/role-mappings/realm" `
                -Method Post -Headers $kcHeaders -Body $rolePayload
            Write-Host "Assigned role '$($u.Role)' to '$($u.Username)' in Keycloak." -ForegroundColor Green
        }
    } catch {}
}

# RESTORED: Configure Protocol Mapper for Roles claim
try {
    $kcClients = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/clients" -Method Get -Headers $kcHeaders
    foreach ($client in $kcClients) {
        if ($client.clientId -notlike "admin-cli" -and $client.clientId -notlike "account*") {
            $mapperBody = @{
                name           = "realm roles to userinfo"
                protocol       = "openid-connect"
                protocolMapper = "oidc-usermodel-realm-role-mapper"
                config         = @{
                    "multivalued"          = "true"
                    "userinfo.token.claim" = "true"
                    "id.token.claim"       = "true"
                    "access.token.claim"   = "true"
                    "claim.name"           = "roles"
                    "jsonType.label"       = "String"
                }
            } | ConvertTo-Json -Depth 5

            try {
                $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/clients/$($client.id)/protocol-mappers/models" `
                    -Method Post -Headers $kcHeaders -Body $mapperBody
                Write-Host "Configured 'roles' claim mapper for client: $($client.clientId)" -ForegroundColor Green
            } catch {}
        }
    }
} catch {}


# ==============================================================================
# 3. Provision Rocket.Chat Channels, Memberships & OAuth Merging
# ==============================================================================
Write-Host "`n--- Provisioning Rocket.Chat ---" -ForegroundColor Cyan

$rcAdminPass = "AdminPassword123!"
try {
    $rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" -Method Post -ContentType "application/json" -Body (@{ user = "admin"; password = $rcAdminPass } | ConvertTo-Json)
    $passBytes = [System.Text.Encoding]::UTF8.GetBytes($rcAdminPass)
    $passHash  = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($passBytes) | ForEach-Object { $_.ToString("x2") })

    $rcHeaders = @{
        "X-Auth-Token" = $rcAuth.data.authToken; "X-User-Id" = $rcAuth.data.userId
        "X-2fa-Code" = $passHash; "X-2fa-Method" = "password"; "Content-Type" = "application/json"
    }

    $channelMap = @{}
    $privateChannels = @("trades", "trade-approvals", "hr", "dev", "managers")
    foreach ($chan in $privateChannels) {
        try {
            $resp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.create" -Method Post -Headers $rcHeaders -Body (@{ name = $chan } | ConvertTo-Json)
            $channelMap[$chan] = $resp.group._id
        } catch {
            try {
                $info = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.info?roomName=$chan" -Method Get -Headers $rcHeaders
                $channelMap[$chan] = $info.group._id
            } catch {}
        }
    }
    try {
        $genInfo = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.info?roomName=general" -Method Get -Headers $rcHeaders
        $channelMap["general"] = $genInfo.channel._id
    } catch {}

    $existingRcUsers = (Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.list" -Method Get -Headers $rcHeaders).users

    foreach ($u in $discoveredUsers) {
        if (-not $u.Role -or -not $accessMatrix.ContainsKey($u.Role)) { continue }

        $matchedRcUser = $existingRcUsers | Where-Object { $_.username -eq $u.Username }
        $rcUserId = $matchedRcUser._id

        if (-not $rcUserId) {
            try {
                $userBody = @{ name = $u.FullName; email = $u.Email; username = $u.Username; password = "Password123!"; sendWelcomeEmail = $false; verified = $true } | ConvertTo-Json
                $createResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.create" -Method Post -Headers $rcHeaders -Body $userBody
                $rcUserId = $createResp.user._id
            } catch {}
        }

        if (-not $rcUserId) { continue }

        foreach ($chanName in $accessMatrix[$u.Role].RCChannels) {
            $roomId = $channelMap[$chanName]
            if (-not $roomId) { continue }
            $endpoint = if ($chanName -eq "general") { "channels.invite" } else { "groups.invite" }
            try {
                $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/$endpoint" -Method Post -Headers $rcHeaders -Body (@{ roomId = $roomId; userId = $rcUserId } | ConvertTo-Json)
                Write-Host "Added '$($u.Username)' to Rocket.Chat #$chanName" -ForegroundColor Green
            } catch {}
        }
    }

    # RESTORED: Enable Rocket.Chat OAuth merge settings
    function Set-RCSetting ($Name, $Val) {
        $key = "Accounts_OAuth_Custom-keycloak-$Name"
        try { $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings/$key" -Method Post -Headers $rcHeaders -Body (@{ value = $Val } | ConvertTo-Json) } catch {}
    }
    Set-RCSetting "enabled" $true
    Set-RCSetting "merge_users" $true
    Write-Host "Enabled Rocket.Chat OAuth User Merging." -ForegroundColor Green
} catch {}


# ==============================================================================
# 4. Provision Gitea Org, Repos, Teams & Branch Protection
# ==============================================================================
Write-Host "`n--- Provisioning Gitea Infrastructure, Teams & Governance ---" -ForegroundColor Cyan

$giteaHeaders = @{
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:Password123!"))
    "Content-Type"   = "application/json"
}

$orgName  = "trading-org"
$repoName = "trade-scripts"

# RESTORED: Ensure Organization & Repository Exist
try { $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs" -Method Post -Headers $giteaHeaders -Body (@{ username = $orgName; visibility = "public" } | ConvertTo-Json) } catch {}
try { $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/repos" -Method Post -Headers $giteaHeaders -Body (@{ name = $repoName; private = $false; auto_init = $true } | ConvertTo-Json) } catch {}

# RESTORED: Ensure Teams are created with strict access levels
$teamsConfig = @(
    @{ name = "Developers"; permission = "write"; units = @("repo.code", "repo.issues", "repo.pulls"); includes_all_repositories = $true },
    @{ name = "Traders";    permission = "read";  units = @("repo.code", "repo.issues", "repo.pulls"); includes_all_repositories = $true },
    @{ name = "Managers";   permission = "admin"; units = @("repo.code", "repo.issues", "repo.pulls", "repo.releases"); includes_all_repositories = $true }
)

$teamMap = @{}
foreach ($t in $teamsConfig) {
    try {
        $resp = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/teams" -Method Post -Headers $giteaHeaders -Body ($t | ConvertTo-Json)
        $teamMap[$t.name] = $resp.id
    } catch {
        $allTeams = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/teams" -Method Get -Headers $giteaHeaders
        $matched = $allTeams | Where-Object { $_.name -eq $t.name }
        if ($matched) { $teamMap[$t.name] = $matched.id }
    }
}

# Resolve OIDC Source ID
$keycloakAuthId = 1
try {
    $cliOut = docker exec -u git iam-gitea gitea admin auth list
    $line = $cliOut | Where-Object { $_ -like "*keycloak*" }
    if ($line) { $keycloakAuthId = [int]($line.Trim().Split()[0]) }
} catch {}

# Provision Users & Teams
foreach ($u in $discoveredUsers) {
    $targetTeamName = if ($u.Role -and $accessMatrix.ContainsKey($u.Role)) { $accessMatrix[$u.Role].GiteaTeam } else { $null }

    if (-not $targetTeamName) {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/$($u.Username)" -Method Delete -Headers $giteaHeaders
            Write-Host "Restricted $($u.Username) from Gitea access." -ForegroundColor Yellow
        } catch {}
        continue
    }

    try {
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/users/$($u.Username)" -Method Get -Headers $giteaHeaders
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/$($u.Username)" -Method Patch -Headers $giteaHeaders -Body (@{ source_id = $keycloakAuthId; login_name = $u.Username } | ConvertTo-Json)
    } catch {
        $userBody = @{ username = $u.Username; email = $u.Email; password = "Password123!"; must_change_password = $false; source_id = $keycloakAuthId; login_name = $u.Username } | ConvertTo-Json
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users" -Method Post -Headers $giteaHeaders -Body $userBody
    }

    $teamId = $teamMap[$targetTeamName]
    if ($teamId) {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/teams/$teamId/members/$($u.Username)" -Method Put -Headers $giteaHeaders
            Write-Host "Added '$($u.Username)' to Gitea Team '$targetTeamName'" -ForegroundColor Green
        } catch {}
    }
}

# RESTORED: Enforce Branch Protections
$branchProtectBody = @{
    branch_name                = "main"
    enable_push                = $false
    enable_whitelist           = $false
    required_approvals         = 1
    enable_approvals_whitelist = $true
    approvals_whitelist_teams  = @("Managers")
} | ConvertTo-Json

try {
    $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/$orgName/$repoName/branch_protections" -Method Post -Headers $giteaHeaders -Body $branchProtectBody
    Write-Host "Gitea branch protection configured on 'main'." -ForegroundColor Green
} catch {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/$orgName/$repoName/branch_protections/main" -Method Patch -Headers $giteaHeaders -Body $branchProtectBody
        Write-Host "Updated Gitea branch protection on 'main'." -ForegroundColor Green
    } catch {}
}
