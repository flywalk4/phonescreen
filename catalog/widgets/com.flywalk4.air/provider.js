// Air quality: the European AQI and pollutants (Open-Meteo Air Quality, no key).

const LEVELS = [ // upper bound of the index → rating (strings.json: level.<key>, tip.<key>)
  { max: 20, key: "excellent", tip: "fine", color: "green" },
  { max: 40, key: "good", tip: "fine", color: "mint" },
  { max: 60, key: "fair", tip: "sensitive", color: "yellow" },
  { max: 80, key: "poor", tip: "less", color: "orange" },
  { max: 100, key: "veryPoor", tip: "stay", color: "red" },
  { max: Infinity, key: "hazardous", tip: "home", color: "purple" },
];

async function refresh(ctx) {
  const place = await locate((ctx.settings.place || "Moscow").trim());
  const res = await fetch("https://air-quality-api.open-meteo.com/v1/air-quality"
    + `?latitude=${place.lat}&longitude=${place.lon}&timezone=auto`
    + "&current=european_aqi,pm2_5,pm10,nitrogen_dioxide,ozone,uv_index"
    + "&hourly=european_aqi&forecast_hours=24");
  if (!res.ok) throw new Error(t("httpError", { status: res.status }));
  const data = await res.json();
  const c = data.current || {};
  if (c.european_aqi == null) throw new Error(t("noIndex"));

  const aqi = Math.round(c.european_aqi);
  const level = LEVELS.find((l) => aqi <= l.max);
  const hourly = (data.hourly?.european_aqi || []).filter((v) => v != null).slice(0, 24);
  const worst = hourly.length ? Math.max(...hourly) : aqi;
  const uv = c.uv_index ?? 0;
  return {
    place: place.name,
    aqi: String(aqi),
    level: t(`level.${level.key}`), levelLine: t(`levelLine.${level.key}`), tip: t(`tip.${level.tip}`), color: level.color,
    scale: Math.min(1, aqi / 100),
    pollutants: [
      item("PM2.5", c.pm2_5, 25, t("unit")),
      item("PM10", c.pm10, 50, t("unit")),
      item("NO₂", c.nitrogen_dioxide, 40, t("unit")),
      item(t("ozone"), c.ozone, 100, t("unit")),
    ],
    uv: format.number(uv, 1),
    uvText: t(`uv.${uv < 3 ? "low" : uv < 6 ? "moderate" : uv < 8 ? "high" : uv < 11 ? "veryHigh" : "extreme"}`),
    uvColor: uv < 3 ? "green" : uv < 6 ? "yellow" : uv < 8 ? "orange" : "red",
    hourly,
    hasHourly: hourly.length > 1,
    outlook: worst > aqi + 10 ? t("worse", { n: Math.round(worst) }) : t("steady"),
  };
}

// A pollutant as a share of the WHO 24-hour guideline: bar and colour.
function item(name, value, guide, unit) {
  const v = value ?? 0, share = v / guide;
  return {
    name, value: v < 10 ? format.number(v, 1) : String(Math.round(v)), unit,
    bar: Math.min(1, share),
    color: share < 0.5 ? "green" : share < 1 ? "yellow" : share < 2 ? "orange" : "red",
  };
}

async function locate(text) {
  const m = /^\s*(-?\d+(?:\.\d+)?)\s*[,; ]\s*(-?\d+(?:\.\d+)?)\s*$/.exec(text);
  if (m) return { lat: Number(m[1]), lon: Number(m[2]), name: `${m[1]}, ${m[2]}` };
  const cached = storage.get("place");
  if (cached && cached.query === text) return cached;
  const res = await fetch(`https://geocoding-api.open-meteo.com/v1/search?count=1&language=${format.lang}&name=${encodeURIComponent(text)}`);
  if (!res.ok) throw new Error(t("geoError", { status: res.status }));
  const r = ((await res.json()).results || [])[0];
  if (!r) throw new Error(t("notFound", { text }));
  const place = { query: text, lat: r.latitude, lon: r.longitude, name: r.name };
  storage.set("place", place);
  return place;
}
