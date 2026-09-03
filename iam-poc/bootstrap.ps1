# bootstrap.ps1 - Automated IAM PoC Environment Setup

Write-Host "Launching Docker multicontainer environment" -ForegroundColor Cyan

docker compose up -d

Start-Sleep -Seconds 60 # wait for containers to initalize


$ErrorActionPreference = "Stop"
Write-Host "[1/4] Waiting for services to become responsive..." -ForegroundColor Cyan

# Polling helper function
function Wait-ForUrl {
    param (
        [string]$Uri,
        [string]$ServiceName
    )
    Write-Host "Waiting for $ServiceName ($Uri)..." -NoNewline
    do {
        Start-Sleep -Seconds 3
        $statusCode = try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            $response.StatusCode
        } catch {
            if ($_.Exception.Response) {
                [int]$_.Exception.Response.StatusCode
            } else {
                0
            }
        }
        Write-Host "." -NoNewline
    } until ($statusCode -ge 200 -and $statusCode -lt 400)
    
    Write-Host " Ready! (HTTP $statusCode)" -ForegroundColor Green
}

# Wait for Keycloak and Gitea web endpoints
Wait-ForUrl -Uri "http://localhost:8080/realms/master" -ServiceName "Keycloak"
Wait-ForUrl -Uri "http://localhost:3000" -ServiceName "Gitea"

Write-Host "`n[2/4] Provisioning Keycloak OIDC Clients via kcadm CLI..." -ForegroundColor Cyan

$giteaSecret = "gitea-secret-123"
$rocketchatSecret = "rocketchat-secret-123"

$oldEAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# Authenticate Keycloak Admin CLI inside container
docker exec iam-keycloak /opt/keycloak/bin/kcadm.sh config credentials `
    --server http://localhost:8080 `
    --realm master `
    --user admin `
    --password admin

# Define JSON payloads
$giteaClientJson = @"
{
    "clientId": "gitea",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "$giteaSecret",
    "redirectUris": ["http://localhost:3000/user/oauth2/keycloak/callback"],
    "publicClient": false
}
"@

$rocketchatClientJson = @"
{
    "clientId": "rocketchat",
    "enabled": true,
    "clientAuthenticatorType": "client-secret",
    "secret": "$rocketchatSecret",
    "redirectUris": ["http://localhost:4000/_oauth/keycloak"],
    "publicClient": false
}
"@

$giteaClientJson | docker exec -i iam-keycloak /opt/keycloak/bin/kcadm.sh create clients -r master -f -
$rocketchatClientJson | docker exec -i iam-keycloak /opt/keycloak/bin/kcadm.sh create clients -r master -f -

# Seed Keycloak users from XML
$xmlFilePath = "init_employees_midPoint.xml"

if (Test-Path $xmlFilePath) {
    [xml]$xmlContent = Get-Content $xmlFilePath
    $xmlUsers = $xmlContent.SelectNodes("//*[local-name()='user']")

    foreach ($u in $xmlUsers) {
        $username  = $u.name
        $firstName = if ($u.givenName) { $u.givenName } else { $username }
        $lastName  = if ($u.familyName) { $u.familyName } else { "User" }
        $email     = if ($u.emailAddress) { $u.emailAddress } else { "$username@company.local" }

        docker exec iam-keycloak /opt/keycloak/bin/kcadm.sh create users -r master `
            -s username="$username" `
            -s enabled=true `
            -s email="$email" `
            -s firstName="$firstName" `
            -s lastName="$lastName"

        docker exec iam-keycloak /opt/keycloak/bin/kcadm.sh set-password -r master `
            --username "$username" `
            --new-password "Password123!" `
            --temporary=false
    }
    Write-Host "Parsed XML and seeded $($xmlUsers.Count) users into Keycloak." -ForegroundColor Green
} else {
    Write-Host "Warning: $xmlFilePath not found. Skipping Keycloak user seeding." -ForegroundColor Yellow
}

Write-Host "Keycloak OIDC clients configured successfully." -ForegroundColor Green

Write-Host "`n[3/4] Configuring Gitea Admin, Keycloak SSO, and Trade Scripts Repo..." -ForegroundColor Cyan

# Create Gitea Admin User
docker exec -u git iam-gitea gitea admin user create `
    --username giteaadmin `
    --password "Password123!" `
    --email "admin@company.local" `
    --admin

