// ---- DOM References ----
const el = {
  phoneList:       document.getElementById("phoneList"),
  targetIp:        document.getElementById("targetIp"),
  username:        document.getElementById("username"),
  password:        document.getElementById("password"),
  status:          document.getElementById("status"),
  log:             document.getElementById("log"),
  keyInput:        document.getElementById("keyInput"),
  dialInput:       document.getElementById("dialInput"),
  customXml:       document.getElementById("customXml"),
  screenshot:      document.getElementById("screenshot"),
  screenshotError: document.getElementById("screenshotError"),
  sshCommand:      document.getElementById("sshCommand"),
  sshOutput:       document.getElementById("sshOutput")
};

// ---- Map SEP name -> phone config (from phones.json) ----
var phonesMap = {};
var currentPhoneSep = "";

// ---- Tabs ----
document.querySelectorAll(".tab-btn").forEach(function(btn) {
  btn.addEventListener("click", function() {
    document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
    document.querySelectorAll(".tab-pane").forEach(function(p) { p.classList.remove("active"); });
    btn.classList.add("active");
    document.getElementById(btn.dataset.tab).classList.add("active");
  });
});

// ---- Resizable splitters ----
function initSplitter(splitterId, leftId, rightId, defaultFraction) {
  var splitter = document.getElementById(splitterId);
  var leftEl   = document.getElementById(leftId);
  var rightEl  = document.getElementById(rightId);
  if (!splitter || !leftEl || !rightEl) return;
  // Initial width: fraction of parent container
  var frac = (defaultFraction != null) ? defaultFraction : null;
  if (frac != null) {
    var parent = leftEl.parentElement;
    var containerW = parent ? parent.offsetWidth : 0;
    if (containerW > 0) {
      leftEl.style.width = Math.round(containerW * frac) + "px";
      leftEl.style.flexShrink = "0";
    }
  }
  var dragging = false;
  var startX = 0;
  var startW = 0;
  splitter.addEventListener("mousedown", function(e) {
    dragging = true;
    startX = e.clientX;
    startW = leftEl.offsetWidth;
    splitter.classList.add("dragging");
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
    e.preventDefault();
  });
  document.addEventListener("mousemove", function(e) {
    if (!dragging) return;
    var newW = Math.max(160, startW + (e.clientX - startX));
    leftEl.style.width = newW + "px";
    leftEl.style.flexShrink = "0";
  });
  document.addEventListener("mouseup", function() {
    if (!dragging) return;
    dragging = false;
    splitter.classList.remove("dragging");
    document.body.style.cursor = "";
    document.body.style.userSelect = "";
  });
}
initSplitter("splitterCtrl", "ctrlScreenCol", "ctrlControlsCol", 0.5);
initSplitter("splitterAxl",  "axlSidebar",    "axlPanel");

// ---- Auto-refresh state ----
let autoRefreshActive = false;
let screenshotFailCount = 0;
var SCREENSHOT_MAX_FAILS = 15;

// ---- Pending provisioning (waiting for phone reboot) ----
// { sep, ip }: updated after doDeviceReset, cleared when screenshot is OK
var provisioningPending = null;

// ---- Utilitaires ----
function setStatus(text, isOk) {
  if (isOk === undefined) isOk = true;
  el.status.textContent = text;
  el.status.className = "status " + (isOk ? "ok" : "err");
}

function addLog(message) {
  var stamp = new Date().toLocaleTimeString();
  el.log.textContent = "[" + stamp + "] " + message + "\n" + el.log.textContent;
}

// ---- Phone list loading ----
async function loadPhones() {
  try {
    var res = await fetch("/api/phones");
    if (!res.ok) throw new Error("HTTP " + res.status);
    var phones = await res.json();

    // Build SEP -> phone map
    phonesMap = {};
    phones.forEach(function(p) {
      if (p.sep) phonesMap[p.sep.toLowerCase()] = p;
    });

    el.phoneList.innerHTML = "";
    var ph = document.createElement("option");
    ph.value = "";
    ph.textContent = "Choose a phone...";
    el.phoneList.appendChild(ph);

    phones.forEach(function(p) {
      var opt = document.createElement("option");
      opt.value = p.ip;
      opt.textContent = p.name + " (" + p.ip + ")";
      opt.dataset.username = p.username || "";
      opt.dataset.password = p.password || "";
      opt.dataset.sep = p.sep || "";
      el.phoneList.appendChild(opt);
    });

    // Si un seul phone : activer automatiquement
    if (phones.length === 1) {
      el.phoneList.selectedIndex = 1;
      el.phoneList.dispatchEvent(new Event("change"));
    }
  } catch (err) {
    setStatus("Failed to load phone list: " + err.message, false);
  }
}

