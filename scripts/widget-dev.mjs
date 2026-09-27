#!/usr/bin/env node
// Widget development without a Mac: runs provider.js in an emulation of the app's sandbox (Node), resolves
// view.json the way WidgetTemplate.swift does, draws an approximate PNG mock, and runs the widgets' fixtures.
//
//   node scripts/widget-dev.mjs run <widget> [--fixture NAME] [--setting k=v] [--secret k=v] [--action NAME]…
//                                            [--now 2026-09-27T14:40:00Z] [--home DIR] [--views]
//   node scripts/widget-dev.mjs preview <widget> out.png [--theme dark|light|glass|ascii|catalog/themes/<id>] [--fixture NAME]
//   node scripts/widget-dev.mjs test [<widget>…]        # every fixtures/*.json of every widget (default: catalog/widgets/*)
//   node scripts/widget-dev.mjs bundle demo.json [--theme catalog/themes/<id>]  # all widgets + pages for the phone's
//                                                        # `--demo --demo-bundle demo.json` (screenshots of the real UI)
//
// The real check is still `PhoneScreen --widget-test` on a Mac (JavaScriptCore, the real sandbox and SwiftUI);
// this emulation mirrors the sandbox API and limits closely enough to catch script, template and layout mistakes.
//
// Fixture (catalog/widgets/<id>/fixtures/<name>.json; the app never downloads these):
//   { "description": "…", "now": "2026-09-27T14:40:00Z", "settings": {}, "secrets": {}, "storage": {},
//     "files": { "~/path/file": "text" | ["line", …] },          // read-only home for permissions.files
//     "fileAge": { "~/path/file": 30 },                            // seconds since it changed (default 0)
//     "timezone": "Europe/Moscow",                                 // default UTC
//     "fetch": [ { "match": "regex on the URL", "status": 200, "body": {…} | "text" } ],
//     "actions": ["tap:4", …],                                    // pressed before the final refresh()
//     "expect": { "data.path": value | "/regex/" }, "error": "text the failure must contain" }

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const MAX_FILE = 1024 * 1024, MAX_STORAGE = 64 * 1024, MAX_RESPONSE = 2 * 1024 * 1024;
const MAX_NODES = 500, MAX_TEXT = 2000;

// ---------------------------------------------------------------- sandbox

