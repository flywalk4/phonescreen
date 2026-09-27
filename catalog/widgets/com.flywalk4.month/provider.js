// Месяц: календарь-сетка текущего месяца — сегодня выделено, выходные и праздники РФ цветом, номер недели,
// сколько рабочих дней осталось. Сеть не нужна.

const WEEKDAYS = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"];
const MONTHS = ["Январь", "Февраль", "Март", "Апрель", "Май", "Июнь", "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь"];
// Нерабочие праздники РФ (ММ-ДД). Переносы выходных каждый год свои — их можно добавить в настройках.
const HOLIDAYS = ["01-01", "01-02", "01-03", "01-04", "01-05", "01-06", "01-07", "01-08", "02-23", "03-08", "05-01", "05-09", "06-12", "11-04"];

function refresh(ctx) {
  const now = new Date();
  const holidays = new Set([...HOLIDAYS, ...extra(ctx.settings.holidays)]);
  const month = grid(now.getFullYear(), now.getMonth(), now, holidays);
  const next = grid(now.getFullYear() + (now.getMonth() === 11 ? 1 : 0), (now.getMonth() + 1) % 12, now, holidays);
  const workLeft = month.days.filter((d) => d.day >= now.getDate() && d.work).length;
  const workTotal = month.days.filter((d) => d.work).length;
  return {
    title: `${MONTHS[now.getMonth()]} ${now.getFullYear()}`,
    month: MONTHS[now.getMonth()],
    weekdays: WEEKDAYS.map((d, i) => ({ d, color: i >= 5 ? "red" : "secondary" })),
    cells: month.cells,
    nextTitle: MONTHS[(now.getMonth() + 1) % 12],
    nextCells: next.cells,
    day: String(now.getDate()),
    weekday: format.date(now, "weekday").split(",")[0],
    week: `неделя ${isoWeek(now)}`,
    work: `рабочих дней: осталось ${workLeft} из ${workTotal}`,
    workShort: `${workLeft} раб. ${format.plural(workLeft, "день", "дня", "дней", false)}`,
    progress: workTotal ? 1 - workLeft / workTotal : 1,
    holiday: holidays.has(key(now)) ? "праздник" : "",
  };
}

// Клетки месяца по неделям с понедельника: пустые до 1-го числа и после последнего.
function grid(year, monthIndex, today, holidays) {
  const first = new Date(year, monthIndex, 1);
  const length = new Date(year, monthIndex + 1, 0).getDate();
  const offset = (first.getDay() + 6) % 7;
  const days = [];
  for (let day = 1; day <= length; day++) {
    const date = new Date(year, monthIndex, day);
    const weekend = date.getDay() === 0 || date.getDay() === 6;
    const holiday = holidays.has(key(date));
    const isToday = date.toDateString() === today.toDateString();
    const past = date < today && !isToday;
    days.push({
      day, work: !weekend && !holiday,
      text: String(day),
      color: isToday ? "accent" : weekend || holiday ? "red" : past ? "secondary" : "primary",
      background: isToday ? "accent" : "clear",
      opacity: isToday ? 0.22 : 1,
      weight: isToday ? "bold" : "regular",
    });
  }
  const blank = { text: " ", color: "secondary", background: "clear", opacity: 1, weight: "regular" };
  const cells = [...Array(offset).fill(blank), ...days];
  while (cells.length % 7) cells.push(blank);
  return { days, cells };
}

function key(date) {
  return `${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

// «2026-12-31, 05-04» → ["12-31", "05-04"] (год не важен: даты те же каждый год, кроме указанных).
function extra(text) {
  return String(text || "").split(",").map((s) => s.trim().slice(-5)).filter((s) => /^\d\d-\d\d$/.test(s));
}

function isoWeek(date) {
  const d = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  d.setUTCDate(d.getUTCDate() + 4 - (d.getUTCDay() || 7));
  return Math.ceil(((d - Date.UTC(d.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
}
