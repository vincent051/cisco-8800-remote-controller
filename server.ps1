param(
    [int]$Port = 8080,
    [string]$PhonesFile = "phones.json"
)

Set-StrictMode -Off
$ErrorActionPreference = "Continue"

# ---- TLS bypass pour appels AXL (certificat auto-signe CUCM) ----
Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCerts : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCerts
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
# TLS 1.2 + TLS 1.3 (12288) pour CUCM 14+ qui exige TLS 1.3
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

    # @() force un tableau meme si phones.json ne contient qu'un seul element (PS5 deserialie en PSObject sinon)
    return @(Get-Content -Path $Path -Raw | ConvertFrom-Json)
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
                throw "Le parametre 'value' est requis pour mode=key."
            }
            # Mapping des touches numeriques vers le format KeyPad requis par Cisco 8800
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
                throw "Le parametre 'value' est requis pour mode=dial."
            }
            $escapedValue = [System.Security.SecurityElement]::Escape($Value)
            return "<CiscoIPPhoneExecute><ExecuteItem Priority=`"0`" URL=`"Dial:$escapedValue`" /></CiscoIPPhoneExecute>"
        }
        "xml" {
            if ([string]::IsNullOrWhiteSpace($Value)) {
                throw "Le XML est vide pour mode=xml."
            }
            return $Value
        }
        default {
            throw "Mode invalide. Valeurs supportees: key, dial, xml."
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

    # Le telephone attend un form field "XML=..." (application/x-www-form-urlencoded)
    # et une authentification Basic avec le user CUCM associe au phone
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
            error = "Fichier introuvable."
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

        # Lit le corps de la reponse d'erreur (SOAP Fault)
        $errBody = ""
        if ($errResp) {
            try {
                $stream = $errResp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $errBody = $reader.ReadToEnd()
            } catch {}
        }

        # Extrait le faultstring (peut contenir des entites XML)
        $faultMsg = ""
        if ($errBody -match "(?s)<faultstring[^>]*>(.+?)</faultstring>") {
            $raw = $Matches[1] -replace "&amp;","&" -replace "&lt;","<" -replace "&gt;",">" -replace "&apos;","'" -replace "&quot;",'"'
            $faultMsg = " - $raw"
        } elseif ($errBody -match "(?s)<axlmessage>(.+?)</axlmessage>") {
            $faultMsg = " - $($Matches[1])"
        }
        Write-Log "AXL HTTP $httpCode body: $($errBody.Substring(0,[Math]::Min(300,$errBody.Length)))"

        switch ($httpCode) {
            401 { throw "AXL 401 Unauthorized$faultMsg. Verifier que '$Username' a le role 'Standard AXL API Access' dans CUCM > User Management > Application User." }
            403 { throw "AXL 403 Forbidden$faultMsg. Acces refuse pour '$Username'." }
            500 { throw "AXL 500 SOAP Fault$faultMsg." }
            599 { throw "AXL 599$faultMsg. Verifier l'IP CUCM et que le service 'Cisco AXL Web Service' est actif (CUCM Serviceability)." }
            0   { throw "AXL connexion impossible vers $Cucm`:8443 - $($webEx.Message)" }
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
        throw "Format de version CUCM inconnu: $verStr"
    } catch [System.Net.WebException] {
        $webEx    = $_.Exception
        $errResp  = $webEx.Response
        $httpCode = if ($errResp) { [int]$errResp.StatusCode } else { 0 }
        switch ($httpCode) {
            401     { throw "AXL 401 - verifier les credentials '$Username'" }
            0       { throw "AXL connexion impossible vers $Cucm`:8443 - $($webEx.Message)" }
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
        # devicePoolName peut etre un objet avec attribut #text ou une string simple
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
            Write-Log "RisPort70 bulk lot $bi erreur: $($_.Exception.Message)"
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
            Write-Log "getAppUser '$UserId' -> $($existing.Count) device(s) existant(s)"
        } catch {
            Write-Log "getAppUser '$UserId' ignoré (nouveau ou aucun device): $_"
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
                throw "AXL 500 : l'Application User '$UserId' est introuvable dans CUCM. Verifier CUCM Admin > User Management > Application User."
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
            Write-Log "getUser '$UserId' -> $($existing.Count) device(s) existant(s)"
        } catch {
            Write-Log "getUser '$UserId' ignoré: $_"
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
                throw "AXL 500 : l'utilisateur '$UserId' n'existe pas comme End User dans CUCM. Verifier CUCM Admin > User Management > End User."
            }
            throw $_
        }
        $updXml = [xml]$updResp.Content
        return $updXml.Envelope.Body.updateUserResponse.return
    }
}

