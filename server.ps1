param(
    [int]$Port = 8080,
    [string]$PhonesFile = "phones.json"
)

Set-StrictMode -Off
$ErrorActionPreference = "Continue"

# ---- TLS bypass for AXL calls (CUCM self-signed certificate) ----
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
# TLS 1.2 + TLS 1.3 (12288) for CUCM 14+ which requires TLS 1.3
try {
    $tls13val = [System.Net.SecurityProtocolType]12288
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor $tls13val
} catch {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
}

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$ts] $Message"
}

function Read-Phones {
    param([string]$Path)

    if (-not (Test-Path -Path $Path)) {
        $sample = Join-Path $PSScriptRoot "phones.example.json"
        if (Test-Path -Path $sample) {
            return @(Get-Content -Path $sample -Raw | ConvertFrom-Json)
        }

        return @()
    }

    # @() forces an array even if phones.json contains only one element (PS5 deserializes as PSObject otherwise)
    return @(Get-Content -Path $Path -Raw | ConvertFrom-Json)
}

# ── Chiffrement DPAPI (lié au compte Windows courant) ───────────────────────
# Prefix ENC: pour distinguer les valeurs chiffrées du texte clair (rétrocompatibilité)
function Protect-Password {
    param([string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return "" }
    try {
        $enc = ConvertTo-SecureString $PlainText -AsPlainText -Force | ConvertFrom-SecureString
        return "ENC:$enc"
    } catch {
        Write-Log "WARN: Protect-Password échoué — stockage en clair"
        return $PlainText
    }
}

function Unprotect-Password {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return "" }
    if (-not $Value.StartsWith("ENC:")) { return $Value }  # texte clair (ancien format)
    try {
        $sec = ConvertTo-SecureString $Value.Substring(4)
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
    } catch {
        Write-Log "WARN: Unprotect-Password échoué — valeur vide retournée"
        return ""
    }
}
# ────────────────────────────────────────────────────────────────────────────

function Read-CucmConnections {
    param([string]$Path)
    if (-not (Test-Path -Path $Path)) { return @() }
    $parsed = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if ($null -eq $parsed) { return @() }
    # Filtrer : ne garder que les entrées valides ayant un champ 'name' non vide
    # (évite la propagation de corruption PS5 issue de sérialisations précédentes)
    return @(@($parsed) | Where-Object {
        $null -ne $_.PSObject.Properties['name'] -and
        -not [string]::IsNullOrWhiteSpace([string]$_.name)
    })
}

function ConvertTo-ExecuteXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [Parameter(Mandatory = $false)]
        [string]$Value
    )

    switch ($Mode.ToLowerInvariant()) {
        "key" {
            if ([string]::IsNullOrWhiteSpace($Value)) {
            throw "The 'value' parameter is required for mode=key."
            }
            # Mapping numeric keys to KeyPad format required by Cisco 8800
            $keyMap = @{
                "0" = "KeyPad0"; "1" = "KeyPad1"; "2" = "KeyPad2"; "3" = "KeyPad3"
                "4" = "KeyPad4"; "5" = "KeyPad5"; "6" = "KeyPad6"; "7" = "KeyPad7"
                "8" = "KeyPad8"; "9" = "KeyPad9"; "*" = "KeyPadStar"; "#" = "KeyPadPound"
            }
            $mappedValue = if ($keyMap.ContainsKey($Value)) { $keyMap[$Value] } else { $Value }
            $escapedValue = [System.Security.SecurityElement]::Escape($mappedValue)
            return "<CiscoIPPhoneExecute><ExecuteItem Priority=`"0`" URL=`"Key:$escapedValue`" /></CiscoIPPhoneExecute>"
        }
        "dial" {
            if ([string]::IsNullOrWhiteSpace($Value)) {
            throw "The 'value' parameter is required for mode=dial."
            }
            $escapedValue = [System.Security.SecurityElement]::Escape($Value)
            return "<CiscoIPPhoneExecute><ExecuteItem Priority=`"0`" URL=`"Dial:$escapedValue`" /></CiscoIPPhoneExecute>"
        }
        "xml" {
            if ([string]::IsNullOrWhiteSpace($Value)) {
            throw "XML is empty for mode=xml."
            }
            return $Value
        }
        default {
            throw "Invalid mode. Supported values: key, dial, xml."
        }
    }
}

function Invoke-CiscoExecute {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Ip,

        [Parameter(Mandatory = $true)]
        [string]$XmlBody,

        [Parameter(Mandatory = $false)]
        [string]$Username,

        [Parameter(Mandatory = $false)]
        [string]$Password
    )

    $uri = "http://$Ip/CGI/Execute"

    # The phone expects a form field "XML=..." (application/x-www-form-urlencoded)
    # and Basic authentication with the CUCM user associated with the phone
    $formBody = "XML=" + [System.Uri]::EscapeDataString($XmlBody)

    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($Username)) {
        $pair = $Username + ":" + $Password
        $base64 = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
        $headers["Authorization"] = "Basic $base64"
    }

    return Invoke-WebRequest -Method Post -Uri $uri -Headers $headers -Body $formBody -ContentType "application/x-www-form-urlencoded" -TimeoutSec 10 -UseBasicParsing
}

function Write-JsonResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory = $true)]
        [int]$StatusCode,

        [Parameter(Mandatory = $true)]
        $Payload
    )

    $json = $Payload | ConvertTo-Json -Depth 6
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json; charset=utf-8"
    $Response.ContentLength64 = $bytes.LongLength
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Get-BodyProp {
    param($Obj, [string]$PropName, [string]$Default = "")
    $prop = $Obj.PSObject.Properties[$PropName]
    if ($null -ne $prop -and $null -ne $prop.Value) {
        $s = [string]$prop.Value
        if ($s -ne '') { return $s }
    }
    return $Default
}

function Write-FileResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.Net.HttpListenerResponse]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        Write-JsonResponse -Response $Response -StatusCode 404 -Payload @{
            ok = $false
            error = "File not found."
        }
        return
    }

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $contentType = switch ($ext) {
        ".html" { "text/html; charset=utf-8" }
        ".js" { "application/javascript; charset=utf-8" }
        ".css" { "text/css; charset=utf-8" }
        default { "application/octet-stream" }
    }

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Response.StatusCode = 200
    $Response.ContentType = $contentType
    $Response.ContentLength64 = $bytes.LongLength
    $Response.AddHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Response.OutputStream.Close()
}

function Invoke-AxlRequest {
    param(
        [string]$Cucm,
        [string]$Username,
        [string]$Password,
        [string]$SoapAction,
        [string]$SoapBody,
        [string]$AxlVersion = "14.0"
    )

    $envelope = @"
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:ns="http://www.cisco.com/AXL/API/$AxlVersion">
  <soapenv:Header/>
  <soapenv:Body>
$SoapBody
  </soapenv:Body>
</soapenv:Envelope>
"@
    $uri  = "https://$Cucm`:8443/axl/"
    $pair = $Username + ":" + $Password
    $b64  = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    # SOAPAction: les guillemets font partie de la valeur du header (standard SOAP 1.1)
    $hdrs = @{
        "Authorization" = "Basic $b64"
        "SOAPAction"    = "`"CUCM:DB ver=$AxlVersion $SoapAction`""
        "Accept"        = "text/xml"
    }

    try {
        return Invoke-WebRequest -Uri $uri -Method Post -Headers $hdrs -Body $envelope `
            -ContentType "text/xml; charset=utf-8" -TimeoutSec 30 -UseBasicParsing
    } catch [System.Net.WebException] {
        $webEx   = $_.Exception
        $errResp = $webEx.Response
        $httpCode = if ($errResp) { [int]$errResp.StatusCode } else { 0 }

        # Read the error response body (SOAP Fault)
        $errBody = ""
        if ($errResp) {
            try {
                $stream = $errResp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $errBody = $reader.ReadToEnd()
            } catch {}
        }

        # Extract faultstring (may contain XML entities)
        $faultMsg = ""
        if ($errBody -match "(?s)<faultstring[^>]*>(.+?)</faultstring>") {
            $raw = $Matches[1] -replace "&amp;","&" -replace "&lt;","<" -replace "&gt;",">" -replace "&apos;","'" -replace "&quot;",'"'
            $faultMsg = " - $raw"
        } elseif ($errBody -match "(?s)<axlmessage>(.+?)</axlmessage>") {
            $faultMsg = " - $($Matches[1])"
        }
        Write-Log "AXL HTTP $httpCode body: $($errBody.Substring(0,[Math]::Min(300,$errBody.Length)))"

        switch ($httpCode) {
            401 { throw "AXL 401 Unauthorized$faultMsg. Check that '$Username' has the 'Standard AXL API Access' role in CUCM > User Management > Application User." }
            403 { throw "AXL 403 Forbidden$faultMsg. Access denied for '$Username'." }
            500 { throw "AXL 500 SOAP Fault$faultMsg." }
            599 { throw "AXL 599$faultMsg. Check the CUCM IP and that the 'Cisco AXL Web Service' is active (CUCM Serviceability)." }
            0   { throw "AXL connection failed to $Cucm`:8443 - $($webEx.Message)" }
            default { throw "AXL HTTP $httpCode$faultMsg - $($webEx.Message)" }
        }
    }
}

