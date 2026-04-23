// ---- DOM References (minimal) ----
const el = {
  phoneList: document.getElementById("phoneList"),
  log:       document.getElementById("log")
};

// ---- Map SEP name -> phone config (from phones.json) ----
var phonesMap = {};
var SCREENSHOT_MAX_FAILS = 15;

// ---- Shared log ----
function addLog(message) {
  var logEl = document.getElementById("log");
  if (!logEl) return;
  var stamp = new Date().toLocaleTimeString();
  logEl.textContent = "[" + stamp + "] " + message + "\n" + logEl.textContent;
}

// ---- Tabs ----
document.querySelectorAll(".tab-btn").forEach(function(btn) {
  btn.addEventListener("click", function() {
    document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
    document.querySelectorAll(".tab-pane").forEach(function(p) { p.classList.remove("active"); });
    btn.classList.add("active");
    document.getElementById(btn.dataset.tab).classList.add("active");
  });
});

// ---- Splitter (AXL tab only) ----
function initSplitter(splitterId, leftId, rightId, defaultFraction) {
  var splitter = document.getElementById(splitterId);
  var leftEl   = document.getElementById(leftId);
  var rightEl  = document.getElementById(rightId);
  if (!splitter || !leftEl || !rightEl) return;
  var frac = (defaultFraction != null) ? defaultFraction : null;
  if (frac != null) {
    var parent = leftEl.parentElement;
    var containerW = parent ? parent.offsetWidth : 0;
    if (containerW > 0) {
      leftEl.style.width = Math.round(containerW * frac) + "px";
      leftEl.style.flexShrink = "0";
    }
  }
  var dragging = false, startX = 0, startW = 0;
  splitter.addEventListener("mousedown", function(e) {
    dragging = true; startX = e.clientX; startW = leftEl.offsetWidth;
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
initSplitter("splitterAxl", "axlSidebar", "axlPanel");

// ---- Backward compat stubs ----
function setStatus(text, isOk) { /* per-panel status now */ }
var provisioningPending = null;

// ================================================================
// ---- MULTI-PANEL PHONE CONTROLLER ----
// ================================================================

var panels = {};     // panelId -> panel state
var panelCount = 0;

function buildPanelHtml(id, phone) {
  var name = escHtml(phone.name || phone.sep || "?");
  var ip   = escHtml(phone.ip || "");
  return [
    '<div class="pp-header">',
      '<span class="pp-drag">⠿⠿</span>',
      '<span class="pp-name">' + name + '</span>',
      '<span class="pp-ip">' + ip + '</span>',
      '<span class="pp-dot pp-dot-off">●</span>',
      '<div class="pp-header-btns">',
        '<button class="pp-btn pp-btn-capture" title="Capture screenshot">📷</button>',
        '<button class="pp-btn pp-btn-ar" title="Auto-refresh">↺</button>',
        '<button class="pp-btn pp-btn-close" title="Close">✕</button>',
      '</div>',
    '</div>',
    '<div class="pp-status-bar"></div>',
    '<div class="pp-body">',
      '<div class="pp-screenshot-wrap">',
        '<img class="pp-screenshot" alt="" />',
        '<p class="pp-screenshot-msg">Click 📷 to capture.</p>',
      '</div>',
      '<div class="pp-softkeys">',
        '<button data-key="Soft1" class="kbtn ksoft">SK 1</button>',
        '<button data-key="Soft2" class="kbtn ksoft">SK 2</button>',
        '<button data-key="Soft3" class="kbtn ksoft">SK 3</button>',
        '<button data-key="Soft4" class="kbtn ksoft">SK 4</button>',
      '</div>',
      '<div class="pp-controls">',
        '<div class="pp-controls-top">',
          '<div class="pp-nav-grid">',
            '<span></span>',
            '<button data-key="NavUp"     class="kbtn knav">▲</button>',
            '<span></span>',
            '<button data-key="NavLeft"   class="kbtn knav">◀</button>',
            '<button data-key="NavSelect" class="kbtn knav ksel">OK</button>',
            '<button data-key="NavRight"  class="kbtn knav">▶</button>',
            '<span></span>',
            '<button data-key="NavDwn"    class="kbtn knav">▼</button>',
            '<span></span>',
          '</div>',
          '<div class="pp-keypad">',
            '<button data-key="1" class="kbtn knum">1</button>',
            '<button data-key="2" class="kbtn knum">2</button>',
            '<button data-key="3" class="kbtn knum">3</button>',
            '<button data-key="4" class="kbtn knum">4</button>',
            '<button data-key="5" class="kbtn knum">5</button>',
            '<button data-key="6" class="kbtn knum">6</button>',
            '<button data-key="7" class="kbtn knum">7</button>',
            '<button data-key="8" class="kbtn knum">8</button>',
            '<button data-key="9" class="kbtn knum">9</button>',
            '<button data-key="*" class="kbtn knum">*</button>',
            '<button data-key="0" class="kbtn knum">0</button>',
            '<button data-key="#" class="kbtn knum">#</button>',
          '</div>',
        '</div>',
        '<div class="pp-audio-call">',
          '<button data-key="Speaker" class="kbtn kaudio">🔊</button>',
          '<button data-key="Headset" class="kbtn kaudio">🎧</button>',
          '<button data-key="Mute"    class="kbtn kaudio">🔇</button>',
          '<button data-key="VolUp"   class="kbtn kaudio">Vol+</button>',
          '<button data-key="VolDwn"  class="kbtn kaudio">Vol−</button>',
          '<button data-key="Hangup"  class="kbtn kdanger">📵</button>',
          '<button data-key="Back"    class="kbtn kapp">⌫</button>',
        '</div>',
      '</div>',
      '<div class="pp-dial-row">',
        '<input class="pp-dial" type="text" placeholder="Dial a number\u2026" />',
        '<button class="pp-dial-btn btn-green">Call</button>',
      '</div>',
      '<div class="pp-ssh-section">',
        '<button class="pp-ssh-toggle">🔒 SSH</button>',
        '<div class="pp-ssh-body">',
          '<div class="pp-ssh-presets">',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show version">Version</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show config network">Network</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show status">Status</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show dhcp">DHCP</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show config security">Security</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show register">Register</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show config security">ITL</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="show call-history summary">Calls</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="erase ctl">Erase CTL</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="erase network configuration">Erase all network settings</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="erase all settings">Erase All settings</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="reset soft">Reset Soft</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="reset hard">Reset Hard</button>',
            '<button class="btn-ssh-preset pp-ssh-cmd" data-cmd="uptime">Uptime</button>',
          '</div>',
          '<div class="pp-ssh-cmd-row">',
            '<input class="pp-ssh-input" type="text" placeholder="Custom SSH command\u2026" />',
            '<button class="pp-ssh-run">Run</button>',
          '</div>',
          '<pre class="pp-ssh-output"></pre>',
        '</div>',
      '</div>',
      '<div class="pp-mini-log"></div>',
    '</div>',
    '<div class="pp-resize-handle" title="Resize"></div>'
  ].join("");
}

function focusPanel(id) {
  Object.keys(panels).forEach(function(pid) {
    panels[pid].dom.panel.classList.remove("pp-focused");
  });
  if (panels[id]) panels[id].dom.panel.classList.add("pp-focused");
}

function setPanelStatus(id, text, isOk) {
  var st = panels[id]; if (!st) return;
  st.dom.status.textContent = text;
  st.dom.status.className = "pp-status-bar" +
    (isOk === false ? " pp-status-err" : (isOk === true ? " pp-status-ok" : ""));
  st.dom.dot.className = "pp-dot " +
    (isOk === false ? "pp-dot-err" : (isOk === true ? "pp-dot-ok" : "pp-dot-off"));
}

function addPanelLog(id, message) {
  var st = panels[id]; if (!st) return;
  var stamp = new Date().toLocaleTimeString();
  st.dom.miniLog.textContent = "[" + stamp + "] " + message + "\n" + st.dom.miniLog.textContent;
  addLog((st.phone.name || id) + ": " + message);
}

function refreshPanelScreenshot(id) {
  var st = panels[id]; if (!st) return;
  var phone = st.phone;
  var url = "/api/screenshot?ip=" + encodeURIComponent(phone.ip)
    + "&username=" + encodeURIComponent(phone.username || "")
    + "&password=" + encodeURIComponent(phone.password || "")
    + "&_t=" + Date.now();
  st.dom.msg.style.display = "none";
  st.dom.img.src = url;
}

function scheduleRefresh(id) {
  var st = panels[id]; if (!st || !st.autoRefresh) return;
  if (st.failCount >= SCREENSHOT_MAX_FAILS) {
    st.autoRefresh = false;
    st.dom.btnAr.classList.remove("pp-ar-on");
    setPanelStatus(id, "Auto-refresh stopped — check credentials.", false);
    return;
  }
  var delay = st.failCount > 0 ? Math.min(1000 + st.failCount * 3000, 15000) : 1000;
  st.refreshTimer = setTimeout(function() { refreshPanelScreenshot(id); }, delay);
}

function setPanelAutoRefresh(id, active) {
  var st = panels[id]; if (!st) return;
  if (st.refreshTimer) { clearTimeout(st.refreshTimer); st.refreshTimer = null; }
  st.autoRefresh = active;
  st.dom.btnAr.classList.toggle("pp-ar-on", active);
  st.dom.btnAr.title = active ? "Auto-refresh: ON (click to stop)" : "Auto-refresh: OFF";
  if (active) { st.failCount = 0; refreshPanelScreenshot(id); }
}

async function sendPanelCommand(id, payload, title) {
  var st = panels[id]; if (!st) return;
  var phone = st.phone;
  var wasAr = st.autoRefresh;
  if (st.refreshTimer) { clearTimeout(st.refreshTimer); st.refreshTimer = null; }
  st.autoRefresh = false;
  var body = { ip: phone.ip, username: phone.username || "", password: phone.password || "" };
  Object.keys(payload).forEach(function(k) { body[k] = payload[k]; });
  try {
    setPanelStatus(id, "Sending: " + title + "\u2026");
    var res = await fetch("/api/execute", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
    setPanelStatus(id, "OK: " + title, true);
    addPanelLog(id, title + " \u2192 " + data.phoneResponseStatus);
    st.autoRefresh = wasAr;
    setTimeout(function() { refreshPanelScreenshot(id); }, 400);
  } catch (err) {
    setPanelStatus(id, "Error: " + err.message, false);
    addPanelLog(id, title + " \u2192 FAILED (" + err.message + ")");
    st.autoRefresh = wasAr;
  }
}

async function enqueuePanelKey(id, key) {
  var st = panels[id]; if (!st) return;
  st.keyQueue = st.keyQueue || [];
  st.keyQueue.push(key);
  if (st.keyQueue.length > 1) addPanelLog(id, "Queue: " + st.keyQueue.join(" \u2192 "));
  if (st.keyTimer) clearTimeout(st.keyTimer);
  st.keyTimer = setTimeout(function() { flushPanelKeys(id); }, 2000);
}

async function flushPanelKeys(id) {
  var st = panels[id]; if (!st) return;
  st.keyTimer = null;
  if (!st.keyQueue || !st.keyQueue.length) return;
  var keys = st.keyQueue.slice();
  st.keyQueue = [];
  var phone = st.phone;
  var wasAr = st.autoRefresh;
  if (st.refreshTimer) { clearTimeout(st.refreshTimer); st.refreshTimer = null; }
  st.autoRefresh = false;
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i];
    var body = { ip: phone.ip, username: phone.username || "", password: phone.password || "", mode: "key", value: key };
    try {
      setPanelStatus(id, keys.length > 1 ? "Key " + (i+1) + "/" + keys.length + ": " + key : "Key: " + key);
      var res = await fetch("/api/execute", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body)
      });
      var data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
      addPanelLog(id, "Key:" + key + " \u2192 " + data.phoneResponseStatus);
      if (i < keys.length - 1) await new Promise(function(r) { setTimeout(r, 150); });
    } catch (err) {
      setPanelStatus(id, "Error Key:" + key + ": " + err.message, false);
      addPanelLog(id, "Key:" + key + " \u2192 FAILED (" + err.message + ")");
    }
  }
  setPanelStatus(id, keys.length > 1 ? "OK: " + keys.length + " keys sent" : "OK: Key:" + keys[0], true);
  st.autoRefresh = wasAr;
  setTimeout(function() { refreshPanelScreenshot(id); }, 400);
}