// Refreshes phonesMap only without rebuilding the dropdown
async function refreshPhonesMap() {
  try {
    var res = await fetch("/api/phones?t=" + Date.now());
    if (!res.ok) return;
    var phones = await res.json();
    phonesMap = {};
    phones.forEach(function(p) { if (p.sep) phonesMap[p.sep.toLowerCase()] = p; });
  } catch (e) { /* silent */ }
}

el.phoneList.addEventListener("change", function() {
  var s = el.phoneList.options[el.phoneList.selectedIndex];
  el.targetIp.value = s ? s.value : "";
  if (s && s.value) {
    if (s.dataset.username) el.username.value = s.dataset.username;
    if (s.dataset.password) el.password.value = s.dataset.password;
    var sep = s.dataset.sep || "";
    currentPhoneSep = sep.toLowerCase();
    document.getElementById("activePhoneName").textContent = sep || s.textContent.split(" (")[0];
    document.getElementById("activePhoneIp").textContent = s.value;
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "📱";
  }
});

// ---- Switch to Controller tab with an AXL phone ----
async function switchToControllerWithPhone(sepName) {
  // Always refresh phonesMap from phones.json (file may have changed)
  await refreshPhonesMap();
  var phone = phonesMap[sepName.toLowerCase()];

  // Switch to Controller tab
  document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
  document.querySelectorAll(".tab-pane").forEach(function(p) { p.classList.remove("active"); });
  document.querySelector('.tab-btn[data-tab="tab-controller"]').classList.add("active");
  document.getElementById("tab-controller").classList.add("active");

  if (phone) {
    // Remplir les champs cachés
    el.targetIp.value = phone.ip;
    el.username.value = phone.username || "";
    el.password.value = phone.password || "";

    // Mettre à jour la barre téléphone actif
    currentPhoneSep = sepName.toLowerCase();
    document.getElementById("activePhoneName").textContent = sepName;
    document.getElementById("activePhoneIp").textContent = phone.ip;
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "📱";
    setStatus("Active phone: " + phone.ip, true);
    addLog("Controlling " + sepName + " (" + phone.ip + ")");

    // Démarrer l'auto-refresh
    var btn = document.getElementById("btnAutoRefresh");
    autoRefreshActive = true;
    btn.textContent = "Auto-refresh: ON";
    btn.classList.add("active-btn");
    screenshotFailCount = 0;
    refreshScreenshot();
  } else {
    // Unknown phone -> automatic resolution via AXL
    document.getElementById("activePhoneName").textContent = sepName;
    document.getElementById("activePhoneIp").textContent = "Resolving\u2026";
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u23F3";
    var resolved = await autoAddPhoneFromAxl(sepName);
    if (resolved) {
      var p = phonesMap[sepName.toLowerCase()];
      if (p) {
        el.targetIp.value = p.ip;
        el.username.value = p.username || "";
        el.password.value = p.password || "";
        currentPhoneSep = sepName.toLowerCase();
        document.getElementById("activePhoneName").textContent = sepName;
        document.getElementById("activePhoneIp").textContent = p.ip;
        document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\uD83D\uDCF1";
        setStatus("Phone automatically added: " + p.ip, true);
        addLog("Controlling " + sepName + " (" + p.ip + ")");
        var btnAr = document.getElementById("btnAutoRefresh");
        autoRefreshActive = true;
        btnAr.textContent = "Auto-refresh: ON";
        btnAr.classList.add("active-btn");
        screenshotFailCount = 0;
        refreshScreenshot();
      }
    }
  }
}

