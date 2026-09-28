// Привычки: список из настроек, отметка нажатием на телефоне, серия дней подряд и последние 7 дней точками.
// Хранится только то, что отмечено: { "ГГГГ-ММ-ДД": ["Вода", …] } за последние 60 дней. Без сети.

const KEEP_DAYS = 60;

function dayKey(d) {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function daysAgo(n) {
  const d = new Date();
  d.setHours(12, 0, 0, 0); // полдень: перевод часов не сдвинет дату
  d.setDate(d.getDate() - n);
  return dayKey(d);
}

function habits(ctx) {
  const list = String(ctx.settings.habits || "").split(",").map((s) => s.trim()).filter(Boolean);
  return (list.length ? list : t("defaults").split(",").map((s) => s.trim())).slice(0, 8);
}

function load() {
  const done = storage.get("done") || {};
  const oldest = daysAgo(KEEP_DAYS);
  for (const day of Object.keys(done)) if (day < oldest) delete done[day];
  return done;
}

function refresh(ctx) {
  const done = load();
  const names = habits(ctx);
  const today = done[daysAgo(0)] || [];
  const items = names.map((name, index) => {
    const isDone = today.includes(name);
    // Серия: дни подряд до сегодня; сегодня ещё не отмечено — считаем от вчера, серия не сгорает до полуночи.
    let streak = 0;
    for (let n = isDone ? 0 : 1; n < KEEP_DAYS; n++) {
      if ((done[daysAgo(n)] || []).includes(name)) streak++;
      else break;
    }
    const week = Array.from({ length: 7 }, (_, i) => ((done[daysAgo(6 - i)] || []).includes(name) ? "●" : "○")).join(" ");
    return {
      index, name, done: isDone,
      icon: isDone ? "checkmark.circle.fill" : "circle",
      color: isDone ? "green" : "secondary",
      streak: streak ? t("streak", { n: streak }) : t("noStreak"),
      week,
    };
  });
  const count = items.filter((h) => h.done).length;
  const total = items.length;
  return {
    habits: items,
    count, total,
    progress: total ? count / total : 0,
    ratio: `${count}/${total}`,
    color: count === total ? "green" : "accent",
    summary: count === total ? t("allDone") : t("left", { n: total - count }),
  };
}

// Нажатие на привычку — отметить или снять отметку за сегодня.
function action(name, ctx) {
  const m = /^toggle:(\d+)$/.exec(name);
  if (!m) return;
  const habit = habits(ctx)[Number(m[1])];
  if (!habit) return;
  const done = load();
  const key = daysAgo(0);
  const today = done[key] || [];
  done[key] = today.includes(habit) ? today.filter((h) => h !== habit) : [...today, habit];
  storage.set("done", done);
}
