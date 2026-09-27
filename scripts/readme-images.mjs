#!/usr/bin/env node
// Builds the README pictures (docs/images/*.png) from real Simulator screenshots made by scripts/screenshots.sh
// (or published by CI to the branch screenshots/<branch>):
//
//   git clone -b screenshots/main --depth 1 https://github.com/flywalk4/phonescreen.git /tmp/shots
//   node scripts/readme-images.mjs /tmp/shots        # needs Playwright (npm i -g playwright)

import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const OUT = path.join(ROOT, "docs/images");
const shots = path.resolve(process.argv[2] || "screenshots");
const list = (dir) => (fs.existsSync(path.join(shots, dir)) ? fs.readdirSync(path.join(shots, dir)).filter((f) => f.endsWith(".png")).sort() : []);
const png = (file) => `data:image/png;base64,${fs.readFileSync(path.join(shots, file)).toString("base64")}`;
// English captions for the README (the widgets themselves speak Russian).
const ENGLISH = {
  "com.flywalk4.air": "Air quality", "com.flywalk4.claude-code": "Claude Code", "com.flywalk4.focus": "Focus",
  "com.flywalk4.game2048": "2048", "com.flywalk4.github": "GitHub", "com.flywalk4.hackernews": "Hacker News",
  "com.flywalk4.markets": "Markets", "com.flywalk4.memory": "Memory", "com.flywalk4.minesweeper": "Minesweeper",
  "com.flywalk4.month": "Month", "com.flywalk4.rain": "Rain", "com.flywalk4.rates": "Rates", "com.flywalk4.sky": "Sun & Moon",
  "com.flywalk4.tictactoe": "Tic-tac-toe", "com.flywalk4.time": "Time", "com.flywalk4.wallpaper": "Live wallpaper",
  "com.flywalk4.worldclock": "World clock", "com.flywalk4.winter": "Winter", "com.flywalk4.rainy": "Rainy evening",
};
const name = (id) => {
  if (ENGLISH[id]) return ENGLISH[id];
  const f = path.join(ROOT, "catalog/widgets", id, "manifest.json");
  const t = path.join(ROOT, "catalog/themes", id, "theme.json");
  return fs.existsSync(f) ? JSON.parse(fs.readFileSync(f, "utf8")).name : fs.existsSync(t) ? JSON.parse(fs.readFileSync(t, "utf8")).name : id;
};

// Mixed pages are numbered after the single-widget pages; group the files by page number.
const pageFiles = list("pages");
const numbers = [...new Set(pageFiles.map((f) => Number(f.match(/-(\d+)\.png$/)[1])))].sort((a, b) => a - b);
const page = (theme, n) => (pageFiles.includes(`${theme}-${n}.png`) ? `pages/${theme}-${n}.png` : null);

function phones(items, { width, caption = true }) {
  return items.filter((i) => i.file).map((i) => `<figure style="width:${width}px">
    <div class="phone"><img src="${png(i.file)}"></div>${caption && i.label ? `<figcaption>${i.label}</figcaption>` : ""}</figure>`).join("");
}

function html(body, { columns, width }) {
  return `<!doctype html><meta charset=utf-8><style>
  body{margin:0;background:radial-gradient(120% 90% at 20% 0%,#2b2f5a 0%,#12131c 55%,#0b0b10 100%);font:600 20px 'Liberation Sans',Helvetica,sans-serif;color:#c9cbe0}
  .wrap{display:grid;grid-template-columns:repeat(${columns},${width}px);gap:36px 30px;padding:48px;justify-content:center;width:max-content}
  figure{margin:0}
  .phone{border-radius:${width * 0.14}px;padding:${width * 0.028}px;background:linear-gradient(145deg,#3a3b44,#15161b);box-shadow:0 24px 60px rgba(0,0,0,.55),inset 0 0 0 1.5px rgba(255,255,255,.12)}
  .phone img{display:block;width:100%;border-radius:${width * 0.115}px}
  figcaption{text-align:center;margin-top:14px;letter-spacing:.2px}
  </style><div class="wrap">${body}</div>`;
}

async function render(file, body, opts) {
  const require = createRequire(import.meta.url);
  const { chromium } = require(path.join(execSync("npm root -g").toString().trim(), "playwright"));
  const exe = ["/opt/pw-browsers/chromium-1194/chrome-linux/chrome"].find((p) => fs.existsSync(p));
  const browser = await chromium.launch(exe ? { executablePath: exe } : {});
  const tab = await browser.newPage({ viewport: { width: 400, height: 300 }, deviceScaleFactor: 2 });
  await tab.setContent(html(body, opts));
  const box = await tab.locator(".wrap").boundingBox();
  await tab.setViewportSize({ width: Math.ceil(box.width), height: Math.ceil(box.height) });
  await tab.waitForTimeout(100);
  await tab.screenshot({ path: path.join(OUT, file), fullPage: true });
  await browser.close();
  console.log(`docs/images/${file}`);
}

fs.mkdirSync(OUT, { recursive: true });
const first = numbers[0];
const THEMES = [["dark", "Dark"], ["glass", "Liquid Glass"], ["light", "Light"], ["ascii", "ASCII"]];

// Hero: the same page in the four built-in themes.
await render("hero.png", phones(THEMES.map(([t, label]) => ({ file: page(t, first), label })), { width: 300 }), { columns: 4, width: 300 });

// Widgets: every catalog widget on its own page.
const widgets = list("widgets").map((f) => ({ file: `widgets/${f}`, label: name(f.replace(/\.png$/, "")) }));
await render("widgets.png", phones(widgets, { width: 230 }), { columns: Math.min(6, widgets.length), width: 230 });

// Pages: each mixed page, cycling through the themes.
const mixed = numbers.map((n, i) => ({ file: page(THEMES[i % 4][0], n) || page("dark", n), label: "" }));
await render("pages.png", phones(mixed, { width: 260, caption: false }), { columns: Math.min(3, mixed.length), width: 260 });

// Catalog themes.
const themes = list("catalog-themes").map((f) => ({ file: `catalog-themes/${f}`, label: name(f.replace(/\.png$/, "")) }));
await render("themes.png", phones(themes, { width: 230 }), { columns: Math.min(7, themes.length), width: 230 });
