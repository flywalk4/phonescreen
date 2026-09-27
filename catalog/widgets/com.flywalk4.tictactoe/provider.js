// Крестики-нолики: ты — ✕, Mac — ◯. Ходы приходят кнопками-клетками (action "tap:<0…8>").

const LINES = [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]];

async function refresh(ctx) {
  const g = load();
  const win = winner(g.board);
  const line = win ? win.line : [];
  const status = !win ? (g.board.includes("") ? "Твой ход" : "Ничья") : win.who === "x" ? "Ты победил!" : win.who === "o" ? "Mac победил" : "Ничья";
  const over = Boolean(win) || !g.board.includes("");
  return {
    cells: g.board.map((c, i) => ({
      mark: c === "x" ? "✕" : c === "o" ? "◯" : " ",
      color: c === "x" ? "orange" : "blue",
      bg: line.includes(i) ? "green" : "primary",
      opacity: line.includes(i) ? 0.3 : 0.07,
      action: `tap:${i}`,
    })),
    status: over && !win ? "Ничья" : status,
    statusColor: !over ? "primary" : win && win.who === "x" ? "green" : win && win.who === "o" ? "red" : "secondary",
    over,
    you: String(g.score.x), mac: String(g.score.o), draws: String(g.score.d),
    level: { easy: "лёгкий", normal: "обычный", hard: "непобедимый" }[level(ctx)],
  };
}

async function action(name, ctx) {
  const g = load();
  if (name === "new") {
    g.board = Array(9).fill("");
    g.macFirst = !g.macFirst;
    g.counted = false;
    if (g.macFirst) g.board[macMove(g.board, level(ctx))] = "o";
  } else if (name.startsWith("tap:")) {
    const i = Number(name.slice(4));
    if (winner(g.board) || !g.board.includes("") || g.board[i] !== "") return;
    g.board[i] = "x";
    if (!winner(g.board) && g.board.includes("")) g.board[macMove(g.board, level(ctx))] = "o";
  }
  const w = winner(g.board);
  if (!g.counted && (w || !g.board.includes(""))) {
    g.score[w ? w.who : "d"] += 1;
    g.counted = true;
  }
  storage.set("game", g);
}

function load() {
  return storage.get("game") || { board: Array(9).fill(""), score: { x: 0, o: 0, d: 0 }, macFirst: false, counted: false };
}

function level(ctx) {
  const l = (ctx.settings.level || "normal").trim().toLowerCase();
  return ["easy", "normal", "hard"].includes(l) ? l : "normal";
}

function winner(b) {
  for (const line of LINES) {
    const [a, c, d] = line;
    if (b[a] && b[a] === b[c] && b[a] === b[d]) return { who: b[a], line };
  }
  return null;
}

// Ход Mac: easy — случайно, normal — иногда ошибается, hard — минимакс без ошибок.
function macMove(b, lvl) {
  const free = b.map((c, i) => (c ? -1 : i)).filter((i) => i >= 0);
  const random = () => free[Math.floor(Math.random() * free.length)];
  if (lvl === "easy" && Math.random() < 0.7) return random();
  if (lvl === "normal" && Math.random() < 0.25) return random();
  let best = -Infinity, move = free[0];
  for (const i of free) {
    b[i] = "o";
    const score = minimax(b, false, 0);
    b[i] = "";
    if (score > best) { best = score; move = i; }
  }
  return move;
}

function minimax(b, macTurn, depth) {
  const w = winner(b);
  if (w) return w.who === "o" ? 10 - depth : depth - 10;
  if (!b.includes("")) return 0;
  let best = macTurn ? -Infinity : Infinity;
  for (let i = 0; i < 9; i++) {
    if (b[i]) continue;
    b[i] = macTurn ? "o" : "x";
    const s = minimax(b, !macTurn, depth + 1);
    b[i] = "";
    best = macTurn ? Math.max(best, s) : Math.min(best, s);
  }
  return best;
}
