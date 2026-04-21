# Cisco 8800 Remote Controller

Application web locale pour piloter des **téléphones Cisco IP Phone série 8800** et gérer les ressources CUCM via l'API AXL.

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue?style=flat-square)
![Platform Windows](https://img.shields.io/badge/Platform-Windows-lightgrey?style=flat-square)
![Cisco 8800](https://img.shields.io/badge/Cisco-8800%20Series-049fd9?style=flat-square&logo=cisco)

---

## Fonctionnalités

| Onglet | Description |
|--------|-------------|
| **Contrôleur** | Clavier physique complet (touches molles, navigation, clavier numérique, lignes), écran partagé redimensionnable |
| **AXL / CUCM** | Liste tous les téléphones du CUCM avec IP en temps réel et statut d'enregistrement, provisioning en un clic |
| **Diagnostics SSH** | Console SSH interactive vers le téléphone via plink |

---

## Prérequis

| Composant | Version / Note |
|-----------|----------------|
| Windows | 10 ou supérieur |
| PowerShell | **5.1** (intégré à Windows) — PS6/PS7 non supportés |
| [plink.exe](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) | Release 0.83 minimum — pour les diagnostics SSH |
| Connectivité réseau | Accès IP direct aux téléphones (port 80) et au CUCM (port 8443) |

---

## Installation

### 1. Cloner ou télécharger le dépôt

```powershell
git clone https://github.com/VOTRE_USER/cisco-8800-remote-controller.git
cd cisco-8800-remote-controller
```

Ou télécharger le ZIP depuis la page GitHub et extraire.

### 2. Installer plink

Télécharger `plink.exe` depuis [putty.org](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) et le placer dans un répertoire dans le `PATH` (par exemple `C:\Windows\System32\` ou `C:\tools\`).

Vérifier :
```powershell
plink -V
# Doit afficher : plink: Release 0.83
```

### 3. Configurer les téléphones

```powershell
Copy-Item .\phones.example.json .\phones.json
```

Éditer `phones.json` — chaque entrée représente un téléphone :

```json
[
  {
    "sep":         "SEP001122334455",
    "name":        "Accueil",
    "ip":          "192.168.1.50",
    "description": "Cisco CP-8845 — Réception",
    "username":    "admin",
    "password":    "cisco",
    "sshUser":     "admin",
    "sshPass":     "cisco123",
    "sshHostKey":  "",
    "consoleUser": "debug",
    "consolePass": "debug"
  }
]
```

> `phones.json` est dans `.gitignore` — il ne sera jamais commité.

### 4. Lancer le serveur

```powershell
powershell -ExecutionPolicy Bypass -File .\server.ps1
```

Le serveur démarre sur **http://localhost:8084**.

#### Scripts utilitaires fournis

| Script | Rôle |
|--------|------|
| `install.ps1` | Crée des raccourcis Bureau et Menu Démarrer, vérifie plink, copie `phones.example.json` |
| `launch.ps1` | Vérifie si le serveur tourne, le démarre si besoin, ouvre le navigateur |
| `restart-server.ps1` | Arrête le serveur existant, vérifie la syntaxe PS, relance |

```powershell
# Installation complète (à exécuter une seule fois)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Lancement quotidien
powershell -ExecutionPolicy Bypass -File .\launch.ps1
```

---

## Configuration CUCM

> Cette section est nécessaire uniquement pour utiliser l'onglet **AXL / CUCM**.

### 1. Activer le service AXL

Dans **Cisco Unified Serviceability** (`https://{cucm}/ccmservice`) :

1. **Tools → Service Activation**
2. Sélectionner le nœud Publisher dans la liste déroulante
3. Cocher **Cisco AXL Web Service**
4. Cliquer **Save** puis **OK**

### 2. Activer le service RisPort70 (statut en temps réel)

Toujours dans **Cisco Unified Serviceability** :

1. **Tools → Service Activation**
2. Cocher **Cisco RIS Data Collector**
3. **Save**

> RisPort70 permet d'obtenir l'adresse IP et le statut d'enregistrement en temps réel. Sans ce service actif, les statuts affichent « Inconnu ».

### 3. Créer un utilisateur applicatif AXL

Dans **Cisco Unified CM Administration** (`https://{cucm}/ccmadmin`) :

1. **User Management → Application User → Add New**
2. Remplir les champs :
   - **User ID** : `axl-controller` (ou le nom souhaité)
   - **Password** / **Confirm Password** : mot de passe robuste
   - **Description** : `Cisco 8800 Remote Controller`
3. Dans **Permissions Information**, cliquer **Add to User Group** et ajouter :

   | Groupe / Rôle | Pourquoi |
   |---------------|----------|
   | `Standard AXL API Access` | Opérations AXL (listPhone, getPhone, updatePhone…) |
   | `Standard RealtimeAndTraceCollection` | Accès RisPort70 (IP et statut en temps réel) |
   | `Standard CCM Admin Users` | updatePhone, doDeviceReset, executeSQLUpdate |

4. **Save**

> **Note CUCM 11.5** : pour `executeSQLUpdate` (copie du hash SSH), des droits supplémentaires peuvent être nécessaires. Si une erreur 401/403 apparaît lors du provisioning, ajouter le rôle `Standard CCM Super Users` ou utiliser un compte administrateur.

### 4. Activer l'accès web sur les téléphones

Le contrôleur envoie des commandes via `http://{ip}/CGI/Execute`. L'accès web doit être activé sur chaque téléphone.

#### Option A — Via un Common Phone Profile (recommandé, applique à plusieurs téléphones)

1. **Device → Device Settings → Common Phone Profile**
2. Modifier le profil utilisé par vos téléphones 8800
3. Dans **Product Specific Configuration Layout** :
   - **Web Access** : `Enabled`
4. **Save → Apply Config**
5. Redémarrer les téléphones concernés (**Device → Phone → Reset**)

#### Option B — Par téléphone individuellement

1. **Device → Phone** → sélectionner le téléphone
2. Dans **Product Specific Configuration Layout** :
   - **Web Access** : `Enabled`
3. **Save → Apply Config → Reset**

### 5. Activer SSH sur les téléphones

L'accès SSH est nécessaire pour les diagnostics SSH.

#### Via le bouton 🎮 Contrôle (automatique)

Le provisioning automatique active SSH, configure le mot de passe et redémarre le téléphone en un seul clic depuis l'onglet AXL.

#### Manuellement via CUCM Admin

1. **Device → Phone** → sélectionner le téléphone
2. Dans **Product Specific Configuration Layout** :
   - **SSH Access** : `Enabled`
   - **SSH User ID** : identifiant SSH souhaité (ex. `admin`)
3. **Save → Apply Config → Reset**

> **Limitation CUCM 11.5** : `updatePhone` ignore silencieusement `sshAccess`/`webAccess` en champ de haut niveau. L'application utilise `vendorConfig` en contournement — transparent pour l'utilisateur.

### 6. Credentials HTTP des téléphones

Les téléphones Cisco 8800 utilisent l'authentification HTTP Basic pour `/CGI/Execute`.

Pour définir ou modifier les credentials :

1. **System → Enterprise Phone Configuration** (global) ou **Device → Phone** (individuel)
2. Champ **Phone HTTP Authentication Mode** : `Enabled`
3. Définir **HTTP Admin Username** et **HTTP Admin Password**

Ces valeurs correspondent aux champs `username` et `password` dans `phones.json`.

---

## Utilisation

### Onglet Contrôleur

1. Sélectionner un téléphone dans la liste déroulante
2. Utiliser les touches :
   - **Molles** (Soft1–4) : touches contextuelles de l'écran du téléphone
   - **Navigation** : flèches directionnelles, Select, Back, Home
   - **Clavier numérique** : 0–9, `*`, `#`
   - **Lignes** : L1–L4 (sélection de ligne)
   - **Volume**, **Haut-parleur**, **Muet**, **Raccrocher**
3. Le séparateur vertical est glissable pour ajuster la largeur des colonnes

### Onglet AXL / CUCM

1. Renseigner les champs CUCM :
   - **CUCM IP** : adresse IP du Publisher
   - **Utilisateur AXL** / **Mot de passe**
   - **Version AXL** : `auto` (détection automatique) ou `11.5` / `15.0`
2. Cliquer **📋 Lister les téléphones**
3. Le tableau affiche : Nom SEP, Description, Modèle, Device Pool, IP (temps réel), Statut (Enregistré / Non enregistré / Inconnu)
4. Bouton **🎮 Contrôle** : provisionne le téléphone et bascule sur le contrôleur

### Provisioning automatique (bouton 🎮 Contrôle)

Séquence exécutée automatiquement :

1. Assignation du téléphone à l'utilisateur CUCM spécifié
2. Activation SSH + Web Access via `vendorConfig`
3. Configuration du mot de passe SSH (via `executeSQLUpdate`)
4. Redémarrage du téléphone (`doDeviceReset`)
5. Récupération de l'IP en temps réel via RisPort70
6. Ajout automatique dans `phones.json`

---

## API REST

Le serveur expose les endpoints suivants sur `http://localhost:8084` :

### Contrôle téléphone

| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/api/phones` | Liste les téléphones de `phones.json` |
| `POST` | `/api/phones/add` | Ajoute un téléphone à `phones.json` |
| `POST` | `/api/execute` | Envoie une commande à un téléphone |
| `GET` | `/api/phone/ssh` | Exécute une commande SSH sur un téléphone |

#### Modes pour `/api/execute`

| Mode | Valeur exemple | Description |
|------|----------------|-------------|
| `key` | `Speaker`, `Mute`, `Hold`, `Hangup` | Touche prédéfinie |
| `key` | `KeyPad1`, `KeyPad0`, `KeyPadStar`, `KeyPadPound` | Touche numérique |
| `dial` | `0102030405` | Composition de numéro |
| `xml` | `<CiscoIPPhoneExecute>…</CiscoIPPhoneExecute>` | XML arbitraire |

Exemple :
```powershell
$body = @{
  ip       = "192.168.1.50"
  username = "admin"
  password = "cisco"
  mode     = "key"
  value    = "Speaker"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8084/api/execute" `
  -Method Post -Body $body -ContentType "application/json"
```

### AXL / CUCM

| Méthode | Route | Description |
|---------|-------|-------------|
| `POST` | `/api/axl/version` | Détecte la version AXL |
| `POST` | `/api/axl/phones` | Liste les téléphones + statut RisPort70 |
| `POST` | `/api/axl/phoneip` | IP en temps réel d'un téléphone |
| `POST` | `/api/axl/provision` | Provisionne un téléphone |

Exemple — lister les téléphones :
```powershell
$body = @{
  cucm       = "172.27.199.11"
  username   = "axl-controller"
  password   = "votremotdepasse"
  axlVersion = "auto"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8084/api/axl/phones" `
  -Method Post -Body $body -ContentType "application/json"
```

---

## Compatibilité CUCM

| Version CUCM | Version AXL | Statut |
|-------------|-------------|--------|
| 11.5 | 11.5 | ✅ Testé |
| 15.0 | 15.0 | ✅ Testé |

**Limitations CUCM 11.5 connues** :
- `listPhone` : tags `<product/>` et `<ipAddress/>` invalides — non inclus
- IP en temps réel non accessible via AXL SQL → RisPort70 utilisé
- `updatePhone` ignore `sshAccess`/`webAccess` au niveau racine → `vendorConfig` utilisé

---

## Dépannage

### Le serveur ne démarre pas

```powershell
# Vérifier la syntaxe du script
[System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD\server.ps1", [ref]$null, [ref]$null
)

# Vérifier si le port est occupé
netstat -an | findstr :8084

# Relancer proprement
.\restart-server.ps1
```

### Le téléphone renvoie Status=6 "URI not found"

- Vérifier que **Web Access** est activé (voir [section CUCM](#4-activer-laccès-web-sur-les-téléphones))
- Le nom de touche est sensible à la casse : `KeyPad1` ✅ — `keypad1` ❌

Test manuel :
```powershell
$creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:cisco"))
$xml   = "<CiscoIPPhoneExecute><ExecuteItem Priority=`"0`" URL=`"Key:Speaker`" /></CiscoIPPhoneExecute>"
$body  = "XML=" + [Uri]::EscapeDataString($xml)
Invoke-WebRequest -Uri "http://192.168.1.50/CGI/Execute" -Method POST `
  -Headers @{Authorization="Basic $creds"} -Body $body `
  -ContentType "application/x-www-form-urlencoded" -UseBasicParsing
```

### L'onglet AXL ne fonctionne pas

| Symptôme | Cause probable | Solution |
|----------|----------------|----------|
| `401 Unauthorized` | Credentials incorrects | Vérifier User ID / Password |
| `403 Forbidden` | Rôle AXL manquant | Ajouter `Standard AXL API Access` |
| `500 Internal Server Error` | Service AXL inactif | Activer dans Serviceability |
| Connexion refusée | Mauvaise IP ou port 8443 bloqué | Vérifier IP et pare-feu |
| Statuts « Inconnu » | RIS Data Collector inactif | Activer dans Serviceability |

---

## Sécurité

- Application conçue pour **usage local uniquement** — ne pas exposer publiquement.
- `phones.json` (contient les credentials) est dans `.gitignore`.
- Communications CUCM en HTTPS avec bypass du certificat auto-signé (normal en réseau d'entreprise interne).
- Aucun mot de passe n'est loggé en clair.

---

## Structure du projet

```
cisco-8800-remote-controller/
├── server.ps1              # Serveur HTTP PowerShell 5.1 (port 8084)
├── install.ps1             # Création raccourcis + vérifications initiales
├── launch.ps1              # Démarrage serveur + ouverture navigateur
├── restart-server.ps1      # Redémarrage propre du serveur
├── phones.example.json     # Modèle de configuration téléphones
├── phones.json             # Configuration réelle (gitignore — ne pas commiter)
├── web/
│   ├── index.html          # Interface principale
│   ├── app.js              # Logique frontend
│   └── styles.css          # Styles
└── .github/
    └── copilot-instructions.md
```

---

## Licence

MIT License — voir [LICENSE](LICENSE) pour les détails.