// ---- Send commands ----
async function sendCommand(payload, title) {
  if (!el.targetIp.value.trim()) {
    setStatus("Enter a target IP.", false);
    return;
  }
  // Pause auto-refresh during command (single-threaded server)
  var wasAutoRefresh = autoRefreshActive;
  autoRefreshActive = false;

  var body = { ip: el.targetIp.value.trim(), username: el.username.value, password: el.password.value };
  Object.keys(payload).forEach(function(k) { body[k] = payload[k]; });
  try {
    setStatus("Sending: " + title + "...", true);
    var res = await fetch("/api/execute", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
    setStatus("OK: " + title, true);
    addLog(title + " -> " + data.phoneResponseStatus);
    // Resume auto-refresh and refresh to see the effect
    autoRefreshActive = wasAutoRefresh;
    setTimeout(refreshScreenshot, 400);
  } catch (err) {
    setStatus("Error: " + err.message, false);
    addLog(title + " -> FAILED (" + err.message + ")");
    autoRefreshActive = wasAutoRefresh;
  }
}

// ---- Screenshot ----
function buildScreenshotUrl() {
  var ip = el.targetIp.value.trim();
  if (!ip) return null;
  return "/api/screenshot?ip=" + encodeURIComponent(ip)
    + "&username=" + encodeURIComponent(el.username.value)
    + "&password=" + encodeURIComponent(el.password.value)
    + "&_t=" + Date.now();
}

function refreshScreenshot() {
  var url = buildScreenshotUrl();
  if (!url) { setStatus("Enter a target IP for the screenshot.", false); return; }
  el.screenshotError.style.display = "none";
  el.screenshot.src = url;
}

function scheduleNextRefresh() {
  if (!autoRefreshActive) return;
  if (screenshotFailCount >= SCREENSHOT_MAX_FAILS) {
    autoRefreshActive = false;
    var btn = document.getElementById("btnAutoRefresh");
    btn.textContent = "Auto-refresh: OFF";
    btn.classList.remove("active-btn");
    el.screenshotError.textContent = "Auto-refresh stopped after " + SCREENSHOT_MAX_FAILS + " failures. Check IP/credentials.";
    el.screenshotError.style.display = "block";
    return;
  }
  var delay = screenshotFailCount > 0 ? Math.min(1000 + screenshotFailCount * 3000, 15000) : 1000;
  setTimeout(refreshScreenshot, delay);
}

el.screenshot.addEventListener("load", function() {
  el.screenshot.style.display = "block";
  el.screenshotError.style.display = "none";
  screenshotFailCount = 0;
  // Update status after phone comes back online post-reset
  if (provisioningPending && provisioningPending.sep === currentPhoneSep) {
    var pSep = provisioningPending.sep;
    var pIp  = provisioningPending.ip;
    provisioningPending = null;
    document.getElementById("activePhoneIp").textContent = pIp;
    setStatus("Phone back online: " + escHtml(pIp), true);
    addLog(pSep.toUpperCase() + " back online ("+pIp+")");
  }
  scheduleNextRefresh();
});

el.screenshot.addEventListener("error", function() {
  screenshotFailCount++;
  el.screenshot.style.display = "none";
  el.screenshotError.style.display = "block";
  el.screenshotError.textContent = "Screenshot error (" + screenshotFailCount + "/" + SCREENSHOT_MAX_FAILS + ") - check IP/credentials.";
  scheduleNextRefresh();
});

document.getElementById("btnScreenshot").addEventListener("click", function() {
  screenshotFailCount = 0;
  refreshScreenshot();
});
document.getElementById("btnRefreshNow").addEventListener("click", function() {
  screenshotFailCount = 0;
  refreshScreenshot();
});

document.getElementById("btnAutoRefresh").addEventListener("click", function() {
  autoRefreshActive = !autoRefreshActive;
  if (autoRefreshActive) {
    this.textContent = "Auto-refresh: ON";
    this.classList.add("active-btn");
    screenshotFailCount = 0;
    refreshScreenshot();
  } else {
    this.textContent = "Auto-refresh: OFF";
    this.classList.remove("active-btn");
  }
});

// ---- Commandes manuelles ----
document.getElementById("btnKey").addEventListener("click", function() {
  var v = el.keyInput.value.trim();
  sendCommand({ mode: "key", value: v }, "Key:" + v);
});

document.getElementById("btnDial").addEventListener("click", function() {
  var v = el.dialInput.value.trim();
  sendCommand({ mode: "dial", value: v }, "Dial:" + v);
});

document.getElementById("btnXml").addEventListener("click", function() {
  sendCommand({ mode: "xml", value: el.customXml.value }, "XML custom");
});

// ---- Key queue (2s debounce) ----
var keyQueue = [];
var keyFlushTimer = null;

function enqueueKey(key) {
  keyQueue.push(key);
  if (keyQueue.length > 1) {
    addLog("Queue: " + keyQueue.join(" → "));
  }
  if (keyFlushTimer) clearTimeout(keyFlushTimer);
  keyFlushTimer = setTimeout(flushKeyQueue, 2000);
}

async function flushKeyQueue() {
  keyFlushTimer = null;
  if (!keyQueue.length) return;
  var keys = keyQueue.slice();
  keyQueue = [];

  if (!el.targetIp.value.trim()) {
    setStatus("Enter a target IP.", false);
    return;
  }

  var wasAutoRefresh = autoRefreshActive;
  autoRefreshActive = false;

  for (var i = 0; i < keys.length; i++) {
    var key = keys[i];
    var body = {
      ip:       el.targetIp.value.trim(),
      username: el.username.value,
      password: el.password.value,
      mode:     "key",
      value:    key
    };
    try {
      if (keys.length > 1) {
        setStatus("Sending " + (i + 1) + "/" + keys.length + ": Key:" + key, true);
      } else {
        setStatus("Sending: Key:" + key + "...", true);
      }
      var res = await fetch("/api/execute", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      var data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
      addLog("Key:" + key + " -> " + data.phoneResponseStatus);
      // Inter-key pause so the phone processes each digit correctly
      if (i < keys.length - 1) {
        await new Promise(function(r) { setTimeout(r, 150); });
      }
    } catch (err) {
      setStatus("Error Key:" + key + ": " + err.message, false);
      addLog("Key:" + key + " -> FAILED (" + err.message + ")");
    }
  }

  if (keys.length > 1) {
    setStatus("OK: " + keys.length + " keys sent", true);
  } else {
    setStatus("OK: Key:" + keys[0], true);
  }

  autoRefreshActive = wasAutoRefresh;
  setTimeout(refreshScreenshot, 400);
}

// ---- Full keyboard ----
document.querySelectorAll("[data-key]").forEach(function(btn) {
  btn.addEventListener("click", function() {
    var key = btn.getAttribute("data-key");
    btn.style.opacity = "0.5";
    setTimeout(function() { btn.style.opacity = ""; }, 300);
    enqueueKey(key);
  });
});

// ---- Init ----
loadPhones();

// ================================================================
// ---- CUCM AXL ----
// ================================================================
function axlSetStatus(text, isOk) {
  var s = document.getElementById("axlStatus");
  s.textContent = text;
  s.className = "status " + (isOk === false ? "err" : "ok");
}

function axlGetCreds() {
  return {
    cucm:         document.getElementById("axlCucm").value.trim(),
    username:     document.getElementById("axlUser").value.trim(),
    password:     document.getElementById("axlPass").value.trim(),
    userId:       document.getElementById("axlCtrlUser").value.trim(),
    userType:     document.getElementById("axlUserType").value,
    axlVersion:   document.getElementById("axlVersion").value,
    phoneSshUser:  document.getElementById("axlPhoneSshUser").value.trim(),
    phoneSshPass:  document.getElementById("axlPhoneSshPass").value,
    phoneHttpUser: document.getElementById("axlPhoneHttpUser").value.trim(),
    phoneHttpPass: document.getElementById("axlPhoneHttpPass").value
  };
}

// Updates userId label based on selected type
document.getElementById("axlUserType").addEventListener("change", function() {
  var lbl = document.getElementById("axlCtrlUserLabel");
  lbl.textContent = this.value === "app" ? "Application User (userId)" : "End User (userId)";
});

// ---- Saved CUCM connections ----

async function loadCucmConnections() {
  try {
    var res = await fetch("/api/cucm-connections");
    var data = await res.json();
    var sel = document.getElementById("axlConnSelect");
    // Rebuild options without touching sel.value (avoids any browser change-event side effects)
    while (sel.options.length > 0) sel.remove(0);
    var def = document.createElement("option");
    def.value = ""; def.textContent = "— select —";
    sel.appendChild(def);
    data.forEach(function(c) {
      var opt = document.createElement("option");
      opt.value = c.name;
      opt.textContent = c.name;
      sel.appendChild(opt);
    });
    // Caller is responsible for setting sel.value after this returns
  } catch (e) { /* silent */ }
}

function fillFormFromConnection(conn) {
  document.getElementById("axlCucm").value        = conn.cucm          || "";
  document.getElementById("axlUser").value        = conn.username      || "";
  document.getElementById("axlPass").value        = conn.password      || "";
  document.getElementById("axlCtrlUser").value    = conn.userId        || "";
  document.getElementById("axlUserType").value    = conn.userType      || "app";
  document.getElementById("axlVersion").value     = conn.axlVersion    || "auto";
  document.getElementById("axlPhoneSshUser").value  = conn.phoneSshUser  || "";
  document.getElementById("axlPhoneSshPass").value  = conn.phoneSshPass  || "";
  document.getElementById("axlPhoneHttpUser").value = conn.phoneHttpUser || "";
  document.getElementById("axlPhoneHttpPass").value = conn.phoneHttpPass || "";
  document.getElementById("axlConnName").value    = conn.name          || "";
  // update userId label
  var lbl = document.getElementById("axlCtrlUserLabel");
  lbl.textContent = (conn.userType === "end") ? "End User (userId)" : "Application User (userId)";
}

document.getElementById("axlConnSelect").addEventListener("change", async function() {
  var name = this.value;
  if (!name) return;
  try {
    var res = await fetch("/api/cucm-connections");
    var data = await res.json();
    var conn = data.find(function(c) { return c.name === name; });
    if (conn) fillFormFromConnection(conn);
  } catch (e) { /* silent */ }
});

document.getElementById("btnConnSave").addEventListener("click", async function() {
  var creds = axlGetCreds();
  var name = document.getElementById("axlConnName").value.trim();
  if (!name) { setStatus("Enter a connection name.", false); return; }
  try {
    var res = await fetch("/api/cucm-connections", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name:          name,
        cucm:          creds.cucm,
        username:      creds.username,
        password:      creds.password,
        userId:        creds.userId,
        userType:      creds.userType,
        axlVersion:    creds.axlVersion,
        phoneSshUser:  creds.phoneSshUser,
        phoneSshPass:  creds.phoneSshPass,
        phoneHttpUser: creds.phoneHttpUser,
        phoneHttpPass: creds.phoneHttpPass
      })
    });
    var data = await res.json();
    if (!data.ok) throw new Error(data.error);
    await loadCucmConnections();
    document.getElementById("axlConnSelect").value = name;
    document.getElementById("axlConnName").value = "";  // vider pour éviter un écrasement accidentel
    document.getElementById("axlStatus").textContent = "✅ Connection \"" + escHtml(name) + "\" saved.";
    document.getElementById("axlStatus").style.color = "var(--success)";
  } catch (e) {
    document.getElementById("axlStatus").textContent = "Error: " + e.message;
    document.getElementById("axlStatus").style.color = "var(--error)";
  }
});

