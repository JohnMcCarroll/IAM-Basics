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

# 2. Minimal user XML payload (isolates base user ingestion)
$testUserXml = @"
<user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3"
      xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>devan.dev</name>
    <givenName>Devan</givenName>
    <familyName>Dev</familyName>
    <emailAddress>devan.dev@company.local</emailAddress>
    <credentials>
        <password>
            <value>
                <clearValue>Password123!</clearValue>
            </value>
        </password>
    </credentials>
    <assignment>
        <targetRef oid="10000000-0000-0000-0000-000000000001" type="c:RoleType"/>
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
    Write-Host "Successfully ingested devan.dev into midPoint!" -ForegroundColor Green
} catch {
    Write-Host "Failed to ingest user:" -ForegroundColor Red
    if ($_.Exception.Response) {
        $stream = $_.Exception.Response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream)
        Write-Host $reader.ReadToEnd() -ForegroundColor Yellow
    } else {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}


..\rbac.ps1