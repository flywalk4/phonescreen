// Claude Code's limits and state. Works on its own; the bridge is optional.
//
// Without the bridge: reads the session logs Claude Code writes anyway to ~/.claude/projects/*/*.jsonl
// (read-only; the widget never goes online). From them: what Claude is doing (the crab) and how many tokens
// went into the current 5-hour window and the last 7 days. No percentages here: subscription limits aren't
// published anywhere, but a token budget can be set in the settings — then there are bars.
//
// With the bridge (python3 scripts/claude-code-bridge.py install), more precise:
//   ~/.claude/qwovi/status.json — the official rate_limits from the status line (Pro/Max): % and reset time
//   ~/.claude/qwovi/state.json  — session state from hooks: working / waiting / idle

const BRIDGE = "~/.claude/qwovi/";
const ROOTS = ["~/.claude/projects/", "~/.config/claude/projects/"];
const HOUR = 3600, WEEK = 7 * 86400;

async function refresh(ctx) {
  const now = Date.now() / 1000;
  await scanLogs(now);

  const status = readJSON(BRIDGE + "status.json");
  const limits = (status && status.rate_limits) || {};
  const official = Boolean(limits.five_hour || limits.seven_day);
  const hooks = readJSON(BRIDGE + "state.json");
  const mood = hooks && now - (hooks.at || 0) < HOUR ? hookMood(hooks, now) : logMood(now);

  let five, week, note = "", noteShort = "";
  if (official) {
    five = limitWindow(limits.five_hour, now, false);
    week = limitWindow(limits.seven_day, now, true);
  } else {
    five = tokenWindow(currentBlock(now), Number(ctx.settings.budget5h), now);
    week = tokenWindow(lastWeek(now), Number(ctx.settings.budgetWeek), now);
    note = t(!scan.ready ? "note.counting" : status ? "note.afterReply" : !scan.logs ? "note.noSessions" : "note.logs");
    noteShort = !scan.ready ? t("short.counting") : status ? t("short.afterReply") : !scan.logs ? t("short.noSessions") : "";
  }

  return {
    mood: mood.key,
    moodText: t(`mood.${mood.key}`),
    moodColor: mood.color,
    mascot: mascot(mood.key),
    model: prettyModel((status && status.model) || scan.model),
    official,
    five, week,
    note,
    noteShort,
    ...activity(now),
  };
}

// Tokens per hour over the last 24 hours: the bars on the page.
function activity(now) {
  const top = Math.floor(now / HOUR) * HOUR;
  const values = Array.from({ length: 24 }, (_, i) => scan.hours[top - (23 - i) * HOUR] || 0);
  const total = values.reduce((a, b) => a + b, 0);
  return { activity: values, hasActivity: total > 0, activityTotal: format.compact(total) };
}

function readJSON(path) {
  const text = files.read(path);
  if (!text) return null;
  try { return JSON.parse(text); } catch (e) { return null; }
}

const MOODS = {
  working: { key: "working", color: "orange" },
  waiting: { key: "waiting", color: "yellow" },
  idle: { key: "idle", color: "secondary" },
};

// Bridge: working if any session is (recently) working, else waiting, else idle.
function hookMood(state, now) {
  const sessions = Object.values(state.sessions || {});
  const fresh = (s, maxAge) => now - (s.at || 0) < maxAge;
  if (sessions.some((s) => s.state === "working" && fresh(s, 600))) return MOODS.working;
  if (sessions.some((s) => s.state === "waiting" && fresh(s, HOUR))) return MOODS.waiting;
  return MOODS.idle;
}

// ---- Session logs ----
//
// Read in chunks from where we stopped, so a regular refresh() parses only new lines.
// Tokens are summed per hour (for the 5-hour window and the week); per file we keep the last message — the crab comes from it.

const scan = {
  ready: false,
  files: {},      // path → { off, size, modified, last }
  hours: {},      // start of the hour (s) → tokens
  seen: [],       // ids of recent messages: one reply is written as several lines with the same usage
  model: "",
  loaded: false,
};

const CHUNK = 1024 * 1024;

