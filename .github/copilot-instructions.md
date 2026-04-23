# Instructions Copilot — Cisco 8800 Remote Controller

## Langue
- Tous les commentaires, messages de log, messages d'erreur API et textes affichés à l'utilisateur sont en **français**.
- Les noms de variables, fonctions et paramètres sont en **anglais** (conventions PowerShell/JS).

## Stack technique
- Serveur : **PowerShell 5.1** (`HttpListener`). Ne pas utiliser de syntaxe PS6/PS7 (ex. `??=`, `ForEach-Object -Parallel`, ternaire `?:` inline).
- Frontend : HTML/CSS/JS vanilla. Pas de frameworks (pas de React, Vue, etc.).
- Communication : API REST JSON locale sur `http://localhost:8084`.

## Port serveur
- Le serveur écoute sur le **port 8084**.
- Les ports 8081 et 8082 sont définitivement bloqués par Windows HTTP.sys (PID 4 = System) — ne jamais les utiliser ni les suggérer.
- Le port 8083 peut aussi être occupé — préférer 8084.
- Après chaque modification de `server.ps1`, toujours :
  1. Vérifier la syntaxe : `[System.Management.Automation.Language.Parser]::ParseFile(...)`
  2. Stopper le job existant : `Get-Job | Stop-Job -PassThru | Remove-Job -Force`
  3. Relancer : `Start-Job -ScriptBlock { powershell -File "...\server.ps1" -Port 8084 }`

## PowerShell — règles de style

### Requêtes HTTP
- Toujours utiliser `-UseBasicParsing` avec `Invoke-WebRequest`.
- TLS : bypass via `ICertificatePolicy` (classe `TrustAllCerts`) + `ServicePointManager.ServerCertificateValidationCallback = { $true }` + TLS 1.2.

### AXL Cisco CUCM
- Le header `SOAPAction` doit contenir des guillemets **littéraux** :
  ```powershell
  "SOAPAction" = "`"CUCM:DB ver=$AxlVersion $SoapAction`""
  ```
- Les tags `<product/>` et `<ipAddress/>` sont **invalides** dans `listPhone` pour AXL **11.5 ET 15.0** — ne jamais les inclure dans `returnedTags`.
- `<ipAddress/>` est aussi invalide dans `getPhone` sur CUCM 11.5 (connexion TCP coupée = NO RESP).
- **L'IP en temps réel d'un téléphone n'est pas accessible via AXL** (`executeSQLQuery` ou `listPhone`) sur CUCM 11.5 :
  - `device.ipaddress` : colonne inexistante → HTTP 500
  - `device.description` : type LVARCHAR → déconnexion TCP (FAULT 0)
  - `endpointregistration` JOIN → connexion coupée (table inaccessible)
  - Pour obtenir l'IP en temps réel, utiliser le service **RisPort70** (`/realtimeservice2/services/RISService70`) 
- RisPort70 `selectCmDevice` : le champ `<soap:NodeName></soap:NodeName>` est **obligatoire** (même vide) entre `<soap:Status>` et `<soap:SelectBy>` — CUCM 11.5 retourne HTTP 500 `Unexpected subelement SelectBy` si absent.
- L'IP est dans `ns1:IPAddress/ns1:item/ns1:IP` — utiliser XPath `//*[local-name()='IPAddress']/*[local-name()='item']/*[local-name()='IP']` pour l'extraire (et non `IpAddress` ou `.InnerText` sur `IPAddress`).
- `/api/axl/phoneip` utilise RisPort70 `selectCmDevice` pour obtenir l'IP en temps réel. Retourne `notRegistered: true` si le téléphone n'est pas enregistré (RisPort70 `TotalDevicesFound=0`).
- **Bug CUCM 11.5 : `updatePhone` ignore silencieusement `<sshPassword>` et `<webAccess>`/`<sshAccess>` en champ de haut niveau.** Contournements :
  - SSH access : utiliser `<vendorConfig><sshAccess>0</sshAccess></vendorConfig>` dans `updatePhone` (`0`=Activé, `1`=Désactivé — valeurs inversées). `updatePhone vendorConfig` REMPLACE tout le PSC (pas de fusion partielle).
  - Web access : utiliser `<vendorConfig><webAccess>0</webAccess></vendorConfig>` (`0`=Default/Enabled via profil).
  - sshPassword : utiliser `executeSQLUpdate` pour copier le hash depuis un téléphone de référence :
    ```sql
    UPDATE device SET sshpassword = (SELECT FIRST 1 sshpassword FROM device d2 WHERE d2.sshuserid = '$sshUser' AND d2.sshpassword IS NOT NULL AND d2.sshpassword != '' AND d2.name != '$devName') WHERE name = '$devName'
    ```
  - Hash connu pour "postpost" sur CUCM 11.5 : `5b872c9608e4eb787b79c8495d65b5dd2a4d0a9a8921e86886a4dfeb83660fbb`
