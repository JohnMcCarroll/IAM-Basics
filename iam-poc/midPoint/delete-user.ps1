# 1. Search for devan.dev OID                                          
$searchXml = @"                                                                                             
<query xmlns="http://prism.evolveum.com/xml/ns/public/query-3">                          
    <filter>                                                                   
        <equal>                                                                                                          
            <path>name</path>                                                                                       
            <value>devan.dev</value>                           
        </equal>                                         
    </filter>                                                                                             
</query>                                        
"@                                                                                                     
                                           
$searchResults = Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/search" `
                                   -Method Post `
                                   -Headers $headers `                                                                   
                                   -ContentType "application/xml" `              
                                   -Body $searchXml
                                                                                                                
$devanOid = $searchResults.object.object.oid                                                                             
                                       
# 2. Delete user from midPoint                                                                         
if ($devanOid) {                
    Invoke-RestMethod -Uri "http://localhost:8081/midpoint/ws/rest/users/$devanOid" `
                      -Method Delete `            
                      -Headers $headers
    Write-Host "Deleted user devan.dev (OID: $devanOid) from midPoint." -ForegroundColor Green
} else {
    Write-Host "User devan.dev not found in midPoint." -ForegroundColor Yellow
}