// MARK: - WebUI
// Full single-page app as a Swift string constant.

enum WebUI {
    static let html = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>NateBot</title>
<style>
  :root {
    --bg: #0d0d0d; --surface: #1a1a1a; --border: #2e2e2e;
    --text: #e0e0e0; --muted: #888; --accent: #4f9eff;
    --green: #22c55e; --red: #ef4444; --yellow: #f59e0b;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: -apple-system, monospace; font-size: 14px; }
  #app { display: flex; flex-direction: column; height: 100vh; }
  nav { display: flex; background: var(--surface); border-bottom: 1px solid var(--border); padding: 0 16px; gap: 4px; }
  nav button { background: none; border: none; color: var(--muted); cursor: pointer; padding: 12px 16px; font-size: 14px; border-bottom: 2px solid transparent; }
  nav button.active { color: var(--accent); border-bottom-color: var(--accent); }
  nav button:hover { color: var(--text); }
  main { flex: 1; overflow-y: auto; padding: 20px; }
  .tab { display: none; } .tab.active { display: block; }
  h2 { font-size: 16px; font-weight: 600; margin-bottom: 16px; color: var(--text); }
  h3 { font-size: 14px; font-weight: 600; margin-bottom: 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .5px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 20px; }
  th { text-align: left; padding: 8px 12px; color: var(--muted); font-size: 12px; border-bottom: 1px solid var(--border); }
  td { padding: 8px 12px; border-bottom: 1px solid var(--border); }
  tr:hover td { background: var(--surface); }
  input, select, textarea { background: var(--surface); border: 1px solid var(--border); color: var(--text); padding: 8px 12px; border-radius: 6px; font-size: 14px; width: 100%; }
  textarea { font-family: monospace; resize: vertical; }
  input:focus, select:focus, textarea:focus { outline: 1px solid var(--accent); }
  button.btn { background: var(--accent); color: #fff; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 14px; }
  button.btn:hover { opacity: .85; }
  button.btn-sm { background: var(--surface); color: var(--muted); border: 1px solid var(--border); padding: 4px 10px; border-radius: 4px; cursor: pointer; font-size: 12px; }
  button.btn-sm:hover { color: var(--text); }
  button.btn-red { background: #7f1d1d; color: #fca5a5; }
  .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 6px; }
  .dot.green { background: var(--green); } .dot.red { background: var(--red); }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 16px; }
  .grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
  .grid3 { display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 16px; }
  .progress-bar { background: var(--border); border-radius: 4px; height: 6px; overflow: hidden; margin-top: 4px; }
  .progress-fill { height: 100%; border-radius: 4px; background: var(--accent); }
  .stat-label { color: var(--muted); font-size: 12px; }
  .stat-value { font-size: 20px; font-weight: 700; }
  .row { display: flex; gap: 12px; margin-bottom: 12px; align-items: flex-end; }
  .row > * { flex: 1; }
  .row > button { flex: 0 0 auto; }
  .toast { position: fixed; bottom: 20px; right: 20px; background: var(--green); color: #fff; padding: 10px 20px; border-radius: 6px; font-size: 14px; z-index: 999; display: none; }
  .toast.err { background: var(--red); }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; background: var(--border); color: var(--muted); }
  .badge.green { background: #14532d; color: #86efac; }
  .badge.red { background: #7f1d1d; color: #fca5a5; }
  .section-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 12px; }
  .spacer { flex: 1; }
  label { color: var(--muted); font-size: 12px; display: block; margin-bottom: 4px; margin-top: 10px; }
  .form-section { background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 16px; margin-bottom: 20px; }
  .heatmap { display: flex; gap: 4px; flex-wrap: wrap; margin-top: 8px; }
  .heatmap-cell { width: 14px; height: 14px; border-radius: 2px; background: var(--border); }
  .heatmap-cell.done { background: var(--green); }
  pre { background: var(--surface); padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 12px; }
  .spinner { display: inline-block; width: 16px; height: 16px; border: 2px solid var(--border); border-top-color: var(--accent); border-radius: 50%; animation: spin .6s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .empty { color: var(--muted); text-align: center; padding: 40px; }
  #loc-map { height: 400px; border-radius: 8px; border: 1px solid var(--border); margin-bottom: 16px; }
  .timeline { position: relative; padding-left: 28px; }
  .timeline::before { content: ''; position: absolute; left: 10px; top: 0; bottom: 0; width: 2px; background: var(--border); }
  .tl-item { position: relative; margin-bottom: 16px; }
  .tl-dot { position: absolute; left: -22px; top: 4px; width: 10px; height: 10px; border-radius: 50%; background: var(--accent); border: 2px solid var(--bg); }
  .tl-dot.home { background: var(--green); }
  .tl-dot.away { background: var(--yellow); }
  .tl-dot.now { background: var(--accent); box-shadow: 0 0 8px var(--accent); }
  .tl-time { color: var(--muted); font-size: 12px; }
  .tl-label { font-weight: 600; }
  .tl-addr { color: var(--muted); font-size: 12px; }
</style>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css" />
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
</head>
<body>
<div id="app">
  <nav>
    <button class="active" onclick="switchTab('dashboard')">Dashboard</button>
    <button onclick="switchTab('log')">Activity Log</button>
    <button onclick="switchTab('config')">Config</button>
    <button onclick="switchTab('goals')">Goals</button>
    <button onclick="switchTab('calendar')">Calendar</button>
    <button onclick="switchTab('reminders')">Reminders</button>
    <button onclick="switchTab('location')">Location</button>
  </nav>
  <main>

    <!-- DASHBOARD -->
    <div id="tab-dashboard" class="tab active">
      <div class="section-head"><h2>Dashboard</h2>
        <button class="btn-sm" onclick="loadDashboard()">Refresh</button>
      </div>
      <div class="grid3" id="sys-metrics">
        <div class="card"><div class="stat-label">CPU</div><div class="stat-value" id="cpu-val">—</div>
          <div class="progress-bar"><div class="progress-fill" id="cpu-bar" style="width:0%"></div></div></div>
        <div class="card"><div class="stat-label">RAM</div><div class="stat-value" id="ram-val">—</div>
          <div class="progress-bar"><div class="progress-fill" id="ram-bar" style="width:0%"></div></div></div>
        <div class="card"><div class="stat-label">Disk</div><div class="stat-value" id="disk-val">—</div>
          <div class="progress-bar"><div class="progress-fill" id="disk-bar" style="width:0%"></div></div></div>
      </div>
      <div class="card">
        <h3>Apps</h3>
        <table><thead><tr><th>App</th><th>Status</th><th>Detail</th></tr></thead>
          <tbody id="apps-tbody"></tbody></table>
      </div>
      <div class="card">
        <h3>Docker</h3>
        <table><thead><tr><th>Container</th><th>Status</th></tr></thead>
          <tbody id="docker-tbody"></tbody></table>
      </div>
    </div>

    <!-- ACTIVITY LOG -->
    <div id="tab-log" class="tab">
      <div class="section-head"><h2>Activity Log</h2>
        <div style="display:flex;gap:8px;align-items:center">
          <label style="margin:0;color:var(--muted)">Count:</label>
          <select id="log-count" style="width:80px" onchange="loadLog()">
            <option>20</option><option selected>50</option><option>100</option>
          </select>
          <button class="btn-sm" onclick="loadLog()">Refresh</button>
        </div>
      </div>
      <table>
        <thead><tr><th>Time</th><th>Action</th><th>Result</th><th>Message</th><th>Reply</th></tr></thead>
        <tbody id="log-tbody"></tbody>
      </table>
    </div>

    <!-- CONFIG -->
    <div id="tab-config" class="tab">
      <div class="section-head"><h2>Config</h2>
        <button class="btn" onclick="saveConfig()">Save</button>
      </div>
      <div class="form-section">
        <h3>General</h3>
        <label>Trusted Sender</label><input id="cfg-trusted-sender">
        <label>Passphrase</label><input id="cfg-passphrase">
        <label>Claude API Key</label><input id="cfg-claude-api-key">
        <label>Web UI Port</label><input id="cfg-webui-port" type="number">
      </div>
      <div class="form-section">
        <h3>Briefing</h3>
        <label>Time (HH:MM)</label><input id="cfg-briefing-time">
        <label>Upcoming Days</label><input id="cfg-briefing-upcoming-days" type="number">
        <label>Include Overdue</label>
        <select id="cfg-briefing-include-overdue"><option value="true">Yes</option><option value="false">No</option></select>
      </div>
      <div class="form-section">
        <h3>Calendars</h3>
        <label>Default</label><input id="cfg-cal-default">
        <label>Work</label><input id="cfg-cal-work">
        <label>School</label><input id="cfg-cal-school">
      </div>
      <div class="form-section">
        <h3>Reminder Lists</h3>
        <label>Default</label><input id="cfg-rem-default">
        <label>Work</label><input id="cfg-rem-work">
        <label>School</label><input id="cfg-rem-school">
      </div>
      <div class="form-section">
        <h3>Raw JSON</h3>
        <textarea id="cfg-raw" rows="20" oninput="onRawEdit()"></textarea>
      </div>
    </div>

    <!-- GOALS -->
    <div id="tab-goals" class="tab">
      <div class="section-head"><h2>Goals</h2></div>
      <div class="card">
        <h3>Add Goal</h3>
        <div class="row">
          <div><label style="margin:0">Name</label><input id="goal-name" placeholder="Morning Prayer"></div>
          <div><label style="margin:0">Frequency</label>
            <select id="goal-freq"><option value="daily">Daily</option><option value="weekly">Weekly</option></select></div>
          <div><label style="margin:0">Reminder (HH:MM)</label><input id="goal-rt" placeholder="optional"></div>
          <div><label style="margin:0">Location</label><input id="goal-loc" placeholder="e.g. Gym"></div>
          <button class="btn" onclick="addGoal()">Add</button>
        </div>
      </div>
      <div id="goals-list"></div>
    </div>

    <!-- CALENDAR -->
    <div id="tab-calendar" class="tab">
      <div class="section-head"><h2>Calendar</h2>
        <div style="display:flex;gap:8px">
          <label style="margin:0;color:var(--muted)">Days:</label>
          <select id="cal-days" style="width:70px" onchange="loadCalendar()">
            <option value="7">7</option><option value="14" selected>14</option><option value="30">30</option>
          </select>
          <button class="btn-sm" onclick="loadCalendar()">Refresh</button>
        </div>
      </div>
      <div class="card">
        <h3>Add Event</h3>
        <div class="row">
          <input id="cal-details" placeholder="dentist Friday 2pm for 1 hour">
          <button class="btn" onclick="addCalEvent()">Add</button>
        </div>
      </div>
      <table>
        <thead><tr><th>Title</th><th>Start</th><th>End</th><th>Calendar</th><th></th></tr></thead>
        <tbody id="cal-tbody"></tbody>
      </table>
    </div>

    <!-- REMINDERS -->
    <div id="tab-reminders" class="tab">
      <div class="section-head"><h2>Reminders</h2>
        <button class="btn-sm" onclick="loadReminders()">Refresh</button>
      </div>
      <div class="card">
        <h3>Add Reminder</h3>
        <div class="row">
          <input id="rem-details" placeholder="call mom tomorrow at noon">
          <button class="btn" onclick="addReminder()">Add</button>
        </div>
      </div>
      <table>
        <thead><tr><th>Title</th><th>List</th><th>Due</th><th>Priority</th><th></th></tr></thead>
        <tbody id="rem-tbody"></tbody>
      </table>
    </div>

    <!-- LOCATION -->
    <div id="tab-location" class="tab">
      <div class="section-head"><h2>Location</h2>
        <div style="display:flex;gap:8px;align-items:center">
          <input type="date" id="loc-date" style="width:160px" onchange="loadLocation()">
          <button class="btn-sm" onclick="scrapeNow()">Scrape Now</button>
          <button class="btn-sm" onclick="loadLocation()">Refresh</button>
        </div>
      </div>
      <div id="loc-current" class="card" style="display:none">
        <div style="display:flex;align-items:center;gap:8px">
          <span class="dot green"></span>
          <strong id="loc-cur-label">—</strong>
          <span class="badge" id="loc-cur-time">—</span>
        </div>
        <div style="color:var(--muted);font-size:12px;margin-top:4px" id="loc-cur-addr">—</div>
      </div>
      <div id="loc-map"></div>
      <div class="card">
        <h3>Timeline</h3>
        <div class="timeline" id="loc-timeline"></div>
      </div>
    </div>

  </main>
</div>
<div class="toast" id="toast"></div>

<script>
// ── Utils ──────────────────────────────────────────────────────────────────

function showToast(msg, err) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.className = 'toast' + (err ? ' err' : '');
  t.style.display = 'block';
  setTimeout(() => t.style.display = 'none', 3000);
}

async function api(method, path, body) {
  const opts = { method, headers: {} };
  if (body !== undefined) {
    opts.headers['content-type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const r = await fetch(path, opts);
  return r.json().catch(() => ({}));
}

function fmt(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString([], {month:'short',day:'numeric',hour:'numeric',minute:'2-digit'});
}

// ── Tab switching ──────────────────────────────────────────────────────────

const loaders = {
  dashboard: loadDashboard,
  log: loadLog,
  config: loadConfig,
  goals: loadGoals,
  calendar: loadCalendar,
  reminders: loadReminders,
  location: loadLocation,
};

function switchTab(name) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
  document.getElementById('tab-' + name).classList.add('active');
  event.target.classList.add('active');
  if (loaders[name]) loaders[name]();
}

// ── Dashboard ──────────────────────────────────────────────────────────────

async function loadDashboard() {
  const [sys, apps, docker] = await Promise.all([
    api('GET', '/api/status/system'),
    api('GET', '/api/status'),
    api('GET', '/api/status/docker'),
  ]);

  if (sys.cpuPercent !== undefined) {
    document.getElementById('cpu-val').textContent = sys.cpuPercent.toFixed(0) + '%';
    document.getElementById('cpu-bar').style.width = sys.cpuPercent.toFixed(0) + '%';
    document.getElementById('ram-val').textContent = sys.ramUsedGB.toFixed(1) + '/' + sys.ramTotalGB.toFixed(0) + 'GB';
    const ramPct = sys.ramTotalGB > 0 ? (sys.ramUsedGB / sys.ramTotalGB * 100).toFixed(0) : 0;
    document.getElementById('ram-bar').style.width = ramPct + '%';
    document.getElementById('disk-val').textContent = sys.diskUsedGB.toFixed(0) + '/' + sys.diskTotalGB.toFixed(0) + 'GB';
    const diskPct = sys.diskTotalGB > 0 ? (sys.diskUsedGB / sys.diskTotalGB * 100).toFixed(0) : 0;
    document.getElementById('disk-bar').style.width = diskPct + '%';
  }

  const atb = document.getElementById('apps-tbody');
  atb.innerHTML = (apps || []).map(a =>
    `<tr><td><span class="dot ${a.isUp ? 'green' : 'red'}"></span>${a.displayName}</td>
     <td><span class="badge ${a.isUp ? 'green' : 'red'}">${a.isUp ? 'UP' : 'DOWN'}</span></td>
     <td>${a.detail || '—'}</td></tr>`
  ).join('') || '<tr><td colspan="3" class="empty">No apps configured</td></tr>';

  const dtb = document.getElementById('docker-tbody');
  dtb.innerHTML = (docker || []).map(c =>
    `<tr><td><span class="dot ${c.isRunning ? 'green' : 'red'}"></span>${c.name}</td>
     <td>${c.status}</td></tr>`
  ).join('') || '<tr><td colspan="2" class="empty">No containers</td></tr>';
}

// ── Activity Log ───────────────────────────────────────────────────────────

async function loadLog() {
  const count = document.getElementById('log-count').value;
  const entries = await api('GET', '/api/log?count=' + count);
  const tb = document.getElementById('log-tbody');
  const rows = [...(entries || [])].reverse();
  tb.innerHTML = rows.map(e =>
    `<tr>
       <td style="white-space:nowrap;color:var(--muted)">${e.timestamp.slice(0,19).replace('T',' ')}</td>
       <td><code>${e.action}</code></td>
       <td><span class="badge ${e.result==='success'||e.result==='ok'||e.result==='sent'?'green':e.result==='error'?'red':''}">${e.result}</span></td>
       <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(e.message)}">${esc(e.message)}</td>
       <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${esc(e.reply)}">${esc(e.reply)}</td>
     </tr>`
  ).join('') || '<tr><td colspan="5" class="empty">No entries</td></tr>';
}

function esc(s) { return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }

// ── Config ─────────────────────────────────────────────────────────────────

let _configRawDirty = false;

async function loadConfig() {
  const cfg = await api('GET', '/api/config');
  _currentCfg = cfg;
  document.getElementById('cfg-trusted-sender').value = cfg.trusted_sender || '';
  document.getElementById('cfg-passphrase').value = cfg.passphrase || '';
  document.getElementById('cfg-claude-api-key').value = cfg.claude_api_key || '';
  document.getElementById('cfg-webui-port').value = cfg.webui_port || 8080;
  document.getElementById('cfg-briefing-time').value = (cfg.briefing||{}).time || '';
  document.getElementById('cfg-briefing-upcoming-days').value = (cfg.briefing||{}).upcoming_days || 7;
  document.getElementById('cfg-briefing-include-overdue').value = String((cfg.briefing||{}).include_overdue !== false);
  document.getElementById('cfg-cal-default').value = (cfg.calendars||{}).default || '';
  document.getElementById('cfg-cal-work').value = (cfg.calendars||{}).work || '';
  document.getElementById('cfg-cal-school').value = (cfg.calendars||{}).school || '';
  document.getElementById('cfg-rem-default').value = (cfg.reminder_lists||{}).default || '';
  document.getElementById('cfg-rem-work').value = (cfg.reminder_lists||{}).work || '';
  document.getElementById('cfg-rem-school').value = (cfg.reminder_lists||{}).school || '';
  document.getElementById('cfg-raw').value = JSON.stringify(cfg, null, 2);
  _configRawDirty = false;
}

function onRawEdit() { _configRawDirty = true; }

async function saveConfig() {
  let cfg;
  if (_configRawDirty) {
    try { cfg = JSON.parse(document.getElementById('cfg-raw').value); }
    catch(e) { showToast('Invalid JSON: ' + e.message, true); return; }
  } else {
    cfg = Object.assign({}, _currentCfg);
    cfg.trusted_sender = document.getElementById('cfg-trusted-sender').value;
    cfg.passphrase = document.getElementById('cfg-passphrase').value;
    cfg.claude_api_key = document.getElementById('cfg-claude-api-key').value;
    cfg.webui_port = parseInt(document.getElementById('cfg-webui-port').value) || 8080;
    cfg.briefing = Object.assign({}, cfg.briefing, {
      time: document.getElementById('cfg-briefing-time').value,
      upcoming_days: parseInt(document.getElementById('cfg-briefing-upcoming-days').value) || 7,
      include_overdue: document.getElementById('cfg-briefing-include-overdue').value === 'true',
    });
    cfg.calendars = { default: document.getElementById('cfg-cal-default').value,
      work: document.getElementById('cfg-cal-work').value, school: document.getElementById('cfg-cal-school').value };
    cfg.reminder_lists = { default: document.getElementById('cfg-rem-default').value,
      work: document.getElementById('cfg-rem-work').value, school: document.getElementById('cfg-rem-school').value };
  }
  const r = await api('PUT', '/api/config', cfg);
  if (r.status === 'saved') { showToast('Config saved'); loadConfig(); }
  else showToast('Save failed: ' + (r.error || JSON.stringify(r)), true);
}

let _currentCfg = {};

// ── Goals ──────────────────────────────────────────────────────────────────

async function loadGoals() {
  const [goals, checkins] = await Promise.all([
    api('GET', '/api/goals'),
    api('GET', '/api/goals/checkins'),
  ]);
  const gl = document.getElementById('goals-list');
  if (!goals || goals.length === 0) { gl.innerHTML = '<div class="empty">No goals yet.</div>'; return; }

  gl.innerHTML = goals.map(g => {
    const myCheckins = (checkins || []).filter(c => c.goal_id === g.id);
    const days = last7days();
    const cells = days.map(d => {
      const done = myCheckins.some(c => sameDay(c.timestamp, d));
      return `<div class="heatmap-cell ${done ? 'done' : ''}" title="${d}"></div>`;
    }).join('');
    return `<div class="card">
      <div style="display:flex;justify-content:space-between;align-items:center">
        <div>
          <strong>${esc(g.name)}</strong>
          <span class="badge" style="margin-left:8px">${g.frequency}</span>
          ${g.reminder_time ? `<span class="badge" style="margin-left:4px">⏰ ${g.reminder_time}</span>` : ''}
          ${g.location ? `<span class="badge" style="margin-left:4px;background:#1e3a5f;color:#93c5fd">📍 ${g.location}</span>` : ''}
        </div>
        <div style="display:flex;gap:8px">
          <button class="btn-sm" onclick="checkinGoal('${g.id}','${esc(g.name)}')">Check In</button>
          <button class="btn-sm btn-red" onclick="deleteGoal('${g.id}')">Delete</button>
        </div>
      </div>
      <div class="stat-label" style="margin-top:8px">Last 7 days</div>
      <div class="heatmap">${cells}</div>
    </div>`;
  }).join('');
}

function last7days() {
  const days = [];
  for (let i = 6; i >= 0; i--) {
    const d = new Date(); d.setDate(d.getDate() - i);
    days.push(d.toISOString().slice(0, 10));
  }
  return days;
}

function sameDay(iso, dateStr) {
  return (iso || '').slice(0, 10) === dateStr;
}

async function addGoal() {
  const name = document.getElementById('goal-name').value.trim();
  const freq = document.getElementById('goal-freq').value;
  const rt   = document.getElementById('goal-rt').value.trim();
  const loc  = document.getElementById('goal-loc').value.trim();
  if (!name) { showToast('Enter a goal name', true); return; }
  const body = { name, frequency: freq };
  if (rt) body.reminder_time = rt;
  if (loc) body.location = loc;
  const r = await api('POST', '/api/goals', body);
  if (r.id) {
    showToast('Goal added');
    document.getElementById('goal-name').value = '';
    document.getElementById('goal-rt').value = '';
    document.getElementById('goal-loc').value = '';
    loadGoals();
  } else showToast('Failed: ' + (r.error || ''), true);
}

async function deleteGoal(id) {
  if (!confirm('Delete this goal?')) return;
  const r = await api('DELETE', '/api/goals/' + id);
  if (r.status === 'ok') { showToast('Deleted'); loadGoals(); }
  else showToast('Failed: ' + (r.error || ''), true);
}

async function checkinGoal(id, name) {
  const note = prompt('Note (optional) for: ' + name) ?? null;
  const r = await api('POST', '/api/goals/' + id + '/checkin', { note: note || undefined });
  if (r.status === 'ok') { showToast('Checked in!'); loadGoals(); }
  else showToast('Failed', true);
}

// ── Calendar ───────────────────────────────────────────────────────────────

async function loadCalendar() {
  const days = document.getElementById('cal-days').value;
  const events = await api('GET', '/api/calendar/events?days=' + days);
  const tb = document.getElementById('cal-tbody');
  tb.innerHTML = (events || []).map(e =>
    `<tr>
       <td>${esc(e.title)}</td>
       <td style="white-space:nowrap">${fmt(e.startDate)}</td>
       <td style="white-space:nowrap">${fmt(e.endDate)}</td>
       <td>${esc(e.calendar || '—')}</td>
       <td><button class="btn-sm btn-red" onclick="deleteCalEvent('${e.id}')">Delete</button></td>
     </tr>`
  ).join('') || '<tr><td colspan="5" class="empty">No upcoming events</td></tr>';
}

async function addCalEvent() {
  const details = document.getElementById('cal-details').value.trim();
  if (!details) return;
  const r = await api('POST', '/api/calendar/events', { details });
  showToast(r.reply || 'Done', r.reply && r.reply.startsWith('⚠️'));
  document.getElementById('cal-details').value = '';
  loadCalendar();
}

async function deleteCalEvent(id) {
  if (!confirm('Delete this event?')) return;
  const r = await api('DELETE', '/api/calendar/events/' + encodeURIComponent(id));
  if (r.status === 'deleted') { showToast('Deleted'); loadCalendar(); }
  else showToast('Failed: ' + (r.error || ''), true);
}

// ── Reminders ──────────────────────────────────────────────────────────────

async function loadReminders() {
  const reminders = await api('GET', '/api/reminders');
  const tb = document.getElementById('rem-tbody');
  tb.innerHTML = (reminders || []).map(r =>
    `<tr>
       <td>${esc(r.title)}</td>
       <td>${esc(r.list || '—')}</td>
       <td style="white-space:nowrap">${r.dueDate ? fmt(r.dueDate) : '—'}</td>
       <td>${esc(r.priority || 'none')}</td>
       <td>
         <button class="btn-sm" style="margin-right:4px" onclick="completeReminder('${r.id}')">Done</button>
         <button class="btn-sm btn-red" onclick="deleteReminder('${r.id}')">Delete</button>
       </td>
     </tr>`
  ).join('') || '<tr><td colspan="5" class="empty">No incomplete reminders</td></tr>';
}

async function addReminder() {
  const details = document.getElementById('rem-details').value.trim();
  if (!details) return;
  const r = await api('POST', '/api/reminders', { details });
  showToast(r.reply || 'Done', r.reply && r.reply.startsWith('⚠️'));
  document.getElementById('rem-details').value = '';
  loadReminders();
}

async function completeReminder(id) {
  const r = await api('PUT', '/api/reminders/' + encodeURIComponent(id) + '/complete');
  if (r.status === 'ok') { showToast('Marked complete'); loadReminders(); }
  else showToast('Failed: ' + (r.error || ''), true);
}

async function deleteReminder(id) {
  if (!confirm('Delete this reminder?')) return;
  const r = await api('DELETE', '/api/reminders/' + encodeURIComponent(id));
  if (r.status === 'ok') { showToast('Deleted'); loadReminders(); }
  else showToast('Failed: ' + (r.error || ''), true);
}

// ── Location ──────────────────────────────────────────────────────────

let _locMap = null;
let _locMarkers = [];

function initLocDate() {
  const d = document.getElementById('loc-date');
  if (!d.value) d.value = new Date().toISOString().slice(0, 10);
}

async function loadLocation() {
  initLocDate();
  const dateStr = document.getElementById('loc-date').value;
  const [history, current] = await Promise.all([
    api('GET', '/api/location/history?date=' + dateStr),
    api('GET', '/api/location/current'),
  ]);

  // Current location card
  const curCard = document.getElementById('loc-current');
  if (current && !current.error) {
    curCard.style.display = 'block';
    document.getElementById('loc-cur-label').textContent = current.label || current.address || '—';
    document.getElementById('loc-cur-addr').textContent = current.address || '';
    document.getElementById('loc-cur-time').textContent = fmt(current.timestamp);
  } else {
    curCard.style.display = 'none';
  }

  // Map
  renderMap(history || []);

  // Timeline
  renderTimeline(history || []);
}

const _labelColors = {};
const _colorPalette = ['#22c55e','#4f9eff','#f59e0b','#ef4444','#a855f7','#ec4899','#06b6d4','#84cc16'];
let _colorIdx = 0;

function labelColor(label) {
  if (!label) return '#888';
  if (!_labelColors[label]) {
    _labelColors[label] = _colorPalette[_colorIdx % _colorPalette.length];
    _colorIdx++;
  }
  return _labelColors[label];
}

function renderMap(entries) {
  const mapDiv = document.getElementById('loc-map');
  if (!entries.length || !entries.some(e => e.latitude)) {
    mapDiv.style.display = 'none';
    return;
  }
  mapDiv.style.display = 'block';

  if (!_locMap) {
    _locMap = L.map('loc-map', { zoomControl: true });
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      attribution: '© OpenStreetMap',
      maxZoom: 19,
    }).addTo(_locMap);
  }

  // Clear old markers
  _locMarkers.forEach(m => _locMap.removeLayer(m));
  _locMarkers = [];

  const points = entries.filter(e => e.latitude && e.longitude);
  const latlngs = [];

  points.forEach((e, i) => {
    const ll = [e.latitude, e.longitude];
    latlngs.push(ll);
    const color = labelColor(e.label);
    const icon = L.divIcon({
      className: '',
      html: '<div style="background:' + color + ';color:#fff;width:22px;height:22px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:700;border:2px solid #0d0d0d;">' + (i + 1) + '</div>',
      iconSize: [22, 22],
      iconAnchor: [11, 11],
    });
    const marker = L.marker(ll, { icon }).addTo(_locMap);
    const time = new Date(e.timestamp).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'});
    marker.bindPopup('<b>' + (e.label || e.address) + '</b><br>' + e.address + '<br><span style="color:#888">' + time + '</span>');
    _locMarkers.push(marker);
  });

  // Path line
  if (latlngs.length > 1) {
    const line = L.polyline(latlngs, { color: '#4f9eff', weight: 2, opacity: 0.6, dashArray: '6' }).addTo(_locMap);
    _locMarkers.push(line);
  }

  if (latlngs.length > 0) {
    _locMap.fitBounds(L.latLngBounds(latlngs).pad(0.2));
  }
}

function renderTimeline(entries) {
  const tl = document.getElementById('loc-timeline');
  if (!entries.length) {
    tl.innerHTML = '<div class="empty">No location data for this date.</div>';
    return;
  }

  // Collapse consecutive same-location entries into ranges
  const ranges = [];
  entries.forEach(e => {
    const name = e.label || e.address;
    const time = new Date(e.timestamp).toLocaleTimeString([], {hour:'numeric',minute:'2-digit'});
    if (ranges.length && ranges[ranges.length - 1].name === name) {
      ranges[ranges.length - 1].end = time;
      ranges[ranges.length - 1].count++;
    } else {
      ranges.push({ name, address: e.address, start: time, end: time, label: e.label, count: 1 });
    }
  });

  // Check if last entry is recent (within 1 hour)
  const lastTs = new Date(entries[entries.length - 1].timestamp);
  const isRecent = (Date.now() - lastTs.getTime()) < 3600000;

  tl.innerHTML = ranges.map((r, i) => {
    const isLast = i === ranges.length - 1;
    const dotClass = isLast && isRecent ? 'now' : (r.label ? 'home' : 'away');
    const timeRange = r.start === r.end ? r.start : r.start + ' – ' + (isLast && isRecent ? 'Now' : r.end);
    return '<div class="tl-item">' +
      '<div class="tl-dot ' + dotClass + '" style="background:' + labelColor(r.label) + '"></div>' +
      '<div class="tl-time">' + timeRange + '</div>' +
      '<div class="tl-label">' + esc(r.name) + '</div>' +
      (r.label ? '<div class="tl-addr">' + esc(r.address) + '</div>' : '') +
      '</div>';
  }).join('');
}

async function scrapeNow() {
  showToast('Scraping...');
  const r = await api('POST', '/api/location/scrape');
  if (r.status === 'ok') {
    showToast('Location updated: ' + (r.label || r.address));
    loadLocation();
  } else {
    showToast(r.error || 'Scrape failed', true);
  }
}

// ── Auto-refresh + init ────────────────────────────────────────────────────

setInterval(() => {
  if (document.getElementById('tab-dashboard').classList.contains('active')) loadDashboard();
}, 30000);

loadDashboard();
</script>
</body>
</html>
"""
}
