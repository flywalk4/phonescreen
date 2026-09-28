// Helpers every widget gets (loaded before provider.js by the app and by scripts/widget-dev.mjs, so both behave the
// same): `format` — numbers, dates and durations in the widget's language — and `t(key, vars)` — the widget's own
// strings from strings.json. The host sets `__lang` ("ru", "en"…) and `__strings` (that language's table, with the
// fallback language's keys underneath) before loading this file.
"use strict";

const LANG = typeof globalThis.__lang === "string" ? globalThis.__lang : "ru";
const STRINGS = globalThis.__strings && typeof globalThis.__strings === "object" ? globalThis.__strings : {};
const LOCALE = { ru: "ru-RU", en: "en-US", uk: "uk-UA", de: "de-DE", es: "es-ES", fr: "fr-FR", it: "it-IT", pt: "pt-BR",
                 zh: "zh-CN", ja: "ja-JP", ko: "ko-KR", tr: "tr-TR", pl: "pl-PL", kk: "kk-KZ" }[LANG] || LANG;

// The few words the helpers themselves say; languages not listed use English.
const WORDS = {
  ru: { h: "ч", min: "мин", s: "с", now: "только что", ago: "{x} назад", in: "через {x}", yesterday: "вчера", tomorrow: "завтра",
        day: ["день", "дня", "дней"], bytes: ["Б", "КБ", "МБ", "ГБ", "ТБ"], thousand: "тыс.", million: "млн", billion: "млрд",
        yes: "да", no: "нет" },
  en: { h: "h", min: "min", s: "s", now: "just now", ago: "{x} ago", in: "in {x}", yesterday: "yesterday", tomorrow: "tomorrow",
        day: ["day", "days", "days"], bytes: ["B", "KB", "MB", "GB", "TB"], thousand: "K", million: "M", billion: "B",
        yes: "yes", no: "no" },
};
const W = WORDS[LANG] || WORDS.en;

/** Plural category for n in the widget's language: "one", "few", "many", "other"… */
function pluralCategory(n) {
  try { return new Intl.PluralRules(LOCALE).select(n); } catch { return n === 1 ? "one" : "other"; }
}

/** Picks a form: an object {one, few, many, other} by n, or a string as is. */
function pick(forms, n) {
  if (forms == null || typeof forms !== "object") return forms;
  const cat = pluralCategory(Number(n) || 0);
  return forms[cat] ?? forms.other ?? forms.many ?? forms.few ?? forms.one ?? "";
}

/**
 * The widget's string `key` in the current language (strings.json), `{name}` placeholders filled from `vars`.
 * A plural string is an object {"one": "{n} day", "other": "{n} days"} (Russian: one/few/many) — `vars.n` picks the form.
 * A missing key returns the key itself, so a gap is visible instead of silently empty.
 */
globalThis.t = function t(key, vars = {}) {
  const raw = STRINGS[key];
  if (raw == null) return String(key);
  const text = String(pick(raw, vars.n) ?? "");
  return text.replace(/\{(\w+)\}/g, (m, name) => (name in vars ? String(vars[name]) : m));
};