- `/api/axl/provision` (POST) : exécute les 4 étapes de provisioning d'un téléphone :
  1. `Add-AxlDeviceToUser` — assigne le device à l'Application User ou End User (champ `userId`)
  2a. `updatePhone` avec `<vendorConfig><sshAccess>0</sshAccess><webAccess>0</webAccess></vendorConfig>` + `<sshUserId>` (active SSH/web dans le PSC)
  2b. `executeSQLUpdate` — copie le hash sshpassword depuis un téléphone de référence (contournement bug AXL)
  3. `doDeviceReset` avec `isHardReset=false` — déclenche un redémarrage du téléphone pour appliquer les changements
  Corps requis : `cucm`, `username`, `password`, `axlVersion`, `deviceName`, `userId`, `userType`, `phoneSshUser`, `phoneSshPass`.
- Quand l'utilisateur clique "🎮 Contrôle" dans le tableau AXL sur un téléphone inconnu, `autoAddPhoneFromAxl` appelle d'abord `/api/axl/provision`, puis `/api/axl/phoneip`, puis `/api/phones/add`.
- Le formulaire AXL contient les champs `axlPhoneSshUser` et `axlPhoneSshPass` pour les credentials SSH à configurer sur le téléphone (distincts des credentials AXL).
- `Get-AxlCucmVersion` utilise le namespace `1.0` et n'envoie **pas** de SOAPAction — ne pas en ajouter.
- Le champ `devicePoolName` retourné par AXL peut être un `XmlElement` ou une string simple : utiliser `$p.devicePoolName.InnerText` si XmlElement, sinon `[string]$p.devicePoolName`.

### PS5 : sérialisation tableau JSON
- PowerShell 5 sérialise un tableau d'un seul élément en objet JSON `{}` au lieu de `[]`. Toujours sérialiser les listes manuellement avec `[` + éléments JSON + `]` pour garantir un tableau JSON valide.
- Pattern : `"[" + ($results | ForEach-Object { $_ | ConvertTo-Json -Depth 4 -Compress }) -join "," + "]"`

### Accès sécurisé aux propriétés (StrictMode)
- En `Set-StrictMode -Version 2`, accéder à une propriété inexistante d'un objet PSCustomObject lève une erreur.
- Utiliser la fonction helper `Get-BodyProp $obj $name $default` pour lire des propriétés JSON de manière sûre.

### Gestion des erreurs
- Les erreurs API retournent toujours `@{ ok = $false; error = "message en français" }` en JSON.
- Pour les erreurs AXL, inclure des conseils spécifiques dans le message (ex. rôle CUCM manquant, service AXL inactif).
- Logger systématiquement avec `Write-Log` (fonction définie dans `server.ps1`).

### SSH via plink (`/api/phone/ssh`)
- plink version installée : **Release 0.83** — ne supporte **pas** `-acceptnewkeys` (option invalide).
- Pour les téléphones sans `sshHostKey` en cache : envoyer `"y\n"` via stdin (Sleep 500ms puis `WriteLine("y")`) AVANT les credentials console serie. Utiliser un flag `$acceptKeyViaStdin = $true`.
- Pour les téléphones avec `sshHostKey` connu : utiliser `-hostkey "fingerprint"` (plink accepte SHA256: format).
- La séquence stdin pour la console serie Cisco 8800 (sans PTY, `-batch`) : `y` (si cle inconnue) → `consoleUser` → `consolePass` → `command` → `exit`.
- Timings en ms : 500 (attente prompt cle) + 1500 (apres y) OU 1800 (cle connue) → puis 1200 → 2500 → 4000 → close.

### Debug
- Sauvegarder les résultats de tests dans `$env:TEMP\axl_*.txt` pour relecture ultérieure.
- Ne jamais supprimer les fichiers de debug sans confirmation.

## JavaScript frontend

- Utiliser `fetch` avec `async/await`.
- Toujours appeler `escHtml()` avant d'insérer du contenu dynamique dans le DOM.
- Les fonctions AXL suivent le pattern : `axlGetCreds()` → `axlDetectVersion()` → action.
- Quand `axlVersion === "auto"`, appeler `axlDetectVersion()` d'abord et mettre à jour le `<select>`.

