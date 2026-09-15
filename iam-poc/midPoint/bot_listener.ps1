# ==============================================================================
# bot_poller.ps1 - Rocket.Chat REST API Poller for IAM Lifecycle Events
# ==============================================================================

# 1. Authenticate with Rocket.Chat
$rcAdminPass = "AdminPassword123!"
$rcAuth = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/login" `
    -Method Post `
    -ContentType "application/json" `
    -Body (@{ user = "admin"; password = $rcAdminPass } | ConvertTo-Json)

$passBytes = [System.Text.Encoding]::UTF8.GetBytes($rcAdminPass)
$passHash  = -join ([System.Security.Cryptography.SHA256]::Create().ComputeHash($passBytes) | ForEach-Object { $_.ToString("x2") })

$rcHeaders = @{
    "X-Auth-Token" = $rcAuth.data.authToken
    "X-User-Id"    = $rcAuth.data.userId
    "X-2fa-Code"   = $passHash
    "X-2fa-Method" = "password"
    "Content-Type" = "application/json"
}

$botUserId = $rcAuth.data.userId

# 2. Get Room ID for #hr
$roomInfo = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.info?roomName=hr" -Method Get -Headers $rcHeaders
$roomId   = $roomInfo.channel._id

Write-Host "IAM Bot Poller active. Watching #hr channel for !join, !move, !leave..." -ForegroundColor Green

# 3. Initialize timestamp tracker
$lastCheckIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

while ($true) {
    try {
        # Fetch recent messages from #hr
        $history = Invoke-RestMethod -Uri "http://localhost:4000/api/v1/channels.history?roomId=$roomId&oldest=$lastCheckIso" -Method Get -Headers $rcHeaders

        if ($history.messages -and $history.messages.Count -gt 0) {
            # Sort chronologically
            $messages = $history.messages | Sort-Object _updatedAt

            foreach ($msg in $messages) {
                # Skip messages sent by the bot itself
                if ($msg.u._id -eq $botUserId) { continue }

                $chatText = $msg.msg.Trim()
                $user     = $msg.u.username
                $parts    = $chatText -split "\s+"
                $cmd      = $parts[0].ToLower()

                if ($cmd -in @("!join", "!move", "!leave")) {
                    Write-Host "Processing $cmd command from @$user..." -ForegroundColor Cyan
                    $replyText = ""

                    try {
                        switch ($cmd) {
                            "!join" {
                                $targetUser = $parts[1]
                                $targetRole = $parts[2]
                                $givenName  = if ($parts.Count -gt 3) { $parts[3] } else { "New" }
                                $familyName = if ($parts.Count -gt 4) { $parts[4] } else { "User" }

                                $output = & .\test_joiner.ps1 -username $targetUser -roleName $targetRole -givenName $givenName -familyName $familyName 2>&1 | Out-String
                                $replyText = "*[JOINER COMPLETED]* Executed by @" + $user + "`n`n" + $output
                            }
                            "!move" {
                                $targetUser = $parts[1]
                                $newRole    = $parts[2]

                                $output = & .\test_mover.ps1 -targetUsername $targetUser -newRoleName $newRole 2>&1 | Out-String
                                $replyText = "*[MOVER COMPLETED]* Executed by @" + $user + "`n`n" + $output
                            }
                            "!leave" {
                                $targetUser = $parts[1]

                                $output = & .\test_leaver.ps1 -targetUsername $targetUser 2>&1 | Out-String
                                $replyText = "*[LEAVER COMPLETED]* Executed by @" + $user + "`n`n" + $output
                            }
                        }
                    } catch {
                        $replyText = "*[ERROR]* Execution failed: " + $_.Exception.Message
                    }

                    # Reply directly back to the channel
                    $postBody = @{ roomId = $roomId; text = $replyText } | ConvertTo-Json
                    Invoke-RestMethod -Uri "http://localhost:4000/api/v1/chat.postMessage" -Method Post -Headers $rcHeaders -Body $postBody | Out-Null
                }

                # Update checkpoint timestamp
                $lastCheckIso = $msg._updatedAt
            }
        }
    } catch {
        Write-Host "Polling error: $_" -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}