async function runPanelSsh(id, command) {
  var st = panels[id]; if (!st) return;
  var phone = st.phone;
  var sshOut = st.dom.sshOut;
  if (!sshOut) return;
  if (!phone.sshUser || !phone.consoleUser) {
    sshOut.textContent = "SSH credentials not configured (sshUser/sshPass/consoleUser/consolePass required).";
    return;
  }
  var wasAr = st.autoRefresh;
  st.autoRefresh = false;
  sshOut.textContent = "Running\u2026";
  try {
    var res = await fetch("/api/phone/ssh", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ip:          phone.ip,
        sshUser:     phone.sshUser || "",
        sshPass:     phone.sshPass || "",
        sshHostKey:  phone.sshHostKey || "",
        consoleUser: phone.consoleUser || "",
        consolePass: phone.consolePass || "",
        command:     command
      })
    });
    var data = await res.json();
    if (!res.ok || !data.ok) throw new Error(data.error || "HTTP " + res.status);
    sshOut.textContent = data.output || "(no output)";
    addPanelLog(id, "SSH: " + command);
  } catch (err) {
    sshOut.textContent = "Error: " + err.message;
    addPanelLog(id, "SSH: " + command + " \u2192 FAILED");
  } finally {
    st.autoRefresh = wasAr;
    if (wasAr) setTimeout(function() { refreshPanelScreenshot(id); }, 400);
  }
}