/** Loads a widget into a fresh sandbox. Everything the script can touch comes from `options`. */
export function sandbox(dir, options = {}) {
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
  const perms = manifest.permissions || {};
  const logs = [];
  const log = (line) => { logs.push(line); if (options.verbose) console.error("log:", line); };
  let store = structuredClone(options.storage || {});

  // Time: frozen start that keeps ticking, so timers and "now" behave.
  const shift = options.now ? Date.parse(options.now) - Date.now() : 0;
  const RealDate = Date;
  class FakeDate extends RealDate {
    constructor(...a) { if (a.length) super(...a); else super(RealDate.now() + shift); }
    static now() { return RealDate.now() + shift; }
  }

  // Files: a temporary home with the fixture's files; only permissions.files, symlinks can't escape.
  const home = options.home || fs.mkdtempSync(path.join(os.tmpdir(), "widget-home-"));
  for (const [p, content] of Object.entries(options.files || {})) {
    const abs = path.join(home, p.replace(/^~\//, ""));
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, Array.isArray(content) ? content.join("\n") + "\n" : content);
    const t = (RealDate.now() + shift) / 1000 - (options.fileAge?.[p] ?? 0); // «изменён N секунд назад» по часам фикстуры
    fs.utimesSync(abs, t, t);
  }
  const realHome = fs.realpathSync(home);
  const declared = perms.files || [];
  const allows = (p) => p.startsWith("~/") && !p.split("/").includes("..") && declared.some((e) => (e.endsWith("/") ? p.startsWith(e) : p === e));
  const fileURL = (p) => {
    p = String(p);
    if (!allows(p)) { log(`files: ${p} не разрешён — добавьте путь в permissions.files`); return null; }
    const abs = path.join(home, p.slice(2));
    let real; try { real = fs.realpathSync(abs); } catch { return abs; }
    const inside = declared.some((e) => { const full = realHome + "/" + e.slice(2); return e.endsWith("/") ? (real + "/").startsWith(full) : real === full; });
    if (!inside) { log(`files: ${p} ведёт за пределы разрешённых путей`); return null; }
    return real;
  };
  const files = Object.freeze({
    read(p) { const u = fileURL(p); if (!u) return null; try { const b = fs.readFileSync(u); if (b.length > MAX_FILE) { log(`files.read: ${p} больше 1 МБ`); return null; } return b.toString("utf8"); } catch { return null; } },
    modified(p) { const u = fileURL(p); if (!u) return null; try { return fs.statSync(u).mtimeMs / 1000; } catch { return null; } },
    lines(p, o = {}) {
      const u = fileURL(p); if (!u) return null;
      let fd; try { fd = fs.openSync(u, "r"); } catch { return null; }
      try {
        const size = fs.fstatSync(fd).size, start = Math.min(Math.max(0, Number(o.offset) || 0), size);
        const limit = Math.min(Math.max(1, Number(o.length) || MAX_FILE), MAX_FILE);
        const buf = Buffer.alloc(limit), n = fs.readSync(fd, buf, 0, limit, start), data = buf.subarray(0, n);
        let end = data.lastIndexOf(10) + 1;
        if (end === 0 && n === limit) end = n; // one giant line: step over this piece
        let lines = data.subarray(0, end).toString("utf8").split("\n").filter(Boolean);
        if (end === n && data[n - 1] !== 10) lines = [];
        return { lines, next: start + end, size };
      } finally { fs.closeSync(fd); }
    },
    list(p) {
      const u = fileURL(p); if (!u) return null;
      try {
        return fs.readdirSync(u).filter((n) => !n.startsWith(".")).slice(0, 2000).map((name) => {
          const s = fs.statSync(path.join(u, name));
          return { name, dir: s.isDirectory(), size: s.size, modified: s.mtimeMs / 1000 };
        });
      } catch { return null; }
    },
  });

  // Network: HTTPS to declared hosts only, answered from the fixture.
  const fetched = [];
  const network = perms.network || [];
  async function fetch(url, opts = {}) {
    url = String(url);
    let host; try { host = new URL(url).hostname.toLowerCase(); } catch { host = ""; }
    if (!url.startsWith("https://") || !network.some((h) => host === h || host.endsWith("." + h))) {
      throw new Error(`fetch: ${url} не разрешён — добавьте хост в permissions.network (только HTTPS)`);
    }
    fetched.push(url);
    const mock = (options.fetch || []).find((m) => new RegExp(m.match).test(decodeURIComponent(url)));
    if (!mock) throw new Error(`fetch: в фикстуре нет ответа для ${url}`);
    const text = typeof mock.body === "string" ? mock.body : JSON.stringify(mock.body ?? null);
    if (text.length > MAX_RESPONSE) throw new Error("fetch: ответ больше 2 МБ");
    const status = mock.status ?? 200, headers = Object.fromEntries(Object.entries(mock.headers || {}).map(([k, v]) => [k.toLowerCase(), String(v)]));
    return { status, ok: status >= 200 && status < 300, headers: { get: (k) => headers[String(k).toLowerCase()] ?? null }, text: async () => text, json: async () => JSON.parse(text) };
  }

  const secretKeys = new Set((perms.secrets || []).map((s) => s.key));
  const context = vm.createContext({
    console: Object.freeze({
      log: (...a) => log(a.map(String).join(" ")), warn: (...a) => log("warn: " + a.map(String).join(" ")), error: (...a) => log("error: " + a.map(String).join(" ")),
    }),
    secrets: Object.freeze({ get: (k) => (secretKeys.has(String(k)) ? options.secrets?.[k] ?? null : null) }),
    storage: Object.freeze({
      get: (k) => (String(k) in store ? structuredClone(store[String(k)]) : null),
      set: (k, v) => {
        const next = { ...store };
        if (v === null || v === undefined) delete next[String(k)]; else next[String(k)] = JSON.parse(JSON.stringify(v));
        if (JSON.stringify(next).length > MAX_STORAGE) { log(`storage: превышен лимит ${MAX_STORAGE / 1024} КБ, значение не сохранено`); return; }
        store = next;
      },
    }),
    files, fetch,
    setTimeout: (fn, ms) => setTimeout(fn, Math.max(0, Math.min(Number(ms) || 0, 60000))),
    sleep: (ms) => new Promise((r) => setTimeout(r, Math.max(0, Math.min(Number(ms) || 0, 60000)))),
    Date: FakeDate,
  });
  vm.runInContext(fs.readFileSync(path.join(dir, "provider.js"), "utf8"), context, { filename: "provider.js", timeout: 2000 });

  const settings = {};
  for (const s of manifest.settings || []) settings[s.key] = options.settings?.[s.key] ?? s.default ?? "";
  const call = async (fn, args) => {
    if (typeof context[fn] !== "function") { if (fn === "refresh") throw new Error("В provider.js нет функции refresh()"); return null; }
    const started = RealDate.now();
    const value = await Promise.race([
      Promise.resolve(context[fn](...args, { settings })),
      new Promise((_, reject) => setTimeout(() => reject(new Error("Скрипт не ответил за 20 с")), 20000).unref()),
    ]);
    const took = RealDate.now() - started;
    if (took > 1500 && fetched.length === 0) log(`warn: ${fn}() занял ${took} мс — в приложении на синхронный код даётся 2 с`);
    return JSON.parse(JSON.stringify(value ?? null));
  };
  return {
    manifest, settings, logs, fetched, home,
    get storage() { return store; },
    refresh: () => call("refresh", []),
    action: (name) => call("action", [name]),
  };
}

// ---------------------------------------------------------------- template (a port of WidgetTemplate.swift)

const WHOLE = /^\s*\{\{\s*([^}]+?)\s*\}\}\s*$/, INLINE = /\{\{\s*([^}]+?)\s*\}\}/g;

