$port = 8084
$script = "c:\Users\deepadm\Documents\vsc\server.ps1"

# 1. Stopper les jobs PowerShell
Get-Job | Stop-Job -PassThru | Remove-Job -Force

# 2. Tuer les processus orphelins (uniquement server.ps1, pas restart-server.ps1)
Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*server.ps1*" -and $_.CommandLine -notlike "*restart-server*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Tue PID $($_.ProcessId)" }

# 3. Attendre liberation du port (max 8s)
Write-Host "Attente liberation port $port..."
$waited = 0
while ($waited -lt 8) {
    $listeners = Get-NetTCPConnection -LocalPort $port -ErrorAction SilentlyContinue |
                 Where-Object { $_.State -eq "Listen" -or $_.State -eq "SynReceived" }
    if (-not $listeners) { break }
    Start-Sleep -Seconds 1; $waited++
}

# 4. Verifier la syntaxe avant de relancer
$errs = $null; $toks = $null
[System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$toks, [ref]$errs) | Out-Null
if ($errs.Count -gt 0) {
    $errs | ForEach-Object { Write-Host "ERR ligne $($_.Extent.StartLineNumber): $($_.Message)" }
    Write-Host "SYNTAXE KO - serveur non relance."
    exit 1
}
Write-Host "SYNTAXE OK"

# 5. Relancer via Start-Process (processus independant, survit a la fin du script)
Start-Process -FilePath "powershell" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$script`" -Port $port" -WindowStyle Hidden
Write-Host "Processus lance - attente serveur (max 15s)..."

# 6. Boucle d attente jusqu a 15s
$ok = $false
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-WebRequest "http://localhost:$port/api/phones" -UseBasicParsing -TimeoutSec 2
        Write-Host "Serveur OK (HTTP $($r.StatusCode)) apres $($i+1)s"
        $ok = $true
        break
    } catch { }
}
if (-not $ok) {
    Write-Host "ERREUR : serveur ne repond pas apres 15s"
    exit 1
}