function setupPanelDrag(panel) {
  var header = panel.querySelector(".pp-header");
  var dragging = false, ox = 0, oy = 0;
  header.addEventListener("mousedown", function(e) {
    if (e.target.closest("button")) return;
    dragging = true;
    ox = e.clientX - panel.offsetLeft;
    oy = e.clientY - panel.offsetTop;
    document.body.style.userSelect = "none";
    focusPanel(panel.id);
    e.preventDefault();
  });
  document.addEventListener("mousemove", function(e) {
    if (!dragging) return;
    var ws = document.getElementById("panelWorkspace");
    var wsR = ws.getBoundingClientRect();
    var nx = e.clientX - ox - wsR.left + ws.scrollLeft;
    var ny = e.clientY - oy - wsR.top  + ws.scrollTop;
    panel.style.left = Math.max(0, nx) + "px";
    panel.style.top  = Math.max(0, ny) + "px";
  });
  document.addEventListener("mouseup", function() {
    if (!dragging) return;
    dragging = false;
    document.body.style.userSelect = "";
  });
}

function setupPanelResize(panel) {
  var handle = panel.querySelector(".pp-resize-handle");
  var resizing = false, sx = 0, sy = 0, sw = 0, sh = 0;
  handle.addEventListener("mousedown", function(e) {
    resizing = true;
    sx = e.clientX; sy = e.clientY;
    sw = panel.offsetWidth; sh = panel.offsetHeight;
    document.body.style.userSelect = "none";
    e.preventDefault();
    e.stopPropagation();
  });
  document.addEventListener("mousemove", function(e) {
    if (!resizing) return;
    panel.style.width  = Math.max(310, sw + (e.clientX - sx)) + "px";
    panel.style.height = Math.max(400, sh + (e.clientY - sy)) + "px";
  });
  document.addEventListener("mouseup", function() {
    if (!resizing) return;
    resizing = false;
    document.body.style.userSelect = "";
  });
}