function lookup(p, scope) {
  const parts = p.split(".");
  let cur = parts[0] === "item" || parts[0] === "index" ? scope[parts.shift()] : scope.$;
  for (const k of parts) {
    if (cur && typeof cur === "object" && !Array.isArray(cur)) cur = cur[k];
    else if (Array.isArray(cur) && /^\d+$/.test(k)) cur = cur[Number(k)];
    else return null;
  }
  return cur ?? null;
}
const text = (v) => (v == null ? "" : typeof v === "boolean" ? (v ? "да" : "нет") : typeof v === "object" ? JSON.stringify(v) : String(v));
const value = (raw, scope) => {
  if (typeof raw !== "string") return raw;
  const m = WHOLE.exec(raw);
  return m ? lookup(m[1], scope) : raw.replace(INLINE, (_, p) => text(lookup(p, scope)));
};
const number = (v) => (typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" && !isNaN(Number(v)) ? Number(v) : null);
const truthy = (v) => !(v == null || v === false || v === 0 || v === "" || v === "false" || v === "0" || (Array.isArray(v) && v.length === 0));
const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/** view.json template + data → resolved node tree, as the Mac sends it to the phone (shape: { type, …fields }). */
export function resolve(template, data) {
  const budget = { left: MAX_NODES };
  const out = node(template, { $: data }, budget);
  if (!out) throw new Error("Шаблон пустой");
  return out;
}

function node(t, scope, budget) {
  if (!t || typeof t !== "object" || Array.isArray(t)) throw new Error("Узел шаблона должен быть объектом");
  if ("if" in t && !truthy(value(t.if, scope))) return null;
  if (--budget.left < 0) throw new Error(`Слишком много элементов (больше ${MAX_NODES})`);
  const str = (k) => (k in t ? text(value(t[k], scope)) : undefined);
  const num = (k) => (k in t ? number(value(t[k], scope)) ?? undefined : undefined);
  const children = () => (t.children || []).map((c) => node(c, scope, budget)).filter(Boolean);
  const columns = (v) => clamp(Math.trunc(v ?? 2), 1, 6);
  switch (t.type) {
    case "vstack": case "hstack": return { type: t.type, spacing: num("spacing"), align: str("align"), children: children() };
    case "text": {
      const size = num("size");
      const font = size !== undefined || "weight" in t || "design" in t ? { size: size === undefined ? undefined : clamp(size, 6, 160), weight: str("weight"), design: str("design") } : undefined;
      return { type: "text", text: (str("text") ?? "").slice(0, MAX_TEXT), style: str("style"), color: str("color"), lines: num("lines"), align: str("align"), font };
    }
    case "symbol": return { type: "symbol", name: str("name") ?? "questionmark", color: str("color"), size: num("size") };
    case "gauge": return { type: "gauge", value: clamp(num("value") ?? 0, 0, 1), label: str("label"), color: str("color") };
    case "progress": return { type: "progress", value: clamp(num("value") ?? 0, 0, 1), color: str("color") };
    case "chart": {
      const values = (Array.isArray(value(t.values, scope)) ? value(t.values, scope) : []).map(number).filter((v) => v !== null).slice(-200);
      const h = num("height");
      return { type: "chart", values, color: str("color"), style: str("style"), height: h === undefined ? undefined : clamp(h, 20, 400) };
    }
    case "button": {
      const action = str("action");
      if (!action) throw new Error("У кнопки нет action");
      return { type: "button", title: str("title") ?? "", symbol: str("symbol"), action };
    }
    case "sprite": {
      const frames = (value(t.frames, scope) || []).slice(0, 16).filter(Array.isArray).map((f) => f.slice(0, 48).map((r) => text(r).slice(0, 48)));
      if (!frames.length) throw new Error("У sprite нет frames");
      const pal = value(t.palette, scope) || {};
      return { type: "sprite", frames, palette: Object.fromEntries(Object.entries(pal).map(([k, v]) => [k.slice(0, 1), text(v)])), fps: num("fps") };
    }
    case "spacer": case "divider": return { type: t.type };
    case "box": {
      const op = num("opacity"), asp = num("aspect"), action = str("action");
      return { type: "box", spacing: num("spacing"), align: str("align"), padding: num("padding"), background: str("background"),
               opacity: op === undefined ? undefined : clamp(op, 0, 1), radius: num("radius"), fit: "fit" in t ? truthy(value(t.fit, scope)) : undefined,
               action: action ? action.slice(0, 200) : undefined, aspect: asp === undefined ? undefined : clamp(asp, 0.2, 5), children: children() };
    }
    case "grid": return { type: "grid", columns: columns(num("columns")), spacing: num("spacing"), children: children() };
    case "list": {
      const items = value(t.items, scope);
      if (!t.template) throw new Error("У списка нет template");
      const rows = (Array.isArray(items) ? items : []).map((item, index) => node(t.template, { ...scope, item, index }, budget)).filter(Boolean);
      const n = num("columns");
      if (n !== undefined && n > 1) return { type: "grid", columns: columns(n), spacing: num("spacing"), children: rows };
      return { type: "vstack", spacing: num("spacing") ?? 6, align: str("align") ?? "leading", children: rows };
    }
    default: return null; // unknown type: skipped, like the app
  }
}

/** Resolved views for every size present in view.json. */
export function views(dir, data) {
  const view = JSON.parse(fs.readFileSync(path.join(dir, "view.json"), "utf8"));
  const out = {};
  for (const size of ["full", "medium", "small"]) {
    if (!view[size]) continue;
    try { out[size] = resolve(view[size], data); } catch (e) { throw new Error(`view.json (${size}): ${e.message}`); }
  }
  return out;
}

// ---------------------------------------------------------------- fixtures

export function fixtures(dir) {
  const folder = path.join(dir, "fixtures");
  if (!fs.existsSync(folder)) return [];
  return fs.readdirSync(folder).filter((f) => f.endsWith(".json")).sort()
    .map((f) => ({ name: f.replace(/\.json$/, ""), ...JSON.parse(fs.readFileSync(path.join(folder, f), "utf8")) }));
}

/** Runs one scenario: actions, then refresh() and view resolution. Returns { data, views, error, box }. */
export async function scenario(dir, fx = {}, extra = {}) {
  const tz = process.env.TZ;
  process.env.TZ = fx.timezone || "UTC"; // местное время в сценарии не зависит от машины
  const box = sandbox(dir, { ...fx, ...extra });
  try {
    for (const a of fx.actions || []) await box.action(a);
    const data = await box.refresh();
    return { data, views: views(dir, data), box };
  } catch (e) {
    return { error: e.message, box };
  } finally {
    if (!fx.home && !extra.home) fs.rmSync(box.home, { recursive: true, force: true });
    if (tz === undefined) delete process.env.TZ; else process.env.TZ = tz;
  }
}

function check(result, fx) {
  const problems = [];
  if (fx.error) {
    if (!result.error) problems.push(`ожидалась ошибка «${fx.error}», а refresh() прошёл`);
    else if (!result.error.includes(fx.error)) problems.push(`ошибка «${result.error}», ожидалась «${fx.error}»`);
    return problems;
  }
  if (result.error) return [result.error];
  for (const [p, want] of Object.entries(fx.expect || {})) {
    const got = lookup(p, { $: result.data });
    const ok = typeof want === "string" && want.length > 1 && want.startsWith("/") && want.endsWith("/")
      ? new RegExp(want.slice(1, -1)).test(text(got))
      : JSON.stringify(got) === JSON.stringify(want);
    if (!ok) problems.push(`${p}: ${JSON.stringify(got)}, ожидалось ${JSON.stringify(want)}`);
  }
  return problems;
}

// ---------------------------------------------------------------- preview (approximate HTML → PNG)

const THEMES = {
  dark: { bg: "#000", text: "#fff", sec: "#98989F", accent: "#0A84FF", card: "rgba(255,255,255,.07)", surface: "rgba(255,255,255,.07)", style: "flat", radius: 22 },
  light: { bg: "#F2F2F7", text: "#000", sec: "#6C6C70", accent: "#007AFF", card: "#fff", surface: "rgba(0,0,0,.05)", style: "flat", radius: 22 },
  glass: { bg: "linear-gradient(145deg,#1B2A6B,#6A2C8F,#0E7C86)", text: "#fff", sec: "rgba(255,255,255,.7)", accent: "#7FD4FF", card: "rgba(255,255,255,.12)", surface: "rgba(255,255,255,.14)", style: "glass", radius: 28 },
  ascii: { bg: "#050805", text: "#39FF14", sec: "#1FA30C", accent: "#39FF14", card: "transparent", surface: "transparent", style: "ascii", radius: 0 },
};
const SYSTEM = { red: "#FF453A", orange: "#FF9F0A", yellow: "#FFD60A", green: "#30D158", mint: "#63E6E2", teal: "#40C8E0", cyan: "#64D2FF", blue: "#0A84FF", indigo: "#5E5CE6", purple: "#BF5AF2", pink: "#FF375F", brown: "#AC8E68", gray: "#8E8E93", white: "#FFFFFF" };
const STYLES = { largeTitle: [34, 600], title: [28, 600], title2: [22, 600], title3: [20, 600], headline: [17, 600], body: [17, 400], callout: [16, 400], subheadline: [15, 400], footnote: [13, 400], caption: [12, 400], caption2: [11, 400] };
const WEIGHTS = { ultraLight: 200, thin: 250, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
// SF Symbols aren't available off Apple platforms: a few common ones as emoji, the rest as a dot.
const SYMBOLS = { "sun.max.fill": "☀️", "cloud.rain.fill": "🌧️", "cloud.snow.fill": "🌨️", "location.fill": "📍", globe: "🌐", "briefcase.fill": "💼", "moon.zzz.fill": "🌙", "moon.fill": "🌙", "sunset.fill": "🌇", "cup.and.saucer.fill": "☕", "chart.line.uptrend.xyaxis": "📈", "arrow.clockwise": "↻", sparkles: "✨", "dollarsign.arrow.circlepath": "💱", timer: "⏱️", "play.fill": "▶", "pause.fill": "⏸", "forward.fill": "⏭", "arrow.uturn.backward": "↩", "flame.fill": "🔥", "leaf.fill": "🍃", "aqi.medium": "🌫️", "sun.horizon.fill": "🌅", "newspaper.fill": "📰", hourglass: "⏳", "arrow.triangle.pull": "🔀", "flag.fill": "🚩", "hand.tap.fill": "👆", "exclamationmark.triangle.fill": "⚠️" };

/** A theme.json (folder or file) as the preview's colours. */
function themeFromFile(p) {
  const file = fs.statSync(p).isDirectory() ? path.join(p, "theme.json") : p;
  const t = JSON.parse(fs.readFileSync(file, "utf8"));
  const css = (hex) => { const m = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(hex || ""); if (!m) return null; const v = parseInt(m[1], 16);
    return `rgba(${v >> 16},${(v >> 8) & 255},${v & 255},${m[2] ? (parseInt(m[2], 16) / 255).toFixed(3) : 1})`; };
  const bg = t.background.colors.map(css);
  const text = css(t.colors.text), light = t.appearance === "light";
  return {
    bg: bg.length > 1 ? `linear-gradient(${180 - (t.background.angle || 0)}deg,${bg.join(",")})` : bg[0],
    text, sec: css(t.colors.secondary), accent: css(t.colors.accent),
    card: css(t.colors.card) || "transparent", surface: text.replace(/[\d.]+\)$/, "0.07)"), border: css(t.colors.border),
    style: t.style, radius: t.radius, light, font: t.font, palette: Object.fromEntries(Object.entries(t.colors.palette || {}).map(([k, v]) => [k.toLowerCase(), css(v)])),
  };
}

function renderHTML(tree, themeName) {
  const T = THEMES[themeName] || (themeName && fs.existsSync(themeName) ? themeFromFile(themeName) : THEMES.dark);
  if (T.light === undefined) T.light = T.text === "#000";
  const color = (n) => {
    if (!n) return null;
    const l = String(n).toLowerCase();
    if (T.palette?.[l]) return T.palette[l];
    if (l === "primary") return T.text;
    if (l === "secondary" || l === "tertiary") return T.sec;
    if (l === "accent") return T.accent;
    if (SYSTEM[l]) return themeName === "ascii" && !["red", "orange", "yellow"].includes(l) ? T.text : SYSTEM[l];
    return /^#[0-9a-f]{6}([0-9a-f]{2})?$/i.test(n) ? n : null;
  };
  const esc = (s) => String(s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;");
  const align = (a, def = "flex-start") => ({ leading: "flex-start", center: "center", trailing: "flex-end" })[a] || def;
  const r = (n) => {
    switch (n.type) {
      case "vstack": return `<div class="v" style="gap:${n.spacing ?? 8}px;align-items:${align(n.align, "center")}">${n.children.map(r).join("")}</div>`;
      case "hstack": return `<div class="h" style="gap:${n.spacing ?? 8}px;align-items:${({ top: "flex-start", bottom: "flex-end", baseline: "baseline" })[n.align] || "center"}">${n.children.map(r).join("")}</div>`;
      case "text": {
        const [size, weight] = STYLES[n.style] || STYLES.body;
        const fam = ({ monospaced: "DejaVu Sans Mono,monospace", serif: "Liberation Serif,serif", rounded: "DejaVu Sans,sans-serif" })[n.font?.design] || "inherit";
        const clamp = n.lines ? `display:-webkit-box;-webkit-line-clamp:${n.lines};-webkit-box-orient:vertical;overflow:hidden;` : "";
        return `<div class="t" style="font-size:${n.font?.size ?? size}px;font-weight:${WEIGHTS[n.font?.weight] ?? weight};font-family:${fam};color:${color(n.color) || T.text};text-align:${({ center: "center", trailing: "right" })[n.align] || "left"};${clamp}">${esc(n.text)}</div>`;
      }
      case "symbol": return `<span style="font-size:${n.size ?? 17}px;line-height:1;color:${color(n.color) || T.text}">${SYMBOLS[n.name] || "●"}</span>`;
      case "gauge": return `<div class="v" style="gap:4px;align-items:center"><svg width="56" height="56"><circle cx="28" cy="28" r="25" fill="none" stroke="${T.text}" stroke-opacity=".12" stroke-width="6"/><circle cx="28" cy="28" r="25" fill="none" stroke="${color(n.color) || T.accent}" stroke-width="6" stroke-linecap="round" stroke-dasharray="${157 * n.value} 999" transform="rotate(-90 28 28)"/><text x="28" y="32" text-anchor="middle" font-size="12" font-weight="600" fill="${T.text}">${Math.round(n.value * 100)}%</text></svg>${n.label ? `<div class="t" style="font-size:11px;color:${T.sec}">${esc(n.label)}</div>` : ""}</div>`;
      case "progress": {
        const c = color(n.color) || T.accent;
        if (T.style === "ascii") { const k = Math.round(24 * n.value); return `<div class="t mono" style="color:${c}">[${"#".repeat(k)}${".".repeat(24 - k)}]</div>`; }
        return `<div class="track"><div style="width:${n.value * 100}%;height:100%;border-radius:2px;background:${c}"></div></div>`;
      }
      case "chart": return chart(n.values, color(n.color) || T.accent, n.style || "line", n.height, T);
      case "button": return `<div class="button" style="color:${T.accent}">${SYMBOLS[n.symbol] ? SYMBOLS[n.symbol] + " " : ""}${esc(T.style === "ascii" ? `[ ${n.title} ]` : n.title)}</div>`;
      case "sprite": {
        const f = n.frames[0], cols = Math.max(...f.map((row) => row.length)), cell = 6;
        let px = "";
        f.forEach((row, y) => [...row].forEach((ch, x) => { const c = color(n.palette[ch]); if (c) px += `<rect x="${x * cell}" y="${y * cell}" width="${cell + 0.5}" height="${cell + 0.5}" fill="${c}"/>`; }));
        return `<svg width="${cols * cell}" height="${f.length * cell}" style="max-width:100%">${px}</svg>`;
      }
      case "spacer": return `<div class="sp"></div>`;
      case "divider": return T.style === "ascii" ? `<div class="t mono" style="color:${T.sec};overflow:hidden;white-space:nowrap;width:100%">${"-".repeat(80)}</div>` : `<div class="divider"></div>`;
      case "box": {
        const bg = color(n.background), radius = n.radius ?? Math.max(0, Math.min(T.radius - 6, 18));
        const surface = bg ? `background:${bg};opacity:${n.opacity ?? 1};` : T.style === "ascii" ? `border:1px dashed ${T.sec};` : `background:${T.surface};${T.style === "glass" ? "border:1px solid rgba(255,255,255,.2);" : ""}`;
        const shape = n.aspect ? `aspect-ratio:${n.aspect};justify-content:center;align-items:center;` : `align-items:${align(n.align)};`;
        return `<div class="v box ${n.fit ? "fit" : "fill"}" style="gap:${n.spacing ?? 6}px;padding:${n.padding ?? 12}px;${shape}"><div class="surface" style="border-radius:${radius}px;${surface}"></div>${n.children.map(r).join("")}</div>`;
      }
      case "grid": return `<div class="grid" style="grid-template-columns:repeat(${n.columns},minmax(0,1fr));gap:${n.spacing ?? 10}px">${n.children.map((c) => `<div class="v cell">${r(c)}</div>`).join("")}</div>`;
      default: return "";
    }
  };
  const card = (size, w, h, full) => `<div class="card${full ? " full" : ""}" style="width:${w}px;height:${h}px"><div class="inner">${tree[size] ? r(tree[size]) : ""}</div></div>`;
  const pick = (s) => (tree[s] ? s : s === "small" ? (tree.medium ? "medium" : "full") : s === "medium" ? (tree.full ? "full" : "small") : tree.medium ? "medium" : "small");
  const [F, M, S] = [pick("full"), pick("medium"), pick("small")];
  return `<!doctype html><meta charset=utf-8><style>
body{margin:0;background:#1c1c1e;font-family:${({ monospaced: "'DejaVu Sans Mono',monospace", serif: "'Liberation Serif',serif", rounded: "'DejaVu Sans',sans-serif" })[T.font] || "'Liberation Sans',Helvetica,sans-serif"};display:flex;gap:28px;padding:28px}
.phone{width:393px;height:852px;border-radius:54px;overflow:hidden;background:${T.bg};position:relative;box-shadow:0 0 0 10px #2c2c2e;flex-shrink:0}
.page{position:absolute;inset:62px 18px 18px 18px;display:flex;flex-direction:column;gap:12px}
.label{position:absolute;top:22px;width:100%;text-align:center;color:${T.sec};font-size:12px}
.v{display:flex;flex-direction:column;min-width:0;position:relative}.h{display:flex;width:100%;min-width:0}.t{line-height:1.2;min-width:0}
.mono{font-family:'DejaVu Sans Mono',monospace;font-size:12px}.sp{flex:1 1 0;min-width:0;min-height:0}
.h>.v{flex:0 1 auto}.v>.v{align-self:stretch}.h>.h{width:auto;flex:0 0 auto}.v>.box.fill{align-self:stretch}.h>.box.fill{flex:1 1 0}
.box.fit{flex:0 0 auto}.v>.box.fit{align-self:flex-start}.box>*:not(.surface){position:relative}.surface{position:absolute;inset:0}
.grid{display:grid;width:100%;align-items:start}.cell{align-items:stretch}
.track{width:100%;height:4px;border-radius:2px;background:${T.light ? "rgba(0,0,0,.1)" : "rgba(255,255,255,.18)"}}
.divider{height:1px;width:100%;background:${T.light ? "rgba(0,0,0,.12)" : "rgba(255,255,255,.15)"}}
.button{padding:7px 12px;border-radius:9px;background:${T.light ? "rgba(0,0,0,.06)" : "rgba(255,255,255,.12)"};font-size:15px;font-weight:500;white-space:nowrap;align-self:flex-start}
.card{border-radius:${T.radius}px;background:${T.card};${T.style === "glass" ? `border:1px solid ${T.border || "rgba(255,255,255,.22)"};backdrop-filter:blur(30px);` : T.border && T.style === "flat" ? `border:1px solid ${T.border};` : ""}${T.style === "ascii" ? `outline:1px dashed ${T.sec};` : ""}overflow:hidden;box-sizing:border-box;padding:14px;display:flex;${T.style === "ascii" ? "font-family:'DejaVu Sans Mono',monospace;" : ""}}
.card>.inner{display:flex;flex-direction:column;width:100%;height:100%;overflow:hidden}.card>.inner>.v{flex:1}
.card.full{background:none;border:none;outline:none;padding:18px 2px}
</style>
<div class="phone"><div class="label">full</div><div class="page">${card(F, 357, 772, true)}</div></div>
<div class="phone"><div class="label">medium ×2</div><div class="page" style="inset:92px 18px 48px">${card(M, 357, 350)}${card(M, 357, 350)}</div></div>
<div class="phone"><div class="label">small ×4</div><div class="page" style="inset:92px 18px 48px;display:grid;grid-template-columns:1fr 1fr">${[1, 2, 3, 4].map(() => card(S, 172, 350)).join("")}</div></div>`;
}

function chart(values, c, style, height, T) {
  if (values.length < 2) return "";
  const W = 300, H = height || 90;
  let lo = Math.min(...values), hi = Math.max(...values);
  if (T.style === "ascii") {
    const cols = 36, rows = 5, g = Array.from({ length: rows }, () => Array(cols).fill(" "));
    for (let x = 0; x < cols; x++) {
      const v = values[Math.round((x / (cols - 1)) * (values.length - 1))];
      const y = rows - 1 - Math.round((hi > lo ? (v - lo) / (hi - lo) : 0.5) * (rows - 1));
      g[y][x] = "*"; if (y < rows - 1) g[rows - 1][x] = ".";
    }
    return `<div class="t mono" style="color:${c};white-space:pre;line-height:1.1">${g.map((row) => row.join("")).join("\n")}</div>`;
  }
  if (style === "bar") {
    lo = Math.min(0, lo);
    const bw = W / values.length;
    return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:${H}px">${values.map((v, i) => { const h = ((v - lo) / (hi - lo || 1)) * H; return `<rect x="${i * bw + bw * 0.15}" y="${H - h}" width="${bw * 0.7}" height="${h}" rx="3" fill="${c}"/>`; }).join("")}</svg>`;
  }
  if (hi === lo) { hi += 1; lo -= 1; }
  const pts = values.map((v, i) => [(i / (values.length - 1)) * W, H - 4 - ((v - lo) / (hi - lo)) * (H - 8)]);
  const d = pts.map((p, i) => `${i ? "L" : "M"}${p[0].toFixed(1)},${p[1].toFixed(1)}`).join("");
  const id = `g${Math.random().toString(36).slice(2)}`;
  const area = style === "area" ? `<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${c}" stop-opacity=".45"/><stop offset="1" stop-color="${c}" stop-opacity=".02"/></linearGradient></defs><path d="${d}L${W},${H}L0,${H}Z" fill="url(#${id})"/>` : "";
  return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:${H}px">${area}<path d="${d}" fill="none" stroke="${c}" stroke-width="2.5" vector-effect="non-scaling-stroke" stroke-linejoin="round"/></svg>`;
}

async function screenshot(html, out) {
  let playwright;
  try {
    const require = createRequire(import.meta.url);
    try { playwright = require("playwright"); } catch { playwright = require(path.join(execSync("npm root -g").toString().trim(), "playwright")); }
  } catch {
    throw new Error("Для preview нужен Playwright с Chromium: npm i -g playwright && npx playwright install chromium");
  }
  const launch = process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {};
  const browser = await playwright.chromium.launch(launch);
  try {
    const page = await browser.newPage({ viewport: { width: 1320, height: 910 } });
    await page.setContent(html);
    await page.screenshot({ path: out });
  } finally { await browser.close(); }
}

// ---------------------------------------------------------------- CLI

function parseArgs(argv) {
  const args = { _: [], setting: {}, secret: {}, action: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { args._.push(a); continue; }
    const key = a.slice(2), next = () => argv[++i];
    if (key === "setting" || key === "secret") { const [k, ...v] = next().split("="); args[key][k] = v.join("="); }
    else if (key === "action") args.action.push(next());
    else if (key === "views" || key === "verbose") args[key] = true;
    else args[key] = next();
  }
  return args;
}

function widgetDir(p) {
  const dir = path.resolve(p);
  if (!fs.existsSync(path.join(dir, "manifest.json"))) throw new Error(`${p}: это не папка виджета (нет manifest.json)`);
  return dir;
}

function fixtureFor(dir, args) {
  const all = fixtures(dir);
  let fx = {};
  if (args.fixture) {
    fx = all.find((f) => f.name === args.fixture);
    if (!fx) throw new Error(`нет фикстуры «${args.fixture}» (есть: ${all.map((f) => f.name).join(", ") || "никаких"})`);
  }
  return {
    ...fx,
    settings: { ...(fx.settings || {}), ...args.setting },
    secrets: { ...(fx.secrets || {}), ...args.secret },
    actions: [...(fx.actions || []), ...args.action],
    now: args.now || fx.now,
    home: args.home,
    verbose: args.verbose,
  };
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  if (command === "run") {
    const dir = widgetDir(args._[0] || ".");
    const result = await scenario(dir, fixtureFor(dir, args));
    for (const line of result.box.logs) console.error("log:", line);
    if (result.error) { console.error(`FAIL ${result.error}`); process.exit(1); }
    console.log(JSON.stringify(args.views ? { data: result.data, views: result.views } : result.data, null, 2));
    console.log("OK");
  } else if (command === "preview") {
    const [w, out] = args._;
    if (!w || !out) throw new Error("preview <widget> <out.png> [--theme dark|light|glass|ascii] [--fixture NAME]");
    const dir = widgetDir(w);
    const result = await scenario(dir, fixtureFor(dir, args));
    if (result.error) { console.error(`FAIL ${result.error}`); process.exit(1); }
    await screenshot(renderHTML(result.views, args.theme || "dark"), out);
    console.log(`${out}: примерный макет (шрифт и значки не как на iPhone)`);
  } else if (command === "bundle") {
    // Every catalog widget with data from its first successful fixture, plus pages — for `--demo-bundle` on the phone.
    const out = args._[0];
    if (!out) throw new Error("bundle <out.json> [--theme catalog/themes/<id>]");
    const dirs = fs.readdirSync(path.join(ROOT, "catalog/widgets")).sort().map((d) => path.join(ROOT, "catalog/widgets", d));
    const widgets = [];
    for (const dir of dirs) {
      const list = fixtures(dir).filter((f) => !f.error);
      const fx = list.find((f) => f.name === "ok") || list[0] || {};
      const result = await scenario(dir, fx);
      if (result.error) { console.error(`✗ ${path.basename(dir)}: ${result.error}`); continue; }
      const m = result.box.manifest;
      widgets.push({ id: m.id, name: m.name, symbol: m.symbol, view: JSON.parse(fs.readFileSync(path.join(dir, "view.json"), "utf8")), data: result.data });
    }
    const ids = new Set(widgets.map((w) => w.id));
    const ref = (id) => (ids.has(`com.flywalk4.${id}`) ? `custom:com.flywalk4.${id}` : id);
    const pages = [
      ...widgets.map((w) => ({ layout: "single", widgets: [`custom:${w.id}`] })),
      { layout: "grid", widgets: ["markets", "time", "air", "focus"].map(ref) },
      { layout: "trio", widgets: ["claude-code", "sky", "rates"].map(ref) },
      { layout: "split", widgets: ["rain", "hackernews"].map(ref) },
      { layout: "grid", widgets: ["tictactoe", "game2048", "memory", "minesweeper"].map(ref) },
      { layout: "grid", widgets: ["music", "weather", "calendar", "monitor"] },
    ];
    const bundle = { widgets, pages };
    if (args.theme) {
      const file = fs.statSync(args.theme).isDirectory() ? path.join(args.theme, "theme.json") : args.theme;
      bundle.theme = JSON.parse(fs.readFileSync(file, "utf8"));
    }
    fs.writeFileSync(out, JSON.stringify(bundle));
    console.log(`${out}: ${widgets.length} виджетов, ${pages.length} страниц (страница N = --page N)`);
    pages.forEach((p, i) => console.log(`  ${i}: ${p.layout} ${p.widgets.join(", ")}`));
  } else if (command === "test") {
    const dirs = args._.length ? args._.map(widgetDir)
      : fs.readdirSync(path.join(ROOT, "catalog/widgets")).map((d) => path.join(ROOT, "catalog/widgets", d)).filter((d) => fs.existsSync(path.join(d, "manifest.json")));
    let failed = 0, total = 0;
    for (const dir of dirs.sort()) {
      const list = fixtures(dir);
      if (!list.length) { console.log(`- ${path.basename(dir)}: нет fixtures/`); continue; }
      for (const fx of list) {
        total++;
        const problems = check(await scenario(dir, fx), fx);
        if (problems.length) { failed++; console.log(`✗ ${path.basename(dir)} · ${fx.name}`); problems.forEach((p) => console.log(`    ${p}`)); }
        else console.log(`✓ ${path.basename(dir)} · ${fx.name}`);
      }
    }
    console.log(failed ? `${failed} из ${total} сценариев не прошли` : `OK: ${total} сценариев`);
    process.exit(failed ? 1 : 0);
  } else {
    console.error(fs.readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 9).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    process.exit(2);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(`FAIL ${e.message}`); process.exit(1); });
