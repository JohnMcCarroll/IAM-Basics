# ==============================================================================
# 1. Provision midPoint Roles & Users from File
# ==============================================================================
Write-Host "--- Provisioning midPoint Roles & Users from File ---" -ForegroundColor Cyan

$xmlPath = ".\init_employees_midPoint.xml"
if (-not (Test-Path $xmlPath)) {
    Write-Error "Could not find $xmlPath in current directory."
    exit
}

[xml]$employeesXml = Get-Content -Path $xmlPath

$mpHeaders = @{
    "Authorization" = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("administrator:5ecr3t"))
    "Content-Type"  = "application/xml"
}

# Provision Roles
foreach ($roleNode in $employeesXml.objects.role) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/roles" `
            -Method Post -Headers $mpHeaders -Body $roleNode.OuterXml
        Write-Host "Provisioned midPoint role: $($roleNode.name)" -ForegroundColor Green
    } catch {
        Write-Host "Role $($roleNode.name) already exists or skipped." -ForegroundColor Yellow
    }
}

# Provision Users
foreach ($userNode in $employeesXml.objects.user) {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users" `
            -Method Post -Headers $mpHeaders -Body $userNode.OuterXml
        Write-Host "Provisioned midPoint user: $($userNode.name)" -ForegroundColor Green
    } catch {
        Write-Host "User $($userNode.name) already exists or skipped." -ForegroundColor Yellow
    }
}


# ==============================================================================
# 2. Sync Roles, Assign Roles to Users & Configure UserInfo Mapper in Keycloak
# ==============================================================================
Write-Host "--- Syncing Roles & User Mappings to Keycloak ---" -ForegroundColor Cyan

$kcTokenResp = Invoke-RestMethod -Uri "http://localhost:8080/realms/master/protocol/openid-connect/token" `
    -Method Post `
    -Body @{
        client_id  = "admin-cli"
        grant_type = "password"
        username   = "admin"
        password   = "admin"
    }

$kcHeaders = @{
    "Authorization" = "Bearer $($kcTokenResp.access_token)"
    "Content-Type"  = "application/json"
}

# 1. Create Realm Roles in Keycloak
foreach ($roleName in $employeesXml.objects.role.name) {
    $roleBody = @{ name = $roleName } | ConvertTo-Json
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles" `
            -Method Post -Headers $kcHeaders -Body $roleBody
        Write-Host "Created Keycloak Realm Role: $roleName" -ForegroundColor Green
    } catch {
        Write-Host "Keycloak Role $roleName already exists." -ForegroundColor Yellow
    }
}

# 2. Assign Realm Roles to Users (Strict JSON Array string format)
$userRoleMap = @{
    "alice.dev"   = "developer"
    "bob.trader"  = "trader"
    "charlie.mgr" = "manager"
    "diana.hr"    = "human_resources"
}

foreach ($username in $userRoleMap.Keys) {
    $targetRoleName = $userRoleMap[$username]
    try {
        $kcUser = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users?username=$username" `
            -Method Get -Headers $kcHeaders
        
        $kcRole = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles/$targetRoleName" `
            -Method Get -Headers $kcHeaders

        if ($kcUser -and $kcRole) {
            $userId = $kcUser[0].id
            # Exact JSON array format required by Keycloak
            $rolePayload = "[{`"id`":`"$($kcRole.id)`",`"name`":`"$($kcRole.name)`"}]"
            
            $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/users/$userId/role-mappings/realm" `
                -Method Post -Headers $kcHeaders -Body $rolePayload
            Write-Host "Assigned role '$targetRoleName' to user '$username' in Keycloak." -ForegroundColor Green
        }
    } catch {
        Write-Host "Role mapping for $username skipped or failed: $_" -ForegroundColor Yellow
    }
}

# 3. Configure Keycloak Protocol Mapper to expose 'roles' in /userinfo payload
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
                Write-Host "Configured 'roles' UserInfo claim mapper for client: $($client.clientId)" -ForegroundColor Green
            } catch {
                # Mapper already configured
            }
        }
    }
} catch {
    Write-Host "Failed to configure Keycloak protocol mappers: $_" -ForegroundColor Yellow
}


# ==============================================================================
# 3. Pre-Create Private Channels (Groups), Users & Assign Memberships in Rocket.Chat
# ==============================================================================
Write-Host "--- Provisioning Private Channels & Users in Rocket.Chat ---" -ForegroundColor Cyan

$rcAdminPass = "AdminPassword123!"
$rcLoginBody = @{ user = "admin"; password = $rcAdminPass } | ConvertTo-Json