document.getElementById("btnConnDelete").addEventListener("click", async function() {
  var name = document.getElementById("axlConnSelect").value;
  if (!name) return;
  if (!confirm("Delete connection \"" + name + "\"?")) return;
  try {
    var res = await fetch("/api/cucm-connections", {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name: name })
    });
    var data = await res.json();
    if (!data.ok) throw new Error(data.error);
    await loadCucmConnections();
    document.getElementById("axlConnSelect").value = "";
    document.getElementById("axlConnName").value = "";
    document.getElementById("axlStatus").textContent = "🗑 Connection \"" + escHtml(name) + "\" deleted.";
    document.getElementById("axlStatus").style.color = "var(--muted)";
  } catch (e) {
    document.getElementById("axlStatus").textContent = "Error: " + e.message;
    document.getElementById("axlStatus").style.color = "var(--error)";
  }
});

// Load saved connections on startup
loadCucmConnections();

async function axlDetectVersion(creds) {
  var res = await fetch("/api/axl/version", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ cucm: creds.cucm, username: creds.username, password: creds.password })
  });
  var data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
  var sel = document.getElementById("axlVersion");
  if (!sel.querySelector("option[value='" + data.axlVersion + "']")) {
    var opt = document.createElement("option");
    opt.value = data.axlVersion;
    opt.textContent = data.axlVersion;
    sel.appendChild(opt);
  }
  sel.value = data.axlVersion;
  axlSetStatus("CUCM " + data.cucmVersion + " -> AXL " + data.axlVersion, true);
  return data.axlVersion;
}