$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Host "Erreur demarrage sur port $Port : $($_.Exception.Message)"
    Write-Host "Conseil : verifier qu'aucune autre instance ne tourne sur ce port."
    exit 1
}

Write-Log "Cisco 8800 Controller en ecoute sur $prefix"
Write-Log "App web: http://localhost:$Port/"
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
                # Serialiser manuellement en tableau JSON (ConvertTo-Json PS5 ne gere pas bien les tableaux)
                $items = @($phones) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }
                $json = "[" + ($items -join ",") + "]"
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

                if ([string]::IsNullOrWhiteSpace($body.sep)) { throw "Le champ 'sep' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.ip))  { throw "Le champ 'ip' est requis." }

                $phonesPath = Join-Path $PSScriptRoot $PhonesFile
                $phones = [System.Collections.ArrayList]@(Read-Phones -Path $phonesPath)

                # Supprimer l'entree existante pour ce SEP si elle existe (mise a jour)
                $existing = $phones | Where-Object { $_.sep -eq [string]$body.sep }
                if ($existing) { $null = $phones.Remove($existing) }

                $newPhone = [ordered]@{
                    name        = Get-BodyProp $body "name" ([string]$body.sep)
                    sep         = [string]$body.sep
                    ip          = [string]$body.ip
                    description = Get-BodyProp $body "description"
                    username    = Get-BodyProp $body "username" "admin"
                    password    = Get-BodyProp $body "password"
                    sshUser     = Get-BodyProp $body "sshUser"
                    sshPass     = Get-BodyProp $body "sshPass"
                    sshHostKey  = Get-BodyProp $body "sshHostKey"
                    consoleUser = Get-BodyProp $body "consoleUser"
                    consolePass = Get-BodyProp $body "consolePass"
                }
                $null = $phones.Add($newPhone)

                # Ecrire le fichier JSON (tableau formaté)
                $items = @($phones) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 4 -Compress }
                $jsonOut = "[`n  " + ($items -join ",`n  ") + "`n]"
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
                    throw "Le corps JSON est vide."
                }

                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.ip)) {
                    throw "Le champ 'ip' est requis."
                }

                $mode = [string]$body.mode
                $value = [string]$body.value
                $username = [string]$body.username
                $password = [string]$body.password

                $xml = ConvertTo-ExecuteXml -Mode $mode -Value $value
                $phoneRes = Invoke-CiscoExecute -Ip $body.ip -XmlBody $xml -Username $username -Password $password

                # Lire le corps de la reponse du telephone (Content peut etre string ou byte[] selon PS5/content-type)
                $phoneBody = ""
                if ($phoneRes.Content -is [string]) {
                    $phoneBody = $phoneRes.Content
                } elseif ($phoneRes.Content -is [byte[]]) {
                    $phoneBody = [System.Text.Encoding]::UTF8.GetString($phoneRes.Content)
                }

                # Si le telephone renvoie une erreur XML, la signaler
                if ($phoneBody -match "CiscoIPPhoneError") {
                    $errNum = ""
                    if ($phoneBody -match 'Number="(\d+)"') { $errNum = " (code $($Matches[1]))" }
                    throw "Le telephone a refuse la commande$errNum. Verifier les credentials et que 'Web Access' est active dans UCM."
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
                    throw "Le parametre 'ip' est requis."
                }

                $hdrs = @{}
                if (-not [string]::IsNullOrWhiteSpace($uname)) {
                    $pair = $uname + ":" + $pword
                    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
                    $hdrs["Authorization"] = "Basic $b64"
                }

                $imgRes = Invoke-WebRequest -Method Get -Uri "http://$ip/CGI/Screenshot" -Headers $hdrs -TimeoutSec 10 -UseBasicParsing
                $ct = $imgRes.Headers["Content-Type"]

                # Si le telephone renvoie du XML/texte c'est une erreur (ex: <CiscoIPPhoneError Number="4" />)
                if ([string]::IsNullOrEmpty($ct) -or $ct -notmatch "^image/") {
                    $rawText = $imgRes.Content
                    $errMsg = "Screenshot non disponible (reponse: $rawText). Verifier que 'Web Access' est active dans Cisco UCM > Device > Phone > Product Specific Configuration."
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
                    # Client deconnecte pendant le transfert (ex: refresh, annulation navigateur)
                    Write-Log "Screenshot: client deconnecte ($($_.Exception.Message.Split([char]10)[0]))"
                } finally {
                    try { $response.OutputStream.Close() } catch {}
                }
                continue
            }

            if ($method -eq "POST" -and $path -eq "/api/axl/version") {
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $raw = $reader.ReadToEnd(); $reader.Close()
                $body = $raw | ConvertFrom-Json

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Le champ 'cucm' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Le champ 'username' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Le champ 'password' est requis." }

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

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Le champ 'cucm' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Le champ 'username' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Le champ 'password' est requis." }

                $axlVer = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }
                $phones = Get-AxlPhones -Cucm $body.cucm -Username $body.username -Password $body.password -AxlVersion $axlVer

                # Enrichissement RisPort70 : IP + statut d'enregistrement en temps reel
                $deviceNames = @($phones | ForEach-Object { [string]$_.name })
                $risMap = @{}
                try {
                    $risMap = Get-RisPort70BulkStatus -Cucm $body.cucm -Username $body.username -Password $body.password -DeviceNames $deviceNames
                    Write-Log "RisPort70 bulk: $($risMap.Count)/$($phones.Count) appareils avec statut"
                } catch {
                    Write-Log "RisPort70 bulk indisponible (IP/statut absent): $($_.Exception.Message)"
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

                # PS5 : serialiser le tableau phones manuellement pour eviter le bug single-element-array
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

                if ([string]::IsNullOrWhiteSpace($body.cucm))     { throw "Le champ 'cucm' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.username)) { throw "Le champ 'username' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.password)) { throw "Le champ 'password' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.sep))      { throw "Le champ 'sep' est requis." }

                $axlVerIp = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }

                # RisPort70 : selectCmDevice pour obtenir l'IP en temps reel du telephone
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
                        401     { throw "RisPort70 401 : acces refuse pour '$risUser'. Ajouter le role 'Standard RealtimeAndTraceCollection' ou 'Standard CCM Admin Users' dans CUCM > User Management." }
                        403     { throw "RisPort70 403 : acces interdit pour '$risUser'. Verifier les roles dans CUCM." }
                        0       { throw "RisPort70 connexion impossible vers ${risCucm}:8443 - $($risEx.Message)" }
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
                    $risStatus2 = if ($devStatus) { $devStatus } else { "non enregistre" }
                    Write-Log "axl/phoneip $([string]$body.sep) -> non enregistre (RisPort70 total=$totalFound statut=$risStatus2)"
                    Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                        ok           = $false
                        notRegistered = $true
                        sep          = [string]$body.sep
                        description  = $descFound
                        axlVersion   = $axlVerIp
                        error        = "Telephone $([string]$body.sep) non enregistre sur CUCM (RisPort70 : $risStatus2)"
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

                if ([string]::IsNullOrWhiteSpace($body.cucm))       { throw "Le champ 'cucm' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.username))   { throw "Le champ 'username' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.password))   { throw "Le champ 'password' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.deviceName)) { throw "Le champ 'deviceName' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.userId))     { throw "Le champ 'userId' est requis." }

                $axlVerProv = if ($body.axlVersion -and $body.axlVersion -ne "auto") { [string]$body.axlVersion } else {
                    (Get-AxlCucmVersion -Cucm $body.cucm -Username $body.username -Password $body.password).version
                }
                $userTypeProv = if ($body.userType -eq "end") { "end" } else { "app" }
                $provSteps    = @()

                # Etape 1 : assigner le device a l'utilisateur (Application User ou End User)
                Add-AxlDeviceToUser -Cucm $body.cucm -Username $body.username -Password $body.password `
                                    -UserId $body.userId -DeviceName $body.deviceName `
                                    -AxlVersion $axlVerProv -UserType $userTypeProv | Out-Null
                $provSteps += "Assigne a l'utilisateur '$([string]$body.userId)'"
                Write-Log "provision: $([string]$body.deviceName) -> assigne a '$([string]$body.userId)'"

                # Etape 2a : activer SSH et web access via vendorConfig (PSC) + configurer sshUserId
                # NOTE CUCM 11.5 : <sshAccess>/<webAccess> en champ de haut niveau sont ignores silencieusement
                # NOTE CUCM 11.5 : <sshPassword> dans updatePhone est ignore silencieusement (bug AXL)
                $devSafe      = [System.Security.SecurityElement]::Escape([string]$body.deviceName)
                $sshUser      = if (-not [string]::IsNullOrWhiteSpace($body.phoneSshUser)) { [System.Security.SecurityElement]::Escape([string]$body.phoneSshUser) } else { "" }
                $sshPass      = if (-not [string]::IsNullOrWhiteSpace($body.phoneSshPass)) { [string]$body.phoneSshPass } else { "" }
                $sshUserBlock = if ($sshUser -ne "") { "<sshUserId>$sshUser</sshUserId>" } else { "" }
                # <sshPassword> en clair : accepte par CUCM 15.0+, ignore silencieusement par CUCM 11.5 (le SQL prend le relais en etape 2b)
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
                $stepWeb = "SSH et Web access actives dans vendorConfig"
                if ($sshUser -ne "") { $stepWeb += ", SSH user '$([string]$body.phoneSshUser)' configure" }
                $provSteps += $stepWeb
                Write-Log "provision: $([string]$body.deviceName) -> $stepWeb"

                # Etape 2b : mot de passe SSH via executeSQLUpdate
                # CUCM 11.5 ignore <sshPassword> dans updatePhone — copier le hash depuis un telephone reference
                # Si aucun telephone reference n'est trouve, utiliser le hash connu (fallback)
                if ($sshUser -ne "" -and $sshPass -ne "") {
                    $devSafeSql  = ([string]$body.deviceName) -replace "'", "''"
                    $sshUserSql  = ([string]$body.phoneSshUser) -replace "'", "''"
                    $sshPassSql  = ([string]$body.phoneSshPass) -replace "'", "''"

                    # Hashes connus pour les mots de passe standards (CUCM 11.5)
                    $knownHashes = @{
                        "postpost" = "5b872c9608e4eb787b79c8495d65b5dd2a4d0a9a8921e86886a4dfeb83660fbb"
                    }

                    # Tentative 1 : copier depuis un telephone reference ayant deja le meme sshuserid
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
                            $provSteps += "Mot de passe SSH configure (depuis reference)"
                            Write-Log "provision: $([string]$body.deviceName) -> sshpassword copie depuis telephone reference"
                        }
                    } catch {
                        Write-Log "WARN provision: $([string]$body.deviceName) -> echec SQL reference: $_"
                    }

                    # Tentative 2 : hash connu pour ce mot de passe (fallback si aucun telephone reference)
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
                                    $provSteps += "Mot de passe SSH configure (hash connu)"
                                    Write-Log "provision: $([string]$body.deviceName) -> sshpassword defini via hash connu"
                                } else {
                                    Write-Log "WARN provision: $([string]$body.deviceName) -> sshpassword hash connu rowsUpdated=0"
                                }
                            } catch {
                                Write-Log "WARN provision: $([string]$body.deviceName) -> echec SQL hash connu: $_"
                            }
                        } else {
                            Write-Log "WARN provision: $([string]$body.deviceName) -> mot de passe SSH non configure (aucun reference ni hash connu pour ce mot de passe)"
                        }
                    }
                }

                # Etape 3 : reset du telephone (redemarrage, pas factory reset)
                $resetBody = @"
    <ns:doDeviceReset>
      <deviceName>$devSafe</deviceName>
      <isHardReset>false</isHardReset>
    </ns:doDeviceReset>