try {
    $rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" `
        -Method Post -ContentType "application/json" -Body $rcLoginBody

    $passBytes = [System.Text.Encoding]::UTF8.GetBytes($rcAdminPass)
    $sha256    = [System.Security.Cryptography.SHA256]::Create()
    $passHash  = -join ($sha256.ComputeHash($passBytes) | ForEach-Object { $_.ToString("x2") })

    $rcHeaders = @{
        "X-Auth-Token" = $rcAuth.data.authToken
        "X-User-Id"    = $rcAuth.data.userId
        "X-2fa-Code"   = $passHash
        "X-2fa-Method" = "password"
        "Content-Type" = "application/json"
    }

    # Helper function to extract exact API response text from web exceptions
    function Get-ExceptionDetail ($err) {
        if ($err.Exception.Response) {
            $reader = [System.IO.StreamReader]::new($err.Exception.Response.GetResponseStream())
            return $reader.ReadToEnd()
        }
        return $err.Exception.Message
    }

    # 1. Provision Private Channels (Convert existing Public channels to Private if needed)
    $privateChannels = @("trades", "trade-approvals", "hr", "dev", "managers")
    $channelMap = @{}

    foreach ($chan in $privateChannels) {
        $chanBody = @{ name = $chan } | ConvertTo-Json
        try {
            # Try creating as a private group
            $resp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.create" `
                -Method Post -Headers $rcHeaders -Body $chanBody
            $channelMap[$chan] = $resp.group._id
            Write-Host "Created private channel: #$chan" -ForegroundColor Green
        } catch {
            # Check if it already exists as a private group
            try {
                $infoResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/groups.info?roomName=$chan" `
                    -Method Get -Headers $rcHeaders
                $channelMap[$chan] = $infoResp.group._id
                Write-Host "Private channel #$chan exists (ID: $($channelMap[$chan]))." -ForegroundColor Yellow
            } catch {
                # Check if it exists as a public channel, and convert it to private
                try {
                    $pubResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.info?roomName=$chan" `
                        -Method Get -Headers $rcHeaders
                    $pubId = $pubResp.channel._id

                    # Convert public channel to private group
                    $setTypeBody = @{ roomId = $pubId; type = "p" } | ConvertTo-Json
                    $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.setType" `
                        -Method Post -Headers $rcHeaders -Body $setTypeBody

                    $channelMap[$chan] = $pubId
                    Write-Host "Converted existing public channel #$chan to Private (ID: $pubId)." -ForegroundColor Green
                } catch {
                    $errDetail = Get-ExceptionDetail $_
                    Write-Host "Failed to create or convert channel #$($chan): $errDetail" -ForegroundColor Red
                }
            }
        }
    }

    # Fetch or set Public '#general' channel
    try {
        $infoResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.info?roomName=general" `
            -Method Get -Headers $rcHeaders
        $channelMap["general"] = $infoResp.channel._id
        Write-Host "Public channel #general exists (ID: $($channelMap['general']))." -ForegroundColor Yellow
    } catch {
        $channelMap["general"] = "GENERAL"
    }

    # 2. Users to Provision
    $usersToProvision = @(
        @{ name = "Alice Dev";    username = "alice.dev";   email = "alice.dev@company.local";   channels = @("dev", "general") },
        @{ name = "Bob Trader";   username = "bob.trader";  email = "bob.trader@company.local";  channels = @("trades", "general") },
        @{ name = "Charlie Mgr";  username = "charlie.mgr"; email = "charlie.mgr@company.local"; channels = @("trade-approvals", "managers", "general") },
        @{ name = "Diana HR";     username = "diana.hr";    email = "diana.hr@company.local";    channels = @("hr", "general") }
    )

    # Fetch all existing users from Rocket.Chat
    $existingRcUsers = (Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.list" -Method Get -Headers $rcHeaders).users

    foreach ($u in $usersToProvision) {
        $targetEmail = $u.email
        $targetUsername = $u.username

        # Resolve matching account by username or email address
        $matchedUser = $existingRcUsers | Where-Object { 
            $_.username -eq $targetUsername -or ($_.emails | Where-Object { $_.address -eq $targetEmail })
        }

        $userId = $null

        if ($matchedUser) {
            $userId = $matchedUser._id
            Write-Host "Found existing Rocket.Chat user account for '$($u.username)' (ID: $userId)." -ForegroundColor Yellow
        } else {
            # Create user account if not found
            $userBody = @{
                name             = $u.name
                email            = $u.email
                username         = $u.username
                password         = "Password123!"
                sendWelcomeEmail = $false
                verified         = $true
            } | ConvertTo-Json

            try {
                $createResp = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/users.create" `
                    -Method Post -Headers $rcHeaders -Body $userBody
                $userId = $createResp.user._id
                Write-Host "Pre-created Rocket.Chat user account: $($u.username) (ID: $userId)" -ForegroundColor Green
            } catch {
                $errDetail = Get-ExceptionDetail $_
                Write-Host "User $($u.username) creation status: $errDetail" -ForegroundColor Yellow
            }
        }

        if (-not $userId) {
            Write-Host "   Skipping channel invites for '$($u.username)': Could not resolve User ID." -ForegroundColor Red
            continue
        }

        # Add user to designated channels
        foreach ($chanName in $u.channels) {
            $roomId = $channelMap[$chanName]
            if (-not $roomId) {
                Write-Host "   Skipping #$chanName for '$($u.username)': Room ID missing." -ForegroundColor Red
                continue
            }

            $inviteBody = @{
                roomId = $roomId
                userId = $userId
            } | ConvertTo-Json

            # Use 'channels.invite' for public #general, 'groups.invite' for private channels
            $inviteEndpoint = if ($chanName -eq "general") { "channels.invite" } else { "groups.invite" }

            try {
                $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/$inviteEndpoint" `
                    -Method Post -Headers $rcHeaders -Body $inviteBody
                Write-Host "   Added '$($u.username)' to #$chanName" -ForegroundColor Green
            } catch {
                $errDetail = Get-ExceptionDetail $_
                if ($errDetail -like "*already-in-room*" -or $errDetail -like "*error-user-already-in-room*") {
                    Write-Host "   '$($u.username)' is already in #$chanName." -ForegroundColor Yellow
                } else {
                    Write-Host "   FAILED to add '$($u.username)' to #$chanName - API Output: $errDetail" -ForegroundColor Red
                }
            }
        }
    }

    # 3. Enable OAuth Merge Settings
    function Set-RCSetting {
        param([string]$Name, [object]$Val)
        $key = "Accounts_OAuth_Custom-keycloak-$Name"
        $body = @{ value = $Val } | ConvertTo-Json
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings/$key" `
                -Method Post -Headers $rcHeaders -Body $body
        } catch {}
    }

    Set-RCSetting -Name "enabled" -Val $true
    Set-RCSetting -Name "merge_users" -Val $true

    Write-Host "Rocket.Chat API private channel provisioning complete." -ForegroundColor Green
} catch {
    $errDetail = Get-ExceptionDetail $_
    Write-Host "Rocket.Chat API Provisioning Failed: $errDetail" -ForegroundColor Red
}












