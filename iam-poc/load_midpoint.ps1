# ==============================================================================
# Helper Functions
# ==============================================================================

# Query midPoint REST API to dynamically fetch the LDAP Connector OID
function Get-MidPointLdapConnectorOid {
    param(
        [string]$BaseUrl = "http://localhost:8081/midpoint",
        [string]$AuthHeader
    )

    $headers = @{
        "Authorization" = $AuthHeader
        "Accept"        = "application/xml"
    }

    $response = Invoke-WebRequest -Uri "$BaseUrl/ws/rest/connectors" -Headers $headers -Method Get -UseBasicParsing
    [xml]$xml = $response.Content

    $connectorNodes = $xml.SelectNodes("//*[local-name()='object']")

    foreach ($node in $connectorNodes) {
        $typeNode = $node.SelectSingleNode("*[local-name()='connectorType']")
        if ($typeNode -and $typeNode.InnerText -eq "com.evolveum.polygon.connector.ldap.LdapConnector") {
            return $node.GetAttribute("oid")
        }
    }

    throw "Could not resolve LDAP Connector OID from midPoint repository."
}

# ==============================================================================
# 1. Prepare Authentication & Resolve LDAP Connector OID for midPoint
# ==============================================================================

$logOutput = docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password"
if ($logOutput) {
    $adminPassword = ($logOutput -split ":")[-1].Trim().Trim('"')
} else {
    $adminPassword = "5ecr3t" # Fallback if standard image is used
}

$midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))
$authHeader = "Basic $midpointAuth"
$mpHeaders = @{ 
    "Authorization" = $authHeader
    "Content-Type"  = "application/xml; charset=utf-8"
}

Write-Host "Resolving LDAP Connector OID from midPoint..." -ForegroundColor Cyan
$ldapOid = Get-MidPointLdapConnectorOid -AuthHeader $authHeader
Write-Host "Successfully resolved LDAP Connector OID: $ldapOid" -ForegroundColor Green

# ==============================================================================
# 2. Load & Upload OpenLDAP Resource to midPoint
# ==============================================================================

