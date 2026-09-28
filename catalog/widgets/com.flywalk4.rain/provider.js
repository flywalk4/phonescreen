// Precipitation for the next hours: when rain (snow) starts or stops, in 15-minute steps 3 hours ahead.
// Data: https://open-meteo.com (free, no key). City → coordinates through their own geocoder.

const WET = 0.1; // mm per 15 minutes; less counts as dry

async function refresh(ctx) {
  const place = await locate((ctx.settings.place || "Moscow").trim());
  const url = "https://api.open-meteo.com/v1/forecast"
    + `?latitude=${place.lat}&longitude=${place.lon}&timezone=auto`
    + "&current=temperature_2m,precipitation,weather_code"
    + "&minutely_15=precipitation,snowfall&forecast_minutely_15=13"
    + "&hourly=precipitation_probability,precipitation&forecast_hours=12";
  const res = await fetch(url);
  if (!res.ok) throw new Error(t("httpError", { status: res.status }));
  const data = await res.json();
  if (data.error) throw new Error(`Open-Meteo: ${data.reason || t("error")}`);

  const offset = data.utc_offset_seconds || 0;
  const at = (t) => (Date.parse(t + ":00Z") / 1000) - offset; // times in the answer are local to the place
  const now = Date.now() / 1000;

  // 15-minute slots; the current one is the one going on now.
  const m = data.minutely_15 || {};
  const slots = (m.time || []).map((time, i) => ({
    at: at(time), mm: m.precipitation?.[i] || 0, snow: (m.snowfall?.[i] || 0) > 0,
  })).filter((s) => s.at + 900 > now).slice(0, 12);
  if (slots.length === 0) throw new Error(t("noSlots"));

  const wetNow = slots[0].mm >= WET || (data.current?.precipitation || 0) >= WET;
  const change = slots.findIndex((s) => (s.mm >= WET) !== wetNow);
  const snowy = slots.some((s) => s.mm >= WET && s.snow);
  const kind = snowy ? "snow" : "rain"; // strings.json: <kind>.now, <kind>.in, …
  const minutes = change > 0 ? Math.max(5, Math.round((slots[change].at - now) / 60 / 5) * 5) : null;

  // headline: a phrase for large tiles; big + bigLabel: short for a small one ("35 min" / "until rain").
  let headline, sub, big, bigLabel;
  if (wetNow) {
    headline = t(`${kind}.now`);
    sub = minutes ? t("stops", { when: inText(minutes) }) : t("wontStop");
    big = minutes ? short(minutes) : ["3+", t("unit.h")];
    bigLabel = t(`${kind}.left`);
  } else if (minutes) {
    headline = t(`${kind}.in`, { when: inText(minutes) });
    sub = t("amount", { mm: fmt(Math.max(...slots.slice(change).map((s) => s.mm))) });
    big = short(minutes);
    bigLabel = t(`${kind}.until`);
  } else {
    headline = t("dry");
    sub = t("next3h");
    big = [t("dryShort"), ""];
    bigLabel = t("noPrecip");
  }

  const h = data.hourly || {};
  const hours = (h.time || []).map((time, i) => ({ at: at(time), p: h.precipitation_probability?.[i] ?? 0, mm: h.precipitation?.[i] || 0 }))
    .filter((x) => x.at + 3600 > now).slice(0, 6)
    .map((x) => ({
      time: localTime(x.at, offset), prob: `${x.p}%`, mm: x.mm > 0 ? t("mm", { n: fmt(x.mm) }) : "",
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

// "55.75, 37.62" → coordinates as is; otherwise a city through the geocoder (cached).
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

// 35 → ["35", "min"], 90 → ["1.5", "h"]: the number large, the unit small.
function short(min) {
  return min < 60 ? [String(min), t("unit.min")] : [format.number(Math.round(min / 30) / 2, min % 60 ? 1 : 0), t("unit.h")];
}

function inText(min) {
  return t("in", { x: format.duration(min * 60) });
}

function localTime(t, offset) {
  const d = new Date((t + offset) * 1000);
  return `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
}

function fmt(mm) { return mm < 10 ? format.number(mm, 1) : String(Math.round(mm)); }