var axlAllPhones = [];

async function axlListPhones() {
  var creds = axlGetCreds();
  if (!creds.cucm) { axlSetStatus("Enter the CUCM IP/FQDN.", false); return; }

  axlSetStatus("Connecting to AXL...", true);
  document.getElementById("btnAxlList").disabled = true;

  try {
    if (creds.axlVersion === "auto") {
      axlSetStatus("Detecting CUCM version...", true);
      creds.axlVersion = await axlDetectVersion(creds);
    }
    var res = await fetch("/api/axl/phones", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ cucm: creds.cucm, username: creds.username, password: creds.password, axlVersion: creds.axlVersion })
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);

    var rawPhones = data.phones;
    axlAllPhones = Array.isArray(rawPhones) ? rawPhones : (rawPhones ? [rawPhones] : []);
    axlApplyFilters(creds);
    axlSetStatus(axlAllPhones.length + " phone(s) found.", true);
  } catch (err) {
    axlSetStatus("Error: " + err.message, false);
  } finally {
    document.getElementById("btnAxlList").disabled = false;
  }
}

function axlApplyFilters(creds) {
  var sepOnly  = document.getElementById("axlFilterSep").checked;
  var searches = Array.from(document.querySelectorAll(".axl-search")).map(function(i) {
    return i.value.trim().toLowerCase();
  });

  var filtered = axlAllPhones.filter(function(p) {
    if (sepOnly && !/^SEP/i.test(p.name)) return false;
    var cols = [p.name, p.description, p.model, p.devicePool, p.ip];
    for (var i = 0; i < searches.length; i++) {
      if (searches[i] && !(cols[i] || "").toLowerCase().includes(searches[i])) return false;
    }
    return true;
  });

  axlRenderTable(filtered, creds || axlGetCreds());
  document.getElementById("axlCount").textContent = filtered.length + " / " + axlAllPhones.length;
}