$resourcePath = "midPoint/resource-ldap.xml"
if (Test-Path -Path $resourcePath) {
    $resourceXml = Get-Content -Path $resourcePath -Raw
    $resourceXml = $resourceXml -replace 'connectorRef oid="[^"]*"', "connectorRef oid=`"$ldapOid`""
    $resourceOid = "10000000-0000-0000-0000-000000000040"

    try {
        $null = Invoke-WebRequest -Uri "http://localhost:8081/midpoint/ws/rest/resources/$resourceOid" `
            -Method Put `
            -Headers $mpHeaders `
            -Body $resourceXml `
            -UseBasicParsing
        Write-Host "OpenLDAP Resource imported successfully into midPoint." -ForegroundColor Green
    } catch {
        Write-Host "Failed to import OpenLDAP Resource to midPoint: $_" -ForegroundColor Red
    }
}

# ==============================================================================
# 3. Configure Keycloak LDAP User Federation
# ==============================================================================

Write-Host "Waiting for Keycloak Master Realm to finish starting up..." -ForegroundColor Yellow
while ($true) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:8080/realms/master/.well-known/openid-configuration" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($response.StatusCode -eq 200) { break }
    } catch {
        # Waiting for Keycloak...
    }
    Start-Sleep -Seconds 3
}
Write-Host "Keycloak Master Realm is online." -ForegroundColor Green

$kcTokenResponse = Invoke-RestMethod -Uri "http://localhost:8080/realms/master/protocol/openid-connect/token" `
    -Method Post `
    -Body @{
        client_id  = "admin-cli"
        grant_type = "password"
        username   = "admin"
        password   = "admin"
    }

$kcHeaders = @{
    "Authorization" = "Bearer $($kcTokenResponse.access_token)"
    "Content-Type"  = "application/json"
}

$kcExisting = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/components?name=midpoint-ldap" -Headers $kcHeaders -Method Get

if ($kcExisting -and $kcExisting.Count -gt 0) {
    $kcLdapId = $kcExisting[0].id
    Write-Host "Keycloak LDAP User Federation already exists (ID: $kcLdapId)." -ForegroundColor Yellow
} else {
    $kcBody = @{
        name         = "midpoint-ldap"
        providerId   = "ldap"
        providerType = "org.keycloak.storage.UserStorageProvider"
        parentId     = "master"
        config       = @{
            vendor                = @("other")
            connectionUrl         = @("ldap://iam-ldap:389")
            usersDn               = @("ou=users,dc=company,dc=local")
            bindDn                = @("cn=admin,dc=company,dc=local")
            bindCredential        = @("adminpassword")
            editMode              = @("READ_ONLY")
            usernameLDAPAttribute = @("uid")
            rdnLDAPAttribute      = @("uid")
            uuidLDAPAttribute     = @("entryUUID")
            userObjectClasses     = @("inetOrgPerson, organizationalPerson")
            importEnabled         = @("true")
        }
    } | ConvertTo-Json -Depth 5

    $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/components" -Method Post -Headers $kcHeaders -Body $kcBody
    $kcComponents = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/components?name=midpoint-ldap" -Headers $kcHeaders -Method Get
    $kcLdapId = $kcComponents[0].id
    Write-Host "Keycloak LDAP User Federation configured (ID: $kcLdapId)." -ForegroundColor Green
}

if ($kcLdapId) {
    $null = Invoke-RestMethod -Uri "http://localhost:8080/admin/realms/master/user-storage/$kcLdapId/sync?action=triggerFullSync" -Method Post -Headers $kcHeaders
    Write-Host "Triggered initial LDAP sync in Keycloak." -ForegroundColor Green
}

# ==============================================================================
# 4. Configure Gitea LDAP Authentication Source
# ==============================================================================

# Write-Host "Waiting for Gitea to finish starting up..." -ForegroundColor Yellow
# while ($true) {
#     try {
#         $response = Invoke-WebRequest -Uri "http://localhost:3001/api/v1/version" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
#         if ($response.StatusCode -eq 200) { break }
#     } catch {
#         # Waiting for Gitea...
#     }
#     Start-Sleep -Seconds 3
# }
# Write-Host "Gitea is online." -ForegroundColor Green

Write-Host "Checking Gitea LDAP Authentication configuration..." -ForegroundColor Yellow
$giteaAuthList = docker exec -u git iam-gitea gitea admin auth list 2>&1
if ($giteaAuthList -match "midpoint-ldap") {
    Write-Host "Gitea LDAP Authentication source already exists." -ForegroundColor Yellow
} else {
    docker exec -u git iam-gitea gitea admin auth add-ldap `
        --name "midpoint-ldap" `
        --security-protocol unencrypted `
        --host iam-ldap `
        --port 389 `
        --user-search-base "ou=users,dc=company,dc=local" `
        --user-filter "(&(objectClass=inetOrgPerson)(|(uid=%[1]s)(mail=%[1]s)))" `
        --username-attribute uid `
        --firstname-attribute givenName `
        --surname-attribute sn `
        --email-attribute mail `
        --bind-dn "cn=admin,dc=company,dc=local" `
        --bind-password "adminpassword" `
        --synchronize-users
    Write-Host "Gitea LDAP Authentication source configured successfully." -ForegroundColor Green
}

# ==============================================================================
# 5. Configure Rocket.Chat LDAP Integration via REST API
# ==============================================================================

# 1. Wait for Rocket.Chat API on Port 4000
Write-Host "Waiting for Rocket.Chat API..." -ForegroundColor Yellow
while ($true) {
    try {
        $response = Invoke-WebRequest -Uri "http://localhost:4000/api/info" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($response.StatusCode -eq 200) { break }
    } catch {
        Start-Sleep -Seconds 3
    }
}
Write-Host "Rocket.Chat API is online." -ForegroundColor Green

$adminUser = "admin"
$adminPassword = "AdminPassword123!"

# 2. SHA-256 hash for 2FA header
$passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($adminPassword)
$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($passwordBytes)
$passwordHash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })

# 3. Authenticate with Rocket.Chat
$rcLogin = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" `
    -Method Post `
    -ContentType "application/json" `
    -Body (@{ user = $adminUser; password = $adminPassword } | ConvertTo-Json)

$rcHeaders = @{
    "X-Auth-Token" = $rcLogin.data.authToken
    "X-User-Id"    = $rcLogin.data.userId
    "x-2fa-code"   = $passwordHash
    "x-2fa-method" = "password"
    "Content-Type" = "application/json"
}