# ==============================================================================
# 4. Enforce Gitea RBAC, Teams & Branch Protections
# ==============================================================================
Write-Host "--- Configuring Gitea RBAC & Branch Protections ---" -ForegroundColor Cyan

$giteaAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:Password123!"))
$giteaHeaders = @{
    "Authorization" = "Basic $giteaAuth"
    "Content-Type"   = "application/json"
}

$orgName  = "trading-org"
$repoName = "trade-scripts"

# 1. Ensure Organization and Repository Exist
$orgBody = @{ username = $orgName; visibility = "public" } | ConvertTo-Json
try { $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs" -Method Post -Headers $giteaHeaders -Body $orgBody } catch {}

$repoBody = @{ name = $repoName; private = $false; auto_init = $true } | ConvertTo-Json
try { $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/repos" -Method Post -Headers $giteaHeaders -Body $repoBody } catch {}

# 2. Dynamically Resolve Keycloak Auth Source ID & Provision Accounts
$giteaUsers = @(
    @{ username = "alice.dev";   email = "alice.dev@company.local";   team = "Developers" },
    @{ username = "bob.trader";  email = "bob.trader@company.local";  team = "Traders" },
    @{ username = "charlie.mgr"; email = "charlie.mgr@company.local"; team = "Managers" }
)

# Resolve Keycloak OAuth2 Source ID directly via CLI
$keycloakAuthId = $null
try {
    $cliAuthOutput = docker exec -u git iam-gitea gitea admin auth list
    $matchedLine = $cliAuthOutput | Where-Object { $_ -like "*keycloak*" }
    if ($matchedLine) {
        $keycloakAuthId = [int]($matchedLine.Trim().Split()[0])
    }
} catch {}

if (-not $keycloakAuthId) { $keycloakAuthId = 1 }

foreach ($u in $giteaUsers) {
    $userExists = $false
    try {
        $existingUser = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/users/$($u.username)" -Method Get -Headers $giteaHeaders
        $userExists = $true
    } catch {}

    if (-not $userExists) {
        $userBody = @{
            username             = $u.username
            email                = $u.email
            password             = "Password123!"
            must_change_password = $false
            source_id            = $keycloakAuthId
            login_name           = $u.username
        } | ConvertTo-Json

        try {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users" -Method Post -Headers $giteaHeaders -Body $userBody
            Write-Host "Created Gitea account: $($u.username) (Bound to Keycloak OIDC Source ID: $keycloakAuthId)" -ForegroundColor Green
        } catch {
            Write-Host "Could not create account $($u.username): $_" -ForegroundColor Red
        }
    } else {
        $updateBody = @{
            source_id  = $keycloakAuthId
            login_name = $u.username
        } | ConvertTo-Json

        try {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/$($u.username)" -Method Patch -Headers $giteaHeaders -Body $updateBody
            Write-Host "Rebound existing user '$($u.username)' to Keycloak OIDC Source ID $keycloakAuthId" -ForegroundColor Green
        } catch {
            Write-Host "Failed to update $($u.username): $_" -ForegroundColor Red
        }
    }
}

# Explicitly purge HR account if created previously
try {
    $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/diana.hr" -Method Delete -Headers $giteaHeaders
    Write-Host "Removed Gitea account for diana.hr (HR access restricted)." -ForegroundColor Green
} catch {}

# 3. Provision Organization Teams with Role-Specific Permissions
$teamsConfig = @(
    @{ name = "Developers"; permission = "write"; units = @("repo.code", "repo.issues", "repo.pulls"); includes_all_repositories = $true },
    @{ name = "Traders";    permission = "read";  units = @("repo.code", "repo.issues", "repo.pulls"); includes_all_repositories = $true },
    @{ name = "Managers";   permission = "admin"; units = @("repo.code", "repo.issues", "repo.pulls", "repo.releases"); includes_all_repositories = $true }
)

$teamIdMap = @{}

foreach ($t in $teamsConfig) {
    $teamBody = @{
        name       = $t.name
        permission = $t.permission
        units      = $t.units
        includes_all_repositories = $t.includes_all_repositories
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/teams" -Method Post -Headers $giteaHeaders -Body $teamBody
        $teamIdMap[$t.name] = $resp.id
        Write-Host "Created Gitea Team: $($t.name) (Permission: $($t.permission))" -ForegroundColor Green
    } catch {
        $allTeams = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/$orgName/teams" -Method Get -Headers $giteaHeaders
        $matchedTeam = $allTeams | Where-Object { $_.name -eq $t.name }
        if ($matchedTeam) {
            $teamIdMap[$t.name] = $matchedTeam.id
            Write-Host "Gitea Team $($t.name) exists (ID: $($matchedTeam.id))." -ForegroundColor Yellow
        }
    }
}

# 4. Assign Users to designated Teams
foreach ($u in $giteaUsers) {
    $teamId = $teamIdMap[$u.team]
    if ($teamId) {
        try {
            $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/teams/$teamId/members/$($u.username)" -Method Put -Headers $giteaHeaders
            Write-Host "Added '$($u.username)' to Gitea Team '$($u.team)'" -ForegroundColor Green
        } catch {
            Write-Host "Could not add $($u.username) to $($u.team): $_" -ForegroundColor Yellow
        }
    }
}

# 5. Enforce Branch Protection Rules on 'main' Branch
$branchProtectBody = @{
    branch_name                = "main"
    enable_push                = $false          # Disables direct commits (forces Pull Requests)
    enable_whitelist           = $false
    required_approvals         = 1               # Requires 1 review approval to merge
    enable_approvals_whitelist = $true           # Restricts approval rights to specific teams
    approvals_whitelist_teams  = @("Managers")   # Only Managers team can approve/accept PRs
} | ConvertTo-Json

try {
    $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/$orgName/$repoName/branch_protections" `
        -Method Post -Headers $giteaHeaders -Body $branchProtectBody
    Write-Host "Gitea branch protection configured for 'main' branch." -ForegroundColor Green
} catch {
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/$orgName/$repoName/branch_protections/main" `
            -Method Patch -Headers $giteaHeaders -Body $branchProtectBody
        Write-Host "Updated Gitea branch protection for 'main' branch." -ForegroundColor Green
    } catch {
        Write-Host "Branch protection status: Active or skipped." -ForegroundColor Yellow
    }
}
