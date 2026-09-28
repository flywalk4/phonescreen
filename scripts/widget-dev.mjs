#!/usr/bin/env node
// Widget development without a Mac: runs provider.js in an emulation of the app's sandbox (Node), resolves
// view.json the way WidgetTemplate.swift does, draws an approximate PNG mock, and runs the widgets' fixtures.
//
//   node scripts/widget-dev.mjs new com.you.widget [--name "Name"] [--dir catalog/widgets]  # a working starter widget
//   node scripts/widget-dev.mjs watch <widget> [--theme …] [--fixture NAME]   # re-run + re-render preview.png on save
//   node scripts/widget-dev.mjs run <widget> [--fixture NAME] [--setting k=v] [--secret k=v] [--action NAME]…
//                                            [--now 2026-09-27T14:40:00Z] [--home DIR] [--views]
//   node scripts/widget-dev.mjs preview <widget> out.png [--theme dark|light|glass|ascii|all|catalog/themes/<id>] [--fixture NAME]
//   node scripts/widget-dev.mjs test [<widget>…]        # every fixtures/*.json of every widget (default: catalog/widgets/*)
//   --lang en with run / preview / watch / bundle: the widget in that language (strings.json); a fixture may set "lang"
//   node scripts/widget-dev.mjs bundle demo.json [--theme catalog/themes/<id>]  # all widgets + pages for the phone's
//                                                        # `--demo --demo-bundle demo.json` (screenshots of the real UI)
//
// The real check is still `Qwovi --widget-test` on a Mac (JavaScriptCore, the real sandbox and SwiftUI);
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

/**
 * A widget's strings.json ({"ru": {…}, "en": {…}}) for `wanted`: that language if the widget has it, else English,
 * else its first language; the fallback language's keys fill any gaps. Mirrors WidgetStrings.swift.
 */
export function strings(dir, wanted = "en") {
  const file = path.join(dir, "strings.json");
  const all = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
  const langs = Object.keys(all);
  const lang = langs.includes(wanted) ? wanted : langs.includes("en") ? "en" : langs[0] || wanted;
  const fallback = langs.includes("en") ? "en" : langs[0];
  return { lang: langs.length ? lang : wanted, table: { ...(all[fallback] || {}), ...(all[lang] || {}) }, all };
}