async function scanLogs(now) {
  if (!scan.loaded) restore();
  const started = Date.now();
  const logs = listLogs(now);
  scan.logs = logs.length;
  let pending = false, chunks = 0;
  for (const log of logs) {
    let f = scan.files[log.path];
    if (!f || log.size < f.off) {
      // A new or rewritten file is read from the start. An unknown one that hasn't changed since the last full count
      // is already counted (storage doesn't fit every file), so it's skipped.
      const counted = !f && scan.countedAt && log.modified <= scan.countedAt;
      f = scan.files[log.path] = { off: counted ? log.size : 0, last: null };
    }
    f.size = log.size;
    f.modified = log.modified;
    while (f.off < log.size) {
      // The rest next time (but at least one chunk per call, so the count always moves).
      if (chunks > 0 && Date.now() - started > 3000) { pending = true; break; }
      chunks++;
      const part = files.lines(log.path, { offset: f.off, length: CHUNK });
      if (!part || part.next <= f.off) break;
      digest(f, part.lines, now);
      f.off = part.next;
      await sleep(0); // a separate slice of synchronous code per megabyte
    }
    if (pending) break;
    // After an app restart the last message is unknown: take it from the file's tail.
    if (!f.last && now - log.modified < HOUR) {
      const tail = files.lines(log.path, { offset: Math.max(0, log.size - 256 * 1024), length: 256 * 1024 });
      if (tail) digest(f, tail.lines, now, false);
    }
  }
  // Forget what's older than a week.
  const alive = new Set(logs.map((l) => l.path));
  for (const path of Object.keys(scan.files)) if (!alive.has(path)) delete scan.files[path];
  for (const h of Object.keys(scan.hours)) if (Number(h) < now - WEEK - HOUR) delete scan.hours[h];
  if (scan.seen.length > 400) scan.seen = scan.seen.slice(-200);
  scan.ready = !pending;
  if (scan.ready) scan.countedAt = now;
  save();
}

// *.jsonl from the last week, newest first (their state matters most). Subfolders are subagent sessions.
function listLogs(now) {
  const out = [];
  const walk = (dir, depth) => {
    for (const e of files.list(dir) || []) {
      const path = dir + e.name;
      if (e.dir) { if (depth < 3) walk(path + "/", depth + 1); }
      else if (e.name.endsWith(".jsonl") && now - e.modified < WEEK) out.push({ path, size: e.size, modified: e.modified });
    }
  };
  ROOTS.forEach((root) => walk(root, 0));
  return out.sort((a, b) => b.modified - a.modified);
}

function digest(f, lines, now, count = true) {
  let last = null;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!MESSAGE.test(line)) continue; // service records (attachment, mode, …) aren't parsed
    let e;
    try { e = JSON.parse(line); } catch (err) { continue; }
    if (e.type !== "assistant" && e.type !== "user") continue;
    if (e.isMeta) continue;
    const at = Date.parse(e.timestamp) / 1000 || 0;
    const m = e.message || {};
    last = { type: e.type, at, blocks: blockTypes(m.content), stop: m.stop_reason || null };
    if (count && e.type === "assistant" && m.usage && m.id && !scan.seen.includes(m.id)) {
      scan.seen.push(m.id);
      if (now - at < WEEK + HOUR) {
        const u = m.usage;
        // Cache reads are cheap and huge; not counted, or the numbers would mean nothing.
        const tokens = (u.input_tokens || 0) + (u.output_tokens || 0) + (u.cache_creation_input_tokens || 0);
        const h = Math.floor(at / HOUR) * HOUR;
        scan.hours[h] = (scan.hours[h] || 0) + tokens;
      }
      if (m.model && m.model !== "<synthetic>" && at >= (scan.modelAt || 0)) { scan.model = m.model; scan.modelAt = at; }
    }
  }
  if (last) f.last = last;
}

function blockTypes(content) {
  if (typeof content === "string") return [content.startsWith("[Request interrupted") ? "interrupt" : "text"];
  if (!Array.isArray(content)) return [];
  return content.map((b) => {
    if (b.type === "tool_use") return QUESTION_TOOLS.includes(b.name) ? "question" : "tool_use";
    if (b.type === "text" && String(b.text).startsWith("[Request interrupted")) return "interrupt";
    return b.type;
  });
}

const MESSAGE = /"type":\s*"(assistant|user)"/;
const QUESTION_TOOLS = ["AskUserQuestion", "ExitPlanMode"];

