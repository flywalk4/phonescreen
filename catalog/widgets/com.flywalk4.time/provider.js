// Прогресс дня / недели / месяца / года и обратный отсчёт до дат из настроек. Сеть не нужна.

const MONTHS = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля", "августа", "сентября", "октября", "ноября", "декабря"];
const WEEKDAYS = ["воскресенье", "понедельник", "вторник", "среда", "четверг", "пятница", "суббота"];

async function refresh(ctx) {
  const now = new Date();
  const y = now.getFullYear(), m = now.getMonth(), d = now.getDate();

  const dayStart = new Date(y, m, d), dayEnd = new Date(y, m, d + 1);
  const work = /^\s*(\d{1,2})\s*[-–]\s*(\d{1,2})\s*$/.exec(ctx.settings.work || "");
  const weekStart = new Date(y, m, d - ((now.getDay() + 6) % 7)); // с понедельника
  const bars = [
    work ? bar("Рабочий день", new Date(y, m, d, +work[1]), new Date(y, m, d, +work[2]), now, "orange")
         : bar("День", dayStart, dayEnd, now, "orange"),
    bar("Неделя", weekStart, new Date(weekStart.getFullYear(), weekStart.getMonth(), weekStart.getDate() + 7), now, "pink"),
    bar("Месяц", new Date(y, m, 1), new Date(y, m + 1, 1), now, "purple"),
    bar("Год", new Date(y, 0, 1), new Date(y + 1, 0, 1), now, "blue"),
  ];
  const year = bars[3];
  const dayOfYear = Math.floor((dayStart - new Date(y, 0, 1)) / 86400000) + 1;
  const daysInYear = Math.round((new Date(y + 1, 0, 1) - new Date(y, 0, 1)) / 86400000);

  const events = parseEvents(ctx.settings.events, now).sort((a, b) => a.days - b.days).slice(0, 6);
  return {
    date: `${WEEKDAYS[now.getDay()]}, ${d} ${MONTHS[m]}`,
    year: String(y),
    yearPct: year.pct,
    yearValue: year.value,
    yearLeft: `день ${dayOfYear} из ${daysInYear} · осталось ${plural(daysInYear - dayOfYear, "день", "дня", "дней")}`,
    bars,
    events,
    hasEvents: events.length > 0,
    first: events[0] || null,
  };
}

function bar(title, start, end, now, color) {
  const v = Math.min(1, Math.max(0, (now - start) / (end - start)));
  return { title, value: v, pct: `${(v * 100).toFixed(v < 0.1 ? 1 : 0).replace(".", ",")}%`, color };
}

// «Отпуск=2026-12-20, Новый год=01-01» → ближайшие даты; без года — ежегодно.
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
      name: name || "Событие",
      days,
      count: days === 0 ? "сегодня" : String(days),
      unit: days === 0 ? "" : plural(days, "день", "дня", "дней").split(" ")[1],
      when: `${when.getDate()} ${MONTHS[when.getMonth()]}${when.getFullYear() !== today.getFullYear() ? " " + when.getFullYear() : ""}`,
      color: days <= 7 ? "orange" : "primary",
    };
  }).filter(Boolean);
}

function plural(n, one, few, many) {
  const a = Math.abs(n) % 100, b = a % 10;
  return `${n} ${a > 10 && a < 20 ? many : b === 1 ? one : b >= 2 && b <= 4 ? few : many}`;
}
