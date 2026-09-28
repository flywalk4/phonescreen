// Progress of the day / week / month / year and countdowns to dates from the settings. No network.


async function refresh(ctx) {
  const now = new Date();
  const y = now.getFullYear(), m = now.getMonth(), d = now.getDate();

  const dayStart = new Date(y, m, d), dayEnd = new Date(y, m, d + 1);
  const work = /^\s*(\d{1,2})\s*[-–]\s*(\d{1,2})\s*$/.exec(ctx.settings.work || "");
  const weekStart = new Date(y, m, d - ((now.getDay() + 6) % 7)); // from Monday
  const bars = [
    work ? bar(t("bar.workday"), new Date(y, m, d, +work[1]), new Date(y, m, d, +work[2]), now, "orange")
         : bar(t("bar.day"), dayStart, dayEnd, now, "orange"),
    bar(t("bar.week"), weekStart, new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + 7), now, "pink"),
    bar(t("bar.month"), new Date(y, m, 1), new Date(y, m + 1, 1), now, "purple"),
    bar(t("bar.year"), new Date(y, 0, 1), new Date(y + 1, 0, 1), now, "blue"),
  ];
  const year = bars[3];
  const dayOfYear = Math.floor((dayStart - new Date(y, 0, 1)) / 86400000) + 1;
  const daysInYear = Math.round((new Date(y + 1, 0, 1) - new Date(y, 0, 1)) / 86400000);

  const events = parseEvents(ctx.settings.events, now).sort((a, b) => a.days - b.days).slice(0, 6);
  return {
    date: format.date(now, "weekday"),
    year: String(y),
    yearPct: year.pct,
    yearValue: year.value,
    yearLeft: t("yearLeft", { day: dayOfYear, total: daysInYear, left: `${daysInYear - dayOfYear} ${t("days", { n: daysInYear - dayOfYear })}` }),
    bars,
    events,
    hasEvents: events.length > 0,
    first: events[0] || null,
    weeks: Array.from({ length: 52 }, (_, i) => {
      const week = Math.min(51, Math.floor((dayOfYear - 1) / 7));
      return i < week ? { color: "blue", opacity: 0.9 } : i === week ? { color: "orange", opacity: 1 } : { color: "gray", opacity: 0.22 };
    }),
    weekOfYear: t("weekOf", { n: Math.min(52, Math.floor((dayOfYear - 1) / 7) + 1) }),
  };
}

function bar(title, start, end, now, color) {
  const v = Math.min(1, Math.max(0, (now - start) / (end - start)));
  return { title, value: v, pct: format.percent(v, v < 0.1 ? 1 : 0), color };
}

// "Vacation=2026-12-20, New Year=01-01" → the nearest dates; without a year, yearly.
function parseEvents(text, now) {
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  return String(text || "").split(",").map((s) => s.trim()).filter(Boolean).map((item) => {
    const [name, date] = item.split("=").map((s) => (s || "").trim());
    let m = /^(\d{4})-(\d{1,2})-(\d{1,2})$/.exec(date), when;
    if (m) when = new Date(+m[1], +m[2] - 1, +m[3]);
    else if ((m = /^(\d{1,2})-(\d{1,2})$/.exec(date))) {
      when = new Date(today.getFullYear(), +m[1] - 1, +m[2]);
      if (when < today) when = new Date(today.getFullYear() + 1, +m[1] - 1, +m[2]);
    } else return null;
    const days = Math.round((when - today) / 86400000);
    if (days < 0) return null;
    return {
      name: name || t("event"),
      days,
      count: days === 0 ? t("today") : String(days),
      unit: days === 0 ? "" : t("days", { n: days }),
      when: format.date(when, when.getFullYear() !== today.getFullYear() ? "full" : "long"),
      color: days <= 7 ? "orange" : "primary",
    };
  }).filter(Boolean);
}

