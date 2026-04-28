; ============================================================
;  Cisco 8800 Remote Controller — Inno Setup Installer Script
;  Compile avec : ISCC.exe installer.iss
; ============================================================

#define AppName    "Cisco 8800 Remote Controller"
#define AppVersion "1.0"
#define AppPublisher "vincent051"
#define AppURL     "https://github.com/vincent051/cisco-8800-remote-controller"
#define AppExeName "launch.ps1"
#define SourceDir  "c:\Users\deepadm\Documents\vsc"

[Setup]
AppId={{8C3F1A2B-4D5E-4F6A-B7C8-D9E0F1A2B3C4}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
DefaultDirName={localappdata}\Cisco8800Controller
DefaultGroupName={#AppName}
AllowNoIcons=yes
OutputDir={#SourceDir}\installer-output
OutputBaseFilename=Cisco8800Controller-Setup-v{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
; Pas de droits admin requis (install dans %LOCALAPPDATA%)

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"

[Tasks]
Name: "desktopicon"; Description: "Créer un raccourci sur le Bureau"; GroupDescription: "Icônes supplémentaires :"; Flags: unchecked
Name: "quicklaunchicon"; Description: "Créer un raccourci dans la barre des tâches"; GroupDescription: "Icônes supplémentaires :"; Flags: unchecked; OnlyBelowVersion: 6.1; Check: not IsAdminInstallMode

[Files]
; Fichiers principaux
Source: "{#SourceDir}\server.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\launch.ps1";        DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\restart-server.ps1";DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\install.ps1";       DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\start.ps1";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\phones.example.json";DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md";         DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE";           DestDir: "{app}"; Flags: ignoreversion

; Dossier web (interface)
Source: "{#SourceDir}\web\*"; DestDir: "{app}\web"; Flags: ignoreversion recursesubdirs createallsubdirs

; phones.json : NE PAS ecraser si deja present (donnees utilisateur)
Source: "{#SourceDir}\phones.example.json"; DestDir: "{app}"; DestName: "phones.json"; Flags: onlyifdoesntexist uninsneveruninstall

; cucm-connections.json : NE PAS ecraser si deja present
Source: "{#SourceDir}\cucm-connections.json"; DestDir: "{app}"; Flags: onlyifdoesntexist uninsneveruninstall

[Icons]
; Raccourci Start Menu
Name: "{group}\{#AppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; Comment: "Lance le controleur Cisco 8800 et ouvre le navigateur"
; Raccourci "Arreter le serveur"
Name: "{group}\Arreter le serveur"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -Command ""Get-NetTCPConnection -LocalPort 8084 -ErrorAction SilentlyContinue | ForEach-Object {{ Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }}; Write-Host 'Serveur arrete.'"""; WorkingDir: "{app}"
; Desinstallation
Name: "{group}\Desinstaller {#AppName}"; Filename: "{uninstallexe}"
; Bureau (optionnel)
Name: "{userdesktop}\{#AppName}"; Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
; Execution de install.ps1 apres installation (cree phones.json, verifie plink)
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NonInteractive -File ""{app}\install.ps1"""; WorkingDir: "{app}"; Flags: runhidden waituntilterminated; StatusMsg: "Configuration initiale..."
; Proposition de lancer l'application apres installation
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\launch.ps1"""; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent; Description: "Lancer {#AppName}"

[UninstallRun]
; Arreter le serveur avant desinstallation
Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -Command ""Get-NetTCPConnection -LocalPort 8084 -ErrorAction SilentlyContinue | ForEach-Object {{ Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }}"""; RunOnceId: "StopServer"; Flags: runhidden waituntilterminated

[UninstallDelete]
; Supprimer les fichiers generes (logs, temp) mais PAS phones.json ni cucm-connections.json
Type: filesandordirs; Name: "{app}\installer-output"