/** Loads a widget into a fresh sandbox. Everything the script can touch comes from `options`. */
export function sandbox(dir, options = {}) {
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "manifest.json"), "utf8"));
  const { lang, table } = strings(dir, options.lang || "en");
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
    const t = (RealDate.now() + shift) / 1000 - (options.fileAge?.[p] ?? 0); // "modified N seconds ago" by the fixture's clock
    fs.utimesSync(abs, t, t);
  }
  const realHome = fs.realpathSync(home);
  const declared = perms.files || [];
  const allows = (p) => p.startsWith("~/") && !p.split("/").includes("..") && declared.some((e) => (e.endsWith("/") ? p.startsWith(e) : p === e));
  const fileURL = (p) => {
    p = String(p);
    if (!allows(p)) { log(`files: ${p} is not allowed — add the path to permissions.files`); return null; }
    const abs = path.join(home, p.slice(2));
    let real; try { real = fs.realpathSync(abs); } catch { return abs; }
    const inside = declared.some((e) => { const full = realHome + "/" + e.slice(2); return e.endsWith("/") ? (real + "/").startsWith(full) : real === full; });
    if (!inside) { log(`files: ${p} leads outside the allowed paths`); return null; }
    return real;
  };
  const files = Object.freeze({
    read(p) { const u = fileURL(p); if (!u) return null; try { const b = fs.readFileSync(u); if (b.length > MAX_FILE) { log(`files.read: ${p} is over 1 MB`); return null; } return b.toString("utf8"); } catch { return null; } },
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
      throw new Error(`fetch: ${url} is not allowed — add the host to permissions.network (HTTPS only)`);
    }
    fetched.push(url);
    const mock = (options.fetch || []).find((m) => new RegExp(m.match).test(decodeURIComponent(url)));
    if (!mock) throw new Error(`fetch: the fixture has no answer for ${url}`);
    const text = typeof mock.body === "string" ? mock.body : JSON.stringify(mock.body ?? null);
    if (text.length > MAX_RESPONSE) throw new Error("fetch: the answer is over 2 MB");
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
        if (JSON.stringify(next).length > MAX_STORAGE) { log(`storage: over the ${MAX_STORAGE / 1024} KB limit, the value wasn't saved`); return; }
        store = next;
      },
    }),
    files, fetch,
    setTimeout: (fn, ms) => setTimeout(fn, Math.max(0, Math.min(Number(ms) || 0, 60000))),
    sleep: (ms) => new Promise((r) => setTimeout(r, Math.max(0, Math.min(Number(ms) || 0, 60000)))),
    Date: FakeDate,
    __lang: lang,
    __strings: table,
  });
  vm.runInContext(fs.readFileSync(path.join(ROOT, "Mac/Widgets/prelude.js"), "utf8"), context, { filename: "prelude.js" });
  vm.runInContext(fs.readFileSync(path.join(dir, "provider.js"), "utf8"), context, { filename: "provider.js", timeout: 2000 });

  const settings = {};
  for (const s of manifest.settings || []) settings[s.key] = options.settings?.[s.key] ?? s.default ?? "";
  const call = async (fn, args) => {
    if (typeof context[fn] !== "function") { if (fn === "refresh") throw new Error("provider.js has no refresh() function"); return null; }
    const started = RealDate.now();
    const value = await Promise.race([
      Promise.resolve(context[fn](...args, { settings, lang })),
      new Promise((_, reject) => setTimeout(() => reject(new Error("The script didn't answer within 20 s")), 20000).unref()),
    ]);
    const took = RealDate.now() - started;
    if (took > 1500 && fetched.length === 0) log(`warn: ${fn}() took ${took} ms — the app allows 2 s of synchronous code`);
    return JSON.parse(JSON.stringify(value ?? null));
  };
  return {
    manifest, settings, logs, fetched, home, lang, strings: table,
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
const text = (v) => (v == null ? "" : typeof v === "boolean" ? (v ? "yes" : "no") : typeof v === "object" ? JSON.stringify(v) : String(v));
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
  if (!out) throw new Error("The template is empty");
  return out;
}

