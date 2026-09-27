// Мировое время: часы в выбранных часовых поясах, разница с местным временем и кто сейчас работает.
// Сеть не нужна — часовые пояса знает сам JavaScript (Intl).

async function refresh(ctx) {
  const zones = parseZones(ctx.settings.zones);
  if (zones.length === 0) throw new Error("Добавьте города в настройках: Лондон=Europe/London, Токио=Asia/Tokyo");
  const [workFrom, workTo] = parseWork(ctx.settings.work);
  const now = new Date();
  const here = parts(now, undefined);

  const rows = zones.map(({ name, zone }) => {
    const t = parts(now, zone);
    const diff = Math.round((t.stamp - here.stamp) / 60000); // минуты относительно местного
    const day = t.day === here.day ? "" : t.stamp > here.stamp ? "завтра" : "вчера";
    const status = t.hour >= 23 || t.hour < 7 ? STATUS.night
      : t.weekend ? STATUS.weekend
      : t.hour >= workFrom && t.hour < workTo ? STATUS.work : STATUS.evening;
    return {
      name,
      time: `${pad(t.hour)}:${pad(t.minute)}`,
      diff: diffText(diff),
      day,
      dayLabel: day ? ` · ${day}` : "",
      detail: [diffText(diff), day, t.weekdayName].filter(Boolean).join(" · "),
      status: status.text, icon: status.icon, color: status.color,
    };
  });

  return {
    local: `${pad(here.hour)}:${pad(here.minute)}`,
    rows,
    first: rows[0],
    rest: rows.slice(1, 4),
    working: rows.filter((r) => r.status === STATUS.work.text).length,
    total: rows.length,
  };
}

const STATUS = {
  work: { text: "рабочий день", icon: "briefcase.fill", color: "green" },
  evening: { text: "не на работе", icon: "sunset.fill", color: "orange" },
  night: { text: "ночь", icon: "moon.zzz.fill", color: "indigo" },
  weekend: { text: "выходной", icon: "cup.and.saucer.fill", color: "teal" },
};

// «Лондон=Europe/London, Asia/Tokyo» → [{name, zone}]; без названия — город из имени пояса.
function parseZones(text) {
  return String(text || "").split(",").map((s) => s.trim()).filter(Boolean).map((item) => {
    const [a, b] = item.split("=").map((s) => s.trim());
    const zone = b || a;
    const name = b ? a : zone.split("/").pop().replace(/_/g, " ");
    try { new Intl.DateTimeFormat("en-US", { timeZone: zone }); }
    catch (e) { throw new Error(`Неизвестный часовой пояс «${zone}». Пример: Europe/London, Asia/Tokyo`); }
    return { name, zone };
  });
}

function parseWork(text) {
  const m = /^\s*(\d{1,2})\s*[-–]\s*(\d{1,2})\s*$/.exec(text || "");
  return m ? [Number(m[1]), Number(m[2])] : [9, 18];
}

const WEEKDAYS = { Mon: "пн", Tue: "вт", Wed: "ср", Thu: "чт", Fri: "пт", Sat: "сб", Sun: "вс" };

// Части даты в поясе zone (undefined — местный) и «метка» — те же часы, как если бы это было UTC,
// чтобы разница меток давала разницу поясов.
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
  if (min === 0) return "как у тебя";
  const sign = min > 0 ? "+" : "−";
  const a = Math.abs(min), h = Math.floor(a / 60), m = a % 60;
  return `${sign}${h}${m ? `:${pad(m)}` : ""} ч`;
}

function pad(n) { return String(n).padStart(2, "0"); }
