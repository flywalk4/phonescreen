// Лимиты Claude Code и его состояние. Данные пишет мост (scripts/claude-code-bridge.py):
//   ~/.claude/phonescreen/status.json — rate_limits из статусной строки Claude Code (Pro/Max)
//   ~/.claude/phonescreen/state.json  — что делает каждая сессия: working / waiting / idle (хуки)

const DIR = "~/.claude/phonescreen/";

async function refresh(ctx) {
  const status = readJSON(DIR + "status.json");
  if (!status) {
    throw new Error("Мост не установлен. В репозитории PhoneScreen: python3 scripts/claude-code-bridge.py install");
  }
  const now = Date.now() / 1000;
  const mood = currentMood(readJSON(DIR + "state.json"), status, now);
  const limits = status.rate_limits || {};

  return {
    mood: mood.key,
    moodText: mood.text,
    moodColor: mood.color,
    mascot: mascot(mood.key),
    model: status.model || "",
    hasLimits: Boolean(limits.five_hour || limits.seven_day),
    noLimits: !(limits.five_hour || limits.seven_day),
    five: limitWindow(limits.five_hour, now, false),
    week: limitWindow(limits.seven_day, now, true),
  };
}

function readJSON(path) {
  const text = files.read(path);
  if (!text) return null;
  try { return JSON.parse(text); } catch (e) { return null; }
}

// Working if any session is working (recently), else waiting, else idle.
function currentMood(state, status, now) {
  const sessions = Object.values((state && state.sessions) || {});
  const fresh = (s, maxAge) => now - (s.at || 0) < maxAge;
  if (sessions.some((s) => s.state === "working" && fresh(s, 600))) return MOODS.working;
  if (sessions.some((s) => s.state === "waiting" && fresh(s, 3600))) return MOODS.waiting;
  // No hooks yet: a status line update in the last 20 s also means Claude is busy.
  if (!state && status && now - status.at < 20) return MOODS.working;
  return MOODS.idle;
}

const MOODS = {
  working: { key: "working", text: "Claude работает", color: "orange" },
  waiting: { key: "waiting", text: "Ждёт тебя", color: "yellow" },
  idle: { key: "idle", text: "Отдыхает", color: "secondary" },
};

function limitWindow(w, now, weekly) {
  if (!w) return { pct: "—", value: 0, color: "secondary", reset: "", has: false };
  const pct = Math.max(0, Math.min(100, Number(w.used_percentage) || 0));
  return {
    has: true,
    pct: `${Math.round(pct)}%`,
    value: pct / 100,
    color: pct < 50 ? "green" : pct < 80 ? "orange" : "red",
    reset: w.resets_at ? resetText(w.resets_at, now, weekly) : "",
  };
}

function resetText(at, now, weekly) {
  const left = at - now;
  if (left <= 0) return "сброшен";
  const h = Math.floor(left / 3600), m = Math.floor((left % 3600) / 60);
  if (!weekly || left < 86400) return `сброс через ${h > 0 ? `${h} ч ` : ""}${m} мин`;
  const d = new Date(at * 1000);
  const days = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"];
  return `сброс в ${days[d.getDay()]} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
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


