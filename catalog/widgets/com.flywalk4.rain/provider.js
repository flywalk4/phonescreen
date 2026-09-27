// Осадки на ближайшие часы: когда начнётся или закончится дождь (снег), по 15 минут на 3 часа вперёд.
// Данные: https://open-meteo.com (бесплатно, без ключа). Город → координаты через их же геокодер.

const WET = 0.1; // мм за 15 минут — меньше считаем «сухо»

async function refresh(ctx) {
  const place = await locate((ctx.settings.place || "Москва").trim());
  const url = "https://api.open-meteo.com/v1/forecast"
    + `?latitude=${place.lat}&longitude=${place.lon}&timezone=auto`
    + "&current=temperature_2m,precipitation,weather_code"
    + "&minutely_15=precipitation,snowfall&forecast_minutely_15=13"
    + "&hourly=precipitation_probability,precipitation&forecast_hours=12";
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Open-Meteo ответил ${res.status}`);
  const data = await res.json();
  if (data.error) throw new Error(`Open-Meteo: ${data.reason || "ошибка"}`);

  const offset = data.utc_offset_seconds || 0;
  const at = (t) => (Date.parse(t + ":00Z") / 1000) - offset; // время в ответе — местное для точки
  const now = Date.now() / 1000;

  // Интервалы по 15 минут; текущий — тот, что идёт сейчас.
  const m = data.minutely_15 || {};
  const slots = (m.time || []).map((t, i) => ({
    at: at(t), mm: m.precipitation?.[i] || 0, snow: (m.snowfall?.[i] || 0) > 0,
  })).filter((s) => s.at + 900 > now).slice(0, 12);
  if (slots.length === 0) throw new Error("Open-Meteo не вернул прогноз по 15 минутам");

  const wetNow = slots[0].mm >= WET || (data.current?.precipitation || 0) >= WET;
  const change = slots.findIndex((s) => (s.mm >= WET) !== wetNow);
  const snowy = slots.some((s) => s.mm >= WET && s.snow);
  const kind = snowy ? "Снег" : "Дождь";
  const minutes = change > 0 ? Math.max(5, Math.round((slots[change].at - now) / 60 / 5) * 5) : null;

  // headline — фраза для больших плиток; big + bigLabel — коротко для маленькой («35 мин» / «до дождя»).
  const genitive = snowy ? "снега" : "дождя";
  let headline, sub, big, bigLabel;
  if (wetNow) {
    headline = `${kind} идёт`;
    sub = minutes ? `закончится ${inText(minutes)}` : "и не прекратится ближайшие 3 часа";
    big = minutes ? short(minutes) : ["3+", "ч"];
    bigLabel = `${kind.toLowerCase()} идёт, ещё`;
  } else if (minutes) {
    headline = `${kind} ${inText(minutes)}`;
    sub = `около ${fmt(Math.max(...slots.slice(change).map((s) => s.mm)))} мм за 15 минут`;
    big = short(minutes);
    bigLabel = `до ${genitive}`;
  } else {
    headline = "Без осадков";
    sub = "ближайшие 3 часа";
    big = ["Сухо", ""];
    bigLabel = "осадков не будет";
  }

  const h = data.hourly || {};
  const hours = (h.time || []).map((t, i) => ({ at: at(t), p: h.precipitation_probability?.[i] ?? 0, mm: h.precipitation?.[i] || 0 }))
    .filter((x) => x.at + 3600 > now).slice(0, 6)
    .map((x) => ({
      time: localTime(x.at, offset), prob: `${x.p}%`, mm: x.mm > 0 ? `${fmt(x.mm)} мм` : "",
      color: x.p >= 60 ? "blue" : x.p >= 30 ? "cyan" : "secondary",
    }));

  const wetSoon = wetNow || minutes !== null;
  return {
    place: place.name,
    headline, sub, bigLabel, bigValue: big[0], bigUnit: big[1],
    icon: wetSoon ? (snowy ? "cloud.snow.fill" : "cloud.rain.fill") : "sun.max.fill",
    color: wetSoon ? "blue" : "orange",
    temp: data.current?.temperature_2m != null ? `${Math.round(data.current.temperature_2m)}°` : "",
    chart: slots.map((s) => s.mm),
    hasChart: slots.some((s) => s.mm > 0),
    hours,
    updated: localTime(now, offset),
  };
}

// «55.75, 37.62» → координаты как есть; иначе город через геокодер (кэшируется).
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

// 35 → ["35", "мин"], 90 → ["1,5", "ч"] — число крупно, единица мелко.
function short(min) {
  return min < 60 ? [String(min), "мин"] : [format.number(Math.round(min / 30) / 2, min % 60 ? 1 : 0), "ч"];
}

function inText(min) {
  if (min < 60) return `через ${min} мин`;
  const h = Math.floor(min / 60), m = min % 60;
  return `через ${h} ч${m ? ` ${m} мин` : ""}`;
}

function localTime(t, offset) {
  const d = new Date((t + offset) * 1000);
  return `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
}

function fmt(mm) { return mm < 10 ? mm.toFixed(1).replace(".", ",") : String(Math.round(mm)); }