# 4. Rocket.Chat LDAP Settings Array
$rcLdapSettings = @(
    @{ _id = "LDAP_Enable"; value = $true },
    @{ _id = "LDAP_Host"; value = "iam-ldap" },
    @{ _id = "LDAP_Port"; value = "389" },
    @{ _id = "LDAP_Encryption"; value = "plain" },
    @{ _id = "LDAP_BaseDN"; value = "ou=users,dc=company,dc=local" },
    @{ _id = "LDAP_Authentication"; value = $true },
    @{ _id = "LDAP_Authentication_UserDN"; value = "cn=admin,dc=company,dc=local" },
    @{ _id = "LDAP_Authentication_Password"; value = "adminpassword" },
    @{ _id = "LDAP_User_Search_Field"; value = "uid" },
    @{ _id = "LDAP_User_Search_Filter"; value = "(objectClass=inetOrgPerson)" },
    @{ _id = "LDAP_Sync_User_Data"; value = $true },
    @{ _id = "LDAP_Background_Sync"; value = $true }
)

# 5. Apply each setting independently
foreach ($setting in $rcLdapSettings) {
    try {
        $body = @{ value = $setting.value } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings/$($setting._id)" `
            -Method Post `
            -Headers $rcHeaders `
            -ContentType "application/json" `
            -Body $body

        if ($res.success) {
            Write-Host "Updated setting: $($setting._id)" -ForegroundColor Green
        }
    } catch {
        $errBody = ""
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errBody = $reader.ReadToEnd()
        }
        Write-Host "Note updating $($setting._id): $errBody" -ForegroundColor Yellow
    }
}

# ==============================================================================
# 6. Import midPoint Roles, Users, and Object Template
# ==============================================================================

if (Test-Path -Path "midpoint/roles_and_users.xml") {
    docker cp midpoint/roles_and_users.xml iam-midpoint:/tmp/roles_and_users.xml
    docker exec iam-midpoint /opt/midpoint/bin/ninja.sh import -i /tmp/roles_and_users.xml -O
    Write-Host "Synchronized midPoint roles, inducements, and identities successfully." -ForegroundColor Green
}

if (Test-Path -Path "midpoint/user-template.xml") {
    docker cp midpoint/user-template.xml iam-midpoint:/tmp/user-template.xml
    docker exec iam-midpoint /opt/midpoint/bin/ninja.sh import -i /tmp/user-template.xml -O
    Write-Host "Default User Object Template imported into midPoint." -ForegroundColor Green
}

# ==============================================================================
# 7. Apply System Configuration Delta & Trigger User Recomputation
# ==============================================================================

$logOutput = docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password"
if ($logOutput) {
    $adminPassword = ($logOutput -split ":")[-1].Trim().Trim('"')
} else {
    $adminPassword = "5ecr3t" # Fallback if standard image is used
}

$midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))
$authHeader = "Basic $midpointAuth"
$mpHeaders = @{ 
    "Authorization" = $authHeader
    "Content-Type"  = "application/xml; charset=utf-8"
}

if (Test-Path -Path "midPoint/apply-user-template-delta.xml") {
    Write-Host "Applying Default User Template to System Configuration..." -ForegroundColor Yellow
    $deltaXml = Get-Content -Path "midPoint/apply-user-template-delta.xml" -Raw

    try {
        $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/systemConfigurations/00000000-0000-0000-0000-000000000001" `
            -Method Patch `
            -Headers $mpHeaders `
            -ContentType "application/xml" `
            -Body $deltaXml
        Write-Host "Default User Template successfully assigned to System Configuration." -ForegroundColor Green
    } catch {
        Write-Host "Failed to apply System Configuration delta: $_" -ForegroundColor Red
    }
}

Write-Host "Reconciling midPoint users to OpenLDAP target..." -ForegroundColor Yellow

$recomputeTask = @"
<task xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
      xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>Recompute All Users</name>
    <category>Recomputation</category>
    <ownerRef oid="00000000-0000-0000-0000-000000000002" type="c:UserType"/>
    <executionState>runnable</executionState>
    <activity>
        <work>
            <recomputation>
                <objects>
                    <type>c:UserType</type>
                </objects>
            </recomputation>
        </work>
    </activity>
</task>
"@

try {
    $null = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/tasks" `
        -Method Post `
        -Headers $mpHeaders `
        -ContentType "application/xml" `
        -Body $recomputeTask
    Write-Host "Triggered midPoint user recomputation task." -ForegroundColor Green
} catch {
    Write-Host "Failed to trigger recomputation task: $_" -ForegroundColor Red
}