function createPhonePanel(phone) {
  for (var pid in panels) {
    if (panels[pid].phone.ip === phone.ip) {
      focusPanel(pid);
      setPanelStatus(pid, "Already open.", true);
      return pid;
    }
  }
  var id = "pp" + (++panelCount);
  var st = {
    id: id, phone: phone,
    autoRefresh: false, failCount: 0,
    keyQueue: [], keyTimer: null, refreshTimer: null,
    dom: {}
  };
  panels[id] = st;

  var ws = document.getElementById("panelWorkspace");
  var offset = Object.keys(panels).length - 1;
  var col = offset % 4, row = Math.floor(offset / 4);
  var panel = document.createElement("div");
  panel.className = "phone-panel";
  panel.id = id;
  panel.style.left = (20 + col * 30) + "px";
  panel.style.top  = (20 + row * 30) + "px";
  panel.innerHTML = buildPanelHtml(id, phone);
  ws.appendChild(panel);
  document.getElementById("workspaceEmpty").style.display = "none";

  st.dom = {
    panel:      panel,
    status:     panel.querySelector(".pp-status-bar"),
    dot:        panel.querySelector(".pp-dot"),
    img:        panel.querySelector(".pp-screenshot"),
    msg:        panel.querySelector(".pp-screenshot-msg"),
    btnCapture: panel.querySelector(".pp-btn-capture"),
    btnAr:      panel.querySelector(".pp-btn-ar"),
    btnClose:   panel.querySelector(".pp-btn-close"),
    dialInput:  panel.querySelector(".pp-dial"),
    sshOut:     panel.querySelector(".pp-ssh-output"),
    sshBody:    panel.querySelector(".pp-ssh-body"),
    sshToggle:  panel.querySelector(".pp-ssh-toggle"),
    sshInput:   panel.querySelector(".pp-ssh-input"),
    miniLog:    panel.querySelector(".pp-mini-log")
  };

  setupPanelDrag(panel);
  setupPanelResize(panel);

  st.dom.img.addEventListener("load", function() {
    st.dom.img.style.display = "block";
    st.dom.msg.style.display = "none";
    st.failCount = 0;
    setPanelStatus(id, "Screenshot OK", true);
    scheduleRefresh(id);
  });
  st.dom.img.addEventListener("error", function() {
    st.failCount++;
    st.dom.img.style.display = "none";
    st.dom.msg.style.display = "";
    st.dom.msg.textContent = "Error (" + st.failCount + "/" + SCREENSHOT_MAX_FAILS + ")";
    setPanelStatus(id, "Screenshot error (" + st.failCount + "/" + SCREENSHOT_MAX_FAILS + ")", false);
    scheduleRefresh(id);
  });

  st.dom.btnCapture.addEventListener("click", function() {
    st.failCount = 0; refreshPanelScreenshot(id);
  });
  st.dom.btnAr.addEventListener("click", function() {
    setPanelAutoRefresh(id, !st.autoRefresh);
  });
  st.dom.btnClose.addEventListener("click", function() {
    setPanelAutoRefresh(id, false);
    if (st.keyTimer) clearTimeout(st.keyTimer);
    panel.remove();
    delete panels[id];
    if (Object.keys(panels).length === 0) {
      document.getElementById("workspaceEmpty").style.display = "";
    }
  });

  panel.addEventListener("mousedown", function() { focusPanel(id); });

  panel.addEventListener("click", function(e) {
    var btn = e.target.closest("[data-key]");
    if (!btn || !btn.closest(".pp-body")) return;
    var key = btn.dataset.key;
    btn.style.opacity = "0.5";
    setTimeout(function() { btn.style.opacity = ""; }, 250);
    enqueuePanelKey(id, key);
  });

  st.dom.dialInput.addEventListener("keydown", function(e) {
    if (e.key === "Enter") {
      var v = st.dom.dialInput.value.trim();
      if (v) sendPanelCommand(id, { mode: "dial", value: v }, "Dial:" + v);
    }
  });
  panel.querySelector(".pp-dial-btn").addEventListener("click", function() {
    var v = st.dom.dialInput.value.trim();
    if (v) sendPanelCommand(id, { mode: "dial", value: v }, "Dial:" + v);
  });

  st.dom.sshToggle.addEventListener("click", function() {
    var open = st.dom.sshBody.style.display === "block";
    st.dom.sshBody.style.display = open ? "none" : "block";
  });
  panel.querySelectorAll(".pp-ssh-cmd").forEach(function(b) {
    b.addEventListener("click", function() { runPanelSsh(id, b.dataset.cmd); });
  });
  panel.querySelector(".pp-ssh-run").addEventListener("click", function() {
    var cmd = st.dom.sshInput.value.trim();
    if (cmd) runPanelSsh(id, cmd);
  });
  st.dom.sshInput.addEventListener("keydown", function(e) {
    if (e.key === "Enter") {
      var cmd = st.dom.sshInput.value.trim();
      if (cmd) runPanelSsh(id, cmd);
    }
  });

  focusPanel(id);
  setPanelAutoRefresh(id, true);
  return id;
}

