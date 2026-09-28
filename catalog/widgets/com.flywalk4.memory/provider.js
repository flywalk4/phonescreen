// Find the pairs: 4×4 cards. tap:<0…15> flips a card; a mismatched pair closes on the next tap.

const SETS = {
  animals: ["🦊", "🐼", "🐸", "🦉", "🐙", "🦁", "🐧", "🦄"],
  food: ["🍕", "🍣", "🍩", "🥑", "🍓", "🌮", "🧀", "🍉"],
  space: ["🚀", "🪐", "🌙", "⭐", "☄️", "🛸", "🌍", "👩‍🚀"],
};

async function refresh(ctx) {
  const g = load(ctx);
  const done = g.matched.every(Boolean);
  return {
    cards: g.cards.map((c, i) => {
      const shown = g.matched[i] || g.open.includes(i);
      const wrong = g.open.length === 2 && g.cards[g.open[0]] !== g.cards[g.open[1]] && g.open.includes(i);
      return {
        face: shown ? c : "?",
        faceColor: shown ? "primary" : "accent",
        bg: g.matched[i] ? "green" : wrong ? "red" : shown ? "primary" : "accent",
        opacity: g.matched[i] ? 0.22 : wrong ? 0.3 : shown ? 0.1 : 0.25,
        action: `tap:${i}`,
      };
    }),
    moves: String(g.moves),
    pairs: t("pairsOf", { n: g.matched.filter(Boolean).length / 2, total: 8 }),
    movesLine: t("movesLine", { n: g.moves }),
    best: g.best != null ? t("moves", { n: g.best }) : t("noBest"),
    done,
    status: done ? t("done", { n: g.moves }) : g.open.length === 2 && g.cards[g.open[0]] !== g.cards[g.open[1]] ? t("mismatch") : t("findAll"),
    statusColor: done ? "green" : "secondary",
  };
}

async function action(name, ctx) {
  let g = load(ctx);
  if (name === "new") g = fresh(ctx, g.best);
  else if (name.startsWith("tap:")) {
    const i = Number(name.slice(4));
    if (g.open.length === 2) g.open = []; // a mismatched pair closes on the next tap
    if (!g.matched[i] && !g.open.includes(i)) {
      g.open.push(i);
      if (g.open.length === 2) {
        g.moves += 1;
        const [a, b] = g.open;
        if (g.cards[a] === g.cards[b]) { g.matched[a] = g.matched[b] = true; g.open = []; }
        if (g.matched.every(Boolean)) g.best = g.best != null ? Math.min(g.best, g.moves) : g.moves;
      }
    }
  }
  storage.set("game", g);
}

function load(ctx) {
  const g = storage.get("game");
  if (g && g.cards && g.set === setName(ctx)) return g;
  const created = fresh(ctx, g ? g.best : null); // saved at once so the layout doesn't change between refreshes
  storage.set("game", created);
  return created;
}

function setName(ctx) { const s = (ctx.settings.set || "animals").trim().toLowerCase(); return SETS[s] ? s : "animals"; }

function fresh(ctx, best) {
  const set = setName(ctx);
  const cards = [...SETS[set], ...SETS[set]];
  for (let i = cards.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [cards[i], cards[j]] = [cards[j], cards[i]]; }
  return { set, cards, open: [], matched: Array(16).fill(false), moves: 0, best };
}
