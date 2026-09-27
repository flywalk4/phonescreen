// Сапёр 8×8. Кнопки: tap:<0…63> — открыть (или поставить флажок в режиме флажков), mode — переключить режим, new.

const N = 8;
const NUMBER_COLORS = ["", "blue", "green", "red", "indigo", "brown", "teal", "primary", "gray"];

async function refresh(ctx) {
  const g = load(ctx);
  const now = Date.now() / 1000;
  const cells = [];
  for (let i = 0; i < N * N; i++) {
    const open = g.open[i], mine = g.mines.includes(i), flag = g.flags[i];
    const boom = g.status === "lost" && mine;
    let text = "", color = "primary";
    if (open && !mine) { const n = around(g, i); text = n ? String(n) : ""; color = NUMBER_COLORS[n] || "primary"; }
    if (boom) text = i === g.hit ? "💥" : "💣";
    else if (flag) text = "🚩";
    cells.push({
      text, color, action: `tap:${i}`,
      bg: boom && i === g.hit ? "red" : open ? "primary" : "gray",
      opacity: boom && i === g.hit ? 0.5 : open ? 0.04 : 0.45,
    });
  }
  const flags = g.flags.filter(Boolean).length;
  const time = g.started ? Math.round((g.ended || now) - g.started) : 0;
  return {
    cells,
    minesLeft: String(g.mines.length - flags),
    time: clock(time),
    best: g.best != null ? clock(g.best) : "—",
    modeTitle: g.flagMode ? "Режим: флажки" : "Режим: открывать",
    modeSymbol: g.flagMode ? "flag.fill" : "hand.tap.fill",
    face: g.status === "won" ? "😎" : g.status === "lost" ? "😵" : "🙂",
    status: g.status === "won" ? "Все мины найдены!" : g.status === "lost" ? "Бум! Попробуй ещё" : g.started ? "Осторожно…" : "Первый ход безопасен",
    statusColor: g.status === "won" ? "green" : g.status === "lost" ? "red" : "secondary",
  };
}

async function action(name, ctx) {
  const g = load(ctx);
  if (name === "new") return storage.set("game", fresh(mineCount(ctx), g.best));
  if (name === "mode") { g.flagMode = !g.flagMode; return storage.set("game", g); }
  if (!name.startsWith("tap:") || g.status !== "playing") return;
  const i = Number(name.slice(4));
  if (g.open[i]) return;
  if (g.flagMode) { g.flags[i] = !g.flags[i]; return storage.set("game", g); }
  if (g.flags[i]) return; // флажок защищает клетку от случайного нажатия
  if (!g.started) { placeMines(g, i); g.started = Date.now() / 1000; }
  if (g.mines.includes(i)) { g.status = "lost"; g.hit = i; g.ended = Date.now() / 1000; }
  else flood(g, i);
  if (g.status === "playing" && g.open.filter(Boolean).length === N * N - g.mines.length) {
    g.status = "won"; g.ended = Date.now() / 1000;
    const t = Math.round(g.ended - g.started);
    g.best = g.best != null ? Math.min(g.best, t) : t;
    g.mines.forEach((m) => { g.flags[m] = true; });
  }
  storage.set("game", g);
}

function mineCount(ctx) { return Math.min(20, Math.max(5, Number(ctx.settings.mines) || 10)); }

function load(ctx) {
  const g = storage.get("game");
  return g && g.open ? g : fresh(mineCount(ctx), null);
}

function fresh(count, best) {
  return { count, mines: [], open: Array(N * N).fill(false), flags: Array(N * N).fill(false),
           status: "playing", flagMode: false, started: 0, ended: 0, hit: -1, best };
}

// Мины расставляются после первого нажатия, мимо него и его соседей.
function placeMines(g, safe) {
  const banned = new Set([safe, ...neighbours(safe)]);
  const free = Array.from({ length: N * N }, (_, i) => i).filter((i) => !banned.has(i));
  for (let k = 0; k < g.count && free.length; k++) g.mines.push(free.splice(Math.floor(Math.random() * free.length), 1)[0]);
}

function neighbours(i) {
  const r = Math.floor(i / N), c = i % N, out = [];
  for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) {
    const rr = r + dr, cc = c + dc;
    if ((dr || dc) && rr >= 0 && rr < N && cc >= 0 && cc < N) out.push(rr * N + cc);
  }
  return out;
}

function around(g, i) { return neighbours(i).filter((j) => g.mines.includes(j)).length; }

function flood(g, start) {
  const stack = [start];
  while (stack.length) {
    const i = stack.pop();
    if (g.open[i] || g.mines.includes(i)) continue;
    g.open[i] = true; g.flags[i] = false;
    if (around(g, i) === 0) stack.push(...neighbours(i));
  }
}

function clock(s) { return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`; }
