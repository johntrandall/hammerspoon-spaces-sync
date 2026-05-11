--- === SpacesSync.settings_pane ===
---
--- hs.webview-hosted settings pane for SpacesSync. The HTML/CSS is a
--- thinned-down version of the mockup at
--- `dev-docs/diagrams/settings-pane-mockup.html`; JS drives interactivity
--- and posts changes to Lua via hs.webview.usercontent message handlers.
---
--- Autosave on every change — there is no Apply button. Every edit
--- live-commits to ~/.hammerspoon/SpacesSync.json via config.save +
--- applyConfig. The footer is just a single "Done" button.

local M = {}

-- Filled in by init.lua via loadSettingsModules().
M.logger = { d = function() end, i = function() end,
             w = function() end, e = function() end }

local webview = nil
local userContent = nil
local deps = nil  -- { config, logger, applyConfig, getStatus, getDisplayInventory }

local WINDOW_WIDTH = 600
local WINDOW_HEIGHT = 760
local MESSAGE_HANDLER = "spacessync"

-- ============================================================================
-- HTML / CSS / JS
-- ============================================================================

local function htmlEscape(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;")
  s = s:gsub("<", "&lt;")
  s = s:gsub(">", "&gt;")
  s = s:gsub('"', "&quot;")
  s = s:gsub("'", "&#39;")
  return s
end

-- Serialize a Lua value into a JS-safe JSON expression. Used to inject
-- the initial state into the HTML template.
local function jsJSON(v)
  if v == nil then return "null" end
  local kind = type(v)
  if kind == "boolean" then return v and "true" or "false" end
  if kind == "number" then
    if v ~= v then return "null" end  -- NaN
    return string.format("%.14g", v)
  end
  if kind == "string" then
    if hs and hs.json and hs.json.encode then
      return hs.json.encode(v)
    end
    -- Defensive: escape essentials.
    local esc = v:gsub("\\", "\\\\"):gsub('"', '\\"')
                 :gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return '"' .. esc .. '"'
  end
  if kind == "table" then
    if hs and hs.json and hs.json.encode then
      return hs.json.encode(v)
    end
    -- Fallback recursive encoder.
    local isArray = true
    local n = 0
    for k in pairs(v) do
      n = n + 1
      if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then isArray = false break end
    end
    if isArray and n == #v then
      local parts = {}
      for _, item in ipairs(v) do parts[#parts + 1] = jsJSON(item) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for k, val in pairs(v) do
      parts[#parts + 1] = jsJSON(tostring(k)) .. ":" .. jsJSON(val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

-- The page is one big template literal so we can inline the initial state
-- as a JS const without escaping headaches. Color tokens lifted from the
-- mockup; layout is the same vocabulary (Detected Displays, Group Labels,
-- Group Membership, Sync, Timing, Hotkeys).
local function buildHTML(initialState)
  local stateJSON = jsJSON(initialState)
  return [[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>SpacesSync</title>
<style>
:root {
  --bg-page: #1a1a1c;
  --panel-fill: rgba(30, 30, 32, 0.92);
  --panel-stroke: rgba(255, 255, 255, 0.10);
  --row-fill: rgba(255, 255, 255, 0.03);
  --text-primary: rgba(255, 255, 255, 1.0);
  --text-secondary: rgba(255, 255, 255, 0.72);
  --text-tertiary: rgba(255, 255, 255, 0.55);
  --accent-blue: rgb(10, 132, 255);
  --warn: #d4a853;
  --warn-bg: rgba(212, 168, 83, 0.12);
  --group-a: #4caf50;
  --group-b: #ce93d8;
  --group-c: #ffb74d;
  --group-d: #4dd0e1;
  --group-e: #ff8a65;
  --group-f: #ba68c8;
  --group-g: #81c784;
  --group-h: #ffd54f;
  --group-i: #4fc3f7;
  --group-j: #f06292;
}
html, body { margin: 0; padding: 0; background: var(--bg-page);
  color: var(--text-primary); font-family: -apple-system, BlinkMacSystemFont,
  "Helvetica Neue", sans-serif; -webkit-user-select: none; user-select: none; }
.pane { padding: 18px 22px 12px; }
h3 { font-size: 11px; font-weight: 600; color: var(--text-tertiary);
  margin: 22px 0 10px; letter-spacing: 0.06em; text-transform: uppercase; }
h3:first-child { margin-top: 0; }
.row { display: flex; align-items: center; justify-content: space-between;
  padding: 12px 16px; background: var(--row-fill); border-radius: 10px; gap: 16px; }
.row + .row { margin-top: 8px; }
.row .label { font-size: 14px; font-weight: 500; }
.row .sublabel { font-size: 12px; color: var(--text-secondary); margin-top: 2px; line-height: 1.4; }
.row.master { border: 1px solid rgba(10, 132, 255, 0.20); }
.switch { position: relative; width: 44px; height: 26px; border-radius: 13px;
  background: var(--accent-blue); transition: background 0.15s ease; flex-shrink: 0; cursor: pointer; }
.switch::after { content: ""; position: absolute; top: 2px; left: 20px; width: 22px; height: 22px;
  border-radius: 50%; background: white; box-shadow: 0 2px 4px rgba(0, 0, 0, 0.3); transition: left 0.15s ease; }
.switch.off { background: rgba(120, 120, 128, 0.32); }
.switch.off::after { left: 2px; }
.inset { background: var(--row-fill); border-radius: 10px; overflow: visible; }
.detected-row { display: grid; grid-template-columns: 100px 1fr; gap: 16px;
  padding: 10px 16px; border-bottom: 1px solid var(--panel-stroke); align-items: start; }
.detected-row:last-child { border-bottom: none; }
.detected-row .pos { font-size: 13px; color: var(--text-tertiary); text-align: right; padding-top: 1px; }
.detected-row .name { font-size: 13px; color: var(--text-primary); }
.detected-row .uuid { font-family: "SF Mono", Menlo, monospace; font-size: 10.5px; color: var(--text-tertiary); margin-top: 2px; }
.footnote { font-size: 11.5px; color: var(--text-secondary); margin: 6px 4px 0; line-height: 1.5; }
.section-hint { font-size: 11.5px; color: var(--text-tertiary); margin: -4px 4px 8px; }

/* Group Membership */
.group-row { display: grid; grid-template-columns: 100px 1fr auto; gap: 16px;
  padding: 10px 16px; border-bottom: 1px solid var(--panel-stroke); align-items: center; }
.group-row:last-child { border-bottom: none; }
.group-row .pos { font-size: 13px; color: var(--text-tertiary); text-align: right; }
.group-row .display-name { font-size: 13px; color: var(--text-secondary); }
.group-row.stale .display-name { font-style: italic; color: var(--text-tertiary); }
.group-row select { background: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.10);
  border-radius: 6px; font-size: 12.5px; color: var(--text-primary); padding: 5px 10px;
  font-family: inherit; min-width: 130px; -webkit-appearance: none; appearance: none;
  background-image: url('data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="10" height="6"><path d="M0 0l5 6 5-6z" fill="%23999"/></svg>');
  background-repeat: no-repeat; background-position: right 8px center; padding-right: 24px; }
.stale-warn { color: var(--warn); font-size: 12px; background: var(--warn-bg); padding: 4px 10px; border-radius: 6px; }

/* Group Labels */
.label-row { display: grid; grid-template-columns: 44px 1fr auto; gap: 14px;
  align-items: center; padding: 8px 16px; border-bottom: 1px solid var(--panel-stroke); }
.label-row:last-child { border-bottom: none; }
.label-row .letter { display: inline-flex; align-items: center; gap: 6px;
  font-family: "SF Mono", Menlo, monospace; font-size: 13px; font-weight: 600; }
.label-row .chip { width: 12px; height: 12px; border-radius: 3px; flex-shrink: 0; }
.label-row input.label-input { background: rgba(255, 255, 255, 0.05);
  border: 1px solid rgba(255, 255, 255, 0.16); border-radius: 5px;
  color: var(--text-primary); padding: 4px 8px; font-size: 12.5px; font-family: inherit;
  width: 100%; box-sizing: border-box; }
.label-row input.label-input:focus { outline: none; border-color: var(--accent-blue);
  background: rgba(10, 132, 255, 0.06); }
.label-row input.label-input::placeholder { color: var(--text-tertiary); font-style: italic; }
.label-row.dim { opacity: 0.55; }
.label-row .member-count { font-size: 11.5px; color: var(--text-tertiary);
  white-space: nowrap; text-align: right; min-width: 90px; }

.chip.a { background: var(--group-a); } .chip.b { background: var(--group-b); }
.chip.c { background: var(--group-c); } .chip.d { background: var(--group-d); }
.chip.e { background: var(--group-e); } .chip.f { background: var(--group-f); }
.chip.g { background: var(--group-g); } .chip.h { background: var(--group-h); }
.chip.i { background: var(--group-i); } .chip.j { background: var(--group-j); }
.chip.none { background: transparent; border: 1px dashed rgba(255, 255, 255, 0.32); }

/* Segmented control */
.segmented { display: inline-flex; background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 7px; padding: 2px; flex-shrink: 0; }
.segmented button { padding: 5px 12px; font-size: 12.5px; color: var(--text-secondary);
  background: transparent; border: none; border-radius: 5px; cursor: pointer; font-family: inherit; }
.segmented button.active { background: var(--accent-blue); color: white; box-shadow: 0 1px 3px rgba(0, 0, 0, 0.3); }

/* Sync Now button */
.btn-action { display: inline-flex; align-items: center; gap: 8px; white-space: nowrap;
  background: rgba(10, 132, 255, 0.16); border: 1px solid rgba(10, 132, 255, 0.36);
  color: var(--accent-blue); border-radius: 7px; padding: 6px 14px; font-size: 13px;
  font-weight: 500; cursor: pointer; font-family: inherit; }
.btn-action .kbd { color: var(--text-tertiary); font-family: "SF Mono", Menlo, monospace;
  font-size: 11px; margin-left: 4px; }

/* Timing fields */
.timing-grid { display: grid; grid-template-columns: 1fr 90px 30px;
  gap: 8px 14px; align-items: center; padding: 4px 4px; }
.timing-grid .timing-label { font-size: 13px; color: var(--text-secondary); }
.timing-grid input { background: rgba(255, 255, 255, 0.06); border: 1px solid rgba(255, 255, 255, 0.10);
  border-radius: 6px; color: var(--text-primary); padding: 5px 8px; font-size: 13px;
  font-family: "SF Mono", Menlo, monospace; text-align: right; width: 100%; box-sizing: border-box; }
.timing-grid .unit { font-size: 12px; color: var(--text-tertiary); }

/* Hotkeys */
.hotkey-row { display: grid; grid-template-columns: 1fr auto auto; gap: 14px;
  align-items: center; padding: 10px 16px; border-bottom: 1px solid var(--panel-stroke); }
.hotkey-row:last-child { border-bottom: none; }
.hotkey-row .label { font-size: 13px; color: var(--text-primary); }
.hotkey-row .sublabel { font-size: 11.5px; color: var(--text-secondary); margin-top: 1px; }
.kbd-cell { display: inline-flex; align-items: center; gap: 4px; padding: 5px 10px;
  min-width: 78px; justify-content: center; background: rgba(255, 255, 255, 0.06);
  border: 1px solid rgba(255, 255, 255, 0.14); border-radius: 6px;
  font-family: "SF Mono", Menlo, monospace; font-size: 12.5px; color: var(--text-primary);
  cursor: pointer; user-select: none; }
.kbd-cell:hover { border-color: rgba(10, 132, 255, 0.5); background: rgba(10, 132, 255, 0.06); }
.kbd-cell.recording { border-color: var(--accent-blue); background: rgba(10, 132, 255, 0.16);
  color: var(--accent-blue); font-style: italic; }
.kbd-reset { color: var(--text-tertiary); font-size: 11px; cursor: pointer;
  padding: 3px 6px; border-radius: 4px; }
.kbd-reset:hover { color: var(--text-secondary); background: rgba(255, 255, 255, 0.05); }

/* Env banner */
.env-banner { display: flex; gap: 12px; align-items: flex-start; padding: 12px 16px;
  background: rgba(212, 83, 83, 0.10); border: 1px solid rgba(212, 83, 83, 0.42);
  border-radius: 10px; margin-bottom: 16px; }
.env-banner .icon { color: #ef9a9a; font-size: 18px; line-height: 1.2; }
.env-banner .title { color: #ef9a9a; font-weight: 600; font-size: 13px; }
.env-banner .body-text { color: var(--text-secondary); font-size: 12px; margin-top: 3px; line-height: 1.5; }
.hide { display: none !important; }

/* Footer */
.footer { display: flex; justify-content: flex-end; gap: 10px; padding: 14px 22px 18px;
  border-top: 1px solid var(--panel-stroke); margin-top: 14px; }
.btn { padding: 7px 18px; border-radius: 7px; font-size: 13px; font-weight: 500;
  border: none; cursor: pointer; font-family: inherit; }
.btn.apply { background: var(--accent-blue); color: white; }
</style>
</head>
<body>
<div class="pane">

  <div id="env-banner" class="env-banner hide">
    <div class="icon">⚠</div>
    <div>
      <div class="title" id="env-banner-title"></div>
      <div class="body-text" id="env-banner-body"></div>
    </div>
  </div>

  <h3>General</h3>
  <div class="row master">
    <div>
      <div class="label">Enable SpacesSync</div>
      <div class="sublabel">Hotkeys, the popup, the picker, the status HUD, and sync.
        Disable to silence everything until you toggle back on.</div>
    </div>
    <div id="enabled-switch" class="switch"></div>
  </div>

  <h3>Detected Displays</h3>
  <div class="inset" id="detected-displays"></div>
  <div class="footnote">Groups are by position. Reordering displays in System Settings will reshuffle group membership.</div>

  <h3>Group Labels</h3>
  <div class="section-hint">Set an optional label per group. Labeled groups display as "Letter: Label";
    unlabeled groups fall back to "Group A", "Group B", and so on.</div>
  <div class="inset" id="group-labels"></div>

  <h3>Group Membership</h3>
  <div class="section-hint">Two or more displays in the same group sync together.
    Displays set to <em>— None</em> stay independent.</div>
  <div class="inset" id="group-membership"></div>

  <h3>Sync</h3>
  <div class="row">
    <div>
      <div class="label">Sync mode</div>
      <div class="sublabel"><strong>Automatic</strong> — sync every Space switch to the rest of the group.
        <strong>Manual</strong> — displays move freely; press <em>Sync Now</em> to bring them together.</div>
    </div>
    <div class="segmented" id="sync-mode">
      <button data-mode="automatic">Automatic</button>
      <button data-mode="manual">Manual</button>
    </div>
  </div>
  <div class="row">
    <div>
      <div class="label">Sync Now</div>
      <div class="sublabel">Switch the cursor display's group to the cursor display's current Space.
        Works in either Sync mode.</div>
    </div>
    <button class="btn-action" id="sync-now-btn">Sync Now <span class="kbd" id="sync-now-kbd">⌃⌥⌘S</span></button>
  </div>

  <h3>Timing</h3>
  <div class="timing-grid" id="timing-grid"></div>

  <h3>Hotkeys</h3>
  <div class="section-hint">Click a shortcut to re-record. Esc cancels.</div>
  <div class="inset" id="hotkey-rows"></div>

</div>

<div class="footer">
  <button class="btn apply" id="done-btn">Done</button>
</div>

<script>
const INITIAL_STATE = ]] .. stateJSON .. [[;

// ---- IPC ---------------------------------------------------------------
function post(action, payload) {
  if (!window.webkit || !window.webkit.messageHandlers ||
      !window.webkit.messageHandlers.]] .. MESSAGE_HANDLER .. [[) {
    console.warn("messageHandler not available", action, payload);
    return;
  }
  window.webkit.messageHandlers.]] .. MESSAGE_HANDLER .. [[.postMessage(
    { action: action, payload: payload });
}

// ---- Constants ---------------------------------------------------------
const LETTERS = ["A","B","C","D","E","F","G","H","I","J"];
const MOD_SYMBOLS = { ctrl: "⌃", alt: "⌥", cmd: "⌘", shift: "⇧" };

function letterChipClass(letter) { return "chip " + letter.toLowerCase(); }
function displayName(letter, labels) {
  const label = labels && labels[letter];
  return label ? letter + ": " + label : "Group " + letter;
}
function hotkeyDisplay(entry) {
  if (!entry || !entry.key) return "(unset)";
  const mods = (entry.mods || []).map(m => MOD_SYMBOLS[m.toLowerCase()] || m).join(" ");
  return mods ? mods + " " + entry.key : entry.key;
}

// ---- State -------------------------------------------------------------
let state = JSON.parse(JSON.stringify(INITIAL_STATE.config || {}));
const inventory = INITIAL_STATE.inventory || {};
const lastSeen = state._lastSeen || {};
const env = INITIAL_STATE.env || {};

// ---- Render ------------------------------------------------------------
function render() {
  renderEnvBanner();
  renderMaster();
  renderDetected();
  renderGroupLabels();
  renderMembership();
  renderSyncMode();
  renderTiming();
  renderHotkeys();
  renderSyncNowLabel();
}

function renderEnvBanner() {
  const banner = document.getElementById("env-banner");
  if (env.blocked) {
    banner.classList.remove("hide");
    document.getElementById("env-banner-title").textContent = env.title || "Environment issue";
    document.getElementById("env-banner-body").textContent = env.detail || "";
  } else {
    banner.classList.add("hide");
  }
}

function renderMaster() {
  const sw = document.getElementById("enabled-switch");
  sw.classList.toggle("off", !state.enabled);
  sw.onclick = () => { state.enabled = !state.enabled; post("setEnabled", state.enabled); renderMaster(); };
}

function renderDetected() {
  const el = document.getElementById("detected-displays");
  el.innerHTML = "";
  const positions = Object.keys(inventory).map(Number).sort((a,b) => a - b);
  if (positions.length === 0) {
    el.innerHTML = '<div class="detected-row"><div class="pos">—</div><div class="name">(no displays detected)</div></div>';
    return;
  }
  for (const pos of positions) {
    const info = inventory[pos];
    const row = document.createElement("div");
    row.className = "detected-row";
    row.innerHTML = `<div class="pos">position ${pos}</div>
      <div><div class="name">${info.name || ""}</div>
      <div class="uuid">${info.uuid || ""}</div></div>`;
    el.appendChild(row);
  }
}

function renderGroupLabels() {
  const el = document.getElementById("group-labels");
  el.innerHTML = "";
  // Count members per letter for sublabel.
  const memberCounts = {};
  for (const posKey in (state.groupOf || {})) {
    const letter = state.groupOf[posKey];
    memberCounts[letter] = (memberCounts[letter] || 0) + 1;
  }
  for (const letter of LETTERS) {
    const row = document.createElement("div");
    row.className = "label-row" + (memberCounts[letter] ? "" : " dim");
    const labelValue = (state.groupLabels && state.groupLabels[letter]) || "";
    const memberCount = memberCounts[letter] || 0;
    const memberStr = memberCount > 0
      ? (memberCount === 1 ? "1 display" : memberCount + " displays")
      : "— empty";
    row.innerHTML = `<span class="letter"><span class="${letterChipClass(letter)}"></span>${letter}</span>
      <input class="label-input" type="text" data-letter="${letter}" value="${labelValue.replace(/"/g, '&quot;')}" placeholder="Group ${letter} (default)">
      <span class="member-count">${memberStr}</span>`;
    const input = row.querySelector("input");
    input.oninput = (e) => {
      const v = e.target.value;
      if (!state.groupLabels) state.groupLabels = {};
      if (v && v.trim() !== "") {
        state.groupLabels[letter] = v;
      } else {
        delete state.groupLabels[letter];
      }
      post("setGroupLabel", { letter: letter, label: v || "" });
    };
    el.appendChild(row);
  }
}

function renderMembership() {
  const el = document.getElementById("group-membership");
  el.innerHTML = "";

  // Combine connected positions (from inventory) with stale positions
  // (in state.groupOf or _lastSeen but no current display).
  const allPositions = new Set();
  Object.keys(inventory).forEach(p => allPositions.add(Number(p)));
  Object.keys(state.groupOf || {}).forEach(p => allPositions.add(Number(p)));
  Object.keys(lastSeen || {}).forEach(p => allPositions.add(Number(p)));

  const sortedPositions = Array.from(allPositions).sort((a,b) => a - b);

  if (sortedPositions.length === 0) {
    el.innerHTML = '<div class="group-row"><div class="pos">—</div><div class="display-name">(no displays detected)</div><div></div></div>';
    return;
  }

  for (const pos of sortedPositions) {
    const present = !!inventory[pos];
    const row = document.createElement("div");
    row.className = "group-row" + (present ? "" : " stale");

    let nameCell;
    if (present) {
      nameCell = inventory[pos].name || ("position " + pos);
    } else {
      const ls = lastSeen[String(pos)] || {};
      const dateStr = ls.date ? `, last seen ${ls.date}` : "";
      const wasInStr = ls.wasIn ? `, was in ${displayName(ls.wasIn, state.groupLabels)}` : "";
      nameCell = `${ls.name || "(unknown)"}${dateStr}${wasInStr}`;
    }

    // Group selector.
    const currentLetter = (state.groupOf && state.groupOf[String(pos)]) || "";
    const selectOpts = ['<option value="">— None</option>'];
    for (const letter of LETTERS) {
      const selected = currentLetter === letter ? " selected" : "";
      selectOpts.push(`<option value="${letter}"${selected}>${displayName(letter, state.groupLabels)}</option>`);
    }

    const staleEl = present ? "" : '<span class="stale-warn">⚠ not connected</span>';

    row.innerHTML = `<div class="pos">position ${pos}</div>
      <div class="display-name">${nameCell}</div>
      <div>${staleEl}<select data-pos="${pos}">${selectOpts.join("")}</select></div>`;

    const select = row.querySelector("select");
    select.onchange = (e) => {
      const newLetter = e.target.value;
      if (!state.groupOf) state.groupOf = {};
      if (newLetter) state.groupOf[String(pos)] = newLetter;
      else delete state.groupOf[String(pos)];
      post("setGroupFor", { position: pos, letter: newLetter || null });
      // Re-render labels (member counts changed) and membership (group
      // names in dropdowns may have changed if a label was set).
      renderGroupLabels();
      renderMembership();
    };
    el.appendChild(row);
  }
}

function renderSyncMode() {
  const seg = document.getElementById("sync-mode");
  for (const btn of seg.querySelectorAll("button")) {
    btn.classList.toggle("active", btn.dataset.mode === state.syncMode);
    btn.onclick = () => {
      state.syncMode = btn.dataset.mode;
      post("setSyncMode", state.syncMode);
      renderSyncMode();
    };
  }
  document.getElementById("sync-now-btn").onclick = () => post("triggerSyncNow", null);
}

function renderTiming() {
  const el = document.getElementById("timing-grid");
  el.innerHTML = "";
  const fields = [
    { name: "switchDelay", label: "Switch delay" },
    { name: "debounceSeconds", label: "Debounce" },
    { name: "popupDuration", label: "Popup duration" },
    { name: "statusDuration", label: "Status HUD duration" },
  ];
  for (const f of fields) {
    const labelEl = document.createElement("span");
    labelEl.className = "timing-label";
    labelEl.textContent = f.label;

    const input = document.createElement("input");
    input.type = "text";
    input.inputMode = "decimal";
    input.value = state[f.name];
    input.onchange = () => {
      const v = parseFloat(input.value);
      if (!isNaN(v) && v > 0) {
        state[f.name] = v;
        post("setTiming", { field: f.name, value: v });
      } else {
        input.value = state[f.name];
      }
    };

    const unit = document.createElement("span");
    unit.className = "unit";
    unit.textContent = "s";

    el.appendChild(labelEl);
    el.appendChild(input);
    el.appendChild(unit);
  }
}

let recordingAction = null;

function renderHotkeys() {
  const el = document.getElementById("hotkey-rows");
  el.innerHTML = "";
  const actions = [
    { key: "toggle",       label: "Toggle SpacesSync",   sublabel: "Flip the master switch on/off." },
    { key: "showNames",    label: "Open Space picker",   sublabel: "List Spaces on the cursor display, navigate with arrows." },
    { key: "renameSpace",  label: "Rename current Space", sublabel: "Names this Space across the sync group — every display in the group sees the same name at this index." },
    { key: "syncNow",      label: "Sync Now",            sublabel: "Switch the cursor display's group to the cursor display's current Space." },
    { key: "openSettings", label: "Open Settings",       sublabel: "Open this pane." },
  ];
  for (const a of actions) {
    const hk = (state.hotkeys && state.hotkeys[a.key]) || {};
    const row = document.createElement("div");
    row.className = "hotkey-row";
    row.innerHTML = `<div><div class="label">${a.label}</div><div class="sublabel">${a.sublabel}</div></div>
      <span class="kbd-cell" data-action="${a.key}">${hotkeyDisplay(hk)}</span>
      <a class="kbd-reset" data-action="${a.key}" title="Restore default">Reset</a>`;
    const cell = row.querySelector(".kbd-cell");
    cell.onclick = () => startRecord(a.key, cell);
    row.querySelector(".kbd-reset").onclick = () => post("resetHotkey", a.key);
    el.appendChild(row);
  }
}

function renderSyncNowLabel() {
  const hk = state.hotkeys && state.hotkeys.syncNow;
  document.getElementById("sync-now-kbd").textContent = hotkeyDisplay(hk);
}

function startRecord(action, cell) {
  if (recordingAction) return;
  recordingAction = action;
  cell.classList.add("recording");
  cell.textContent = "Press shortcut… (Esc to cancel)";
  const handler = (e) => {
    e.preventDefault();
    if (e.key === "Escape") {
      finishRecord(null);
      return;
    }
    // Ignore pure-modifier presses; wait for a non-mod key.
    const k = e.key;
    if (k === "Control" || k === "Alt" || k === "Meta" || k === "Shift") return;
    const mods = [];
    if (e.ctrlKey) mods.push("ctrl");
    if (e.altKey) mods.push("alt");
    if (e.metaKey) mods.push("cmd");
    if (e.shiftKey) mods.push("shift");
    // Map JS key to canonical character. Special-case the named keys we care about.
    let key = k;
    if (k.length === 1) key = k.toUpperCase();
    finishRecord({ mods: mods, key: key });
  };
  function finishRecord(combo) {
    document.removeEventListener("keydown", handler, true);
    cell.classList.remove("recording");
    recordingAction = null;
    if (combo) {
      if (!state.hotkeys) state.hotkeys = {};
      state.hotkeys[action] = combo;
      post("setHotkey", { action: action, mods: combo.mods, key: combo.key });
    }
    renderHotkeys();
    renderSyncNowLabel();
  }
  document.addEventListener("keydown", handler, true);
}

document.getElementById("done-btn").onclick = () => post("close", null);

render();
</script>
</body>
</html>
]]
end

-- ============================================================================
-- IPC: handle messages from the JS side
-- ============================================================================

local function reloadAndApply()
  local cfg = deps.config.load()
  if deps.applyConfig then deps.applyConfig(cfg) end
end

local function mutateAndPersist(mutator)
  local cfg = deps.config.load()
  mutator(cfg)
  deps.config.save(cfg)
  if deps.applyConfig then deps.applyConfig(cfg) end
end

local function handleMessage(msg)
  if type(msg) ~= "table" then return end
  local body = msg.body
  if type(body) ~= "table" then return end
  local action = body.action
  local payload = body.payload
  M.logger.d("settings_pane: action=" .. tostring(action))

  if action == "setEnabled" then
    mutateAndPersist(function(cfg) cfg.enabled = (payload == true) end)

  elseif action == "setSyncMode" then
    if payload == "automatic" or payload == "manual" then
      mutateAndPersist(function(cfg) cfg.syncMode = payload end)
    end

  elseif action == "setGroupFor" then
    if type(payload) == "table" and type(payload.position) == "number" then
      mutateAndPersist(function(cfg)
        cfg.groupOf = cfg.groupOf or {}
        if type(payload.letter) == "string" and payload.letter ~= "" then
          cfg.groupOf[tostring(payload.position)] = payload.letter
        else
          cfg.groupOf[tostring(payload.position)] = nil
        end
      end)
    end

  elseif action == "setGroupLabel" then
    if type(payload) == "table" and type(payload.letter) == "string" then
      mutateAndPersist(function(cfg)
        cfg.groupLabels = cfg.groupLabels or {}
        if type(payload.label) == "string" and payload.label ~= "" then
          cfg.groupLabels[payload.letter] = payload.label
        else
          cfg.groupLabels[payload.letter] = nil
        end
      end)
    end

  elseif action == "setTiming" then
    if type(payload) == "table" and type(payload.field) == "string" and
       type(payload.value) == "number" and payload.value > 0 then
      mutateAndPersist(function(cfg) cfg[payload.field] = payload.value end)
    end

  elseif action == "setHotkey" then
    if type(payload) == "table" and type(payload.action) == "string" and
       type(payload.key) == "string" then
      local mods = {}
      if type(payload.mods) == "table" then
        for _, m in ipairs(payload.mods) do
          if type(m) == "string" then table.insert(mods, m) end
        end
      end
      mutateAndPersist(function(cfg)
        cfg.hotkeys = cfg.hotkeys or {}
        cfg.hotkeys[payload.action] = { mods = mods, key = payload.key }
      end)
    end

  elseif action == "resetHotkey" then
    if type(payload) == "string" then
      mutateAndPersist(function(cfg)
        local default = deps.config.DEFAULT.hotkeys[payload]
        if default then
          cfg.hotkeys = cfg.hotkeys or {}
          cfg.hotkeys[payload] = deps.config._deepClone(default)
        end
      end)
    end

  elseif action == "triggerSyncNow" then
    -- Defer to next tick so we don't run engine work inside the JS message
    -- callback (Hammerspoon will wedge if the callback blocks).
    hs.timer.doAfter(0, function()
      local spoon = _G.spoon and _G.spoon.SpacesSync
      if spoon and spoon.syncNow then spoon:syncNow() end
    end)

  elseif action == "close" then
    M.close()

  else
    M.logger.w("settings_pane: unknown action " .. tostring(action))
  end
end

-- ============================================================================
-- ENV-CHECK SNAPSHOT for the banner
-- ============================================================================

-- Forward-decl so M.open can reference it before the function body.
local buildInitialState

local function envSnapshot()
  -- Mirror the engine's environment check, but as a structured signal the
  -- HTML can render. Cheap re-run on every open.
  local spans = hs.execute("defaults read com.apple.spaces spans-displays 2>/dev/null"):gsub("%s+", "")
  if spans == "1" then
    return {
      blocked = true,
      title = "\"Displays have separate Spaces\" is off",
      detail = "All displays share one Space — there's nothing to sync. Enable it in " ..
               "System Settings → Desktop & Dock → Mission Control (requires logout).",
    }
  end
  return { blocked = false }
end

-- ============================================================================
-- OPEN / CLOSE
-- ============================================================================

function M.open(d)
  deps = d or deps
  if not deps or not deps.config then
    error("settings_pane.open: deps.config required")
  end

  if webview then
    -- Already open — bring to front and refresh state.
    webview:hswindow():focus()
    webview:html(buildHTML(buildInitialState()))
    return
  end

  if type(hs) ~= "table" or type(hs.webview) ~= "table" or
     type(hs.webview.new) ~= "function" then
    M.logger.e("settings_pane: hs.webview unavailable; cannot open settings")
    return
  end

  local screen = hs.screen.mainScreen()
  local sf = screen:frame()
  local rect = {
    x = sf.x + (sf.w - WINDOW_WIDTH) / 2,
    y = sf.y + (sf.h - WINDOW_HEIGHT) / 2,
    w = WINDOW_WIDTH,
    h = WINDOW_HEIGHT,
  }

  userContent = hs.webview.usercontent.new(MESSAGE_HANDLER)
  userContent:setCallback(handleMessage)

  webview = hs.webview.new(rect, { developerExtrasEnabled = false }, userContent)
    :windowTitle("SpacesSync")
    :windowStyle({ "titled", "closable", "resizable" })
    :allowTextEntry(true)
    :darkMode(true)
    :level(hs.drawing.windowLevels.normal)
    :html(buildHTML(buildInitialState()))
    :show()
  M.logger.i("settings_pane: opened")
end

buildInitialState = function()
  if not deps or not deps.config then return { config = {}, inventory = {}, env = {} } end
  local cfg = deps.config.load()
  local inventory = (deps.getDisplayInventory and deps.getDisplayInventory()) or {}
  return {
    config = cfg,
    inventory = inventory,
    env = envSnapshot(),
  }
end

function M.close()
  if webview then
    pcall(function() webview:delete() end)
    webview = nil
  end
  if userContent then
    -- usercontent has no explicit destructor; dropping the reference is
    -- enough as long as the webview that owned it is gone.
    userContent = nil
  end
  M.logger.d("settings_pane: closed")
end

return M