// The mood from the last messages of sessions changed within the last hour.
function logMood(now) {
  let best = MOODS.idle;
  for (const f of Object.values(scan.files)) {
    if (!f.last || now - f.modified > HOUR) continue;
    const m = sessionMood(f.last, now - f.modified);
    if (m === MOODS.working) return m;
    if (m === MOODS.waiting) best = m;
  }
  return best;
}

function sessionMood(last, quiet) {
  const b = last.blocks;
  if (b.includes("interrupt")) return MOODS.idle;
  if (last.type === "user") return quiet < 600 ? MOODS.working : MOODS.idle; // a prompt or a tool result
  if (b.includes("question")) return MOODS.waiting;                         // Claude asked a question
  if (b.includes("tool_use")) {
    // A tool was requested with no result yet: either still running or waiting for permission. The log can't tell,
    // so a long silence counts as waiting (the bridge knows for sure).
    return quiet < 45 ? MOODS.working : MOODS.waiting;
  }
  if (last.stop === "end_turn" || last.stop === "stop_sequence" || last.stop === "max_tokens") return MOODS.idle;
  return quiet < 600 ? MOODS.working : MOODS.idle; // still thinking / writing the reply
}

// The current 5-hour window, as Claude counts it: starts at the first message (to the hour) and lasts 5 hours;
// the next message after it ends opens a new one. The chain of windows is built over the whole stored week.
function currentBlock(now) {
  const hours = Object.keys(scan.hours).map(Number).sort((a, b) => a - b);
  let start = null;
  for (const h of hours) if (start === null || h >= start + 5 * HOUR) start = h;
  if (start === null || now >= start + 5 * HOUR) return { tokens: 0, resetsAt: null };
  let tokens = 0;
  for (const h of hours) if (h >= start) tokens += scan.hours[h];
  return { tokens, resetsAt: start + 5 * HOUR };
}

function lastWeek(now) {
  let tokens = 0;
  for (const [h, t] of Object.entries(scan.hours)) if (Number(h) > now - WEEK) tokens += t;
  return { tokens, resetsAt: null, weekly: true };
}

function tokenWindow(w, budget, now) {
  const hasBudget = budget > 0;
  const share = hasBudget ? Math.min(1, w.tokens / budget) : 0;
  return {
    has: true,
    bar: hasBudget,
    pct: hasBudget ? `${Math.round((w.tokens / budget) * 100)}%` : tokensText(w.tokens),
    value: share,
    color: hasBudget ? levelColor(share * 100) : "primary",
    reset: [hasBudget ? t("tokensShort", { n: tokensText(w.tokens) }) : t("tokens"),
      w.resetsAt ? "≈ " + resetText(w.resetsAt, now, false) : w.weekly ? t("last7") : ""].filter(Boolean).join(" · "),
  };
}

function tokensText(n) {
  return format.compact(n);
}

function prettyModel(id) {
  const m = /^claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?:-\d{8})?(\[1m\])?$/.exec(id || "");
  if (!m) return id || "";
  return `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2]}${m[3] ? "." + m[3] : ""}`;
}

// The counters survive an app restart (storage), so a week of logs isn't read again.
function restore() {
  scan.loaded = true;
  const saved = storage.get("scan");
  // The first count didn't finish: offsets aren't stored for every file, so starting over is safer.
  if (!saved || saved.v !== 1 || !saved.countedAt) return;
  scan.hours = saved.hours || {};
  scan.seen = saved.seen || [];
  scan.model = saved.model || "";
  scan.modelAt = saved.modelAt || 0;
  scan.countedAt = saved.countedAt || 0;
  for (const [path, off] of Object.entries(saved.offsets || {})) scan.files[path] = { off, last: null };
}

let savedJSON = "";
function save() {
  const offsets = {};
  // At most the 150 newest files, to fit into 64 KB of storage.
  Object.entries(scan.files).sort((a, b) => (b[1].modified || 0) - (a[1].modified || 0)).slice(0, 150)
    .forEach(([path, f]) => { offsets[path] = f.off; });
  const data = { v: 1, hours: scan.hours, seen: scan.seen.slice(-200), model: scan.model, modelAt: scan.modelAt, offsets };
  const json = JSON.stringify(data);
  if (json === savedJSON) return; // nothing new: don't write to disk every 5 s
  storage.set("scan", { ...data, countedAt: scan.countedAt || 0 });
  savedJSON = json;
}

// ---- Official limits (bridge) ----

