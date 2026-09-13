$testUserXml = @"
<user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3" 
      xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
    <name>evan.dev</name>
    <givenName>Evan</givenName>
    <familyName>Dev</familyName>
    <assignment>
        <targetRef oid="10000000-0000-0000-0000-000000000001" type="c:RoleType"/>
    </assignment>
</user>
"@

$testUserXml | Out-File -Encoding utf8 test_evan.xml
docker cp test_evan.xml iam-midpoint:/tmp/test_evan.xml
docker exec iam-midpoint /opt/midpoint/bin/ninja.sh import -i /tmp/test_evan.xml

Start-Sleep -Seconds 30

# Export evan.dev directly to an XML file inside the container
docker exec iam-midpoint /opt/midpoint/bin/ninja.sh export -t user -f "%name = 'evan.dev'" -o /tmp/evan_exported.xml

# View the exported user identity XML
docker exec iam-midpoint cat /tmp/evan_exported.xml