function tilePanels() {
  var ws = document.getElementById("panelWorkspace");
  var wsW = ws.clientWidth, wsH = ws.clientHeight;
  var ids = Object.keys(panels);
  if (!ids.length) return;
  var n = ids.length;
  var cols = Math.ceil(Math.sqrt(n));
  var rows = Math.ceil(n / cols);
  var gap = 10;
  var pw = Math.max(310, Math.floor((wsW - gap * (cols + 1)) / cols));
  var ph = Math.max(400, Math.floor((wsH - gap * (rows + 1)) / rows));
  ids.forEach(function(id, i) {
    var col = i % cols, row = Math.floor(i / cols);
    var panel = panels[id].dom.panel;
    panel.style.left   = (gap + col * (pw + gap)) + "px";
    panel.style.top    = (gap + row * (ph + gap)) + "px";
    panel.style.width  = pw + "px";
    panel.style.height = ph + "px";
  });
}

// ---- Dock buttons ----
document.getElementById("btnAddPanel").addEventListener("click", function() {
  var sel = document.getElementById("phoneList");
  var opt = sel.options[sel.selectedIndex];
  if (!opt || !opt.value) return;
  var phone = phonesMap[(opt.dataset.sep || "").toLowerCase()] || {
    ip:       opt.value,
    name:     opt.textContent.split(" (")[0],
    sep:      opt.dataset.sep || "",
    username: opt.dataset.username || "",
    password: opt.dataset.password || ""
  };
  createPhonePanel(phone);
});

