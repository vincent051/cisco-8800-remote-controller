# build-installer.ps1 — Telecharge Inno Setup si absent, puis compile installer.iss
# Usage : double-cliquer build-installer.bat  (ou lancer en tant qu'Administrateur)
$ErrorActionPreference = "Stop"

# ── Verifier les droits admin (requis pour installer Inno Setup) ──────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "ATTENTION : ce script doit etre lance en tant qu'Administrateur" -ForegroundColor Red
    Write-Host "pour pouvoir installer Inno Setup automatiquement." -ForegroundColor Red
    Write-Host ""
    Write-Host "Solutions :" -ForegroundColor Yellow
    Write-Host "  1. Double-cliquer sur  build-installer.bat  (recommande)" -ForegroundColor Yellow
    Write-Host "  2. Ou installer Inno Setup manuellement : https://jrsoftware.org/isinfo.php" -ForegroundColor Yellow
    Write-Host "     puis relancer ce script normalement." -ForegroundColor Yellow
    Write-Host ""
    # Proposer l'elevation automatique
    $choice = Read-Host "Tenter l'elevation automatique maintenant ? (O/N)"
    if ($choice -match '^[oO]') {
        $scriptPath = $MyInvocation.MyCommand.Path
        Start-Process -FilePath "powershell.exe" `
            -ArgumentList "-ExecutionPolicy Bypass -NoExit -File `"$scriptPath`"" `
            -Verb RunAs
        exit 0
    }
    exit 1
}

$issFile = Join-Path $PSScriptRoot "installer.iss"
$outDir  = Join-Path $PSScriptRoot "installer-output"

# ── Trouver ISCC.exe ─────────────────────────────────────────
$isccPaths = @(
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
    "C:\Program Files\Inno Setup 6\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 5\ISCC.exe"
)
$isccExe = $isccPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $isccExe) {
    # Chercher dans le PATH
    $isccCmd = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
    if ($isccCmd) { $isccExe = $isccCmd.Source }
}

if (-not $isccExe) {
    Write-Host "Inno Setup introuvable. Telechargement en cours..." -ForegroundColor Yellow
    $installerUrl  = "https://jrsoftware.org/download.php/is.exe"
    $installerPath = "$env:TEMP\innosetup-installer.exe"

    # TLS 1.2
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $installerUrl -OutFile $installerPath

    Write-Host "Installation silencieuse d'Inno Setup..." -ForegroundColor Yellow
    Start-Process -FilePath $installerPath -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-" -Wait
    Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

    $isccExe = $isccPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $isccExe) {
        Write-Host "ERREUR : Inno Setup n'a pas pu etre installe automatiquement." -ForegroundColor Red
        Write-Host "Telecharger manuellement : https://jrsoftware.org/isinfo.php" -ForegroundColor Red
        exit 1
    }
    Write-Host "Inno Setup installe : $isccExe" -ForegroundColor Green
}

Write-Host ""
Write-Host "Compilation de $issFile..." -ForegroundColor Cyan
$result = & $isccExe $issFile
if ($LASTEXITCODE -eq 0) {
    $exeFile = Get-ChildItem $outDir -Filter "*.exe" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host ""
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host "  Installeur cree avec succes !" -ForegroundColor Green
    if ($exeFile) { Write-Host "  $($exeFile.FullName)" -ForegroundColor Green }
    Write-Host "=================================================" -ForegroundColor Green
} else {
    Write-Host "ERREUR : compilation echouee (code $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}