function axlRenderTable(phones, creds) {
  var tbody = document.getElementById("axlTableBody");
  if (!phones.length) {
    tbody.innerHTML = '<tr><td colspan="7" class="axl-empty">No phones found.</td></tr>';
    return;
  }
  tbody.innerHTML = phones.map(function(p) {
    var st = p.status || "";
    var badge = st === "Registered"
      ? '<span class="axl-badge axl-badge-reg">REG</span>'
      : (st ? '<span class="axl-badge axl-badge-unreg">UNREG</span>'
             : '<span class="axl-badge axl-badge-unknown">—</span>');
    return '<tr>' +
      '<td class="axl-mono">' + escHtml(p.name) + '</td>' +
      '<td>' + escHtml(p.description || "—") + '</td>' +
      '<td>' + escHtml(p.model || "—") + '</td>' +
      '<td>' + escHtml(p.devicePool || "—") + '</td>' +
      '<td class="axl-mono">' + escHtml(p.ip || "—") + '</td>' +
      '<td>' + badge + '</td>' +
      '<td><button class="btn-control" data-device="' + escHtml(p.name) + '">🎮 Control</button></td>' +
      '</tr>';
  }).join("");

  tbody.querySelectorAll(".btn-control").forEach(function(btn) {
    btn.addEventListener("click", function() {
      axlProvisionAndControl(btn.dataset.device);
    });
  });
}

async function axlAssignPhone(deviceName, btn) {
  var creds = axlGetCreds();
  if (!creds.userId) { axlSetStatus("Enter the target user name.", false); return; }

  btn.disabled = true;
  btn.textContent = "...";
  axlSetStatus("Assigning " + deviceName + " to " + creds.userId + "...", true);

  try {
    var res = await fetch("/api/axl/assign", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        cucm:       creds.cucm,
        username:   creds.username,
        password:   creds.password,
        userId:     creds.userId,
        userType:   creds.userType,
        deviceName: deviceName,
        axlVersion: creds.axlVersion
      })
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
    btn.textContent = "\u2713 Assigned";
    btn.classList.add("btn-assigned");
    axlSetStatus(deviceName + " assigned to " + creds.userId + ".", true);
  } catch (err) {
    btn.disabled = false;
    btn.textContent = "Control";
    axlSetStatus("Error: " + err.message, false);
  }
}

function escHtml(str) {
  return String(str).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;");
}

// ---- SSH ----
function getSshCredsForCurrentPhone() {
  // 1. Look up by current SEP (most reliable)
  if (currentPhoneSep && phonesMap[currentPhoneSep]) return phonesMap[currentPhoneSep];
  // 2. Look up by IP (fallback for manual selection)
  var ip = el.targetIp.value.trim();
  for (var key in phonesMap) {
    if (phonesMap[key].ip === ip) return phonesMap[key];
  }
  return null;
}

async function runSshCommand(command) {
  var ip = el.targetIp.value.trim();
  if (!ip) { el.sshOutput.textContent = "Enter a target IP."; return; }

  var phone = getSshCredsForCurrentPhone();
  if (!phone || !phone.sshUser || !phone.consoleUser) {
    el.sshOutput.textContent = "SSH credentials not configured in phones.json (sshUser/sshPass/consoleUser/consolePass required).";
    return;
  }

  var btnSsh = document.getElementById("btnSsh");
  btnSsh.disabled = true;
  el.sshOutput.textContent = "Running...";

  // Pause auto-refresh during SSH (single-threaded server)
  var wasAutoRefresh = autoRefreshActive;
  autoRefreshActive = false;

  try {
    var res = await fetch("/api/phone/ssh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ip:          ip,
        sshUser:     phone.sshUser,
        sshPass:     phone.sshPass,
        sshHostKey:  phone.sshHostKey || "",
        consoleUser: phone.consoleUser,
        consolePass: phone.consolePass,
        command:     command
      })
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
    el.sshOutput.textContent = data.output || "(no output)";
    addLog("SSH: " + command);
  } catch (err) {
    el.sshOutput.textContent = "Error: " + err.message;
    addLog("SSH: " + command + " -> FAILED (" + err.message + ")");
  } finally {
    btnSsh.disabled = false;
    if (wasAutoRefresh) {
      autoRefreshActive = true;
      refreshScreenshot();
    }
  }
}

