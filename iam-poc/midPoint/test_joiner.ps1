# ==============================================================================
# test_joiner.ps1 - Dynamic Onboarding Process
# ==============================================================================
param(
    [Parameter(Mandatory = $true)]
    [string]$username,

    [Parameter(Mandatory = $true)]
    [string]$roleName,

    [Parameter(Mandatory = $false)]
    [string]$givenName = "New",

    [Parameter(Mandatory = $false)]
    [string]$familyName = "User",

    [Parameter(Mandatory = $false)]
    [string]$email = "$username@company.local",

    [Parameter(Mandatory = $false)]
    [string]$password = "Password123!"
)

# Role OID mapping table
$roleOidMap = @{
    "developer"       = "10000000-0000-0000-0000-000000000001"
    "trader"          = "10000000-0000-0000-0000-000000000002"
    "manager"         = "10000000-0000-0000-0000-000000000003"
    "human_resources" = "10000000-0000-0000-0000-000000000004"
}

# Validate and resolve Role OID
if (-not $roleOidMap.ContainsKey($roleName)) {
    Write-Host "Error: Role '$roleName' is not valid. Allowed roles: $(($roleOidMap.Keys) -join ', ')" -ForegroundColor Red
    exit
}
$roleOid = $roleOidMap[$roleName]

# 1. Safely extract latest initial password
$logMatch = (docker logs iam-midpoint 2>&1 | Select-String -Pattern "initial password")[-1]
if ($logMatch) {
    $adminPassword = ($logMatch -split ":")[-1].Trim().Trim('"')
} else {
    $adminPassword = "5ecr3t"
}

$midpointAuth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("Administrator:$adminPassword"))

$headers = @{
    "Authorization" = "Basic $midpointAuth"
    "Accept"        = "application/xml"
}

# 2. Dynamic user XML payload
$testUserXml = @"
<user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
      xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>$username</name>
    <givenName>$givenName</givenName>
    <familyName>$familyName</familyName>
    <emailAddress>$email</emailAddress>
    <credentials>
        <password>
            <value>
                <clearValue>$password</clearValue>
            </value>
        </password>
    </credentials>
    <assignment>
        <targetRef oid="$roleOid" type="c:RoleType"/>
    </assignment>
</user>
"@

# 3. Ingest user via REST API
try {
    $response = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users" `
                                  -Method Post `
                                  -Headers $headers `
                                  -ContentType "application/xml" `
                                  -Body $testUserXml
    Write-Host "Successfully ingested '$username' into midPoint with role '$roleName'!" -ForegroundColor Green
} catch {
    Write-Host "Failed to ingest user '$username':" -ForegroundColor Red
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        Write-Host $reader.ReadToEnd() -ForegroundColor Yellow
    } else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

# downstream provisioning
..\rbac.ps1
