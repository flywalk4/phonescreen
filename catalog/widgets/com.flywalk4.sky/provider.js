// Солнце (Open-Meteo: восход, закат, долгота дня) и Луна (фаза считается здесь же, без сети).

const SYNODIC = 29.530588853;                 // дней между новолуниями
const NEW_MOON = Date.UTC(2000, 0, 6, 18, 14) / 1000; // опорное новолуние

async function refresh(ctx) {
  const place = await locate((ctx.settings.place || "Москва").trim());
  const res = await fetch("https://api.open-meteo.com/v1/forecast"
    + `?latitude=${place.lat}&longitude=${place.lon}&timezone=auto`
    + "&daily=sunrise,sunset,daylight_duration&past_days=1&forecast_days=8");
  if (!res.ok) throw new Error(`Open-Meteo ответил ${res.status}`);
  const data = await res.json();
  const offset = data.utc_offset_seconds || 0;
  const at = (t) => Date.parse(t + ":00Z") / 1000 - offset;
  const d = data.daily || {};
  if (!d.sunrise || d.sunrise.length < 2) throw new Error("Open-Meteo не вернул восход и закат");

  const now = Date.now() / 1000;
  const [rise, set] = [at(d.sunrise[1]), at(d.sunset[1])];      // [0] — вчера, [1] — сегодня
  const length = d.daylight_duration[1], diff = Math.round((length - d.daylight_duration[0]) / 60);
  const up = now >= rise && now < set;
  const dayShare = Math.min(1, Math.max(0, (now - rise) / (set - rise)));

  const moon = moonInfo(now);
  const DAYS = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"];
  const week = d.sunrise.slice(2, 9).map((sr, i) => {
    const r = at(sr), st = at(d.sunset[i + 2]);
    return { day: DAYS[new Date((r + offset) * 1000).getUTCDay()], sunrise: localTime(r, offset), sunset: localTime(st, offset),
             length: duration(d.daylight_duration[i + 2]) };
  });
  return {
    place: place.name,
    sunrise: localTime(rise, offset),
    sunset: localTime(set, offset),
    length: duration(length),
    diff: diff === 0 ? "как вчера" : `${diff > 0 ? "+" : "−"}${Math.abs(diff)} мин к вчерашнему`,
    diffColor: diff >= 0 ? "green" : "orange",
    up,
    dayShare,
    status: up ? `до заката ${duration(set - now)}` : now < rise ? `до восхода ${duration(rise - now)}`
      : `завтра восход в ${localTime(at(d.sunrise[2] || d.sunrise[1]) , offset)}`,
    icon: up ? "sun.max.fill" : "moon.fill",
    iconColor: up ? "yellow" : "indigo",
    moon: { ...moon, frames: [moonSprite(moon.age)] },
    week,
  };
}

// ---- Луна ----

function moonInfo(now) {
  const age = (((now - NEW_MOON) / 86400) % SYNODIC + SYNODIC) % SYNODIC;
  const lit = (1 - Math.cos((2 * Math.PI * age) / SYNODIC)) / 2;
  const names = ["Новолуние", "Растущий серп", "Первая четверть", "Растущая луна", "Полнолуние", "Убывающая луна", "Последняя четверть", "Убывающий серп"];
  const phase = names[Math.round((age / SYNODIC) * 8) % 8];
  const toFull = ((SYNODIC / 2 - age) + SYNODIC) % SYNODIC;
  const toNew = SYNODIC - age;
  return {
    age,
    phase,
    lit: `${Math.round(lit * 100)}%`,
    nextFull: `полнолуние ${when(toFull, now)}`,
    nextNew: `новолуние ${when(toNew, now)}`,
  };
}

function when(days, now) {
  if (days < 0.5) return "сегодня";
  if (days < 1.5) return "завтра";
  const d = new Date((now + days * 86400) * 1000);
  const months = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
  return `${d.getDate()} ${months[d.getMonth()]}`;
}

// Диск 21×21: освещённая часть по фазе (для северного полушария: растущая светится справа).
function moonSprite(age) {
  const N = 21, R = 9.6, c = (N - 1) / 2;
  const k = Math.cos((2 * Math.PI * age) / SYNODIC); // 1 — новолуние, −1 — полнолуние
  const waxing = age < SYNODIC / 2;
  const rows = [];
  for (let y = 0; y < N; y++) {
    let row = "";
    for (let x = 0; x < N; x++) {
      const dx = x - c, dy = y - c;
      if (dx * dx + dy * dy > R * R) { row += "."; continue; }
      const w = Math.sqrt(R * R - dy * dy);
      const lit = waxing ? dx > k * w : dx < -k * w;
      const crater = [[-3.5, -2.5, 2.3], [2.5, 3, 1.9], [3.5, -4.5, 1.5], [-2, 5, 1.2], [5.5, 0.5, 1.1]]
        .some(([cx, cy, r]) => (dx - cx) ** 2 + (dy - cy) ** 2 < r * r);
      row += lit ? (crater ? "c" : "l") : (crater ? "e" : "d");
    }
    rows.push(row);
  }
  return rows;
}

// ---- Общее ----

async function locate(text) {
  const m = /^\s*(-?\d+(?:\.\d+)?)\s*[,; ]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(text);
  if (m) return { lat: Number(m[1]), lon: Number(m[2]), name: `${m[1]}, ${m[2]}` };
  const cached = storage.get("place");
  if (cached && cached.query === text) return cached;
  const res = await fetch(`https://geocoding-api.open-meteo.com/v1/search?count=1&language=ru&name=${encodeURIComponent(text)}`);
  if (!res.ok) throw new Error(`Геокодер Open-Meteo ответил ${res.status}`);
  const r = ((await res.json()).results || [])[0];
  if (!r) throw new Error(`Не нашёл «${text}». Укажите другой город или координаты «55.75, 37.62»`);
  const place = { query: text, lat: r.latitude, lon: r.longitude, name: r.name };
  storage.set("place", place);
  return place;
}

function localTime(t, offset) {
  const d = new Date((t + offset) * 1000);
  return `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
}

function duration(sec) {
  const h = Math.floor(sec / 3600), m = Math.round((sec % 3600) / 60);
  return h > 0 ? `${h} ч ${m} мин` : `${m} мин`;
}