document.getElementById("btnSsh").addEventListener("click", function() {
  var cmd = el.sshCommand.value.trim();
  if (cmd) runSshCommand(cmd);
});

el.sshCommand.addEventListener("keydown", function(e) {
  if (e.key === "Enter") { e.preventDefault(); var cmd = el.sshCommand.value.trim(); if (cmd) runSshCommand(cmd); }
});

document.querySelectorAll(".btn-ssh-preset").forEach(function(btn) {
  btn.addEventListener("click", function() {
    el.sshCommand.value = btn.dataset.cmd;
    runSshCommand(btn.dataset.cmd);
  });
});

document.getElementById("btnAxlList").addEventListener("click", axlListPhones);
document.getElementById("axlFilterSep").addEventListener("change", function() { axlApplyFilters(); });
document.querySelectorAll(".axl-search").forEach(function(inp) {
  inp.addEventListener("input", function() { axlApplyFilters(); });
});

// ================================================================
// ---- Provisioning + control from AXL table ----
// ================================================================
async function axlProvisionAndControl(sepName) {
  var axlCreds = axlGetCreds();
  if (!axlCreds.cucm || !axlCreds.username) {
    setStatus(escHtml(sepName) + ": AXL credentials required for provisioning.", false);
    return;
  }

  // Switch to Controller tab
  document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
  document.querySelectorAll(".tab-pane").forEach(function(p) { p.classList.remove("active"); });
  document.querySelector('.tab-btn[data-tab="tab-controller"]').classList.add("active");
  document.getElementById("tab-controller").classList.add("active");
  document.getElementById("activePhoneName").textContent = sepName;
  document.getElementById("activePhoneIp").textContent = "Provisioning\u2026";
  document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u23F3";

  try {
    if (axlCreds.axlVersion === "auto") {
      axlCreds.axlVersion = await axlDetectVersion(axlCreds);
    }

    // Step 1: resolve IP BEFORE reset (phone still registered)
    var ip = null;
    var description = "";
    var existingPhone = phonesMap[sepName.toLowerCase()];
    if (existingPhone && existingPhone.ip) {
      ip = existingPhone.ip;
      description = existingPhone.description || "";
    } else {
      setStatus("Resolving IP for " + escHtml(sepName) + "\u2026", true);
      var ipRes = await fetch("/api/axl/phoneip", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ cucm: axlCreds.cucm, username: axlCreds.username, password: axlCreds.password, axlVersion: axlCreds.axlVersion, sep: sepName })
      });
      var ipData = await ipRes.json();
      if (ipData.ok && ipData.ip) {
        ip = ipData.ip;
        description = ipData.description || "";
      } else if (ipData.notRegistered) {
        var manualIp = window.prompt("Phone " + sepName + " not registered on CUCM.\nEnter the IP address manually:", "");
        if (manualIp && manualIp.trim()) { ip = manualIp.trim(); }
      } else {
        throw new Error(ipData.error || "Erreur résolution IP");
      }
    }

    // Step 2: provision (assign + webAccess + SSH + reset)
    setStatus("Provisioning " + escHtml(sepName) + " on CUCM\u2026", true);
    var provRes = await fetch("/api/axl/provision", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        cucm: axlCreds.cucm, username: axlCreds.username, password: axlCreds.password,
        axlVersion: axlCreds.axlVersion, deviceName: sepName,
        userId: axlCreds.userId, userType: axlCreds.userType,
        phoneSshUser: axlCreds.phoneSshUser, phoneSshPass: axlCreds.phoneSshPass
      })
    });
    var provData = await provRes.json();
    if (!provRes.ok || !provData.ok) throw new Error(provData.error || "Provision HTTP " + provRes.status);
    addLog(sepName + " provisioned: " + (provData.steps || []).join(" | "));

    // Step 3: add to phones.json if phone not yet known
    if (ip && !existingPhone) {
      var refPhone = Object.values(phonesMap)[0] || {};
      var addRes = await fetch("/api/phones/add", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sep: sepName, ip: ip, name: description || sepName, description: description,
          username: axlCreds.phoneHttpUser || refPhone.username || "post", password: axlCreds.phoneHttpPass || refPhone.password || "",
          sshUser: axlCreds.phoneSshUser || "", sshPass: axlCreds.phoneSshPass || "",
          sshHostKey: "", consoleUser: refPhone.consoleUser || "", consolePass: refPhone.consolePass || ""
        })
      });
      var addData = await addRes.json();
      if (!addRes.ok || !addData.ok) throw new Error(addData.error || "Erreur ajout phones.json");
    }
    await loadPhones();

    if (!ip) {
      setStatus(escHtml(sepName) + " provisioned (IP unknown - reset in progress).", true);
      document.getElementById("activePhoneIp").textContent = "IP unknown";
      document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u2753";
      return;
    }

    // Step 4: switch controller
    var ctrlPhone = phonesMap[sepName.toLowerCase()] || existingPhone || {};
    el.targetIp.value = ip;
    el.username.value = ctrlPhone.username || "post";
    el.password.value = ctrlPhone.password || "";
    currentPhoneSep = sepName.toLowerCase();
    document.getElementById("activePhoneName").textContent = sepName;
    document.getElementById("activePhoneIp").textContent = ip + " (resetting\u2026)";
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\uD83D\uDCF1";
    setStatus(escHtml(sepName) + " provisioned - reset in progress (~90s). IP: " + escHtml(ip), true);
    addLog(sepName + " ready: " + ip + " (reset sent, screenshot auto in ~90s)");
    provisioningPending = { sep: sepName.toLowerCase(), ip: ip };
    screenshotFailCount = 0;
    var arBtn = document.getElementById("btnAutoRefresh");
    autoRefreshActive = true;
    arBtn.textContent = "Auto-refresh: ON";
    arBtn.classList.add("active-btn");
    refreshScreenshot();
  } catch (err) {
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u2757";
    setStatus(escHtml(sepName) + ": provisioning failed - " + escHtml(err.message), false);
    addLog(sepName + ": provisioning failed (" + err.message + ")");
  }
}

