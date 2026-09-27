// Hacker News: истории из официального API (hacker-news.firebaseio.com, без ключа).

const LISTS = { top: "topstories", best: "beststories", new: "newstories", ask: "askstories", show: "showstories" };

async function refresh(ctx) {
  const list = LISTS[(ctx.settings.list || "top").trim().toLowerCase()] || LISTS.top;
  const count = Math.min(12, Math.max(1, Number(ctx.settings.count) || 8));
  const ids = await get(`https://hacker-news.firebaseio.com/v0/${list}.json`);
  const items = (await Promise.all(ids.slice(0, count).map((id) => get(`https://hacker-news.firebaseio.com/v0/item/${id}.json`).catch(() => null))))
    .filter((i) => i && i.title);
  if (items.length === 0) throw new Error("Hacker News не вернул истории");
  const now = Date.now() / 1000;
  const stories = items.map((i, n) => ({
    rank: String(n + 1),
    title: i.title,
    site: site(i.url) || (i.title.startsWith("Ask HN") ? "Ask HN" : "news.ycombinator.com"),
    points: String(i.score || 0),
    comments: String(i.descendants || 0),
    age: age(now - i.time),
    hot: (i.score || 0) >= 300,
    pointsColor: (i.score || 0) >= 300 ? "orange" : "secondary",
  }));
  return { stories, top: stories[0], rest: stories.slice(1), listName: Object.keys(LISTS).find((k) => LISTS[k] === list) };
}

async function get(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Hacker News ответил ${res.status}`);
  return res.json();
}

function site(url) {
  const m = /^https?:\/\/(?:www\.)?([^/]+)/.exec(url || "");
  return m ? m[1] : "";
}

function age(sec) {
  if (sec < 3600) return `${Math.max(1, Math.round(sec / 60))} мин`;
  if (sec < 86400) return `${Math.round(sec / 3600)} ч`;
  return `${Math.round(sec / 86400)} д`;
}
