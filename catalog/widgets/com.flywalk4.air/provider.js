// Качество воздуха: европейский индекс AQI и загрязнители (Open-Meteo Air Quality, без ключа).

const LEVELS = [ // верхняя граница индекса → оценка
  { max: 20, text: "Отличный", tip: "Можно гулять и проветривать", color: "green" },
  { max: 40, text: "Хороший", tip: "Можно гулять и проветривать", color: "mint" },
  { max: 60, text: "Средний", tip: "Чувствительным — поменьше на улице", color: "yellow" },
  { max: 80, text: "Плохой", tip: "Сократи время на улице", color: "orange" },
  { max: 100, text: "Очень плохой", tip: "Лучше остаться дома, окна закрыть", color: "red" },
  { max: Infinity, text: "Опасный", tip: "Оставайся дома", color: "purple" },
];

async function refresh(ctx) {
  const place = await locate((ctx.settings.place || "Москва").trim());
  const res = await fetch("https://air-quality-api.open-meteo.com/v1/air-quality"
    + `?latitude=${place.lat}&longitude=${place.lon}&timezone=auto`
    + "&current=european_aqi,pm2_5,pm10,nitrogen_dioxide,ozone,uv_index"
    + "&hourly=european_aqi&forecast_hours=24");
  if (!res.ok) throw new Error(`Open-Meteo ответил ${res.status}`);
  const data = await res.json();
  const c = data.current || {};
  if (c.european_aqi == null) throw new Error("Open-Meteo не вернул индекс качества воздуха для этого места");

  const aqi = Math.round(c.european_aqi);
  const level = LEVELS.find((l) => aqi <= l.max);
  const hourly = (data.hourly?.european_aqi || []).filter((v) => v != null).slice(0, 24);
  const worst = hourly.length ? Math.max(...hourly) : aqi;
  const uv = c.uv_index ?? 0;
  return {
    place: place.name,
    aqi: String(aqi),
    level: level.text, tip: level.tip, color: level.color,
    scale: Math.min(1, aqi / 100),
    pollutants: [
      item("PM2.5", c.pm2_5, 25, "мкг/м³"),
      item("PM10", c.pm10, 50, "мкг/м³"),
      item("NO₂", c.nitrogen_dioxide, 40, "мкг/м³"),
      item("Озон", c.ozone, 100, "мкг/м³"),
    ],
    uv: uv.toFixed(1).replace(".", ","),
    uvText: uv < 3 ? "низкий" : uv < 6 ? "умеренный" : uv < 8 ? "высокий" : uv < 11 ? "очень высокий" : "экстремальный",
    uvColor: uv < 3 ? "green" : uv < 6 ? "yellow" : uv < 8 ? "orange" : "red",
    hourly,
    hasHourly: hourly.length > 1,
    outlook: worst > aqi + 10 ? `в ближайшие сутки хуже: до ${Math.round(worst)}` : "в ближайшие сутки без резких изменений",
  };
}

// Загрязнитель с долей от ориентира ВОЗ (сутки): полоса и цвет.
function item(name, value, guide, unit) {
  const v = value ?? 0, share = v / guide;
  return {
    name, value: v < 10 ? v.toFixed(1).replace(".", ",") : String(Math.round(v)), unit,
    bar: Math.min(1, share),
    color: share < 0.5 ? "green" : share < 1 ? "yellow" : share < 2 ? "orange" : "red",
  };
}

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
