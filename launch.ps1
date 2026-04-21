# launch.ps1 — Demarre le serveur Cisco 8800 Controller et ouvre le navigateur
param([int]$Port = 8084)

$dir = $PSScriptRoot

# Demarrer le serveur s'il n'est pas deja en ecoute
$listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $listening) {
    $restartScript = Join-Path $dir "restart-server.ps1"
    powershell -ExecutionPolicy Bypass -NonInteractive -File $restartScript -Port $Port
}

# Ouvrir le navigateur
Start-Process "http://localhost:$Port"