"@
                Invoke-AxlRequest -Cucm $body.cucm -Username $body.username -Password $body.password `
                                  -SoapAction "doDeviceReset" -SoapBody $resetBody -AxlVersion $axlVerProv | Out-Null
                $provSteps += "Reset envoye (redemarrage en cours)"
                Write-Log "provision: $([string]$body.deviceName) -> reset envoye"

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

                if ([string]::IsNullOrWhiteSpace($body.cucm))       { throw "Le champ 'cucm' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.username))   { throw "Le champ 'username' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.password))   { throw "Le champ 'password' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.deviceName)) { throw "Le champ 'deviceName' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.userId))     { throw "Le champ 'userId' est requis." }

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

                if ([string]::IsNullOrWhiteSpace($body.ip))          { throw "Le champ 'ip' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.sshUser))     { throw "Le champ 'sshUser' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.sshPass))     { throw "Le champ 'sshPass' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.consoleUser)) { throw "Le champ 'consoleUser' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.consolePass)) { throw "Le champ 'consolePass' est requis." }
                if ([string]::IsNullOrWhiteSpace($body.command))     { throw "Le champ 'command' est requis." }

                # Connexion SSH Cisco 8800 : sans PTY (-batch), le telephone presente une console serie
                # Sequence : SSH(post/postpost) -> console serie(debug/debug) -> commande -> exit
                $plinkArgs = "-ssh -batch -l $([string]$body.sshUser) -pw $([string]$body.sshPass)"
                if (-not [string]::IsNullOrWhiteSpace($body.sshHostKey)) {
                    # Cle connue : utiliser -hostkey pour eviter le prompt (mode -batch strict)
                    $plinkArgs += " -hostkey `"$([string]$body.sshHostKey)`""
                }
                # Si sshHostKey vide : utiliser le cache registre PuTTY (HKCU\Software\SimonTatham\PuTTY\SshHostKeys)
                # En mode -batch, plink echoue si la cle n'est pas en cache → message clair retourne
                $plinkArgs += " $([string]$body.ip)"

                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "plink"
                $psi.Arguments = $plinkArgs
                $psi.RedirectStandardInput  = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $psi.UseShellExecute        = $false
                $psi.CreateNoWindow         = $true

                Write-Log "SSH $($body.ip) : $($body.command)"
                $sshProc = [System.Diagnostics.Process]::Start($psi)
                $outTask = $sshProc.StandardOutput.ReadToEndAsync()

                # Attendre invite login console serie
                [System.Threading.Thread]::Sleep(1800)
                $sshProc.StandardInput.WriteLine([string]$body.consoleUser)
                [System.Threading.Thread]::Sleep(1200)
                $sshProc.StandardInput.WriteLine([string]$body.consolePass)
                # Attendre prompt DEBUG>
                [System.Threading.Thread]::Sleep(2500)
                $sshProc.StandardInput.WriteLine([string]$body.command)
                # Attendre la sortie de la commande
                [System.Threading.Thread]::Sleep(4000)
                $sshProc.StandardInput.WriteLine("exit")
                $sshProc.StandardInput.Close()

                if (-not $sshProc.WaitForExit(15000)) { $sshProc.Kill() }
                $rawOutput = $outTask.GetAwaiter().GetResult()

                # Nettoyer sequences ANSI et caracteres de controle
                $cleanOutput = [regex]::Replace($rawOutput, '(\x1B\[[0-9;]*[A-Za-z]|\x1B[()][A-Z0-9]|\r|\x00)', '')

                # Extraire uniquement la sortie de la commande (entre l'echo "DEBUG> cmd" et le prochain "DEBUG>")
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
                # Si extraction echoue (echo non trouve), retourner la sortie brute nettoyee
                if ([string]::IsNullOrWhiteSpace($outputStr)) {
                    $outputStr = ($cleanOutput -split '\n' | Where-Object { $_.Trim() }) -join "`n"
                }

                if ([string]::IsNullOrWhiteSpace($outputStr)) {
                    throw "SSH echoue : aucune reponse du telephone. Verifier IP, credentials et que SSH est active."
                }

                Write-JsonResponse -Response $response -StatusCode 200 -Payload @{
                    ok       = $true
                    output   = $outputStr.Trim()
                    exitCode = $sshProc.ExitCode
                }
                continue
            }

            Write-JsonResponse -Response $response -StatusCode 404 -Payload @{
                ok = $false
                error = "Route non trouvee."
            }
        } catch [System.Net.HttpListenerException] {
            if (-not $listener.IsListening) { break }
            continue
        } catch {
            $errMsg = $_.Exception.Message
            Write-Log "ERREUR: $errMsg"
            if ($null -ne $response) {
                try {
                    Write-JsonResponse -Response $response -StatusCode 400 -Payload @{
                        ok = $false
                        error = $errMsg
                    }
                } catch {
                    Write-Log "Impossible d'envoyer la reponse d'erreur: $($_.Exception.Message)"
                    try { $response.OutputStream.Close() } catch {}
                }
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Log "Serveur arrete."
}
