# push-to-github.ps1
# Script de publication du depot sur GitHub
# Executer une seule fois apres l installation de Git
#
# Usage : powershell -ExecutionPolicy Bypass -File .\push-to-github.ps1 -RepoName cisco-8800-remote-controller

param(
    [string]$RepoName = "cisco-8800-remote-controller",
    [string]$Description = "Application web locale pour piloter les telephones Cisco IP Phone 8800 et gerer les ressources CUCM via AXL",
    [switch]$Private
)

$git = "C:\Program Files\Git\bin\git.exe"
$ErrorActionPreference = "Stop"

Write-Host "=== Publication GitHub - Cisco 8800 Remote Controller ===" -ForegroundColor Cyan

# 1. Verifier que git est installe
if (-not (Test-Path $git)) {
    Write-Error "Git non trouve. Installer Git for Windows depuis https://git-scm.com"
    exit 1
}

# 2. Verifier / installer gh CLI (ZIP portable, sans droits admin)
$ghPortable = Get-ChildItem "$env:LOCALAPPDATA\gh-cli" -Filter "gh.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
$ghSystem   = Get-Command gh -ErrorAction SilentlyContinue
$gh = if ($ghPortable) { $ghPortable } elseif ($ghSystem) { $ghSystem.Source } else { $null }
if (-not $gh) {
    Write-Host "Telechargement de gh CLI (ZIP portable)..." -ForegroundColor Yellow
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ghZipUrl = "https://github.com/cli/cli/releases/download/v2.62.0/gh_2.62.0_windows_amd64.zip"
    $ghZip    = "$env:TEMP\gh_cli.zip"
    $ghDir    = "$env:LOCALAPPDATA\gh-cli"
    Invoke-WebRequest -Uri $ghZipUrl -OutFile $ghZip -UseBasicParsing
    Expand-Archive -Path $ghZip -DestinationPath $ghDir -Force
    # Trouver gh.exe ou qu'il soit dans l'arborescence extraite
    $extracted = Get-ChildItem $ghDir -Filter "gh.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $extracted) {
        Write-Error "gh.exe introuvable apres extraction dans $ghDir"
        exit 1
    }
    $gh = $extracted.FullName
    Write-Host "gh CLI installe dans $gh" -ForegroundColor Green
}

# 3. Authentification GitHub
Write-Host "`nAuthentification GitHub (navigateur)..." -ForegroundColor Yellow
& $gh auth login --web --git-protocol https
if ($LASTEXITCODE -ne 0) {
    Write-Error "Authentification GitHub echouee"
    exit 1
}

# 4. Recuperer le nom d utilisateur GitHub
$ghUser = & $gh api user --jq .login 2>&1
Write-Host "Connecte en tant que : $ghUser" -ForegroundColor Green

# 5. Creer le depot GitHub
Write-Host "`nCreation du depot GitHub '$RepoName'..." -ForegroundColor Yellow
$visibility = if ($Private) { "--private" } else { "--public" }
& $gh repo create $RepoName --description $Description $visibility --source . --remote origin --push
if ($LASTEXITCODE -ne 0) {
    # Si le depot existe deja, juste ajouter le remote et pousser
    Write-Host "Ajout du remote existant..." -ForegroundColor Yellow
    & $git remote remove origin 2>&1 | Out-Null
    & $git remote add origin "https://github.com/$ghUser/$RepoName.git"
    & $git push -u origin main
}

Write-Host "`n=== Publie avec succes ! ===" -ForegroundColor Green
Write-Host "URL : https://github.com/$ghUser/$RepoName" -ForegroundColor Cyan
Write-Host "Mettre a jour le lien clone dans README.md :" -ForegroundColor Yellow
Write-Host "  git clone https://github.com/$ghUser/$RepoName.git" -ForegroundColor White
