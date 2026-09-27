// Helpers every widget gets as the global `format` (loaded before provider.js by the app and by
// scripts/widget-dev.mjs, so both behave the same). Russian by default.
"use strict";
globalThis.format = Object.freeze({
  /** 1234.5 → "1 234,5" (digits after the comma: exactly `digits`, or up to 2 when omitted). */
  number(n, digits) {
    if (n == null || !isFinite(n)) return "—";
    const opts = digits == null ? { maximumFractionDigits: 2 } : { minimumFractionDigits: digits, maximumFractionDigits: digits };
    return new Intl.NumberFormat("ru-RU", opts).format(n);
  },

  /** 1234567 → "1,2 млн", 12400 → "12 тыс.", 950 → "950". */
  compact(n) {
    if (n == null || !isFinite(n)) return "—";
    const a = Math.abs(n);
    if (a >= 1e9) return `${format.number(n / 1e9, a >= 1e10 ? 0 : 1)} млрд`;
    if (a >= 1e6) return `${format.number(n / 1e6, a >= 1e7 ? 0 : 1)} млн`;
    if (a >= 1e4) return `${format.number(Math.round(n / 1e3), 0)} тыс.`;
    return format.number(Math.round(n), 0);
  },

  /** 0.4213 → "42%"; with digits: "42,1%". */
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

  /** 5 → "5 дней" — plural("день", "дня", "дней"); `withNumber: false` for just the word. */
  plural(n, one, few, many, withNumber = true) {
    const a = Math.abs(n) % 100, b = a % 10;
    const word = a > 10 && a < 20 ? many : b === 1 ? one : b >= 2 && b <= 4 ? few : many;
    return withNumber ? `${n} ${word}` : word;
  },

  /** Date → "14:05". */
  time(date = new Date()) {
    const d = date instanceof Date ? date : new Date(date);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  },

  /** Date → "27 сентября" ("short": "27 сен", "weekday": "воскресенье, 27 сентября", "full": "27 сентября 2026"). */
  date(date = new Date(), style = "long") {
    const d = date instanceof Date ? date : new Date(date);
    const months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
    const days = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"];
    if (style === "short") return `${d.getDate()} ${months[d.getMonth()].slice(0, 3)}`;
    if (style === "weekday") return `${days[d.getDay()]}, ${d.getDate()} ${months[d.getMonth()]}`;
    if (style === "full") return `${d.getDate()} ${months[d.getMonth()]} ${d.getFullYear()}`;
    return `${d.getDate()} ${months[d.getMonth()]}`;
  },

  /** Seconds → "2 ч 5 мин", "45 мин", "30 с". */
  duration(seconds) {
    const s = Math.max(0, Math.round(seconds));
    if (s < 60) return `${s} с`;
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
    return h ? `${h} ч${m ? ` ${m} мин` : ""}` : `${m} мин`;
  },

  /** A moment relative to now: "только что", "5 мин назад", "через 2 ч", "вчера", "3 дня назад". */
  relative(date) {
    const t = date instanceof Date ? date.getTime() : typeof date === "number" && date < 1e12 ? date * 1000 : new Date(date).getTime();
    const diff = (t - Date.now()) / 1000, a = Math.abs(diff);
    if (a < 45) return "только что";
    const say = (text) => (diff < 0 ? `${text} назад` : `через ${text}`);
    if (a < 3600) return say(`${Math.round(a / 60)} мин`);
    if (a < 86400) return say(`${Math.round(a / 3600)} ч`);
    const days = Math.round(a / 86400);
    if (days === 1) return diff < 0 ? "вчера" : "завтра";
    return say(format.plural(days, "день", "дня", "дней"));
  },

  /** Bytes → "1,5 МБ". */
  bytes(n) {
    const units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
    let i = 0, v = Math.abs(n);
    while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
    return `${format.number(v, v < 10 && i ? 1 : 0)} ${units[i]}`;
  },

  /** A 0…1 level as a status colour: green below `warn`, orange below `alert`, red above. */
  level(fraction, warn = 0.5, alert = 0.8) {
    return fraction < warn ? "green" : fraction < alert ? "orange" : "red";
  },
});