# Register Keycloak in Gitea
docker exec -u git iam-gitea gitea admin auth add-oauth `
    --name keycloak `
    --provider openidConnect `
    --key gitea `
    --secret $giteaSecret `
    --auto-discover-url "http://keycloak:8080/realms/master/.well-known/openid-configuration" `
    --use-custom-urls true `
    --custom-auth-url "http://localhost:8080/realms/master/protocol/openid-connect/auth" `
    --custom-token-url "http://keycloak:8080/realms/master/protocol/openid-connect/token" `
    --custom-profile-url "http://keycloak:8080/realms/master/protocol/openid-connect/userinfo"

# Populate Gitea Repository via REST API
$giteaAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("giteaadmin:Password123!"))
$giteaHeaders = @{
    "Authorization" = "Basic $giteaAuth"
    "Content-Type"  = "application/json"
}

try {
    $repoBody = @{ name = "trade-scripts"; auto_init = $true; private = $false } | ConvertTo-Json
    Invoke-RestMethod -Uri "http://localhost:3000/api/v1/admin/users/giteaadmin/repos" `
        -Method Post -Headers $giteaHeaders -Body $repoBody
    Write-Host "Created Gitea repository: trade-scripts" -ForegroundColor Green
} catch {
    Write-Host "Gitea repository 'trade-scripts' already exists." -ForegroundColor Yellow
}

# Seed simulate_trade.py script into Gitea
$pythonCode = @"
import sys, random, json

trade_id = sys.argv[1] if len(sys.argv) > 1 else "TRD-DEFAULT"
symbol   = sys.argv[2] if len(sys.argv) > 2 else "AAPL"
quantity = sys.argv[3] if len(sys.argv) > 3 else "100"

pnl = round(random.uniform(-500.0, 1500.0), 2)
result = {
    "trade_id": trade_id,
    "symbol": symbol,
    "quantity": quantity,
    "status": "PROFIT" if pnl >= 0 else "LOSS",
    "pnl_usd": pnl
}
print(json.dumps(result))
"@

$encodedCode = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pythonCode))

try {
    $fileBody = @{
        content = $encodedCode
        message = "Add simulate_trade.py execution script"
    } | ConvertTo-Json

    Invoke-RestMethod -Uri "http://localhost:3000/api/v1/repos/giteaadmin/trade-scripts/contents/simulate_trade.py" `
        -Method Post -Headers $giteaHeaders -Body $fileBody
    Write-Host "Seeded simulate_trade.py into Gitea repo." -ForegroundColor Green
} catch {
    Write-Host "simulate_trade.py already present in repository." -ForegroundColor Yellow
}

$ErrorActionPreference = $oldEAP
Write-Host "Gitea setup complete." -ForegroundColor Green

Write-Host "`n[4/4] Synchronizing midPoint and Configuring Rocket.Chat..." -ForegroundColor Cyan

Wait-ForUrl -Uri "http://localhost:8081" -ServiceName "midPoint"

if (Test-Path $xmlFilePath) {
    docker cp $xmlFilePath iam-midpoint:/tmp/init_employees_midPoint.xml
    docker exec iam-midpoint /opt/midpoint/bin/ninja.sh import -i /tmp/init_employees_midPoint.xml -O
    Write-Host "Employees and roles synchronized into midPoint." -ForegroundColor Green
} else {
    Write-Host "Error: $xmlFilePath was not found!" -ForegroundColor Red
}

# Rocket.Chat REST API Setup
Wait-ForUrl -Uri "http://localhost:4000/api/info" -ServiceName "Rocket.Chat API"

$adminUser = "admin"
$adminPassword = "AdminPassword123!"

$passwordBytes = [System.Text.Encoding]::UTF8.GetBytes($adminPassword)
$hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash($passwordBytes)
$passwordHash = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })

$rcLogin = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" -Method Post `
    -ContentType "application/json" -Body (@{ user = $adminUser; password = $adminPassword } | ConvertTo-Json)

$rcHeaders = @{
    "X-Auth-Token" = $rcLogin.data.authToken
    "X-User-Id"    = $rcLogin.data.userId
    "x-2fa-code"   = $passwordHash
    "x-2fa-method" = "password"
}

try {
    Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings.addCustomOAuth" -Method Post `
        -Headers $rcHeaders -ContentType "application/json" -Body (@{ name = "keycloak" } | ConvertTo-Json)
} catch {
    Write-Host "Custom OAuth integration 'keycloak' already instantiated." -ForegroundColor Yellow
}

