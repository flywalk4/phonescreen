// 2048 on a 4×4 board. Buttons: left, right, up, down, new. The best score and the game live in storage.

const COLORS = { // value → [background, text]
  2: ["#EEE4DA", "#776E65"], 4: ["#EDE0C8", "#776E65"], 8: ["#F2B179", "#FFFFFF"], 16: ["#F59563", "#FFFFFF"],
  32: ["#F67C5F", "#FFFFFF"], 64: ["#F65E3B", "#FFFFFF"], 128: ["#EDCF72", "#FFFFFF"], 256: ["#EDCC61", "#FFFFFF"],
  512: ["#EDC850", "#FFFFFF"], 1024: ["#EDC53F", "#FFFFFF"], 2048: ["#EDC22E", "#FFFFFF"],
};

async function refresh() {
  const g = load();
  return {
    tiles: g.grid.map((v) => ({
      text: v ? String(v) : "",
      bg: v ? (COLORS[v] || ["#3C3A32"])[0] : "#CDC1B4",
      opacity: v ? 1 : 0.35,
      color: v ? (COLORS[v] || [0, "#FFFFFF"])[1] : "#CDC1B4",
      size: v >= 1024 ? 22 : v >= 128 ? 26 : 32,
      sizeSmall: v >= 1024 ? 10 : v >= 128 ? 12 : 15,
    })),
    score: String(g.score), best: String(g.best),
    over: g.over, won: g.won && !g.over,
    status: g.over ? t("over") : g.won ? t("won") : t("bestTile", { n: Math.max(...g.grid) }),
    statusColor: g.over ? "red" : g.won ? "orange" : "secondary",
  };
}

async function action(name) {
  let g = load();
  if (name === "new") g = fresh(g.best);
  else if (["left", "right", "up", "down"].includes(name) && !g.over) {
    const moved = move(g, name);
    if (moved) { addTile(g.grid); g.over = !canMove(g.grid); }
  }
  g.best = Math.max(g.best, g.score);
  storage.set("game", g);
}

// A new game is saved at once: otherwise the screen shows one random board and the first move lands on another.
function load() {
  let g = storage.get("game");
  if (!g) { g = fresh(0); storage.set("game", g); }
  return g;
}

function fresh(best) {
  const g = { grid: Array(16).fill(0), score: 0, best, over: false, won: false };
  addTile(g.grid); addTile(g.grid);
  return g;
}

function addTile(grid) {
  const empty = grid.map((v, i) => (v ? -1 : i)).filter((i) => i >= 0);
  if (empty.length) grid[empty[Math.floor(Math.random() * empty.length)]] = Math.random() < 0.9 ? 2 : 4;
}

// Cell indices of each line in the order tiles slide towards them.
function lines(dir) {
  const out = [];
  for (let k = 0; k < 4; k++) {
    const line = [];
    for (let j = 0; j < 4; j++) {
      if (dir === "left") line.push(k * 4 + j);
      if (dir === "right") line.push(k * 4 + 3 - j);
      if (dir === "up") line.push(j * 4 + k);
      if (dir === "down") line.push((3 - j) * 4 + k);
    }
    out.push(line);
  }
  return out;
}

function move(g, dir) {
  let moved = false;
  for (const line of lines(dir)) {
    const values = line.map((i) => g.grid[i]).filter(Boolean);
    const merged = [];
    for (let i = 0; i < values.length; i++) {
      if (values[i] === values[i + 1]) {
        const v = values[i] * 2;
        merged.push(v); g.score += v; if (v === 2048) g.won = true;
        i++;
      } else merged.push(values[i]);
    }
    line.forEach((cell, j) => {
      const v = merged[j] || 0;
      if (g.grid[cell] !== v) moved = true;
      g.grid[cell] = v;
    });
  }
  return moved;
}

function canMove(grid) {
  if (grid.includes(0)) return true;
  for (let i = 0; i < 16; i++) {
    if (i % 4 < 3 && grid[i] === grid[i + 1]) return true;
    if (i < 12 && grid[i] === grid[i + 4]) return true;
  }
  return false;
}