document.getElementById("btnTileAll").addEventListener("click", tilePanels);

document.getElementById("btnToggleLog").addEventListener("click", function() {
  var bar = document.getElementById("sharedLogBar");
  var visible = bar.style.display === "block";
  bar.style.display = visible ? "none" : "block";
});

// ---- Phone list loading ----
async function loadPhones() {
  try {
    var res = await fetch("/api/phones");
    if (!res.ok) throw new Error("HTTP " + res.status);
    var phones = await res.json();
    phonesMap = {};
    phones.forEach(function(p) { if (p.sep) phonesMap[p.sep.toLowerCase()] = p; });
    var sel = document.getElementById("phoneList");
    sel.innerHTML = "";
    var ph = document.createElement("option");
    ph.value = ""; ph.textContent = "Choose a phone\u2026";
    sel.appendChild(ph);
    phones.forEach(function(p) {
      var opt = document.createElement("option");
      opt.value = p.ip;
      opt.textContent = (p.name || p.sep || p.ip) + " (" + p.ip + ")";
      opt.dataset.username = p.username || "";
      opt.dataset.password = p.password || "";
      opt.dataset.sep = p.sep || "";
      sel.appendChild(opt);
    });
  } catch (err) {
    addLog("Failed to load phone list: " + err.message);
  }
}

async function refreshPhonesMap() {
  try {
    var res = await fetch("/api/phones?t=" + Date.now());
    if (!res.ok) return;
    var phones = await res.json();
    phonesMap = {};
    phones.forEach(function(p) { if (p.sep) phonesMap[p.sep.toLowerCase()] = p; });
  } catch (e) { /* silent */ }
}

// ---- Switch to Controller tab with an AXL phone (creates a panel) ----
async function switchToControllerWithPhone(sepName) {
  await refreshPhonesMap();
  var phone = phonesMap[sepName.toLowerCase()];
  document.querySelectorAll(".tab-btn").forEach(function(b) { b.classList.remove("active"); });
  document.querySelectorAll(".tab-pane").forEach(function(p) { p.classList.remove("active"); });
  document.querySelector('.tab-btn[data-tab="tab-controller"]').classList.add("active");
  document.getElementById("tab-controller").classList.add("active");

  if (phone) {
    var pid = createPhonePanel(phone);
    setPanelAutoRefresh(pid, true);
    addLog("Controlling " + sepName + " (" + phone.ip + ")");
  } else {
    addLog("Phone " + sepName + " unknown \u2014 resolving via AXL\u2026");
    var resolved = await autoAddPhoneFromAxl(sepName);
    if (resolved) {
      var p = phonesMap[sepName.toLowerCase()];
      if (p) {
        var pid2 = createPhonePanel(p);
        setPanelAutoRefresh(pid2, true);
        addLog("Controlling " + sepName + " (" + p.ip + ")");
      }
    }
  }
}

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
  addLog(sepName + " : provisioning en cours\u2026");

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
      addLog(sepName + " provisionné (IP inconnue, reset en cours)");
      return;
    }

    // Step 4: ouvrir un panneau de contrôle
    await refreshPhonesMap();
    var ctrlPhone = phonesMap[sepName.toLowerCase()] || existingPhone || { ip: ip, name: sepName, sep: sepName };
    ctrlPhone.ip = ctrlPhone.ip || ip;
    var pid = createPhonePanel(ctrlPhone);
    addLog(sepName + " prêt : " + ip + " (reset envoyé, auto-refresh dans ~90s)");
    // Démarrer l'auto-refresh (le téléphone revient en ligne après ~90s)
    setPanelAutoRefresh(pid, true);
  } catch (err) {
    addLog(sepName + " : provisioning échoué (" + err.message + ")");
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
        addLog(sepName + " : ajout annulé (IP non fournie).");
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
    addLog(sepName + " : résolution AXL échouée — " + err.message);
    return false;
  }
}