$rcSettings = @(
    @{ _id = "Accounts_OAuth_Custom-Keycloak"; value = $true },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-url"; value = "http://keycloak:8080" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-authorize_path"; value = "/realms/master/protocol/openid-connect/auth" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-token_path"; value = "/realms/master/protocol/openid-connect/token" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-identity_path"; value = "/realms/master/protocol/openid-connect/userinfo" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-identity_token_sent_via"; value = "header" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-token_sent_via"; value = "header" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-id"; value = "rocketchat" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-secret"; value = "rocketchat-secret-123" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-login_style"; value = "redirect" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-button_label_text"; value = "Keycloak" },
    @{ _id = "Accounts_OAuth_Custom-Keycloak-merge_users"; value = $true },
    @{ _id = "Accounts_EmailVerification"; value = $false },
    @{ _id = "Accounts_Verify_Email_For_OAuth_Users"; value = $false },
    @{ _id = "Accounts_TwoFactorAuthentication_By_Email_Auto_Opt_In"; value = $false },
    @{ _id = "Accounts_TwoFactorAuthentication_By_Email_Enabled"; value = $false }
)

foreach ($setting in $rcSettings) {
    try {
        $body = @{ value = $setting.value } | ConvertTo-Json
        $res = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/settings/$($setting._id)" `
            -Method POST -Headers $rcHeaders -ContentType "application/json" -Body $body
        if ($res.success) {
            Write-Host "Successfully updated $($setting._id)" -ForegroundColor Green
        }
    } catch {
        Write-Host "Note updating $($setting._id)" -ForegroundColor Yellow
    }
}

# Create Rocket.Chat Channels
$channels = @("managers", "dev", "trades", "hr", "trade-approvals")

foreach ($channel in $channels) {
    try {
        Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.create" `
            -Method Post -Headers $rcHeaders -ContentType "application/json" `
            -Body (@{ name = $channel; isDefault = $true } | ConvertTo-Json)
        Write-Host "Created channel: #$channel" -ForegroundColor Green
    } catch {
        Write-Host "Channel #$channel already exists." -ForegroundColor Yellow
    }
}

# Initialize PostgreSQL table for trades logging using container credentials
try {
    $createTableSql = "CREATE TABLE IF NOT EXISTS trades (trade_id VARCHAR(50) PRIMARY KEY, requester VARCHAR(50), approver VARCHAR(50), symbol VARCHAR(10), quantity INT, status VARCHAR(20), pnl_usd NUMERIC(10,2), created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP);"
    
    # Updated credentials: -U iam_user -d iam_database
    $psqlOut = docker exec -i iam-postgres psql -U iam_user -d iam_database -c $createTableSql 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Initialized PostgreSQL trades audit table." -ForegroundColor Green
    } else {
        Write-Host "PostgreSQL initialization failed: $psqlOut" -ForegroundColor Red
    }
} catch {
    Write-Host "Error connecting to PostgreSQL container: $_" -ForegroundColor Red
}

# configure rocketchat webhooks
# Auto-configure Rocket.Chat Integrations for Trade Bot
$tradeHookJson = @"
{
    "type": "webhook-outgoing",
    "name": "Trade Request Hook",
    "enabled": true,
    "username": "admin",
    "channel": "#trades",
    "event": "sendMessage",
    "triggerWords": ["!trade"],
    "urls": ["http://trade-bot:5000/webhook/trade"],
    "scriptEnabled": false
}
"@

$approveHookJson = @"
{
    "type": "webhook-outgoing",
    "name": "Trade Approval Hook",
    "enabled": true,
    "username": "admin",
    "channel": "#trade-approvals",
    "event": "sendMessage",
    "triggerWords": ["!approve"],
    "urls": ["http://trade-bot:5000/webhook/approve"],
    "scriptEnabled": false
}
"@

# Remove existing hooks if present to allow clean re-runs
try {
    $existing = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/integrations.list" -Method Get -Headers $rcHeaders
} catch {
    $existing = $null
}

$hooks = @(
    @{ Name = "Trade Request Hook"; Json = $tradeHookJson },
    @{ Name = "Trade Approval Hook"; Json = $approveHookJson }
)

foreach ($hook in $hooks) {
    $match = $existing.integrations | Where-Object { $_.name -eq $hook.Name }
    if ($match) {
        try {
            $removeBody = @{ integrationId = $match._id; type = "webhook-outgoing" } | ConvertTo-Json
            Invoke-RestMethod -Uri "http://localhost:4000/api/v1/integrations.remove" `
                -Method Post -Headers $rcHeaders -ContentType "application/json" -Body $removeBody | Out-Null
        } catch {}
    }

    try {
        Invoke-RestMethod -Uri "http://localhost:4000/api/v1/integrations.create" `
            -Method Post -Headers $rcHeaders -ContentType "application/json" -Body $hook.Json | Out-Null
        Write-Host "Registered Rocket.Chat webhook: $($hook.Name)" -ForegroundColor Green
    } catch {
        Write-Host "Failed to register webhook $($hook.Name): $_" -ForegroundColor Red
    }
}

Write-Host "`nEnvironment Bootstrap Complete!" -ForegroundColor Green

