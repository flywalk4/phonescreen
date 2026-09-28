// World clock: clocks in the chosen time zones, the difference from local time and who's working now.
// No network: JavaScript itself knows the time zones (Intl).

async function refresh(ctx) {
  const zones = parseZones(ctx.settings.zones);
  if (zones.length === 0) throw new Error(t("noZones"));
  const [workFrom, workTo] = parseWork(ctx.settings.work);
  const now = new Date();
  const here = parts(now, undefined);

  const rows = zones.map(({ name, zone }) => {
    const z = parts(now, zone);
    const diff = Math.round((z.stamp - here.stamp) / 60000); // minutes relative to local
    const day = z.day === here.day ? "" : t(z.stamp > here.stamp ? "tomorrow" : "yesterday");
    const status = z.hour >= 23 || z.hour < 7 ? STATUS.night
      : z.weekend ? STATUS.weekend
      : z.hour >= workFrom && z.hour < workTo ? STATUS.work : STATUS.evening;
    return {
      name,
      time: `${pad(z.hour)}:${pad(z.minute)}`,
      diff: diffText(diff),
      day,
      dayLabel: day ? ` · ${day}` : "",
      detail: [diffText(diff), day, z.weekdayName].filter(Boolean).join(" · "),
      status: t(`status.${status.key}`), working: status === STATUS.work, icon: status.icon, color: status.color,
      dayFraction: (z.hour * 60 + z.minute) / 1440, // how much of the day has passed in the city (for the bar)
    };
  });

  return {
    local: `${pad(here.hour)}:${pad(here.minute)}`,
    localDate: format.date(now, "weekday"),
    summary: rows.some((r) => r.working)
      ? t("workingNow", { list: rows.filter((r) => r.working).map((r) => r.name).join(", ") })
      : t("nobodyWorking"),
    rows,
    first: rows[0],
    rest: rows.slice(1, 4),
    working: rows.filter((r) => r.working).length,
    total: rows.length,
    ...overlap(zones, now, here, workFrom, workTo),
  };
}

// How many cities are in working hours for each hour of your today, and the best window for a call.
function overlap(zones, now, here, workFrom, workTo) {
  const offsets = zones.map(({ zone }) => Math.round((parts(now, zone).stamp - here.stamp) / 3600000));
  const counts = Array.from({ length: 24 }, (_, h) =>
    offsets.filter((o) => { const t = (((h + o) % 24) + 24) % 24; return t >= workFrom && t < workTo; }).length);
  const best = Math.max(...counts);
  let start = -1, end = -1;
  for (let h = 0; h < 24; h++) {
    if (counts[h] !== best) continue;
    if (start < 0) start = h;
    if (end < 0 || end === h) end = h + 1;
  }
  return {
    overlap: counts,
    hasOverlap: best > 0,
    bestWindow: best > 0
      ? t("best", { from: `${pad(start)}:00`, to: `${pad(end % 24)}:00`, n: best, total: zones.length })
      : t("noOverlap"),
    nowHour: here.hour,
  };
}

const STATUS = {
  work: { key: "work", icon: "briefcase.fill", color: "green" },
  evening: { key: "evening", icon: "sunset.fill", color: "orange" },
  night: { key: "night", icon: "moon.zzz.fill", color: "indigo" },
  weekend: { key: "weekend", icon: "cup.and.saucer.fill", color: "teal" },
};

// "London=Europe/London, Asia/Tokyo" → [{name, zone}]; without a name, the city from the zone's name.
function parseZones(text) {
  return String(text || "").split(",").map((s) => s.trim()).filter(Boolean).map((item) => {
    const [a, b] = item.split("=").map((s) => s.trim());
    const zone = b || a;
    const name = b ? a : zone.split("/").pop().replace(/_/g, " ");
    try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); }
    catch (e) { throw new Error(t("badZone", { zone })); }
    return { name, zone };
  });
}

function parseWork(text) {
  const m = /^\s*(\d{1,2})\s*[-–]\s*(\d{1,2})\s*$/.exec(text || "");
  return m ? [Number(m[1]), Number(m[2])] : [9, 18];
}

const WEEKDAYS = Object.fromEntries(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d, i) => [d, t("weekdays").split(",")[i]]));

// Date parts in `zone` (undefined: local) and a "stamp": the same wall time as if it were UTC,
// so the difference of stamps is the difference of the zones.
function parts(date, zone) {
  const f = new Intl.DateTimeFormat("en-US", {
    timeZone: zone, hourCycle: "h23", weekday: "short",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  });
  const p = {};
  for (const { type, value } of f.formatToParts(date)) p[type] = value;
  const [y, mo, d, h, mi] = [p.year, p.month, p.day, p.hour, p.minute].map(Number);
  return {
    hour: h % 24, minute: mi, day: `${y}-${mo}-${d}`,
    stamp: Date.UTC(y, mo - 1, d, h % 24, mi),
    weekend: p.weekday === "Sat" || p.weekday === "Sun",
    weekdayName: WEEKDAYS[p.weekday] || "",
  };
}

function diffText(min) {
  if (min === 0) return t("same");
  const sign = min > 0 ? "+" : "−";
  const a = Math.abs(min), h = Math.floor(a / 60), m = a % 60;
  return t("diff", { x: `${sign}${h}${m ? `:${pad(m)}` : ""}` });
}

function pad(n) { return String(n).padStart(2, "0"); }
