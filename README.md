# Cisco 8800 Remote Controller

Local web application to control **Cisco IP Phone 8800 series** phones and manage CUCM resources via the AXL API.

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue?style=flat-square)
![Platform Windows](https://img.shields.io/badge/Platform-Windows-lightgrey?style=flat-square)
![Cisco 8800](https://img.shields.io/badge/Cisco-8800%20Series-049fd9?style=flat-square&logo=cisco)

---

## Features

| Tab | Description |
|-----|-------------|
| **Controller** | Multi-panel workspace — open one panel per phone simultaneously. Each panel: screenshot, auto-refresh, full keypad, SSH diagnostics. Panels are draggable and resizable. |
| **AXL / CUCM** | Lists all CUCM phones with real-time IP and registration status, one-click provisioning |

---

## Prerequisites

| Component | Version / Note |
|-----------|----------------|
| Windows | 10 or later |
| PowerShell | **5.1** (built into Windows) — PS6/PS7 not supported |
| [plink.exe](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) | Release 0.83 minimum — for SSH diagnostics |
| Network connectivity | Direct IP access to phones (port 80) and to CUCM (port 8443) |

---

## Installation

### 1. Clone or download the repository

```powershell
git clone https://github.com/YOUR_USER/cisco-8800-remote-controller.git
cd cisco-8800-remote-controller
```

Or download the ZIP from the GitHub page and extract it.

### 2. Install plink

Download `plink.exe` from [putty.org](https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html) and place it in a directory in the `PATH` (e.g. `C:\Windows\System32\` or `C:\tools\`).

Verify:
```powershell
plink -V
# Should display: plink: Release 0.83
```

### 3. Configure phones

```powershell
Copy-Item .\phones.example.json .\phones.json
```

Edit `phones.json` — each entry represents a phone:

```json
[
  {
    "sep":         "SEP001122334455",
    "name":        "Reception",
    "ip":          "192.168.1.50",
    "description": "Cisco CP-8845 — Front Desk",
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

> `phones.json` is in `.gitignore` — it will never be committed.

### 4. Start the server

```powershell
powershell -ExecutionPolicy Bypass -File .\server.ps1
```

The server starts on **http://localhost:8084**.

#### Included utility scripts

| Script | Purpose |
|--------|---------|
| `install.ps1` | Creates Desktop and Start Menu shortcuts, verifies plink, copies `phones.example.json` |
| `launch.ps1` | Checks if the server is running, starts it if needed, opens the browser |
| `restart-server.ps1` | Stops the existing server, checks PS syntax, restarts |

```powershell
# Full installation (run once)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Daily launch
powershell -ExecutionPolicy Bypass -File .\launch.ps1
```

---

## CUCM Configuration

> This section is only required to use the **AXL / CUCM** tab.

### 1. Enable the AXL service

In **Cisco Unified Serviceability** (`https://{cucm}/ccmservice`):

1. **Tools → Service Activation**
2. Select the Publisher node from the dropdown
3. Check **Cisco AXL Web Service**
4. Click **Save** then **OK**

### 2. Enable the RisPort70 service (real-time status)

Still in **Cisco Unified Serviceability**:

1. **Tools → Service Activation**
2. Check **Cisco RIS Data Collector**
3. **Save**

> RisPort70 provides real-time IP address and registration status. Without this service active, statuses display as "Unknown".

### 3. Create an AXL application user

In **Cisco Unified CM Administration** (`https://{cucm}/ccmadmin`):

1. **User Management → Application User → Add New**
2. Fill in the fields:
   - **User ID**: `axl-controller` (or any desired name)
   - **Password** / **Confirm Password**: strong password
   - **Description**: `Cisco 8800 Remote Controller`
3. Under **Permissions Information**, click **Add to User Group** and add:

   | Group / Role | Why |
   |--------------|-----|
   | `Standard AXL API Access` | AXL operations (listPhone, getPhone, updatePhone…) |
   | `Standard RealtimeAndTraceCollection` | RisPort70 access (real-time IP and status) |
   | `Standard CCM Admin Users` | updatePhone, doDeviceReset, executeSQLUpdate |

4. **Save**

> **CUCM 11.5 note**: for `executeSQLUpdate` (SSH hash copy), additional rights may be required. If a 401/403 error appears during provisioning, add the `Standard CCM Super Users` role or use an administrator account.

### 4. Enable web access on phones

The controller sends commands via `http://{ip}/CGI/Execute`. Web access must be enabled on each phone.

#### Option A — Via a Common Phone Profile (recommended, applies to multiple phones)

1. **Device → Device Settings → Common Phone Profile**
2. Edit the profile used by your 8800 phones
3. In **Product Specific Configuration Layout**:
   - **Web Access**: `Enabled`
4. **Save → Apply Config**
5. Restart the affected phones (**Device → Phone → Reset**)

#### Option B — Per phone individually

1. **Device → Phone** → select the phone
2. In **Product Specific Configuration Layout**:
   - **Web Access**: `Enabled`
3. **Save → Apply Config → Reset**

### 5. Enable SSH on phones

SSH access is required for SSH diagnostics.

#### Via the 🎮 Control button (automatic)

Automatic provisioning enables SSH, configures the password, and restarts the phone in a single click from the AXL tab.

#### Manually via CUCM Admin

1. **Device → Phone** → select the phone
2. In **Product Specific Configuration Layout**:
   - **SSH Access**: `Enabled`
   - **SSH User ID**: desired SSH username (e.g. `admin`)
3. **Save → Apply Config → Reset**

> **CUCM 11.5 limitation**: `updatePhone` silently ignores `sshAccess`/`webAccess` at the top level. The application uses `vendorConfig` as a workaround — transparent to the user.

### 6. Phone HTTP credentials

Cisco 8800 phones use HTTP Basic authentication for `/CGI/Execute`.

To set or change credentials:

1. **System → Enterprise Phone Configuration** (global) or **Device → Phone** (individual)
2. **Phone HTTP Authentication Mode**: `Enabled`
3. Set **HTTP Admin Username** and **HTTP Admin Password**

These values correspond to the `username` and `password` fields in `phones.json`.

---

## Usage

### Controller Tab

The controller is a **multi-panel workspace** — you can control multiple phones simultaneously.

#### Dock bar (top)

| Control | Description |
|---------|-------------|
| Phone selector | Choose a phone from `phones.json` |
| **＋ Add Panel** | Opens a floating panel for the selected phone |
| **⊞ Tile** | Automatically arranges all open panels in a grid |
| **📋 Log** | Shows/hides the shared event log |

#### Phone panel

Each panel contains:
- **Header bar**: phone name, IP, status indicator (●), capture/auto-refresh/close buttons
  - Drag the header to move the panel anywhere in the workspace
  - Drag the **↘ corner handle** to resize the panel
- **Screenshot** area with auto-refresh (1 s interval, backs off on error)
- **Softkeys** Soft1–4
- **Navigation grid**: ▲▼◀▶ + OK
- **Audio/Call**: Speaker, Headset, Mute, Vol+/−, Hangup, Back
- **Numeric keypad**: 0–9, `*`, `#`
- **Dial**: free-text number + Call button (or press Enter)
- **🔒 SSH** section (expandable): preset commands + custom command input
- **Mini-log**: per-panel event history

> Keys use a 2-second debounce queue — click multiple keys quickly, they are sent in sequence with a 150 ms inter-key delay.

### AXL / CUCM Tab

1. Fill in the CUCM fields:
   - **CUCM IP**: Publisher IP address
   - **AXL User** / **Password**
   - **AXL Version**: `auto` (auto-detect) or `11.5` / `15.0`
2. Click **📋 List Phones**
3. The table shows: SEP Name, Description, Model, Device Pool, IP (real-time), Status (Registered / Not Registered / Unknown)
4. **🎮 Control** button: provisions the phone and switches to the controller

### Automatic provisioning (🎮 Control button)

Sequence executed automatically:

1. Assign the phone to the specified CUCM user
2. Enable SSH + Web Access via `vendorConfig`
3. Configure the SSH password (via `executeSQLUpdate`)
4. Restart the phone (`doDeviceReset`)
5. Retrieve real-time IP via RisPort70
6. Automatically add to `phones.json`

---

## REST API

The server exposes the following endpoints on `http://localhost:8084`:

### Phone control

| Method | Route | Description |
|--------|-------|-------------|
| `GET` | `/api/phones` | Lists phones from `phones.json` |
| `POST` | `/api/phones/add` | Adds a phone to `phones.json` |
| `POST` | `/api/execute` | Sends a command to a phone |
| `GET` | `/api/phone/ssh` | Executes an SSH command on a phone |

#### Modes for `/api/execute`

| Mode | Example value | Description |
|------|---------------|-------------|
| `key` | `Speaker`, `Mute`, `Hold`, `Hangup` | Predefined key |
| `key` | `KeyPad1`, `KeyPad0`, `KeyPadStar`, `KeyPadPound` | Numeric key |
| `dial` | `0102030405` | Dial a number |
| `xml` | `<CiscoIPPhoneExecute>…</CiscoIPPhoneExecute>` | Arbitrary XML |

Example:
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

| Method | Route | Description |
|--------|-------|-------------|
| `POST` | `/api/axl/version` | Detects AXL version |
| `POST` | `/api/axl/phones` | Lists phones + RisPort70 status |
| `POST` | `/api/axl/phoneip` | Real-time IP of a phone |
| `POST` | `/api/axl/provision` | Provisions a phone |

Example — list phones:
```powershell
$body = @{
  cucm       = "172.27.199.11"
  username   = "axl-controller"
  password   = "yourpassword"
  axlVersion = "auto"
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://localhost:8084/api/axl/phones" `
  -Method Post -Body $body -ContentType "application/json"
```

---

## CUCM Compatibility

| CUCM Version | AXL Version | Status |
|-------------|-------------|--------|
| 11.5 | 11.5 | ✅ Tested |
| 15.0 | 15.0 | ✅ Tested |

**Known CUCM 11.5 limitations**:
- `listPhone`: `<product/>` and `<ipAddress/>` tags are invalid — not included
- Real-time IP not accessible via AXL SQL → RisPort70 used instead
- `updatePhone` ignores `sshAccess`/`webAccess` at root level → `vendorConfig` used

---

## Troubleshooting

### Server does not start

```powershell
# Check script syntax
[System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD\server.ps1", [ref]$null, [ref]$null
)

# Check if port is in use
netstat -an | findstr :8084

# Clean restart
.\restart-server.ps1
```

### Phone returns Status=6 "URI not found"

- Verify that **Web Access** is enabled (see [CUCM section](#4-enable-web-access-on-phones))
- Key names are case-sensitive: `KeyPad1` ✅ — `keypad1` ❌

Manual test:
```powershell
$creds = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("admin:cisco"))
$xml   = "<CiscoIPPhoneExecute><ExecuteItem Priority=`"0`" URL=`"Key:Speaker`" /></CiscoIPPhoneExecute>"
$body  = "XML=" + [Uri]::EscapeDataString($xml)
Invoke-WebRequest -Uri "http://192.168.1.50/CGI/Execute" -Method POST `
  -Headers @{Authorization="Basic $creds"} -Body $body `
  -ContentType "application/x-www-form-urlencoded" -UseBasicParsing
```

### AXL tab does not work

| Symptom | Likely cause | Solution |
|---------|--------------|----------|
| `401 Unauthorized` | Incorrect credentials | Check User ID / Password |
| `403 Forbidden` | Missing AXL role | Add `Standard AXL API Access` |
| `500 Internal Server Error` | AXL service inactive | Enable in Serviceability |
| Connection refused | Wrong IP or port 8443 blocked | Check IP and firewall |
| Statuses "Unknown" | RIS Data Collector inactive | Enable in Serviceability |

---

## Security

- Application designed for **local use only** — do not expose publicly.
- `phones.json` (contains credentials) is in `.gitignore`.
- CUCM communications over HTTPS with self-signed certificate bypass (normal in internal corporate networks).
- No passwords are logged in plain text.

---

## Project Structure

```
cisco-8800-remote-controller/
├── server.ps1              # PowerShell 5.1 HTTP server (port 8084)
├── install.ps1             # Shortcut creation + initial checks
├── launch.ps1              # Server start + browser open
├── restart-server.ps1      # Clean server restart
├── phones.example.json     # Phone configuration template
├── phones.json             # Actual configuration (gitignored — do not commit)
├── cucm-connections.json   # Saved CUCM connections (gitignored)
├── web/
│   ├── index.html          # Main interface (multi-panel workspace + AXL tab)
│   ├── app.js              # Frontend logic (panels, key queue, SSH, AXL)
│   └── styles.css          # Styles
└── .github/
    └── copilot-instructions.md
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.
