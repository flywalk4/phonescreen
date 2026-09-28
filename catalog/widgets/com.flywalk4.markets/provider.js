// Crypto and stocks: price, the 24-hour change (crypto) or the change since yesterday's close (stocks), a chart.
// Data: CoinGecko (public API, no key) and the Moscow Exchange's ISS (iss.moex.com).

async function refresh(ctx) {
  const s = ctx.settings;
  const coins = list(s.crypto);
  const stocks = list(s.stocks).map((t) => t.toUpperCase());
  if (coins.length === 0 && stocks.length === 0) throw new Error(t("nothingSet"));
  const vs = (s.currency || "usd").trim().toLowerCase();

  const errors = [];
  const [crypto, shares] = await Promise.all([
    coins.length ? cryptoRows(coins, vs).catch((e) => { errors.push(e.message); return []; }) : [],
    stocks.length ? stockRows(stocks).catch((e) => { errors.push(e.message); return []; }) : [],
  ]);
  const rows = [...crypto, ...shares];
  const found = new Set(rows.map((r) => r.ticker));
  const missing = [...coins.map((c) => c.toUpperCase()), ...stocks].filter((t) => !found.has(t));
  if (missing.length && errors.length === 0) errors.push(t("notFound", { list: missing.join(", ") }));
  if (rows.length === 0) throw new Error(errors.join("; ") || t("nothingFound"));

  const wanted = (s.chart || "").trim().toUpperCase();
  const main = rows.find((r) => r.ticker === wanted) || rows[0];
  const chart = await (main.kind === "crypto" ? cryptoChart(main.id, vs) : stockChart(main.ticker)).catch(() => []);

  const plain = rows.map(({ id, kind, ...r }) => r);
  return {
    rows: plain,
    rest: plain.filter((r) => r.ticker !== main.ticker),
    others: plain.filter((r) => r.ticker !== main.ticker).slice(0, 4),
    main,
    chart,
    hasChart: chart.length > 1,
    chartColor: chart.length > 1 && chart[chart.length - 1] < chart[0] ? "red" : "green",
    warning: errors.join("; "),
    updated: time(new Date()),
  };
}

// ---- Crypto ----

// Ticker → CoinGecko id for popular coins; anything else is taken as an id as is (bitcoin, the-open-network…).
const COINS = {
  BTC: "bitcoin", ETH: "ethereum", TON: "the-open-network", SOL: "solana", USDT: "tether", USDC: "usd-coin",
  BNB: "binancecoin", XRP: "ripple", DOGE: "dogecoin", ADA: "cardano", TRX: "tron", LTC: "litecoin",
  DOT: "polkadot", AVAX: "avalanche-2", LINK: "chainlink", XMR: "monero", NOT: "notcoin", SUI: "sui",
};

async function cryptoRows(coins, vs) {
  const items = coins.map((c) => ({ ticker: c.toUpperCase(), id: COINS[c.toUpperCase()] || c.toLowerCase() }));
  const ids = [...new Set(items.map((i) => i.id))].join(",");
  const data = await getJSON(`https://api.coingecko.com/api/v3/simple/price?ids=${encodeURIComponent(ids)}`
    + `&vs_currencies=${encodeURIComponent(vs)}&include_24hr_change=true`, "CoinGecko");
  return items.filter((i) => data[i.id] && data[i.id][vs] != null).map((i) => {
    const change = data[i.id][`${vs}_24h_change`];
    return row("crypto", i.ticker, i.id, data[i.id][vs], vs, change, t("period.day"));
  });
}

async function cryptoChart(id, vs) {
  const data = await getJSON(`https://api.coingecko.com/api/v3/coins/${encodeURIComponent(id)}/market_chart`
    + `?vs_currency=${encodeURIComponent(vs)}&days=1`, "CoinGecko");
  return thin((data.prices || []).map((p) => p[1]));
}

// ---- Moscow Exchange ----

async function stockRows(tickers) {
  const data = await getJSON("https://iss.moex.com/iss/engines/stock/markets/shares/boards/TQBR/securities.json"
    + `?securities=${tickers.join(",")}&iss.meta=off&iss.only=securities,marketdata`
    + "&securities.columns=SECID,SHORTNAME,PREVPRICE&marketdata.columns=SECID,LAST,LCURRENTPRICE", t("moex"));
  const info = table(data.securities), market = table(data.marketdata);
  return tickers.map((code) => {
    const a = info.find((r) => r.SECID === code), b = market.find((r) => r.SECID === code) || {};
    if (!a) return null;
    const live = b.LAST ?? b.LCURRENTPRICE; // empty outside trading hours: then the close price with no change
    const price = live ?? a.PREVPRICE;
    if (price == null) return null;
    const change = live != null && a.PREVPRICE ? (live / a.PREVPRICE - 1) * 100 : null;
    return { ...row("stock", code, code, price, "rub", change, t("period.close")), name: format.lang === "ru" ? a.SHORTNAME || code : code, noTrades: live == null };
  }).filter(Boolean);
}

async function stockChart(ticker) {
  const from = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
  const data = await getJSON(`https://iss.moex.com/iss/engines/stock/markets/shares/boards/TQBR/securities/${ticker}`
    + `/candles.json?interval=60&from=${from}&iss.meta=off`, t("moex"));
  return thin(table(data.candles).map((c) => c.close).filter((v) => v != null));
}

// ISS returns tables as { columns: [...], data: [[...]] }.
function table(t) {
  if (!t || !t.columns) return [];
  return (t.data || []).map((r) => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
}

// ---- Shared ----

async function getJSON(url, source) {
  const res = await fetch(url);
  if (res.status === 429) throw new Error(t("tooOften", { source }));
  if (!res.ok) throw new Error(t("httpError", { source, status: res.status }));
  return res.json();
}

const SIGNS = { usd: "$", eur: "€", rub: "₽", gbp: "£", cny: "¥", jpy: "¥", usdt: "₮" };

function row(kind, ticker, id, price, vs, change, period) {
  const up = change == null || change >= 0;
  return {
    kind, id, ticker, name: ticker,
    price: money(price, vs),
    change: change == null ? "" : format.change(change),
    changeColor: change == null ? "secondary" : up ? "green" : "red",
    period,
  };
}

function money(v, vs) {
  const digits = v >= 1000 ? 0 : v >= 1 ? 2 : v >= 0.01 ? 4 : 8;
  const n = format.number(v, digits);
  const sign = SIGNS[vs];
  return sign ? (vs === "usd" ? `${sign}${n}` : `${n} ${sign}`) : `${n} ${vs.toUpperCase()}`;
}

function list(text) { return String(text || "").split(",").map((s) => s.trim()).filter(Boolean).slice(0, 12); }

// At most 120 points per chart.
function thin(values) {
  if (values.length <= 120) return values;
  const step = values.length / 120;
  return Array.from({ length: 120 }, (_, i) => values[Math.floor(i * step)]).concat(values[values.length - 1]);
}

function time(d) { return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`; }

// The Refresh button: the widget refreshes by itself after action().
async function action(name, ctx) {}
