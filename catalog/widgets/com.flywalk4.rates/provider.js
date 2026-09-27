// Курсы валют: сколько стоит 1 единица каждой валюты в целевой валюте (по умолчанию в рублях).
// Данные: https://open.er-api.com (бесплатно, без ключа, обновляются раз в сутки).

async function refresh(ctx) {
  const target = (ctx.settings.target || "RUB").trim().toUpperCase();
  const codes = (ctx.settings.codes || "USD,EUR,CNY")
    .split(",").map((c) => c.trim().toUpperCase()).filter((c) => c && c !== target);

  const res = await fetch(`https://open.er-api.com/v6/latest/${target}`);
  if (!res.ok) throw new Error(`Сервер курсов ответил ${res.status}`);
  const data = await res.json();
  if (data.result !== "success") throw new Error(`Нет курсов для ${target}`);

  // API отдаёт «сколько X за 1 target»; нам нужно «сколько target за 1 X».
  const rows = codes
    .filter((code) => data.rates[code])
    .map((code) => ({ code, raw: 1 / data.rates[code] }));
  if (rows.length === 0) throw new Error("Ни одна из валют не найдена — проверьте коды в настройках");

  // История первой валюты — для графика и изменения. Храним не больше 30 точек, по одной в день.
  const day = new Date(data.time_last_update_unix * 1000).toISOString().slice(0, 10);
  let history = storage.get("history") || [];
  if (history.length === 0 || history[history.length - 1].day !== day) {
    history.push({ day, value: rows[0].raw });
    history = history.slice(-30);
    storage.set("history", history);
  }
  const prev = history.length > 1 ? history[history.length - 2].value : null;
  const change = prev ? rows[0].raw - prev : 0;

  return {
    target,
    main: { code: rows[0].code, value: format(rows[0].raw) },
    change: prev ? `${change >= 0 ? "▲" : "▼"} ${format(Math.abs(change))}` : "",
    changeColor: change >= 0 ? "green" : "red",
    rows: rows.map((r) => ({ code: r.code, value: format(r.raw) })),
    history: history.map((h) => h.value),
    hasHistory: history.length > 1,
    updated: day.split("-").reverse().join("."),
  };
}

// Кнопка «Обновить»: делать ничего не нужно — после action() виджет обновляется сам.
async function action(name, ctx) {}

function format(v) {
  return v >= 100 ? v.toFixed(1) : v >= 1 ? v.toFixed(2) : v.toFixed(4);
}