// ================================================================
// ---- Résolution automatique AXL pour téléphones inconnus ----
// ================================================================
async function autoAddPhoneFromAxl(sepName) {
  var axlCreds = axlGetCreds();
  if (!axlCreds.cucm || !axlCreds.username) {
    setStatus(escHtml(sepName) + " : non trouvé dans phones.json. Renseigne les credentials AXL pour la résolution automatique.", false);
    addLog(sepName + " : résolution auto impossible (credentials AXL absents)");
    return false;
  }

  setStatus("Résolution de " + escHtml(sepName) + " via AXL\u2026", true);
  try {
    // Etape 1 : résoudre l'IP AVANT provision/reset
    var ipRes = await fetch("/api/axl/phoneip", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        cucm:       axlCreds.cucm,
        username:   axlCreds.username,
        password:   axlCreds.password,
        axlVersion: axlCreds.axlVersion,
        sep:        sepName
      })
    });
    var ipData = await ipRes.json();
    if (!ipRes.ok) throw new Error(ipData.error || "HTTP " + ipRes.status);
    if (!ipData.ok && ipData.notRegistered) {
      var manualIp = window.prompt(
        "Téléphone " + sepName + " non enregistré sur CUCM (hors ligne ou IP inconnue).\nEntrez l'adresse IP manuellement :",
        ""
      );
      if (!manualIp || !manualIp.trim()) {
        setStatus(escHtml(sepName) + " : ajout annulé (IP non fournie).", false);
        document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u2753";
        return false;
      }
      ipData = { ok: true, ip: manualIp.trim(), description: ipData.description || "", sep: sepName, axlVersion: ipData.axlVersion };
    } else if (!ipData.ok) {
      throw new Error(ipData.error || "Erreur inconnue");
    }

    // Reprendre les creds HTTP du premier téléphone connu comme valeurs par défaut
    var existingPhone = Object.values(phonesMap)[0] || {};
    var addRes = await fetch("/api/phones/add", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        sep:         sepName,
        ip:          ipData.ip,
        name:        ipData.description || sepName,
        description: ipData.description || "",
        username:    axlCreds.phoneHttpUser || existingPhone.username || "admin",
        password:    axlCreds.phoneHttpPass || existingPhone.password || "",
        sshUser:     axlCreds.phoneSshUser || existingPhone.sshUser || "",
        sshPass:     axlCreds.phoneSshPass || existingPhone.sshPass || "",
        sshHostKey:  "",
        consoleUser: existingPhone.consoleUser || "",
        consolePass: existingPhone.consolePass || ""
      })
    });
    var addData = await addRes.json();
    if (!addRes.ok || !addData.ok) throw new Error(addData.error || "Erreur ajout phones.json");

    phonesMap[sepName.toLowerCase()] = addData.phone;
    await loadPhones();
    addLog(sepName + " résolu automatiquement : " + ipData.ip);
    return true;
  } catch (err) {
    document.getElementById("activePhoneBar").querySelector(".active-phone-icon").textContent = "\u2753";
    setStatus(escHtml(sepName) + " : résolution AXL échouée — " + escHtml(err.message), false);
    addLog(sepName + " : résolution auto échouée (" + err.message + ")");
    return false;
  }
}