function Get-AxlCucmVersion {
    param([string]$Cucm, [string]$Username, [string]$Password)

    $envelope = @"
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"
                  xmlns:ns="http://www.cisco.com/AXL/API/1.0">
  <soapenv:Header/>
  <soapenv:Body>
    <ns:getCCMVersion>
      <processNodeName></processNodeName>
    </ns:getCCMVersion>
  </soapenv:Body>
</soapenv:Envelope>
"@
    $uri  = "https://$Cucm`:8443/axl/"
    $pair = $Username + ":" + $Password
    $b64  = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
    $hdrs = @{
        "Authorization" = "Basic $b64"
        "Content-Type"  = "text/xml; charset=utf-8"
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($envelope)

    try {
        $resp   = Invoke-WebRequest -Uri $uri -Method Post -Headers $hdrs -Body $bytes `
            -ContentType "text/xml; charset=utf-8" -TimeoutSec 15 -UseBasicParsing
        $xml    = [xml]$resp.Content
        $verStr = $xml.Envelope.Body.getCCMVersionResponse.return.componentVersion.version
        if ($verStr -match '^(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if     ($major -ge 15)                   { $axlVer = "15.0" }
            elseif ($major -eq 14)                   { $axlVer = "14.0" }
            elseif ($major -eq 12 -and $minor -ge 5) { $axlVer = "12.5" }
            elseif ($major -eq 12)                   { $axlVer = "12.0" }
            elseif ($major -eq 11 -and $minor -ge 5) { $axlVer = "11.5" }
            elseif ($major -eq 11)                   { $axlVer = "11.0" }
            elseif ($major -eq 10 -and $minor -ge 5) { $axlVer = "10.5" }
            else                                     { $axlVer = "10.0" }
            return @{ version = $axlVer; cucmVersion = $verStr }
        }
        throw "Unknown CUCM version format: $verStr"
    } catch [System.Net.WebException] {
        $webEx    = $_.Exception
        $errResp  = $webEx.Response
        $httpCode = if ($errResp) { [int]$errResp.StatusCode } else { 0 }
        switch ($httpCode) {
            401     { throw "AXL 401 - check credentials for '$Username'" }
            0       { throw "AXL connection failed to $Cucm`:8443 - $($webEx.Message)" }
            default { throw "AXL HTTP $httpCode - $($webEx.Message)" }
        }
    }
}

