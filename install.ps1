# install.ps1 — Installation de Cisco 8800 Remote Controller
# Cree un raccourci bureau et prepare l'environnement
$ErrorActionPreference = "Stop"
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host "  Cisco 8800 Remote Controller — Installation   " -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan
Write-Host ""

$ok = $true

# ── 1. Verification plink.exe (requis pour SSH) ───────────────
$plinkInPath   = Get-Command "plink.exe" -ErrorAction SilentlyContinue
$plinkInFolder = Test-Path (Join-Path $dir "plink.exe")
if ($plinkInPath -or $plinkInFolder) {
    Write-Host "[OK]   plink.exe detecte (diagnostics SSH disponibles)" -ForegroundColor Green
} else {
    Write-Host "[WARN] plink.exe introuvable — les diagnostics SSH ne fonctionneront pas." -ForegroundColor Yellow
    Write-Host "       Placer plink.exe dans ce dossier OU l'ajouter au PATH." -ForegroundColor Yellow
    Write-Host "       Telechargement : https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html" -ForegroundColor Yellow
}
Write-Host ""

# ── 2. Copie phones.json si absent ────────────────────────────
$phonesJson    = Join-Path $dir "phones.json"
$phonesExample = Join-Path $dir "phones.example.json"
if (-not (Test-Path $phonesJson)) {
    if (Test-Path $phonesExample) {
        Copy-Item $phonesExample $phonesJson
        Write-Host "[OK]   phones.json cree depuis phones.example.json" -ForegroundColor Green
        Write-Host "       Editer ce fichier pour configurer vos telephones." -ForegroundColor Gray
    } else {
        "[]" | Out-File $phonesJson -Encoding utf8
        Write-Host "[OK]   phones.json cree (vide). Ajouter vos telephones via l'onglet AXL." -ForegroundColor Green
    }
} else {
    Write-Host "[OK]   phones.json existant conserve" -ForegroundColor Green
}
Write-Host ""

# ── 3. Raccourci bureau ────────────────────────────────────────
$launchScript = Join-Path $dir "launch.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Cisco 8800 Controller.lnk"

try {
    $shell            = New-Object -ComObject WScript.Shell
    $sc               = $shell.CreateShortcut($shortcutPath)
    $sc.TargetPath    = "powershell.exe"
    $sc.Arguments     = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$launchScript`""
    $sc.WorkingDirectory = $dir
    $sc.Description   = "Cisco 8800 Remote Controller"
    $sc.IconLocation  = "%SystemRoot%\System32\shell32.dll,22"
    $sc.Save()
    Write-Host "[OK]   Raccourci cree : Bureau\Cisco 8800 Controller" -ForegroundColor Green
} catch {
    Write-Host "[ERR]  Impossible de creer le raccourci : $_" -ForegroundColor Red
    $ok = $false
}
Write-Host ""

# ── 4. Raccourci menu Demarrer (optionnel) ─────────────────────
$startMenu = Join-Path ([Environment]::GetFolderPath("Programs")) "Cisco 8800 Controller.lnk"
try {
    $shell2            = New-Object -ComObject WScript.Shell
    $sc2               = $shell2.CreateShortcut($startMenu)
    $sc2.TargetPath    = "powershell.exe"
    $sc2.Arguments     = "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$launchScript`""
    $sc2.WorkingDirectory = $dir
    $sc2.Description   = "Cisco 8800 Remote Controller"
    $sc2.IconLocation  = "%SystemRoot%\System32\shell32.dll,22"
    $sc2.Save()
    Write-Host "[OK]   Raccourci cree : Menu Demarrer\Cisco 8800 Controller" -ForegroundColor Green
} catch {
    Write-Host "[WARN] Raccourci menu Demarrer non cree : $_" -ForegroundColor Yellow
}
Write-Host ""

# ── Resume ─────────────────────────────────────────────────────
if ($ok) {
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host "  Installation terminee avec succes !            " -ForegroundColor Green
    Write-Host "=================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Double-cliquez sur 'Cisco 8800 Controller'" -ForegroundColor White
    Write-Host "  sur le bureau pour demarrer l'application." -ForegroundColor White
} else {
    Write-Host "Installation terminee avec des avertissements." -ForegroundColor Yellow
}
Write-Host ""

$launch = Read-Host "Demarrer l'application maintenant ? (O/n)"
if ($launch -ne "n" -and $launch -ne "N") {
    & powershell -ExecutionPolicy Bypass -NonInteractive -File $launchScript
}