function limitWindow(w, now, weekly) {
  if (!w) return { pct: "—", value: 0, color: "secondary", reset: "", has: false, bar: false };
  const pct = Math.max(0, Math.min(100, Number(w.used_percentage) || 0));
  return {
    has: true,
    bar: true,
    pct: `${Math.round(pct)}%`,
    value: pct / 100,
    color: levelColor(pct),
    reset: w.resets_at ? resetText(w.resets_at, now, weekly) : "",
  };
}

function levelColor(pct) { return pct < 50 ? "green" : pct < 80 ? "orange" : "red"; }

function resetText(at, now, weekly) {
  const left = at - now;
  if (left <= 0) return t("reset.done");
  if (!weekly || left < 86400) return t("reset.in", { x: format.duration(Math.floor(left / 60) * 60) });
  const d = new Date(at * 1000);
  const day = new Intl.DateTimeFormat(format.lang, { weekday: "short" }).format(d).replace(/\.$/, "");
  return t("reset.at", { day, time: format.time(d) });
}

// ---- Mascot: an orange pixel crab, drawn in code (14×11 cells). ----

function mascot(mood) {
  if (mood === "working") {
    // Scurrying: legs alternate, body bobs, a spark flickers above.
    return { fps: 6, frames: [
      crab({ walk: 0, bob: 0, spark: 1 }), crab({ walk: 1, bob: 1, spark: 0 }),
      crab({ walk: 0, bob: 0, spark: 2 }), crab({ walk: 1, bob: 1, spark: 0 }),
    ] };
  }
  if (mood === "waiting") {
    // Waving one claw with a "!" above.
    return { fps: 3, frames: [
      crab({ wave: 1, bang: true }), crab({ wave: 0, bang: true }),
      crab({ wave: 1, bang: false }), crab({ wave: 0, bang: true }),
    ] };
  }
  // Sleeping: eyes shut, slow breathing, z's drifting up.
  return { fps: 1.5, frames: [
    crab({ sleep: true, bob: 0, z: 0 }), crab({ sleep: true, bob: 1, z: 1 }),
    crab({ sleep: true, bob: 0, z: 2 }), crab({ sleep: true, bob: 1, z: 1 }),
  ] };
}

function crab(o) {
  const W = 14, H = 11;
  const g = Array.from({ length: H }, () => Array(W).fill("."));
  const px = (x, y, c) => { if (x >= 0 && x < W && y >= 0 && y < H) g[y][x] = c; };
  const dy = o.bob || 0;

  for (let y = 3; y < 8; y++) for (let x = 2; x < 12; x++) px(x, y + dy, "o"); // body
  for (let x = 3; x < 11; x++) px(x, 2 + dy, "o");                            // rounded top

  // Claws: the left one waves when waiting.
  const left = o.wave ? 2 + dy : 5 + dy;
  px(0, left, "o"); px(1, left, "o"); if (o.wave) px(0, left - 1, "o");
  px(12, 5 + dy, "o"); px(13, 5 + dy, "o");

  if (o.sleep) { px(4, 5 + dy, "k"); px(5, 5 + dy, "k"); px(8, 5 + dy, "k"); px(9, 5 + dy, "k"); }
  else { px(4, 4 + dy, "k"); px(4, 5 + dy, "k"); px(9, 4 + dy, "k"); px(9, 5 + dy, "k"); }

  // Four legs; when walking, every other one lifts.
  [3, 5, 8, 10].forEach((x, i) => {
    const lifted = o.walk !== undefined && (i + o.walk) % 2 === 0;
    px(x, 8 + dy, "d");
    if (!lifted && 9 + dy < H) px(x, 9 + dy, "d");
  });

  if (o.spark === 1) { px(12, 1, "y"); px(13, 0, "y"); }
  if (o.spark === 2) { px(1, 0, "y"); px(2, 1, "y"); }
  if (o.bang) { px(7, 0, "y"); px(7, 1, "y"); }
  if (o.z !== undefined) { // a 3×3 "z" floating in the free top-left corner
    const zy = o.z === 1 ? 0 : 1;
    px(0, zy, "w"); px(1, zy, "w"); px(2, zy, "w");
    px(1, zy + 1, "w");
    px(0, zy + 2, "w"); px(1, zy + 2, "w"); px(2, zy + 2, "w");
  }
  return g.map((row) => row.join(""));
}