function Get-AxlPhones {
    param([string]$Cucm, [string]$Username, [string]$Password, [string]$AxlVersion = "14.0")

    $body = @"
    <ns:listPhone>
      <searchCriteria><name>%</name></searchCriteria>
      <returnedTags>
        <name/><description/><model/><devicePoolName/>
      </returnedTags>
    </ns:listPhone>
"@
    $resp = Invoke-AxlRequest -Cucm $Cucm -Username $Username -Password $Password `
                              -SoapAction "listPhone" -SoapBody $body -AxlVersion $AxlVersion
    $xml  = [xml]$resp.Content
    $phones = $xml.Envelope.Body.listPhoneResponse.return.phone
    $results = @()
    foreach ($p in $phones) {
        # devicePoolName can be an object with #text attribute or a simple string
        $dp = if ($p.devicePoolName -is [System.Xml.XmlElement]) { $p.devicePoolName.InnerText } else { [string]$p.devicePoolName }
        $results += @{
            name        = [string]$p.name
            description = [string]$p.description
            model       = [string]$p.model
            devicePool  = $dp
        }
    }
    return $results
}

function Get-RisPort70BulkStatus {
    param([string]$Cucm, [string]$Username, [string]$Password, [string[]]$DeviceNames)
    $result = @{}
    if (-not $DeviceNames -or $DeviceNames.Count -eq 0) { return $result }

    $risUri  = "https://$Cucm`:8443/realtimeservice2/services/RISService70"
    $risB64  = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${Username}:${Password}"))
    $risHdrs = @{ "Authorization" = "Basic $risB64"; "SOAPAction" = '""' }

    $batchSize = 500
    for ($bi = 0; $bi -lt $DeviceNames.Count; $bi += $batchSize) {
        $end   = [Math]::Min($bi + $batchSize - 1, $DeviceNames.Count - 1)
        $batch = $DeviceNames[$bi .. $end]
        $itemsXml = ($batch | ForEach-Object {
            $safe = [System.Security.SecurityElement]::Escape($_)
            "<soap:item><soap:Item>$safe</soap:Item></soap:item>"
        }) -join ""
        $maxRet = $batch.Count
        $risEnv = @"
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:soap="http://schemas.cisco.com/ast/soap">
  <soapenv:Header/>
  <soapenv:Body>
    <soap:selectCmDevice>
      <soap:StateInfo></soap:StateInfo>
      <soap:CmSelectionCriteria>
        <soap:MaxReturnedDevices>$maxRet</soap:MaxReturnedDevices>
        <soap:DeviceClass>Phone</soap:DeviceClass>
        <soap:Model>255</soap:Model>
        <soap:Status>Any</soap:Status>
        <soap:NodeName></soap:NodeName>
        <soap:SelectBy>Name</soap:SelectBy>
        <soap:SelectItems>$itemsXml</soap:SelectItems>
        <soap:Protocol>Any</soap:Protocol>
        <soap:DownloadStatus>Any</soap:DownloadStatus>
      </soap:CmSelectionCriteria>
    </soap:selectCmDevice>
  </soapenv:Body>
</soapenv:Envelope>
"@
        try {
            $risResp = Invoke-WebRequest -Uri $risUri -Method Post -Headers $risHdrs -Body $risEnv `
                -ContentType "text/xml; charset=utf-8" -TimeoutSec 30 -UseBasicParsing
            $risXml  = [xml]$risResp.Content
            $devNodes = $risXml.SelectNodes("//*[local-name()='CmDevices']/*[local-name()='item']")
            foreach ($dev in $devNodes) {
                $nameNode = $dev.SelectSingleNode("*[local-name()='Name']")
                $statNode = $dev.SelectSingleNode("*[local-name()='Status']")
                $ipNode   = $dev.SelectSingleNode("*[local-name()='IPAddress']/*[local-name()='item']/*[local-name()='IP']")
                $devName  = if ($nameNode) { $nameNode.InnerText.Trim() } else { "" }
                $devStat  = if ($statNode) { $statNode.InnerText.Trim() } else { "" }
                $devIp    = if ($ipNode)   { $ipNode.InnerText.Trim()   } else { "" }
                if ($devName) { $result[$devName] = @{ ip = $devIp; status = $devStat } }
            }
        } catch {
            Write-Log "RisPort70 bulk batch $bi error: $($_.Exception.Message)"
        }
    }
    return $result
}

function Add-AxlDeviceToUser {
    param(
        [string]$Cucm,
        [string]$Username,
        [string]$Password,
        [string]$UserId,
        [string]$DeviceName,
        [string]$AxlVersion = "14.0",
        [string]$UserType   = "app"   # "app" = Application User, "end" = End User
    )

    if ($UserType -eq "app") {
        # --- Application User : getAppUser / updateAppUser ---
        $getBody = @"
    <ns:getAppUser>
      <userid>$UserId</userid>
      <returnedTags>
        <associatedDevices/>
      </returnedTags>
    </ns:getAppUser>
"@
        $existing = @()
        try {
            $getResp = Invoke-AxlRequest -Cucm $Cucm -Username $Username -Password $Password `
                                         -SoapAction "getAppUser" -SoapBody $getBody -AxlVersion $AxlVersion
            $getXml  = [xml]$getResp.Content
            $existing = @($getXml.Envelope.Body.getAppUserResponse.return.appUser.associatedDevices.device)
            $existing = @($existing | Where-Object { $_ -ne $null -and ([string]$_ -ne $DeviceName) })
            Write-Log "getAppUser '$UserId' -> $($existing.Count) existing device(s)"
        } catch {
            Write-Log "getAppUser '$UserId' ignored (new or no devices): $_"
        }

        $allDevices = @($existing) + @($DeviceName)
        $deviceXml  = ($allDevices | ForEach-Object { "<device>$([string]$_)</device>" }) -join ""

        $updBody = @"
    <ns:updateAppUser>
      <userid>$UserId</userid>
      <associatedDevices>$deviceXml</associatedDevices>
    </ns:updateAppUser>
"@
        try {
            $updResp = Invoke-AxlRequest -Cucm $Cucm -Username $Username -Password $Password `
                                         -SoapAction "updateAppUser" -SoapBody $updBody -AxlVersion $AxlVersion
        } catch {
            $msg = [string]$_
            if ($msg -match "500") {
                throw "AXL 500: Application User '$UserId' not found in CUCM. Check CUCM Admin > User Management > Application User."
            }
            throw $_
        }
        $updXml = [xml]$updResp.Content
        return $updXml.Envelope.Body.updateAppUserResponse.return

    } else {
        # --- End User : getUser / updateUser ---
        $getBody = @"
    <ns:getUser>
      <userid>$UserId</userid>
      <returnedTags>
        <associatedDevices/>
      </returnedTags>
    </ns:getUser>
"@
        $existing = @()
        try {
            $getResp = Invoke-AxlRequest -Cucm $Cucm -Username $Username -Password $Password `
                                         -SoapAction "getUser" -SoapBody $getBody -AxlVersion $AxlVersion
            $getXml  = [xml]$getResp.Content
            $existing = @($getXml.Envelope.Body.getUserResponse.return.user.associatedDevices.device)
            $existing = @($existing | Where-Object { $_ -and ([string]$_ -ne $DeviceName) })
            Write-Log "getUser '$UserId' -> $($existing.Count) existing device(s)"
        } catch {
            Write-Log "getUser '$UserId' ignored: $_"
        }

        $allDevices = @($existing) + @($DeviceName)
        $deviceXml  = ($allDevices | ForEach-Object { "<device>$([string]$_)</device>" }) -join ""

        $updBody = @"
    <ns:updateUser>
      <userid>$UserId</userid>
      <associatedDevices>$deviceXml</associatedDevices>
    </ns:updateUser>
"@
        try {
            $updResp = Invoke-AxlRequest -Cucm $Cucm -Username $Username -Password $Password `
                                         -SoapAction "updateUser" -SoapBody $updBody -AxlVersion $AxlVersion
        } catch {
            $msg = [string]$_
            if ($msg -match "500") {
                throw "AXL 500: User '$UserId' does not exist as End User in CUCM. Check CUCM Admin > User Management > End User."
            }
            throw $_
        }
        $updXml = [xml]$updResp.Content
        return $updXml.Envelope.Body.updateUserResponse.return
    }
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://+:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "Error starting on port $Port : $($_.Exception.Message)"
    Write-Host "Tip: check that no other instance is running on this port."
    exit 1
}

Write-Log "Cisco 8800 Controller listening on $prefix"
Write-Log "Web app: http://localhost:$Port/"
Write-Log "API: GET /api/phones, POST /api/execute"

try {
    while ($listener.IsListening) {
        $context  = $null
        $request  = $null
        $response = $null
        try {
            $context  = $listener.GetContext()
            $request  = $context.Request
            $response = $context.Response
            $method = $request.HttpMethod.ToUpperInvariant()
            $path = $request.Url.AbsolutePath
            Write-Log "$method $path"

            if ($method -eq "GET" -and $path -eq "/") {
                Write-FileResponse -Response $response -Path (Join-Path $PSScriptRoot "web\index.html")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/styles.css") {
                Write-FileResponse -Response $response -Path (Join-Path $PSScriptRoot "web\styles.css")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/app.js") {
                Write-FileResponse -Response $response -Path (Join-Path $PSScriptRoot "web\app.js")
                continue
            }

            if ($method -eq "GET" -and $path -eq "/api/phones") {
                $phonesPath = Join-Path $PSScriptRoot $PhonesFile
                $phones = Read-Phones -Path $phonesPath
                # Déchiffrer les mots de passe avant envoi au client
                # foreach (mot-clé, même scope) évite les problèmes de résolution de fonctions dans ForEach-Object (PS5)
                $itemsList = [System.Collections.Generic.List[string]]::new()
                foreach ($p in $phones) {
                    $d = [ordered]@{}
                    foreach ($prop in $p.PSObject.Properties) { $d[$prop.Name] = $prop.Value }
                    $d['password']    = Unprotect-Password ([string]$p.password)
                    $d['sshPass']     = Unprotect-Password ([string]$p.sshPass)
                    $d['consolePass'] = Unprotect-Password ([string]$p.consolePass)
                    $itemsList.Add((ConvertTo-Json -InputObject $d -Depth 4 -Compress))
                }
                $json = "[" + ($itemsList -join ",") + "]"
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode = 200
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $bytes.LongLength
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/phones/add") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.sep)) { throw "Field 'sep' is required." }
                if ([string]::IsNullOrWhiteSpace($body.ip))  { throw "Field 'ip' is required." }

                $phonesPath = Join-Path $PSScriptRoot $PhonesFile
                # Construction safe (évite le bug PS5 [ArrayList]@(PSCustomObject[]))
                $phones = New-Object System.Collections.ArrayList
                foreach ($ph in (Read-Phones -Path $phonesPath)) { $null = $phones.Add($ph) }

                # Remove existing entry for this SEP if it exists (update)
                $existingIdx = -1
                for ($i = 0; $i -lt $phones.Count; $i++) {
                    if ([string]$phones[$i].sep -ceq [string]$body.sep) { $existingIdx = $i; break }
                }
                if ($existingIdx -ge 0) { $phones.RemoveAt($existingIdx) }

                $newPhone = [ordered]@{
                    name        = Get-BodyProp $body "name" ([string]$body.sep)
                    sep         = [string]$body.sep
                    ip          = [string]$body.ip
                    description = Get-BodyProp $body "description"
                    username    = Get-BodyProp $body "username" "admin"
                    password    = Protect-Password (Get-BodyProp $body "password")
                    sshUser     = Get-BodyProp $body "sshUser"
                    sshPass     = Protect-Password (Get-BodyProp $body "sshPass")
                    sshHostKey  = Get-BodyProp $body "sshHostKey"
                    consoleUser = Get-BodyProp $body "consoleUser"
                    consolePass = Protect-Password (Get-BodyProp $body "consolePass")
                }
                $null = $phones.Add($newPhone)

                # Sérialisation safe avec foreach (évite les problèmes de scope PS5)
                $itemsList3 = [System.Collections.Generic.List[string]]::new()
                foreach ($ph in $phones) { $itemsList3.Add((ConvertTo-Json -InputObject $ph -Depth 4 -Compress)) }
                $jsonOut = "[`n  " + ($itemsList3 -join ",`n  ") + "`n]"
                [System.IO.File]::WriteAllText($phonesPath, $jsonOut, [System.Text.Encoding]::UTF8)

                Write-Log "phones/add SEP=$([string]$body.sep) IP=$([string]$body.ip)"
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok    = $true
                    sep   = [string]$body.sep
                    ip    = [string]$body.ip
                    phone = $newPhone
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/execute") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd()
                $reader.Close()

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    throw "JSON body is empty."
                }

                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.ip)) {
                    throw "Field 'ip' is required."
                }

                $mode = [string]$body.mode
                $value = [string]$body.value
                $username = [string]$body.username
                $password = [string]$body.password

                $xml = ConvertTo-ExecuteXml -Mode $mode -Value $value
                $phoneRes = Invoke-CiscoExecute -Ip $body.ip -XmlBody $xml -Username $username -Password $password

                # Read the phone response body (Content can be string or byte[] depending on PS5/content-type)
                $phoneBody = ""
                if ($phoneRes.Content -is [string]) {
                    $phoneBody = $phoneRes.Content
                } elseif ($phoneRes.Content -is [byte[]]) {
                    $phoneBody = [System.Text.Encoding]::UTF8.GetString($phoneRes.Content)
                }

                # If the phone returns an XML error, report it
                if ($phoneBody -match "CiscoIPPhoneError") {
                    $errNum = ""
                    if ($phoneBody -match 'Number="(\d+)"') { $errNum = " (code $($Matches[1]))" }
                    throw "The phone rejected the command$errNum. Check credentials and that 'Web Access' is enabled in UCM."
                }

                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok = $true
                    request = @{
                        ip = $body.ip
                        mode = $mode
                    }
                    phoneResponseStatus = [string]$phoneRes.StatusCode
                    phoneBody = $phoneBody
                    responseLength = [int]$phoneRes.RawContentLength
                }
                continue
            }

            if ($method -eq "GET" -and $path -eq "/api/screenshot") {
                $query = $request.QueryString
                $ip = $query["ip"]
                $uname = $query["username"]
                $pword = $query["password"]

                if ([string]::IsNullOrWhiteSpace($ip)) {
                    throw "Parameter 'ip' is required."
                }

                $hdrs = @{}
                if (-not [string]::IsNullOrWhiteSpace($uname)) {
                    $pair = $uname + ":" + $pword
                    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
                    $hdrs["Authorization"] = "Basic $b64"
                }

                $imgRes = Invoke-WebRequest -Method Get -Uri "http://$ip/CGI/Screenshot" -Headers $hdrs -TimeoutSec 10 -UseBasicParsing
                $ct = $imgRes.Headers["Content-Type"]

                # If the phone returns XML/text it's an error (e.g.: <CiscoIPPhoneError Number="4" />)
                if ([string]::IsNullOrEmpty($ct) -or $ct -notmatch "^image/") {
                    $rawText = $imgRes.Content
                    $errMsg = "Screenshot not available (response: $rawText). Check that 'Web Access' is enabled in Cisco UCM > Device > Phone > Product Specific Configuration."
                    throw $errMsg
                }

                $imgBytes = $imgRes.RawContentStream.ToArray()
                $response.StatusCode = 200
                $response.ContentType = $ct
                $response.AddHeader("Cache-Control", "no-store")
                $response.ContentLength64 = $imgBytes.LongLength
                try {
                    $response.OutputStream.Write($imgBytes, 0, $imgBytes.Length)
                } catch {
                    # Client disconnected during transfer (e.g.: refresh, browser cancel)
                    Write-Log "Screenshot: client disconnected ($($_.Exception.Message.Split([char]10)[0]))"
                } finally {
                    try { $response.OutputStream.Close() } catch {}
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/version") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Field 'cucm' is required." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Field 'username' is required." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Field 'password' is required." }

                $vInfo = Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok          = $true
                    axlVersion  = $vInfo.version
                    cucmVersion = $vInfo.cucmVersion
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/phones") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Field 'cucm' is required." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Field 'username' is required." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Field 'password' is required." }

                $axlVer = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }
                $phones = Get-AxlPhones -Cucm $body.cucm -Username $body.username -Password $body.password -AxlVersion $axlVer

                # RisPort70 enrichment: IP + real-time registration status
                $deviceNames = @($phones | ForEach-Object { [string]$_.name })
                $risMap = @{}
                try {
                    $risMap = Get-RisPort70BulkStatus -Cucm $body.cucm -Username $body.username -Password $body.password -DeviceNames $deviceNames
                    Write-Log "RisPort70 bulk: $($risMap.Count)/$($phones.Count) devices with status"
                } catch {
                    Write-Log "RisPort70 bulk unavailable (IP/status absent): $($_.Exception.Message)"
                }

                $enriched = @()
                foreach ($p in $phones) {
                    $rs = $risMap[[string]$p.name]
                    $enriched += @{
                        name        = $p.name
                        description = $p.description
                        model       = $p.model
                        devicePool  = $p.devicePool
                        ip          = if ($rs) { $rs.ip     } else { "" }
                        status      = if ($rs) { $rs.status } else { "" }
                    }
                }

                # PS5: manually serialize phones array to avoid single-element-array bug
                $phonesItems = @($enriched) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }
                $phonesArray = "[" + ($phonesItems -join ",") + "]"
                $axlResp = "{`"ok`":true,`"axlVersion`":`"$axlVer`",`"phones`":$phonesArray}"
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($axlResp)
                $response.StatusCode = 200
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $bytes.LongLength
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/phoneip") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Field 'cucm' is required." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Field 'username' is required." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Field 'password' is required." }
                if ([string]::IsNullOrWhiteSpace($body.sep))      { throw "Field 'sep' is required." }

                $axlVerIp = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }

                # RisPort70: selectCmDevice to get the phone's real-time IP
                $sepSafe  = [System.Security.SecurityElement]::Escape([string]$body.sep)
                $risCucm  = [string]$body.cucm
                $risUser  = [string]$body.username
                $risPass  = [string]$body.password
                $risUri   = "https://$risCucm`:8443/realtimeservice2/services/RISService70"
                $risB64   = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${risUser}:${risPass}"))
                $risHdrs  = @{
                    "Authorization" = "Basic $risB64"
                    "SOAPAction"    = '""'
                }
                $risEnv = @"