### Architecture multi-panneaux (onglet Controller)

- Le contrôleur est un **workspace multi-panneaux** : plusieurs téléphones simultanément, chaque panneau indépendant.
- État global : `panels = {}` (id → state), `panelCount = 0`. Pas de variable globale `autoRefreshActive` ni `currentPhoneSep`.
- Chaque panneau a son propre state : `{ id, phone, autoRefresh, failCount, keyQueue, keyTimer, refreshTimer, dom }`.
- `createPhonePanel(phone)` : crée un panneau `position:absolute` dans `#panelWorkspace`, câble tous les events, retourne l'id.
- `setupPanelDrag(panel)` / `setupPanelResize(panel)` : drag via mousedown sur `.pp-header`, resize via `.pp-resize-handle` (coin bas-droit). Les handlers `mousemove`/`mouseup` sont sur `document`.
- `focusPanel(id)` : ajoute `.pp-focused` (z-index élevé, bordure bleue) au panneau cliqué.
- `setPanelAutoRefresh(id, bool)` : gère le timer de refresh par panneau. `scheduleRefresh(id)` planifie le prochain screenshot.
- `enqueuePanelKey(id, key)` / `flushPanelKeys(id)` : debounce 2s, envoi séquentiel avec 150ms inter-touche.
- `sendPanelCommand(id, payload, title)` : envoie `/api/execute` pour un panneau.
- `runPanelSsh(id, command)` : SSH via `/api/phone/ssh` pour un panneau.
- `tilePanels()` : dispose les panneaux en grille dans le workspace.
- `switchToControllerWithPhone(sepName)` : switche sur l'onglet Controller et appelle `createPhonePanel()`. Si téléphone inconnu, appelle `autoAddPhoneFromAxl(sepName)` puis crée le panneau.
- **IDs DOM supprimés** (ne jamais référencer dans le code JS) : `activePhoneBar`, `activePhoneName`, `activePhoneIp`, `btnScreenshot`, `btnAutoRefresh`, `btnRefreshNow`, `screenshot`, `screenshotError`, `ctrlScreenCol`, `ctrlControlsCol`, `splitterCtrl`, `keyInput`, `dialInput`, `customXml`, `btnKey`, `btnDial`, `btnXml`, `btnSsh`, `sshCommand`, `sshOutput`.
- **Variables globales supprimées** : `autoRefreshActive`, `screenshotFailCount`, `provisioningPending`, `keyQueue`, `keyFlushTimer`, `currentPhoneSep` (remplacés par l'état par panneau).
- `loadPhones()` remplit le `<select id="phoneList">` dans le dock (ne déclenche plus de panneau auto sur téléphone unique).
- `addLog(msg)` : écrit dans `#log` (dans `#sharedLogBar`, collapsible). `addPanelLog(id, msg)` : écrit dans `.pp-mini-log` du panneau ET dans le log global.
- Le tableau AXL (`axlRenderTable`) a des boutons "🎮 Control" qui appellent `axlProvisionAndControl(sep)` → provision + `createPhonePanel()` + `setPanelAutoRefresh()`.
- **Erreur fréquente** : tout `getElementById()` ou `addEventListener()` au niveau top-level sur un élément inexistant crashe le script entier et empêche `loadPhones()` de s'exécuter → dropdown vide. Toujours vérifier que l'élément est bien dans le HTML avant d'y attacher un listener.

### CSS styles.css
- Vérifier l'équilibre des accolades après toute modification : `$open` doit égaler `$close`. Une accolade orpheline après `}` d'un bloc ou des propriétés hors sélecteur cassent l'affichage silencieusement.

## Sécurité
- Ne jamais logger les mots de passe en clair dans les logs serveur.
- L'application est locale uniquement — ne pas exposer sur une interface réseau publique.
- Credentials stockés dans `phones.json` : toujours préciser que ce fichier ne doit pas être versionné (il est dans `.gitignore`).

## Clusters CUCM de référence
| IP | Rôle | Version |
|----|------|---------|
| 172.27.199.11 | Pub cluster 1 | CUCM 11.5 → AXL 11.5 |
| 172.27.199.14 | Sub cluster 1 | CUCM 11.5 |
| 172.27.199.111 | Pub cluster 2 | CUCM 15.0 → AXL 15.0 |
| 172.27.199.114 | Sub cluster 2 | CUCM 15.0 |

Téléphone de test : `172.27.1.56` (Cisco CP-8841, SEP2C31246A67AC), credentials HTTP `post/post`, SSH `post/postpost`, console `debug/debug`.