globalThis.format = Object.freeze({
  /** The widget's language: "ru", "en"… (also `ctx.lang`). */
  lang: LANG,

  /** 1234.5 → "1 234,5" / "1,234.5" (digits after the point: exactly `digits`, or up to 2 when omitted). */
  number(n, digits) {
    if (n == null || !isFinite(n)) return "—";
    const opts = digits == null ? { maximumFractionDigits: 2 } : { minimumFractionDigits: digits, maximumFractionDigits: digits };
    return new Intl.NumberFormat(LOCALE, opts).format(n);
  },

  /** 1234567 → "1,2 млн" / "1.2M", 12400 → "12 тыс." / "12K", 950 → "950". */
  compact(n) {
    if (n == null || !isFinite(n)) return "—";
    const a = Math.abs(n), space = LANG === "en" ? "" : " ";
    if (a >= 1e9) return `${format.number(n / 1e9, a >= 1e10 ? 0 : 1)}${space}${W.billion}`;
    if (a >= 1e6) return `${format.number(n / 1e6, a >= 1e7 ? 0 : 1)}${space}${W.million}`;
    if (a >= 1e4) return `${format.number(Math.round(n / 1e3), 0)}${space}${W.thousand}`;
    return format.number(Math.round(n), 0);
  },

  /** 0.4213 → "42%"; with digits: "42,1%" / "42.1%". */
  percent(fraction, digits = 0) {
    return fraction == null || !isFinite(fraction) ? "—" : `${format.number(fraction * 100, digits)}%`;
  },

  /** Signed change with an arrow: 2.41 → "▲ 2,41%", -1.07 → "▼ 1,07%" (unit "%" by default, "" for none). */
  change(value, digits = 2, unit = "%") {
    if (value == null || !isFinite(value)) return "";
    return `${value >= 0 ? "▲" : "▼"} ${format.number(Math.abs(value), digits)}${unit}`;
  },

  /** Colour name for a change: "green" up, "red" down, "secondary" for none. */
  changeColor(value) {
    return value == null || !isFinite(value) || value === 0 ? "secondary" : value > 0 ? "green" : "red";
  },

  /**
   * A number with its word: plural(5, "день", "дня", "дней") → "5 дней" (Russian forms: one, few, many), or
   * plural(5, {one: "day", other: "days"}) in any language. `withNumber: false` for just the word.
   */
  plural(n, one, few, many, withNumber = true) {
    let word;
    if (one && typeof one === "object") {
      word = pick(one, n);
      withNumber = few === undefined ? true : few;
    } else {
      const cat = pluralCategory(n);
      word = cat === "one" ? one : cat === "few" ? few : cat === "many" ? many : (LANG === "ru" ? few : many ?? few);
    }
    return withNumber ? `${n} ${word}` : word;
  },

  /** Date → "14:05" (24-hour everywhere: a desk clock). */
  time(date = new Date()) {
    const d = date instanceof Date ? date : new Date(date);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  },

  /** Date → "27 сентября" / "September 27" ("short": "27 сен", "weekday": "воскресенье, 27 сентября", "full": + year). */
  date(date = new Date(), style = "long") {
    const d = date instanceof Date ? date : new Date(date);
    const opts = style === "short" ? { day: "numeric", month: "short" }
      : style === "weekday" ? { weekday: "long", day: "numeric", month: "long" }
      : style === "full" ? { day: "numeric", month: "long", year: "numeric" }
      : { day: "numeric", month: "long" };
    return new Intl.DateTimeFormat(LOCALE, opts).format(d).replace(/\.$/, "").replace(" г.", "");
  },

  /** Seconds → "2 ч 5 мин" / "2 h 5 min", "45 мин", "30 с". */
  duration(seconds) {
    const s = Math.max(0, Math.round(seconds));
    if (s < 60) return `${s} ${W.s}`;
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return h ? `${h} ${W.h}${m ? ` ${m} ${W.min}` : ""}` : `${m} ${W.min}`;
  },

  /** A moment relative to now: "только что" / "just now", "5 мин назад", "через 2 ч", "вчера", "3 дня назад". */
  relative(date) {
    const t = date instanceof Date ? date.getTime() : typeof date === "number" && date < 1e12 ? date * 1000 : new Date(date).getTime();
    const diff = (t - Date.now()) / 1000, a = Math.abs(diff);
    if (a < 45) return W.now;
    const say = (text) => (diff < 0 ? W.ago : W.in).replace("{x}", text);
    if (a < 3600) return say(`${Math.round(a / 60)} ${W.min}`);
    if (a < 86400) return say(`${Math.round(a / 3600)} ${W.h}`);
    const days = Math.round(a / 86400);
    if (days === 1) return diff < 0 ? W.yesterday : W.tomorrow;
    return say(format.plural(days, W.day[0], W.day[1], W.day[2]));
  },

  /** Bytes → "1,5 МБ" / "1.5 MB". */
  bytes(n) {
    const units = W.bytes;
    let i = 0, v = Math.abs(n);
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${format.number(v, v < 10 && i ? 1 : 0)} ${units[i]}`;
  },

  /** A 0…1 level as a status colour: green below `warn`, orange below `alert`, red above. */
  level(fraction, warn = 0.5, alert = 0.8) {
    return fraction < warn ? "green" : fraction < alert ? "orange" : "red";
  },
});