<?xml version="1.0" encoding="UTF-8"?>
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:soap="http://schemas.cisco.com/ast/soap">
  <soapenv:Header/>
  <soapenv:Body>
    <soap:selectCmDevice>
      <soap:StateInfo></soap:StateInfo>
      <soap:CmSelectionCriteria>
        <soap:MaxReturnedDevices>1</soap:MaxReturnedDevices>
        <soap:DeviceClass>Phone</soap:DeviceClass>
        <soap:Model>255</soap:Model>
        <soap:Status>Any</soap:Status>
        <soap:NodeName></soap:NodeName>
        <soap:SelectBy>Name</soap:SelectBy>
        <soap:SelectItems>
          <soap:item>
            <soap:Item>$sepSafe</soap:Item>
          </soap:item>
        </soap:SelectItems>
        <soap:Protocol>Any</soap:Protocol>
        <soap:DownloadStatus>Any</soap:DownloadStatus>
      </soap:CmSelectionCriteria>
    </soap:selectCmDevice>
  </soapenv:Body>
</soapenv:Envelope>
"@
                try {
                    $risResp = Invoke-WebRequest -Uri $risUri -Method Post -Headers $risHdrs -Body $risEnv `
                        -ContentType "text/xml; charset=utf-8" -TimeoutSec 20 -UseBasicParsing
                } catch [System.Net.WebException] {
                    $risEx     = $_.Exception
                    $risStatus = if ($risEx.Response) { [int]$risEx.Response.StatusCode } else { 0 }
                    switch ($risStatus) {
                        401     { throw "RisPort70 401: access denied for '$risUser'. Add role 'Standard RealtimeAndTraceCollection' or 'Standard CCM Admin Users' in CUCM > User Management." }
                        403     { throw "RisPort70 403: access forbidden for '$risUser'. Check roles in CUCM." }
                        0       { throw "RisPort70 connection failed to ${risCucm}:8443 - $($risEx.Message)" }
                        default { throw "RisPort70 HTTP $risStatus - $($risEx.Message)" }
                    }
                }

                $risXml    = [xml]$risResp.Content
                $ipNode    = $risXml.SelectSingleNode("//*[local-name()='CmDevices']//*[local-name()='IPAddress']/*[local-name()='item']/*[local-name()='IP']")
                $statNode  = $risXml.SelectSingleNode("//*[local-name()='CmDevices']//*[local-name()='Status']")
                $descNode  = $risXml.SelectSingleNode("//*[local-name()='CmDevices']//*[local-name()='Description']")
                $totalNode = $risXml.SelectSingleNode("//*[local-name()='TotalDevicesFound']")

                $ipFound    = if ($ipNode)    { $ipNode.InnerText.Trim()    } else { "" }
                $devStatus  = if ($statNode)  { $statNode.InnerText.Trim()  } else { "" }
                $descFound  = if ($descNode)  { $descNode.InnerText.Trim()  } else { "" }
                $totalFound = if ($totalNode) { $totalNode.InnerText.Trim() } else { "0" }

                if ([string]::IsNullOrWhiteSpace($ipFound)) {
                    $risStatus2 = if ($devStatus) { $devStatus } else { "not registered" }
                    Write-Log "axl/phoneip $([string]$body.sep) -> not registered (RisPort70 total=$totalFound status=$risStatus2)"
                    Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                        ok           = $false
                        notRegistered = $true
                        sep          = [string]$body.sep
                        description  = $descFound
                        axlVersion   = $axlVerIp
                        error        = "Phone $([string]$body.sep) not registered on CUCM (RisPort70: $risStatus2)"
                    }
                    continue
                }

                Write-Log "axl/phoneip $([string]$body.sep) -> IP=$ipFound via RisPort70 (Status=$devStatus)"
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok          = $true
                    sep         = [string]$body.sep
                    ip          = $ipFound
                    description = $descFound
                    axlVersion  = $axlVerIp
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/provision") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))       { throw "Field 'cucm' is required." }
                if ([string]::IsNullOrWhiteSpace($body.username))   { throw "Field 'username' is required." }
                if ([string]::IsNullOrWhiteSpace($body.password))   { throw "Field 'password' is required." }
                if ([string]::IsNullOrWhiteSpace($body.deviceName)) { throw "Field 'deviceName' is required." }
                if ([string]::IsNullOrWhiteSpace($body.userId))     { throw "Field 'userId' is required." }

                $axlVerProv = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }
                $userTypeProv = if ($body.userType -eq "end") { "end" } else { "app" }
                $provSteps    = @()

                # Step 1: assign device to user (Application User or End User)
                Add-AxlDeviceToUser -Cucm $body.cucm -Username $body.username -Password $body.password `
                                    -UserId $body.userId -DeviceName $body.deviceName `
                                    -AxlVersion $axlVerProv -UserType $userTypeProv | Out-Null
                $provSteps += "Assigned to user '$([string]$body.userId)'"
                Write-Log "provision: $([string]$body.deviceName) -> assigned to '$([string]$body.userId)'"

                # Step 2a: enable SSH and web access via vendorConfig (PSC) + configure sshUserId
                # NOTE CUCM 11.5: <sshAccess>/<webAccess> at top-level field are silently ignored
                # NOTE CUCM 11.5: <sshPassword> in updatePhone is silently ignored (AXL bug)
                $devSafe      = [System.Security.SecurityElement]::Escape([string]$body.deviceName)
                $sshUser      = if (-not [string]::IsNullOrWhiteSpace($body.phoneSshUser)) { [System.Security.SecurityElement]::Escape([string]$body.phoneSshUser) } else { "" }
                $sshPass      = if (-not [string]::IsNullOrWhiteSpace($body.phoneSshPass)) { [string]$body.phoneSshPass } else { "" }
                $sshUserBlock = if ($sshUser -ne "") { "<sshUserId>$sshUser</sshUserId>" } else { "" }
                # <sshPassword> in plain text: accepted by CUCM 15.0+, silently ignored by CUCM 11.5 (SQL handles it in step 2b)
                $sshPassEsc   = [System.Security.SecurityElement]::Escape($sshPass)
                $sshPassBlock = if ($sshPass -ne "") { "<sshPassword>$sshPassEsc</sshPassword>" } else { "" }
                $updateBody = @"
    <ns:updatePhone>
      <name>$devSafe</name>
      <vendorConfig>
        <sshAccess>0</sshAccess>
        <webAccess>0</webAccess>
      </vendorConfig>
      $sshUserBlock
      $sshPassBlock
    </ns:updatePhone>
"@
                Invoke-AxlRequest -Cucm $body.cucm -Username $body.username -Password $body.password `
                                  -SoapAction "updatePhone" -SoapBody $updateBody -AxlVersion $axlVerProv | Out-Null
                $stepWeb = "SSH and Web access enabled in vendorConfig"
                if ($sshUser -ne "") { $stepWeb += ", SSH user '$([string]$body.phoneSshUser)' configured" }
                $provSteps += $stepWeb
                Write-Log "provision: $([string]$body.deviceName) -> $stepWeb"

                # Etape 2b : mot de passe SSH via executeSQLUpdate
                # CUCM 11.5 ignore <sshPassword> dans updatePhone — copier le hash depuis un telephone reference
                # Si aucun telephone reference n'est trouve, utiliser le hash connu (fallback)
                if ($sshUser -ne "" -and $sshPass -ne "") {
                    $devSafeSql  = ([string]$body.deviceName) -replace "'", "''"
                    $sshUserSql  = ([string]$body.phoneSshUser) -replace "'", "''"
                    $sshPassSql  = ([string]$body.phoneSshPass) -replace "'", "''"

                    # Known hashes for standard passwords (CUCM 11.5)
                    $knownHashes = @{
                        "postpost" = "5b872c9608e4eb787b79c8495d65b5dd2a4d0a9a8921e86886a4dfeb83660fbb"
                    }

                    # Attempt 1: copy from a reference phone that already has the same sshuserid
                    $sqlPassBody = @"
    <ns:executeSQLUpdate>
      <sql>UPDATE device SET sshpassword = (SELECT FIRST 1 sshpassword FROM device d2 WHERE d2.sshuserid = '$sshUserSql' AND d2.sshpassword IS NOT NULL AND d2.sshpassword != '' AND d2.name != '$devSafeSql') WHERE name = '$devSafeSql'</sql>
    </ns:executeSQLUpdate>
"@
                    $passConfigured = $false
                    try {
                        $sqlResp = Invoke-AxlRequest -Cucm $body.cucm -Username $body.username -Password $body.password `
                                                     -SoapAction "executeSQLUpdate" -SoapBody $sqlPassBody -AxlVersion $axlVerProv
                        $rows  = ([xml]$sqlResp.Content).SelectNodes("//*[local-name()='rowsUpdated']")
                        $rowsN = if ($rows.Count -gt 0) { [int]$rows[0].InnerText } else { 0 }
                        if ($rowsN -gt 0) {
                            $passConfigured = $true
                            $provSteps += "SSH password configured (from reference phone)"
                            Write-Log "provision: $([string]$body.deviceName) -> sshpassword copied from reference phone"
                        }
                    } catch {
                        Write-Log "WARN provision: $([string]$body.deviceName) -> SQL reference failed: $_"
                    }

                    # Attempt 2: known hash for this password (fallback if no reference phone)
                    if (-not $passConfigured) {
                        $knownHash = $knownHashes[[string]$body.phoneSshPass]
                        if ($knownHash) {
                            $sqlHashBody = @"
    <ns:executeSQLUpdate>
      <sql>UPDATE device SET sshpassword = '$knownHash' WHERE name = '$devSafeSql'</sql>
    </ns:executeSQLUpdate>
"@
                            try {
                                $sqlResp2 = Invoke-AxlRequest -Cucm $body.cucm -Username $body.username -Password $body.password `
                                                              -SoapAction "executeSQLUpdate" -SoapBody $sqlHashBody -AxlVersion $axlVerProv
                                $rows2  = ([xml]$sqlResp2.Content).SelectNodes("//*[local-name()='rowsUpdated']")
                                $rowsN2 = if ($rows2.Count -gt 0) { [int]$rows2[0].InnerText } else { 0 }
                                if ($rowsN2 -gt 0) {
                                    $passConfigured = $true
                                    $provSteps += "SSH password configured (known hash)"
                                    Write-Log "provision: $([string]$body.deviceName) -> sshpassword set via known hash"
                                } else {
                                    Write-Log "WARN provision: $([string]$body.deviceName) -> sshpassword known hash rowsUpdated=0"
                                }
                            } catch {
                                Write-Log "WARN provision: $([string]$body.deviceName) -> SQL known hash failed: $_"
                            }
                        } else {
                            Write-Log "WARN provision: $([string]$body.deviceName) -> SSH password not configured (no reference phone or known hash for this password)"
                        }
                    }
                }

                # Step 3: phone reset (reboot, not factory reset)
                $resetBody = @"
    <ns:doDeviceReset>
      <deviceName>$devSafe</deviceName>
      <isHardReset>false</isHardReset>
    </ns:doDeviceReset>
