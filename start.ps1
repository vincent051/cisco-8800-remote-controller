param([int]$Port = 8083)

$script = Join-Path $PSScriptRoot "server.ps1"

while ($true) {
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Starting server on port $Port..."
    & powershell -ExecutionPolicy Bypass -File $script -Port $Port
    $code = $LASTEXITCODE
    Write-Host "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Server stopped (exit $code). Restarting in 2 seconds..."
    Start-Sleep -Seconds 2
}
