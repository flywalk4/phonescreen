// Помодоро: работа → перерыв → работа…, длинный перерыв после каждых N помидоров.
// Состояние в storage, так что таймер переживает перезапуск приложения. Кнопки: toggle, reset, skip.

const PHASES = {
  focus: { title: "Работа", icon: "flame.fill", color: "orange" },
  short: { title: "Перерыв", icon: "cup.and.saucer.fill", color: "green" },
  long: { title: "Длинный перерыв", icon: "leaf.fill", color: "teal" },
};

async function refresh(ctx) {
  const cfg = config(ctx.settings);
  const s = advance(load(cfg), cfg, Date.now() / 1000);
  save(s);

  const total = cfg[s.phase] * 60;
  const left = Math.max(0, s.running ? s.endsAt - Date.now() / 1000 : s.left);
  const phase = PHASES[s.phase];
  const goal = cfg.goal;
  return {
    phase: phase.title, icon: phase.icon, color: phase.color,
    time: clock(left),
    minutes: `${Math.ceil(left / 60)} мин`,
    progress: 1 - left / total,
    running: s.running,
    paused: !s.running && left < total,
    idle: !s.running && left >= total,
    toggleTitle: s.running ? "Пауза" : left < total ? "Продолжить" : "Старт",
    toggleSymbol: s.running ? "pause.fill" : "play.fill",
    until: s.running ? `закончится в ${hhmm(new Date(s.endsAt * 1000))}` : s.justFinished ? s.justFinished
      : left < total ? "на паузе" : "нажми «Старт», когда будешь готов",
    done: s.done,
    goal,
    dots: Array.from({ length: Math.max(goal, s.done) }, (_, i) => (i < s.done ? "●" : "○")).join(" "),
    goalProgress: Math.min(1, s.done / goal),
    focusTime: minutesText(s.done * cfg.focus),
    next: nextText(s, cfg),
  };
}

async function action(name, ctx) {
  const cfg = config(ctx.settings);
  const now = Date.now() / 1000;
  const s = advance(load(cfg), cfg, now);
  s.justFinished = "";
  if (name === "toggle") {
    if (s.running) { s.left = Math.max(0, s.endsAt - now); s.running = false; }
    else { s.endsAt = now + s.left; s.running = true; }
  } else if (name === "reset") {
    s.running = false; s.left = cfg[s.phase] * 60;
  } else if (name === "skip") {
    finish(s, cfg, false);
  }
  save(s);
}

function config(settings) {
  const n = (k, d, min, max) => Math.min(max, Math.max(min, Number(settings[k]) || d));
  return { focus: n("focus", 25, 1, 180), short: n("short", 5, 1, 60), long: n("long", 15, 1, 120),
           every: n("every", 4, 1, 12), goal: n("goal", 8, 1, 24) };
}

function today() { const d = new Date(); return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`; }

function load(cfg) {
  const s = storage.get("pomodoro") || { phase: "focus", running: false, left: cfg.focus * 60, endsAt: 0, done: 0, day: today(), justFinished: "" };
  if (s.day !== today()) { s.day = today(); s.done = 0; } // новый день — новый счёт
  if (!s.running && s.left > cfg[s.phase] * 60) s.left = cfg[s.phase] * 60; // длительность уменьшили в настройках
  return s;
}

function save(s) { storage.set("pomodoro", s); }

// Если время фазы вышло — переходим к следующей и ждём нажатия «Старт».
function advance(s, cfg, now) {
  if (s.running && now >= s.endsAt) finish(s, cfg, true);
  return s;
}

function finish(s, cfg, natural) {
  if (s.phase === "focus") {
    if (natural) s.done += 1;
    s.phase = s.done > 0 && s.done % cfg.every === 0 ? "long" : "short";
    s.justFinished = natural ? "Помидор готов — отдохни" : "";
  } else {
    s.phase = "focus";
    s.justFinished = natural ? "Перерыв окончен" : "";
  }
  s.running = false;
  s.left = cfg[s.phase] * 60;
}

function nextText(s, cfg) {
  if (s.phase !== "focus") return `дальше: работа ${cfg.focus} мин`;
  const long = (s.done + 1) % cfg.every === 0;
  return `дальше: ${long ? "длинный перерыв" : "перерыв"} ${long ? cfg.long : cfg.short} мин`;
}

function clock(sec) { const m = Math.floor(sec / 60), s = Math.floor(sec % 60); return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`; }
function hhmm(d) { return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; }
function minutesText(m) { return m >= 60 ? `${Math.floor(m / 60)} ч ${m % 60 ? `${m % 60} мин` : ""}`.trim() : `${m} мин`; }
