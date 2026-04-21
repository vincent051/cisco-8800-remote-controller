param([int]$Port = 8083)

$script = Join-Path $PSScriptRoot "server.ps1"

while ($true) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Demarrage du serveur sur le port $Port..."
    & powershell -ExecutionPolicy Bypass -File $script -Port $Port
    $code = $LASTEXITCODE
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Serveur arrete (exit $code). Redemarrage dans 2 secondes..."
    Start-Sleep -Seconds 2
}