"@
                Invoke-AxlRequest -Cucm $body.cucm -Username $body.username -Password $body.password `
                                  -SoapAction "doDeviceReset" -SoapBody $resetBody -AxlVersion $axlVerProv | Out-Null
                $provSteps += "Reset sent (reboot in progress)"
                Write-Log "provision: $([string]$body.deviceName) -> reset sent"

                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok         = $true
                    deviceName = [string]$body.deviceName
                    userId     = [string]$body.userId
                    axlVersion = $axlVerProv
                    steps      = $provSteps
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/assign") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))       { throw "Field 'cucm' is required." }
                if ([string]::IsNullOrWhiteSpace($body.username))   { throw "Field 'username' is required." }
                if ([string]::IsNullOrWhiteSpace($body.password))   { throw "Field 'password' is required." }
                if ([string]::IsNullOrWhiteSpace($body.deviceName)) { throw "Field 'deviceName' is required." }
                if ([string]::IsNullOrWhiteSpace($body.userId))     { throw "Field 'userId' is required." }

                $axlVer2 = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }
                $userType = if ($body.userType -eq "end") { "end" } else { "app" }
                $uuid = Add-AxlDeviceToUser -Cucm $body.cucm -Username $body.username -Password $body.password `
                                            -UserId $body.userId -DeviceName $body.deviceName -AxlVersion $axlVer2 -UserType $userType
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok         = $true
                    deviceName = $body.deviceName
                    userId     = $body.userId
                    uuid       = [string]$uuid
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/phone/ssh") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.ip))          { throw "Field 'ip' is required." }
                if ([string]::IsNullOrWhiteSpace($body.sshUser))     { throw "Field 'sshUser' is required." }
                if ([string]::IsNullOrWhiteSpace($body.sshPass))     { throw "Field 'sshPass' is required." }
                if ([string]::IsNullOrWhiteSpace($body.consoleUser)) { throw "Field 'consoleUser' is required." }
                if ([string]::IsNullOrWhiteSpace($body.consolePass)) { throw "Field 'consolePass' is required." }
                if ([string]::IsNullOrWhiteSpace($body.command))     { throw "Field 'command' is required." }

                $sshIp = [string]$body.ip

                # ── Pre-check 1 : test TCP port 22 ───────────────────────────────────
                # Evite d'attendre 15s+ pour un timeout si le telephone est hors ligne
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $tcpConnected = $false
                try {
                    $ar = $tcpClient.BeginConnect($sshIp, 22, $null, $null)
                    $tcpConnected = $ar.AsyncWaitHandle.WaitOne(3000)
                    if ($tcpConnected) { try { $tcpClient.EndConnect($ar) } catch { $tcpConnected = $false } }
                } catch { $tcpConnected = $false }
                finally { try { $tcpClient.Close() } catch {} }

                if (-not $tcpConnected) {
                    Write-Log "SSH pre-check: port 22 inaccessible sur $sshIp"
                    Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                        ok                = $false
                        connectionRefused = $true
                        error             = "SSH pre-check: port 22 inaccessible sur $sshIp — telephone hors ligne, SSH desactive, ou IP incorrecte apres changement de cluster."
                    }
                    continue
                }
                Write-Log "SSH pre-check: port 22 OK sur $sshIp"

                # ── Pre-check 2 : banner SSH (detection algorithme / version) ─────────
                # Permet de savoir si le telephone accepte la connexion SSH avant d'envoyer les creds
                $sshBanner = ""
                try {
                    $bannerTcp = New-Object System.Net.Sockets.TcpClient
                    $bannerTcp.Connect($sshIp, 22)
                    $bannerStream = $bannerTcp.GetStream()
                    $bannerStream.ReadTimeout = 2000
                    $bannerBuf = New-Object byte[] 256
                    $bannerRead = $bannerStream.Read($bannerBuf, 0, 256)
                    if ($bannerRead -gt 0) {
                        $sshBanner = [System.Text.Encoding]::ASCII.GetString($bannerBuf, 0, $bannerRead).Trim()
                    }
                    $bannerTcp.Close()
                } catch { $sshBanner = "" }
                if ($sshBanner) { Write-Log "SSH banner $sshIp : $sshBanner" }

                # ── Detection SSH legacy (OpenSSH 5.x / CUCM 11.5) ───────────────────
                # Plink 0.83 classe aes256-cbc/aes128-cbc apres le marqueur WARN.
                # En mode -batch, plink refuse silencieusement quand un cipher WARN est
                # selectionne → timeout sans sortie. OpenSSH 5.x (CUCM 11.5) ne propose
                # QUE des ciphers CBC → -batch echoue toujours.
                # Sans -batch + -hostkey + stdin redirige : connexion OK, aucun prompt bloquant.
                # IMPORTANT : sans -hostkey, plink lit le prompt "Store key in cache?" depuis le
                # handle console Windows (pas stdin redirige) → blocage indefini. Il FAUT -hostkey.
                $isLegacySsh = $sshBanner -match "SSH-2\.0-OpenSSH_[0-5]\."
                if ($isLegacySsh) { Write-Log "SSH $sshIp : SSH legacy (OpenSSH 5.x / CUCM 11.5) detecte" }

                $storedHostKey    = [string]$body.sshHostKey
                $effectiveHostKey = ""
                $newSshHostKey    = $null

                # ── Obtention de l'empreinte SSH ─────────────────────────────────────
                # Legacy (OpenSSH 5.x) : ssh-keyscan echoue (cipher negotiation)
                #   → sonde ssh.exe -T (pas de PTY) : se connecte, stocke la cle dans un fichier
                #     temporaire known_hosts, sort code 1. La cle est extraite du fichier.
                # Moderne : ssh-keyscan standard.
                if ($isLegacySsh) {
                    Write-Log "SSH $sshIp : sonde ssh.exe pour obtenir la cle hote legacy..."
                    $tempKhFile = [System.IO.Path]::GetTempFileName()
                    $tmpProbeGuid = [System.Guid]::NewGuid().ToString("N")
                    $tmpBatProbe  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "askpass_probe_$tmpProbeGuid.bat")
                    # Le bat ecrit uniquement le mot de passe SSH (pour SSH_ASKPASS)
                    $sshPassEscaped = ([string]$body.sshPass) -replace '"','""'
                    Set-Content -Path $tmpBatProbe -Value "@echo off`r`necho $sshPassEscaped" -Encoding ASCII
                    try {
                        $sshProbePsi = New-Object System.Diagnostics.ProcessStartInfo
                        $sshProbePsi.FileName       = "ssh"
                        $sshProbePsi.UseShellExecute = $false
                        $sshProbePsi.Arguments       = "-T -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o Ciphers=+aes128-cbc -o MACs=+hmac-sha1 -o StrictHostKeyChecking=no -o UserKnownHostsFile=`"$tempKhFile`" -o LogLevel=QUIET -l $([string]$body.sshUser) $sshIp"
                        $sshProbePsi.RedirectStandardInput  = $true
                        $sshProbePsi.RedirectStandardOutput = $true
                        $sshProbePsi.RedirectStandardError  = $true
                        $sshProbePsi.CreateNoWindow          = $true
                        $sshProbePsi.EnvironmentVariables["SSH_ASKPASS"]         = $tmpBatProbe
                        $sshProbePsi.EnvironmentVariables["SSH_ASKPASS_REQUIRE"] = "force"
                        $sshProbeProc = [System.Diagnostics.Process]::Start($sshProbePsi)
                        $sshProbeProc.StandardInput.Close()
                        $null = $sshProbeProc.WaitForExit(5000)
                        # Lire la cle depuis le fichier known_hosts temporaire
                        $khLines = Get-Content $tempKhFile -ErrorAction SilentlyContinue
                        foreach ($khLine in $khLines) {
                            if ($khLine -match '^\S+\s+(ssh-rsa|ssh-dss)\s+(\S+)') {
                                $keyB64 = $Matches[2]
                                try {
                                    $keyBytes  = [Convert]::FromBase64String($keyB64)
                                    $sha256    = [System.Security.Cryptography.SHA256]::Create()
                                    $hashBytes = $sha256.ComputeHash($keyBytes)
                                    $hashB64   = [Convert]::ToBase64String($hashBytes).TrimEnd('=')
                                    $effectiveHostKey = "SHA256:$hashB64"
                                    Write-Log "SSH $sshIp : cle SSH legacy obtenue → $effectiveHostKey"
                                } catch {
                                    Write-Log "SSH $sshIp : erreur SHA256 cle legacy — $($_.Exception.Message)"
                                }
                                break
                            }
                        }
                    } catch {
                        Write-Log "SSH $sshIp : sonde ssh.exe echec — $($_.Exception.Message)"
                    } finally {
                        Remove-Item $tempKhFile  -Force -ErrorAction SilentlyContinue
                        Remove-Item $tmpBatProbe -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Log "SSH $sshIp : keyscan (verification empreinte actuelle)..."
                    try {
                        $ksJob = Start-Job -ScriptBlock {
                            param($ip)
                            & ssh-keyscan -t rsa,dss $ip 2>$null
                        } -ArgumentList $sshIp
                        $null = Wait-Job $ksJob -Timeout 5
                        $keyscanLines = Receive-Job $ksJob
                        Remove-Job $ksJob -Force
                        foreach ($kLine in $keyscanLines) {
                            if ($kLine -match '^\S+\s+(ssh-rsa|ssh-dss)\s+(\S+)') {
                                $keyAlg = $Matches[1]
                                $keyB64 = $Matches[2]
                                try {
                                    $keyBytes  = [Convert]::FromBase64String($keyB64)
                                    $sha256    = [System.Security.Cryptography.SHA256]::Create()
                                    $hashBytes = $sha256.ComputeHash($keyBytes)
                                    $hashB64   = [Convert]::ToBase64String($hashBytes).TrimEnd('=')
                                    $effectiveHostKey = "SHA256:$hashB64"
                                    Write-Log "SSH $sshIp : empreinte keyscan $keyAlg → $effectiveHostKey"
                                } catch {
                                    Write-Log "SSH $sshIp : erreur calcul SHA256 — $($_.Exception.Message)"
                                }
                                break
                            }
                        }
                    } catch {
                        Write-Log "SSH $sshIp : ssh-keyscan echec — $($_.Exception.Message)"
                    }
                }

                # Comparer la cle obtenue avec la cle stockee
                if (-not [string]::IsNullOrWhiteSpace($effectiveHostKey)) {
                    if ($effectiveHostKey -ne $storedHostKey) {
                        $newSshHostKey = $effectiveHostKey
                        Write-Log "SSH $sshIp : empreinte$(if($storedHostKey){' CHANGEE (stockee: ' + $storedHostKey + ')'}else{' decouverte'}) → sauvegarde: $effectiveHostKey"
                    }
                } else {
                    # Sonde echouee : utiliser la cle stockee comme fallback
                    $effectiveHostKey = $storedHostKey
                    Write-Log "SSH $sshIp : empreinte non obtenue — utilisation cle stockee ($(if($storedHostKey){$storedHostKey}else{'aucune'}))"
                }

                # ── Construction des arguments plink ─────────────────────────────────
                # Legacy (OpenSSH 5.x) : plink SANS -batch, AVEC -hostkey (obligatoire :
                #   sans -hostkey plink bloque sur son prompt console Windows, pas stdin redirige).
                # Moderne : plink AVEC -batch -hostkey ou fallback stdin "y".
                $plinkArgsList = @()
                if (-not [string]::IsNullOrWhiteSpace($effectiveHostKey)) {
                    if ($isLegacySsh) {
                        # Legacy : sans -batch (accepte CBC), avec -hostkey (evite le prompt console)
                        $plinkArgsList += @{
                            args      = "-ssh -hostkey `"$effectiveHostKey`" -l $([string]$body.sshUser) -pw $([string]$body.sshPass) $sshIp"
                            acceptKey = $false
                            label     = "legacy empreinte SHA256 (sans -batch)"
                        }
                    } else {
                        # Moderne : avec -batch -hostkey (mode non-interactif strict)
                        $plinkArgsList += @{
                            args      = "-ssh -batch -hostkey `"$effectiveHostKey`" -l $([string]$body.sshUser) -pw $([string]$body.sshPass) $sshIp"
                            acceptKey = $false
                            label     = "empreinte SHA256"
                        }
                    }
                }
                # Fallback stdin "y" uniquement pour SSH moderne (legacy : risque de blocage sur console)
                if (-not $isLegacySsh) {
                    $plinkArgsList += @{
                        args      = "-ssh -l $([string]$body.sshUser) -pw $([string]$body.sshPass) $sshIp"
                        acceptKey = $true
                        label     = "stdin y (fallback)"
                    }
                }
                # Si liste vide (legacy sans empreinte) : erreur explicite
                if ($plinkArgsList.Count -eq 0) {
                    throw "SSH echec : impossible d'obtenir l'empreinte SSH du telephone legacy (OpenSSH 5.x). Assurez-vous que ssh.exe est dans le PATH et que le telephone est joignable."
                }

                Write-Log "SSH $sshIp : $($body.command) [empreinte=$(if($effectiveHostKey){$effectiveHostKey}else{'inconnue'})] banner=$(if($sshBanner){$sshBanner}else{'N/A'})"

                $rawOutput = ""; $rawStderr = ""; $sshExitCode = -1

                foreach ($plinkVariant in $plinkArgsList) {
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName        = "plink"
                    $psi.Arguments       = $plinkVariant.args
                    $psi.RedirectStandardInput  = $true
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError  = $true
                    $psi.UseShellExecute        = $false
                    $psi.CreateNoWindow         = $true

                    Write-Log "SSH plink variant: $($plinkVariant.label)"
                    $sshProc = [System.Diagnostics.Process]::Start($psi)
                    $outTask = $sshProc.StandardOutput.ReadToEndAsync()
                    $errTask = $sshProc.StandardError.ReadToEndAsync()

                    # Forcer LF uniquement — la console serie Cisco 8800 interprete \r comme
                    # un caractere supplementaire dans le mot de passe (authentification echoue avec \r\n)
                    $sshProc.StandardInput.NewLine = "`n"

                    if ($plinkVariant.acceptKey) {
                        # Attendre le prompt "Store key in cache? (y/n, Return cancels connection)"
                        [System.Threading.Thread]::Sleep(500)
                        $sshProc.StandardInput.WriteLine("y")
                        [System.Threading.Thread]::Sleep(1500)
                    } else {
                        # Empreinte connue : pas de prompt cle, attendre directement l'auth SSH
                        [System.Threading.Thread]::Sleep(1800)
                    }

                    $sshProc.StandardInput.WriteLine([string]$body.consoleUser)
                    [System.Threading.Thread]::Sleep(1200)
                    $sshProc.StandardInput.WriteLine([string]$body.consolePass)
                    [System.Threading.Thread]::Sleep(3000)
                    $sshProc.StandardInput.WriteLine([string]$body.command)
                    [System.Threading.Thread]::Sleep(5000)
                    $sshProc.StandardInput.WriteLine("exit")
                    $sshProc.StandardInput.Close()

                    if (-not $sshProc.WaitForExit(20000)) { $sshProc.Kill() }
                    $rawOutput   = $outTask.GetAwaiter().GetResult()
                    $rawStderr   = $errTask.GetAwaiter().GetResult()
                    $sshExitCode = $sshProc.ExitCode

                    # Mismatch de cle : essayer la variante suivante (cle tournee apres keyscan)
                    if ($rawStderr -match "doesn't match|server's host key|wrong key|key exchange|DIFFERENT|not valid format") {
                        Write-Log "SSH $sshIp : rejet cle detecte ($($plinkVariant.label)) — tentative suivante"
                        $newSshHostKey = $null   # invalider la cle decouverte
                        continue
                    }
                    # Connexion refusee : inutile de retenter
                    if ($rawStderr -match 'Connection refused|Network error') { break }
                    # Sortie non vide : succes
                    if (-not [string]::IsNullOrWhiteSpace($rawOutput)) { break }
                }

                # Clean ANSI sequences and control characters
                $cleanOutput = [regex]::Replace($rawOutput, '(\x1B\[[0-9;]*[A-Za-z]|\x1B[()][A-Z0-9]|\r|\x00)', '')

                # Extract only the command output (between echo "DEBUG> cmd" and next "DEBUG>")
                $cmdEcho = "DEBUG> $([string]$body.command)"
                $inResult = $false
                $resultLines = [System.Collections.Generic.List[string]]::new()
                foreach ($line in ($cleanOutput -split '\n')) {
                    $trimmed = $line.TrimEnd()
                    if (-not $inResult) {
                        if ($trimmed -eq $cmdEcho) { $inResult = $true }
                        continue
                    }
                    # Fin de sortie : prochain prompt ou marqueur de fin
                    if ($trimmed -match '^DEBUG>' -or $trimmed -match '^Exiting shell|^Logging out') { break }
                    $resultLines.Add($trimmed)
                }

                $outputStr = ($resultLines | Where-Object { $_ -ne "" }) -join "`n"
                # If extraction fails (echo not found), return raw cleaned output
                if ([string]::IsNullOrWhiteSpace($outputStr)) {
                    $outputStr = ($cleanOutput -split '\n' | Where-Object { $_.Trim() }) -join "`n"
                }

                if ([string]::IsNullOrWhiteSpace($outputStr)) {
                    $stderrClean = $rawStderr.Trim()
                    # Connection refused (ne devrait pas arriver ici grace au pre-check TCP, mais securite)
                    if ($stderrClean -match 'Connection refused|Network error') {
                        Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                            ok                = $false
                            connectionRefused = $true
                            error             = "SSH echec : connexion refusee sur $sshIp (port 22 ferme ou SSH desactive)."
                        }
                        continue
                    }
                    # Mismatch de cle irresolu
                    if ($stderrClean -match "doesn't match|server's host key|wrong key|DIFFERENT") {
                        Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                            ok           = $false
                            keyMismatch  = $true
                            error        = "SSH echec : la cle SSH du telephone a change (changement de cluster ?). Effacez le champ 'sshHostKey' dans phones.json pour ce telephone et reessayez. stderr: $stderrClean"
                        }
                        continue
                    }
                    # Retourner le raw output + stderr pour faciliter le diagnostic
                    $debugInfo = ""
                    if ($stderrClean)  { $debugInfo += "STDERR: $stderrClean`n" }
                    if ($sshBanner)    { $debugInfo += "BANNER: $sshBanner`n" }
                    $rawClean = ($cleanOutput -split '\n' | Where-Object { $_.Trim() } | Select-Object -First 10) -join " | "
                    if ($rawClean)     { $debugInfo += "STDOUT(10 lignes): $rawClean" }
                    Write-Log "SSH $sshIp : no response — $debugInfo"
                    throw "SSH echec: aucune sortie recue. IP=$sshIp banner=$sshBanner. $debugInfo"
                }

                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok             = $true
                    output         = $outputStr.Trim()
                    exitCode       = $sshExitCode
                    newSshHostKey  = $newSshHostKey
                }
                continue
            }

            # ── CUCM Connections CRUD ────────────────────────────────
            $connPath = Join-Path $PSScriptRoot "cucm-connections.json"

            if ($method -eq "GET" -and $path -eq "/api/cucm-connections") {
                $conns = Read-CucmConnections -Path $connPath
                # Déchiffrer les mots de passe avant envoi au client
                $itemsList2 = [System.Collections.Generic.List[string]]::new()
                foreach ($c in $conns) {
                    $d = [ordered]@{}
                    foreach ($prop in $c.PSObject.Properties) { $d[$prop.Name] = $prop.Value }
                    $d['password']      = Unprotect-Password ([string]$c.password)
                    $d['phoneSshPass']  = Unprotect-Password ([string]$c.phoneSshPass)
                    $d['phoneHttpPass'] = Unprotect-Password ([string]$c.phoneHttpPass)
                    $itemsList2.Add((ConvertTo-Json -InputObject $d -Depth 4 -Compress))
                }
                $json = "[" + ($itemsList2 -join ",") + "]"
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                $response.StatusCode = 200
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $bytes.LongLength
                $response.OutputStream.Write($bytes, 0, $bytes.Length)
                $response.OutputStream.Close()
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/cucm-connections") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                $connName = Get-BodyProp $body "name"
                if ([string]::IsNullOrWhiteSpace($connName)) { throw "Field 'name' is required." }

                $conns = [System.Collections.ArrayList]@(Read-CucmConnections -Path $connPath)
                # Use index-based removal (safer than ArrayList.Remove() reference equality in PS5)
                $existingIdx = -1
                for ($i = 0; $i -lt $conns.Count; $i++) {
                    if ([string]$conns[$i].name -ceq $connName) { $existingIdx = $i; break }
                }
                if ($existingIdx -ge 0) { $conns.RemoveAt($existingIdx) }

                $entry = [ordered]@{
                    name          = $connName
                    cucm          = Get-BodyProp $body "cucm"
                    username      = Get-BodyProp $body "username"
                    password      = Protect-Password (Get-BodyProp $body "password")
                    userId        = Get-BodyProp $body "userId"
                    userType      = Get-BodyProp $body "userType" "app"
                    axlVersion    = Get-BodyProp $body "axlVersion" "auto"
                    phoneSshUser  = Get-BodyProp $body "phoneSshUser"
                    phoneSshPass  = Protect-Password (Get-BodyProp $body "phoneSshPass")
                    phoneHttpUser = Get-BodyProp $body "phoneHttpUser"
                    phoneHttpPass = Protect-Password (Get-BodyProp $body "phoneHttpPass")
                }
                $null = $conns.Add($entry)

                $items = @($conns) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }
                $jsonOut = "[`n  " + ($items -join ",`n  ") + "`n]"
                [System.IO.File]::WriteAllText($connPath, $jsonOut, [System.Text.Encoding]::UTF8)

                Write-Log "cucm-connections: saved '$connName'"
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ ok = $true; name = $connName }
                continue
            }

            if ($method -eq "DELETE" -and $path -eq "/api/cucm-connections") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                $connName = Get-BodyProp $body "name"
                if ([string]::IsNullOrWhiteSpace($connName)) { throw "Field 'name' is required." }

                $conns = [System.Collections.ArrayList]@(Read-CucmConnections -Path $connPath)
                $existingIdx = -1
                for ($i = 0; $i -lt $conns.Count; $i++) {
                    if ([string]$conns[$i].name -ceq $connName) { $existingIdx = $i; break }
                }
                if ($existingIdx -ge 0) {
                    $conns.RemoveAt($existingIdx)
                    $items = @($conns) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }
                    $jsonOut = if ($conns.Count -eq 0) { "[]" } else { "[`n  " + ($items -join ",`n  ") + "`n]" }
                    [System.IO.File]::WriteAllText($connPath, $jsonOut, [System.Text.Encoding]::UTF8)
                    Write-Log "cucm-connections: deleted '$connName'"
                }
                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{ ok = $true; name = $connName }
                continue
            }

            Write-JsonResponse -Response $response -StatusCode 404 -Payload @{
                ok = $false
                error = "Route not found."
            }
        } catch [System.Net.HttpListenerException] {
            if (-not $listener.IsListening) { break }
            continue
        } catch {
            $errMsg = $_.Exception.Message
            Write-Log "ERROR: $errMsg"
            if ($null -ne $response) {
                try {
                    Write-JsonResponse -Response $response -StatusCode 400 -Payload @{
                        ok = $false
                        error = $errMsg
                    }
                } catch {
                    Write-Log "Failed to send error response: $($_.Exception.Message)"
                    try { $response.OutputStream.Close() } catch {}
                }
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Log "Server stopped."
}
