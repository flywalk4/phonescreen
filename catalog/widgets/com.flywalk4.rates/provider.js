// Exchange rates: what 1 unit of each currency costs in the target currency (rubles by default).
// Data: https://open.er-api.com (free, no key, updated once a day).

async function refresh(ctx) {
  const target = (ctx.settings.target || "RUB").trim().toUpperCase();
  const codes = (ctx.settings.codes || "USD,EUR,CNY")
    .split(",").map((c) => c.trim().toUpperCase()).filter((c) => c && c !== target);

  const res = await fetch(`https://open.er-api.com/v6/latest/${target}`);
  if (!res.ok) throw new Error(t("httpError", { status: res.status }));
  const data = await res.json();
  if (data.result !== "success") throw new Error(t("noRates", { target }));

  // The API gives "how much X for 1 target"; we need "how much target for 1 X".
  const rows = codes
    .filter((code) => data.rates[code])
    .map((code) => ({ code, raw: 1 / data.rates[code] }));
  if (rows.length === 0) throw new Error(t("noneFound"));

  // History of the first currency for the chart and the change. At most 30 points, one a day.
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
    main: { code: rows[0].code, value: amount(rows[0].raw) },
    change: prev ? `${change >= 0 ? "▲" : "▼"} ${Math.abs(change) >= 0.01 ? format.number(Math.abs(change), 2) : amount(Math.abs(change))}` : "",
    changeColor: change >= 0 ? "green" : "red",
    rows: rows.map((r) => ({ code: r.code, value: amount(r.raw) })),
    history: history.map((h) => h.value),
    hasHistory: history.length > 1,
    updated: format.date(new Date(data.time_last_update_unix * 1000), "short"),
  };
}

// The Refresh button: nothing to do — the widget refreshes by itself after action().
async function action(name, ctx) {}

function amount(v) {
  return format.number(v, v >= 100 ? 1 : v >= 1 ? 2 : 4);
}