function node(t, scope, budget) {
  if (!t || typeof t !== "object" || Array.isArray(t)) throw new Error("A template node must be an object");
  if ("if" in t && !truthy(value(t.if, scope))) return null;
  if (--budget.left < 0) throw new Error(`Too many elements (over ${MAX_NODES})`);
  const str = (k) => (k in t ? text(value(t[k], scope)) : undefined);
  const num = (k) => (k in t ? number(value(t[k], scope)) ?? undefined : undefined);
  const children = () => (t.children || []).map((c) => node(c, scope, budget)).filter(Boolean);
  const columns = (v) => clamp(Math.trunc(v ?? 2), 1, 16);
  switch (t.type) {
    case "vstack": case "hstack": return { type: t.type, spacing: num("spacing"), align: str("align"), children: children() };
    case "text": {
      const size = num("size");
      const font = size !== undefined || "weight" in t || "design" in t ? { size: size === undefined ? undefined : clamp(size, 6, 160), weight: str("weight"), design: str("design") } : undefined;
      return { type: "text", text: (str("text") ?? "").slice(0, MAX_TEXT), style: str("style"), color: str("color"), lines: num("lines"), align: str("align"), font };
    }
    case "symbol": return { type: "symbol", name: str("name") ?? "questionmark", color: str("color"), size: num("size") };
    case "gauge": return { type: "gauge", value: clamp(num("value") ?? 0, 0, 1), label: str("label"), color: str("color"), text: str("text"), fill: "fill" in t ? truthy(value(t.fill, scope)) : undefined };
    case "progress": return { type: "progress", value: clamp(num("value") ?? 0, 0, 1), color: str("color") };
    case "chart": {
      const values = (Array.isArray(value(t.values, scope)) ? value(t.values, scope) : []).map(number).filter((v) => v !== null).slice(-200);
      const h = num("height");
      return { type: "chart", values, color: str("color"), style: str("style"), height: h === undefined ? undefined : clamp(h, 20, 400) };
    }
    case "button": {
      const action = str("action");
      if (!action) throw new Error("The button has no action");
      return { type: "button", title: str("title") ?? "", symbol: str("symbol"), action, color: str("color") };
    }
    case "sprite": {
      const frames = (value(t.frames, scope) || []).slice(0, 16).filter(Array.isArray).map((f) => f.slice(0, 48).map((r) => text(r).slice(0, 48)));
      if (!frames.length) throw new Error("The sprite has no frames");
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
    case "layers": return { type: "layers", align: str("align"), children: children() };
    case "scene": {
      const list = (k) => (Array.isArray(value(t[k], scope)) ? value(t[k], scope).slice(0, 6).map((c) => text(value(c, scope))) : undefined);
      const sp = num("speed");
      return { type: "scene", kind: str("kind") ?? "aurora", colors: list("colors"), tints: list("tints"), speed: sp === undefined ? undefined : clamp(sp, 0.1, 5) };
    }
    case "list": {
      const items = value(t.items, scope);
      if (!t.template) throw new Error("The list has no template");
      const rows = (Array.isArray(items) ? items : []).map((item, index) => node(t.template, { ...scope, item, index }, budget)).filter(Boolean);
      const n = num("columns");
      if (n !== undefined && n > 1) return { type: "grid", columns: columns(n), spacing: num("spacing"), children: rows };
      return { type: "vstack", spacing: num("spacing") ?? 6, align: str("align") ?? "leading", children: rows };
    }
    default: return null; // unknown type: skipped, like the app
  }
}

/** The data view.json sees: refresh()'s result plus `t` — the widget's strings — for `{{t.key}}` (like the app). */
export function withStrings(data, table) {
  return data && typeof data === "object" && !Array.isArray(data) && table && Object.keys(table).length ? { ...data, t: table } : data;
}

/** Resolved views for every size present in view.json. */
export function views(dir, data, table = {}) {
  const view = JSON.parse(fs.readFileSync(path.join(dir, "view.json"), "utf8"));
  const out = {};
  for (const size of ["full", "medium", "small"]) {
    if (!view[size]) continue;
    try { out[size] = resolve(view[size], withStrings(data, table)); } catch (e) { throw new Error(`view.json (${size}): ${e.message}`); }
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
  process.env.TZ = fx.timezone || "UTC"; // local time in a scenario doesn't depend on the machine
  const box = sandbox(dir, { ...fx, ...extra });
  try {
    for (const a of fx.actions || []) await box.action(a);
    const data = await box.refresh();
    return { data, views: views(dir, data, box.strings), box };
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
    if (!result.error) problems.push(`expected the error “${fx.error}”, but refresh() passed`);
    else if (!result.error.includes(fx.error)) problems.push(`the error “${result.error}”, expected “${fx.error}”`);
    return problems;
  }
  if (result.error) return [result.error];
  for (const [p, want] of Object.entries(fx.expect || {})) {
    const got = lookup(p, { $: result.data });
    const ok = typeof want === "string" && want.length > 1 && want.startsWith("/") && want.endsWith("/")
      ? new RegExp(want.slice(1, -1)).test(text(got))
      : JSON.stringify(got) === JSON.stringify(want);
    if (!ok) problems.push(`${p}: ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  }
  return problems;
}

// ---------------------------------------------------------------- preview (approximate HTML → PNG)

const THEMES = {
  dark: { bg: "#000", text: "#fff", sec: "#98989F", accent: "#0A84FF", card: "rgba(255,255,255,.07)", surface: "rgba(255,255,255,.07)", style: "flat", radius: 22 },
  light: { bg: "#F2F2F7", text: "#000", sec: "#6C6C70", accent: "#007AFF", card: "#fff", surface: "rgba(0,0,0,.05)", style: "flat", radius: 22,
    palette: {"green": "#248A3D", "mint": "#0C817B", "teal": "#008299", "cyan": "#0071A4", "yellow": "#B25000", "orange": "#C93400"} }, // the light theme's darker variants (readable on white)
  glass: { bg: "linear-gradient(145deg,#1B2A6B,#6A2C8F,#0E7C86)", text: "#fff", sec: "rgba(255,255,255,.7)", accent: "#7FD4FF", card: "rgba(255,255,255,.12)", surface: "rgba(255,255,255,.14)", style: "glass", radius: 28 },
  ascii: { bg: "#050805", text: "#39FF14", sec: "#1FA30C", accent: "#39FF14", card: "transparent", surface: "transparent", style: "ascii", radius: 0 },
};
const SYSTEM = { red: "#FF453A", orange: "#FF9F0A", yellow: "#FFD60A", green: "#30D158", mint: "#63E6E2", teal: "#40C8E0", cyan: "#64D2FF", blue: "#0A84FF", indigo: "#5E5CE6", purple: "#BF5AF2", pink: "#FF375F", brown: "#AC8E68", gray: "#8E8E93", white: "#FFFFFF" };
const STYLES = { largeTitle: [34, 600], title: [28, 600], title2: [22, 600], title3: [20, 600], headline: [17, 600], body: [17, 400], callout: [16, 400], subheadline: [15, 400], footnote: [13, 400], caption: [12, 400], caption2: [11, 400] };
const WEIGHTS = { ultraLight: 200, thin: 250, light: 300, regular: 400, medium: 500, semibold: 600, bold: 700, heavy: 800, black: 900 };
// SF Symbols aren't available off Apple platforms: a few common ones as emoji, the rest as a dot.
const RELATIVES = { mint: "green", teal: "cyan", cyan: "blue", indigo: "blue", pink: "purple", brown: "orange", grey: "gray" };
const SYMBOLS = { "sun.max.fill": "☀️", "cloud.rain.fill": "🌧️", "cloud.snow.fill": "🌨️", "location.fill": "📍", globe: "🌐", "briefcase.fill": "💼", "moon.zzz.fill": "🌙", "moon.fill": "🌙", "sunset.fill": "🌇", "cup.and.saucer.fill": "☕", "chart.line.uptrend.xyaxis": "📈", "arrow.clockwise": "↻", sparkles: "✨", "dollarsign.arrow.circlepath": "💱", timer: "⏱️", "play.fill": "▶", "pause.fill": "⏸", "forward.fill": "⏭", "arrow.uturn.backward": "↩", "arrow.left": "←", "arrow.right": "→", "arrow.up": "↑", "arrow.down": "↓", "flame.fill": "🔥", "leaf.fill": "🍃", "aqi.medium": "🌫️", "sun.horizon.fill": "🌅", "newspaper.fill": "📰", hourglass: "⏳", "arrow.triangle.pull": "🔀", "flag.fill": "🚩", "hand.tap.fill": "👆", "exclamationmark.triangle.fill": "⚠️" };

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
    // Like the app: a missing name falls back to its nearest relative in the palette (mint → green, teal → cyan…).
    for (let k = l; k; k = RELATIVES[k]) if (T.palette?.[k]) return T.palette[k];
    if (l === "clear" || l === "none") return "transparent";
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
      case "gauge": return `<div class="v" style="gap:4px;align-items:center${n.fill ? ";flex:1;justify-content:center" : ""}"><svg viewBox="0 0 56 56" width="${n.fill ? 110 : 56}" height="${n.fill ? 110 : 56}"><circle cx="28" cy="28" r="25" fill="none" stroke="${T.text}" stroke-opacity=".12" stroke-width="6"/><circle cx="28" cy="28" r="25" fill="none" stroke="${color(n.color) || T.accent}" stroke-width="6" stroke-linecap="round" stroke-dasharray="${157 * n.value} 999" transform="rotate(-90 28 28)"/><text x="28" y="32" text-anchor="middle" font-size="12" font-weight="600" fill="${T.text}">${esc(n.text ?? `${Math.round(n.value * 100)}%`)}</text></svg>${n.label ? `<div class="t" style="font-size:11px;color:${T.sec}">${esc(n.label)}</div>` : ""}</div>`;
      case "progress": {
        const c = color(n.color) || T.accent;
        if (T.style === "ascii") { // like AsciiBar: as many cells as fit the width
          const run = (ch, w) => `<span style="flex:0 0 ${w}%;overflow:hidden;white-space:nowrap">${ch.repeat(120)}</span>`;
          return `<div class="t mono" style="color:${c};display:flex;width:100%;overflow:hidden"><span>[</span><span style="flex:1;display:flex;min-width:0">${run("#", n.value * 100)}${run(".", 100 - n.value * 100)}</span><span>]</span></div>`;
        }
        return `<div class="track"><div style="width:${n.value * 100}%;height:100%;border-radius:2px;background:${c}"></div></div>`;
      }
      case "chart": return chart(n.values, color(n.color) || T.accent, n.style || "line", n.height, T);
      case "button": { // as on the phone: a glass pill (a circle with only a symbol), filled and glowing with a colour
        if (T.style === "ascii") return `<div class="button" style="color:${T.accent};background:none">[ ${esc(n.title || SYMBOLS[n.symbol] || "")} ]</div>`;
        const fill = color(n.color), label = `${SYMBOLS[n.symbol] ? SYMBOLS[n.symbol] + (n.title ? " " : "") : ""}${esc(n.title)}`;
        return fill ? `<div class="button" style="background:${fill};color:#fff;box-shadow:0 0 14px ${fill}88">${label}</div>`
                    : `<div class="button${n.title ? "" : " round"}">${label}</div>`;
      }
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
      case "layers": {
        const pos = ({ top: "flex-start center", bottom: "flex-end center", leading: "center flex-start", trailing: "center flex-end", topLeading: "flex-start flex-start",
                       topTrailing: "flex-start flex-end", bottomLeading: "flex-end flex-start", bottomTrailing: "flex-end flex-end" })[n.align] || "center center";
        const [v, h] = pos.split(" ");
        return `<div class="layers">${n.children.map((c) => `<div class="layer" style="align-items:${v};justify-content:${h}">${r(c)}</div>`).join("")}</div>`;
      }
      case "scene": {
        const base = (n.colors || []).map(color).filter(Boolean), tints = (n.tints || [T.accent]).map((c) => color(c) || c);
        const bg = base.length > 1 ? `linear-gradient(160deg,${base.join(",")})` : base[0] || T.bg;
        const blobs = tints.map((c, i) => `radial-gradient(circle at ${20 + ((i * 37) % 70)}% ${25 + ((i * 53) % 60)}%, ${c}aa 0, transparent 45%)`).join(",");
        return `<div class="scene" style="background:${blobs},${bg}" title="scene ${n.kind}"></div>`;
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
.h>.v{flex:0 1 auto}.h>.v:has(.grid),.h>.grid{flex:1 1 0}.v>.v{align-self:stretch}.h>.h{width:auto;flex:0 0 auto}.v>.box.fill{align-self:stretch}.h>.box.fill{flex:1 1 0}
.box.fit{flex:0 0 auto}.v>.box.fit{align-self:flex-start}.box>*:not(.surface){position:relative}.surface{position:absolute;inset:0}
.grid{display:grid;width:100%;align-items:start}.cell{align-items:stretch}
.layers{display:grid;width:100%;flex:1 1 auto;min-height:0}.layer{grid-area:1/1;display:flex;flex-direction:column;min-height:0}
.scene{width:100%;height:100%;min-height:60px;border-radius:14px}
.track{width:100%;height:4px;border-radius:2px;background:${T.light ? "rgba(0,0,0,.1)" : "rgba(255,255,255,.18)"}}
.divider{height:1px;width:100%;background:${T.light ? "rgba(0,0,0,.12)" : "rgba(255,255,255,.15)"}}
.button{padding:8px 16px;border-radius:999px;background:${T.light ? "rgba(0,0,0,.06)" : "rgba(255,255,255,.1)"};border:1px solid ${T.light ? "rgba(0,0,0,.1)" : "rgba(255,255,255,.15)"};font-size:15px;font-weight:600;white-space:nowrap;align-self:flex-start}.button.round{padding:8px 11px}
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
    const root = execSync("npm root -g").toString().trim();
    // Local install, `npm i -g playwright`, or the copy inside `@playwright/cli`.
    const places = ["playwright", path.join(root, "playwright"), path.join(root, "@playwright/cli/node_modules/playwright")];
    for (const place of places) { try { playwright = require(place); break; } catch {} }
    if (!playwright) throw new Error("no playwright");
  } catch {
    throw new Error("preview needs Playwright with Chromium: npm i -g playwright && npx playwright install chromium");
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
  if (!fs.existsSync(path.join(dir, "manifest.json"))) throw new Error(`${p}: not a widget folder (no manifest.json)`);
  return dir;
}

function fixtureFor(dir, args) {
  const all = fixtures(dir);
  let fx = {};
  if (args.fixture) {
    fx = all.find((f) => f.name === args.fixture);
    if (!fx) throw new Error(`no fixture “${args.fixture}” (there are: ${all.map((f) => f.name).join(", ") || "none"})`);
  }
  return {
    ...fx,
    settings: { ...(fx.settings || {}), ...args.setting },
    secrets: { ...(fx.secrets || {}), ...args.secret },
    actions: [...(fx.actions || []), ...args.action],
    now: args.now || fx.now,
    lang: args.lang || fx.lang,
    home: args.home,
    verbose: args.verbose,
  };
}

/** A small but complete widget: settings, storage, an action, all three sizes, adaptive to every theme. */
function scaffold(dir, id, name) {
  const json = (v) => JSON.stringify(v, null, 2) + "\n";
  const schema = (n) => `https://raw.githubusercontent.com/flywalk4/qwovi/main/schemas/${n}.schema.json`;
  fs.mkdirSync(path.join(dir, "fixtures"), { recursive: true });
  fs.writeFileSync(path.join(dir, "manifest.json"), json({
    $schema: schema("manifest"), id, name, version: "1.0.0", author: id.split(".")[1] || "me",
    description: "A counter with a daily goal — a starter template: settings, storage, buttons and all three sizes.",
    symbol: "sparkles", refresh: 60,
    settings: [{ key: "goal", title: "Daily goal", type: "number", min: 1, max: 20, default: "8" }],
  }));
  fs.writeFileSync(path.join(dir, "strings.json"), json({
    en: { "manifest.name": name, "settings.goal.title": "Daily goal", today: "Today", reset: "Reset", week: "Last 7 days",
          left: { one: "{n} more to go", other: "{n} more to go" }, done: "goal reached 🎉" },
    ru: { "manifest.name": name, "settings.goal.title": "Цель на день", today: "Сегодня", reset: "Сброс", week: "Последние 7 дней",
          left: { one: "ещё {n} раз до цели", few: "ещё {n} раза до цели", many: "ещё {n} раз до цели", other: "ещё {n} раза до цели" },
          done: "цель выполнена 🎉" },
  }));
  const face = (big, extra = [], compact = false) => ({
    type: "vstack", spacing: 10, children: [
      { type: "hstack", children: [
        { type: "symbol", name: "sparkles", color: "accent" },
        { type: "text", text: "{{title}}", style: "headline" },
        ...(compact ? [] : [{ type: "spacer" }, { type: "text", text: "{{updated}}", style: "caption", color: "secondary" }]),
      ] },
      { type: "text", text: "{{count}}", size: big, weight: "bold", design: "rounded" },
      { type: "text", text: "{{left}}", style: "subheadline", color: "{{color}}" },
      { type: "progress", value: "{{progress}}", color: "{{color}}" },
      ...extra,
    ],
  });
  const buttons = { type: "hstack", children: [
    { type: "button", title: "+1", symbol: "plus", action: "add" },
    { type: "button", title: "{{t.reset}}", symbol: "arrow.clockwise", action: "reset" },
  ] };
  fs.writeFileSync(path.join(dir, "view.json"), json({
    $schema: schema("view"),
    full: { type: "vstack", spacing: 16, children: [
      face(96, [buttons]),
      { type: "box", if: "{{history}}", children: [
        { type: "text", text: "{{t.week}}", style: "caption", color: "secondary" },
        { type: "chart", values: "{{history}}", style: "bar", color: "accent", height: 80 },
      ] },
    ] },
    medium: face(56, [buttons]),
    small: { type: "box", action: "add", children: [face(40, [], true)] },
  }));
  fs.writeFileSync(path.join(dir, "provider.js"), `// ${name}: refresh(ctx) returns the data view.json binds to ({{count}} etc.). Runs on the Mac.
// ctx.settings — from manifest.settings; storage — 64 KB that survive restarts; format — number/date helpers;
// t(key, vars) — texts from strings.json in the user's language.

function today() {
  return new Date().toISOString().slice(0, 10);
}

function load() {
  const state = storage.get("state") || { day: today(), count: 0, history: [] };
  if (state.day !== today()) { // a new day: keep yesterday in the history
    state.history = [...state.history, state.count].slice(-6);
    state.day = today();
    state.count = 0;
  }
  return state;
}

function refresh(ctx) {
  const state = load();
  storage.set("state", state);
  const goal = Math.max(1, Number(ctx.settings.goal) || 8);
  const left = goal - state.count;
  return {
    title: t("today"),
    count: format.number(state.count, 0),
    left: left > 0 ? t("left", { n: left }) : t("done"),
    progress: Math.min(1, state.count / goal),
    color: left > 0 ? "accent" : "green",
    history: state.history.length ? [...state.history, state.count] : [],
    updated: format.time(),
  };
}

// Buttons and tappable boxes call action(name, ctx); the widget refreshes right after.
function action(name, ctx) {
  const state = load();
  if (name === "add") state.count += 1;
  if (name === "reset") state.count = 0;
  storage.set("state", state);
}
`);
  fs.writeFileSync(path.join(dir, "fixtures/ok.json"), json({
    description: "Two taps in the morning; the default goal is 8",
    now: "2026-09-27T09:00:00Z",
    storage: { state: { day: "2026-09-27", count: 3, history: [5, 8, 2] } },
    actions: ["add", "add"],
    expect: { count: "5", progress: 0.625, color: "accent", left: "/3 more/" },
  }));
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
    const themes = args.theme === "all" ? ["dark", "light", "glass", "ascii"] : [args.theme || "dark"];
    for (const theme of themes) {
      const file = themes.length > 1 ? out.replace(/(\.png)?$/, `-${theme}.png`) : out;
      await screenshot(renderHTML(result.views, theme), file);
      console.log(`${file}: an approximate mock-up (fonts and icons differ from the iPhone)`);
    }
  } else if (command === "new") {
    const id = args._[0];
    if (!/^[a-z0-9]+(\.[a-z0-9-]+)+$/.test(id || "")) throw new Error("new com.you.widget — an id of lowercase Latin letters, digits and dots");
    const dir = path.resolve(args.dir || path.join(ROOT, "catalog/widgets"), id);
    if (fs.existsSync(dir)) throw new Error(`${dir} already exists`);
    scaffold(dir, id, args.name || "My widget");
    const rel = path.relative(process.cwd(), dir);
    console.log(`${rel}: manifest.json, view.json, provider.js, fixtures/ok.json\n` +
      `next:    node scripts/widget-dev.mjs watch ${rel}   (edit the files — preview.png updates)\n` +
      `         node scripts/widget-dev.mjs test ${rel}\n` +
      `on a Mac: the Qwovi menu → “Widgets…” → “Development folder…” (live reload)`);
  } else if (command === "watch") {
    const dir = widgetDir(args._[0] || ".");
    const out = args.out || path.join(dir, "preview.png");
    let timer = null, running = false;
    const go = async () => {
      if (running) return void (timer = setTimeout(go, 200));
      running = true;
      try {
        const result = await scenario(dir, fixtureFor(dir, args));
        for (const line of result.box.logs) console.error("log:", line);
        if (result.error) console.log(`${new Date().toLocaleTimeString()} ✗ ${result.error}`);
        else {
          await screenshot(renderHTML(result.views, args.theme || "dark"), out);
          console.log(`${new Date().toLocaleTimeString()} ✓ ${path.relative(process.cwd(), out)}  ${JSON.stringify(result.data).slice(0, 120)}`);
        }
      } catch (e) { console.log(`${new Date().toLocaleTimeString()} ✗ ${e.message}`); }
      running = false;
    };
    await go();
    console.log("watching for changes (Ctrl-C to quit)…");
    const skip = (f) => !f || f.endsWith(".png") || f.startsWith(".");
    fs.watch(dir, { recursive: true }, (_, f) => { if (skip(f)) return; clearTimeout(timer); timer = setTimeout(go, 150); });
    fs.watch(path.join(ROOT, "Mac/Widgets/prelude.js"), () => { clearTimeout(timer); timer = setTimeout(go, 150); });
    await new Promise(() => {});
  } else if (command === "bundle") {
    // Every catalog widget with data from its first successful fixture, plus pages — for `--demo-bundle` on the phone.
    const out = args._[0];
    if (!out) throw new Error("bundle <out.json> [--theme catalog/themes/<id>]");
    const dirs = fs.readdirSync(path.join(ROOT, "catalog/widgets")).sort().map((d) => path.join(ROOT, "catalog/widgets", d));
    const widgets = [];
    for (const dir of dirs) {
      const list = fixtures(dir).filter((f) => !f.error);
      const fx = list.find((f) => f.name === "ok") || list[0] || {};
      const result = await scenario(dir, { ...fx, lang: args.lang || fx.lang });
      if (result.error) { console.error(`✗ ${path.basename(dir)}: ${result.error}`); continue; }
      const m = result.box.manifest;
      widgets.push({ id: m.id, name: result.box.strings["manifest.name"] || m.name, symbol: m.symbol,
                     view: JSON.parse(fs.readFileSync(path.join(dir, "view.json"), "utf8")), data: withStrings(result.data, result.box.strings) });
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
      { layout: "trio", widgets: ["wallpaper", "month", "worldclock"].map(ref) },
      { layout: "single", widgets: ["photos"] },
      ...["music", "weather", "calendar", "monitor", "reminders", "notes", "launcher"].map((id) => ({ layout: "single", widgets: [id] })),
      { layout: "split", widgets: ["music", "calendar"] },
      { layout: "six", widgets: ["time", "focus", "sky", "rates", "air", "worldclock"].map(ref) },
      { layout: "trio", widgets: ["habits", "time", "focus"].map(ref) },
      { layout: "split", bare: true, widgets: ["worldclock", "time"].map(ref) },
      { layout: "trio", widgets: ["reminders", "notes", "launcher"] },
      { layout: "stack", widgets: ["music", "weather", "monitor"] },
      { layout: "split", widgets: ["apps", ref("github")] },
    ];
    const bundle = { widgets, pages };
    if (args.theme) {
      const file = fs.statSync(args.theme).isDirectory() ? path.join(args.theme, "theme.json") : args.theme;
      bundle.theme = JSON.parse(fs.readFileSync(file, "utf8"));
    }
    fs.writeFileSync(out, JSON.stringify(bundle));
    console.log(`${out}: ${widgets.length} widgets, ${pages.length} pages (page N = --page N)`);
    pages.forEach((p, i) => console.log(`  ${i}: ${p.layout} ${p.widgets.join(", ")}`));
  } else if (command === "test") {
    const dirs = args._.length ? args._.map(widgetDir)
      : fs.readdirSync(path.join(ROOT, "catalog/widgets")).map((d) => path.join(ROOT, "catalog/widgets", d)).filter((d) => fs.existsSync(path.join(d, "manifest.json")));
    let failed = 0, total = 0;
    for (const dir of dirs.sort()) {
      const list = fixtures(dir);
      if (!list.length) { console.log(`- ${path.basename(dir)}: no fixtures/`); continue; }
      for (const fx of list) {
        total++;
        const problems = check(await scenario(dir, fx), fx);
        if (problems.length) { failed++; console.log(`✗ ${path.basename(dir)} · ${fx.name}`); problems.forEach((p) => console.log(`    ${p}`)); }
        else console.log(`✓ ${path.basename(dir)} · ${fx.name}`);
      }
    }
    console.log(failed ? `${failed} of ${total} scenarios failed` : `OK: ${total} scenario${total === 1 ? "" : "s"}`);
    process.exit(failed ? 1 : 0);
  } else {
    console.error(fs.readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 11).map((l) => l.replace(/^\/\/ ?/, "")).join("\n"));
    process.exit(2);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) main().catch((e) => { console.error(`FAIL ${e.message}`); process.exit(1); });
