# Define RBAC Roles in midPoint

$midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("administrator:5ecr3t"))
$mpHeaders = @{
    "Authorization" = "Basic $midpointAuth"
    "Content-Type"  = "application/xml"
}

# 1. Create Developer Role XML
$developerRoleXml = @"
<role xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>Developer</name>
    <description>Grants developer access: open PRs in Gitea and join #dev-chat in Rocket.Chat</description>
</role>
"@

# 2. Create Manager Role XML
$managerRoleXml = @"
<role xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>Manager</name>
    <description>Grants manager access: approve/merge PRs in Gitea and join #trade-approvals in Rocket.Chat</description>
</role>
"@

# Post Roles to midPoint
Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/roles" -Method Post -Headers $mpHeaders -Body $developerRoleXml
Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/roles" -Method Post -Headers $mpHeaders -Body $managerRoleXml
Write-Host "Created Developer and Manager roles in midPoint." -ForegroundColor Green


# Sync midPoint Roles to Keycloak Realm Roles

# Get Admin Token from Keycloak
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

# Create Developer & Manager Realm Roles in Keycloak
@("Developer", "Manager") | ForEach-Object {
    $roleBody = @{ name = $_ } | ConvertTo-Json
    try {
        Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/roles" `
            -Method Post -Headers $kcHeaders -Body $roleBody
        Write-Host "Created Keycloak Realm Role: $_" -ForegroundColor Green
    } catch {
        Write-Host "Keycloak Role $_ already exists." -ForegroundColor Yellow
    }
}


# Map Keycloak OIDC Roles to Rocket.Chat Channels

# Get Rocket.Chat Auth Token
$rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" `
    -Method Post `
    -Body @{ username = "admin"; password = "AdminPassword123!" }

$rcHeaders = @{
    "X-Auth-Token" = $rcAuth.data.authToken
    "X-User-Id"    = $rcAuth.data.userId
    "Content-Type" = "application/json"
}

# Map Keycloak roles to Rocket.Chat channels
# Developer -> #dev-chat, Manager -> #trade-approvals
$rcSettings = @(
    @{ _id = "Accounts_OAuth_Custom_keycloak_roles_to_channels"; value = '{"Developer": "dev-chat", "Manager": "trade-approvals"}' },
    @{ _id = "Accounts_OAuth_Custom_keycloak_merge_roles"; value = $true }
)

foreach ($setting in $rcSettings) {
    $body = @{ value = $setting.value } | ConvertTo-Json
    Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings/$($setting._id)" `
        -Method Post -Headers $rcHeaders -Body $body
}
Write-Host "Rocket.Chat OIDC role-to-channel mapping updated." -ForegroundColor Green


# Enforce Gitea Merge Request Permissions

$giteaAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:GiteaPassword123!"))
$giteaHeaders = @{
    "Authorization" = "Basic $giteaAuth"
    "Content-Type"  = "application/json"
}

# 1. Create Organization
$orgBody = @{ username = "trading-org"; visibility = "public" } | ConvertTo-Json
try { Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs" -Method Post -Headers $giteaHeaders -Body $orgBody } catch {}

# 2. Create 'Developers' Team (Can create PRs, write access, but cannot merge to main)
$devTeamBody = @{
    name        = "Developers"
    permission  = "write"
    units       = @("repo.code", "repo.issues", "repo.pulls")
} | ConvertTo-Json
$devTeam = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/trading-org/teams" -Method Post -Headers $giteaHeaders -Body $devTeamBody

# 3. Create 'Managers' Team (Admin access, can approve & merge)
$mgrTeamBody = @{
    name        = "Managers"
    permission  = "admin"
    units       = @("repo.code", "repo.issues", "repo.pulls", "repo.releases")
} | ConvertTo-Json
$mgrTeam = Invoke-RestMethod -Uri "http://localhost:3000/api/v1/orgs/trading-org/teams" -Method Post -Headers $giteaHeaders -Body $mgrTeamBody

# 4. Set Branch Protection on 'main' branch in trade-scripts repository
$branchProtectBody = @{
    branch_name                   = "main"
    enable_push                   = $false
    enable_whitelist              = $true
    whitelist_teams               = @("Managers")  # Only Managers can push/merge directly
    required_approvals            = 1
    enable_approvals_whitelist    = $true
    approvals_whitelist_teams     = @("Managers")  # Only Managers can approve PRs
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/giteaadmin/trade-scripts/branch_protections" `
    -Method Post -Headers $giteaHeaders -Body $branchProtectBody

Write-Host "Gitea branch protection configured: Only Managers can merge PRs." -ForegroundColor Green


# Assign Roles to Users in midPoint

# Example: Assign 'Developer' role to user 'alice.developer' in midPoint
$assignRoleXml = @"
<objectModification xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
                    xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <itemDelta>
        <t:mutationType xmlns:t="http://prism.evolveum.com/xml/ns/public/types-3">add</t:mutationType>
        <t:path xmlns:t="http://prism.evolveum.com/xml/ns/public/types-3">assignment</t:path>
        <t:value xmlns:t="http://prism.evolveum.com/xml/ns/public/types-3">
            <c:targetRef type="c:RoleType">
                <c:filter>
                    <q:equal xmlns:q="http://prism.evolveum.com/xml/ns/public/query-3">
                        <q:path>name</q:path>
                        <q:value>Developer</q:value>
                    </q:equal>
                </c:filter>
            </c:targetRef>
        </t:value>
    </itemDelta>
</objectModification>
"@

# Execute delta update against midPoint user endpoint
Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/alice.developer" `
    -Method Patch -Headers $mpHeaders -Body $assignRoleXml


    