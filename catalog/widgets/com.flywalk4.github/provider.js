// GitHub: PR на твоё ревью, твои открытые PR и число непрочитанных уведомлений (REST API, токен из Связки ключей).

async function refresh(ctx) {
  const token = secrets.get("token");
  if (!token) throw new Error("Добавьте GitHub токен в настройках виджета");
  const [review, mine, notifications] = await Promise.all([
    search("is:open is:pr review-requested:@me archived:false", token),
    search("is:open is:pr author:@me archived:false", token),
    api("https://api.github.com/notifications?per_page=50", token).catch(() => []),
  ]);
  const now = Date.now() / 1000;
  const row = (i) => ({
    title: i.title,
    repo: i.repository_url.split("/").slice(-2).join("/"),
    number: `#${i.number}`,
    age: age(now - Date.parse(i.updated_at) / 1000),
    draft: Boolean(i.draft),
    comments: String(i.comments || 0),
    color: i.draft ? "secondary" : "green",
  });
  return {
    reviewCount: String(review.total_count),
    mineCount: String(mine.total_count),
    unread: String(notifications.length >= 50 ? "50+" : notifications.length),
    review: review.items.slice(0, 5).map(row),
    mine: mine.items.slice(0, 5).map(row),
    hasReview: review.items.length > 0,
    hasMine: mine.items.length > 0,
    reviewColor: review.total_count > 0 ? "orange" : "green",
    allClear: review.total_count === 0,
  };
}

function search(q, token) {
  return api(`https://api.github.com/search/issues?per_page=5&sort=updated&q=${encodeURIComponent(q)}`, token);
}

async function api(url, token) {
  const res = await fetch(url, { headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" } });
  if (res.status === 401) throw new Error("GitHub не принял токен — проверьте его в настройках");
  if (res.status === 403) throw new Error("GitHub: лимит запросов или у токена нет прав");
  if (!res.ok) throw new Error(`GitHub ответил ${res.status}`);
  return res.json();
}

function age(sec) {
  if (!isFinite(sec)) return "";
  if (sec < 3600) return `${Math.max(1, Math.round(sec / 60))} мин`;
  if (sec < 86400) return `${Math.round(sec / 3600)} ч`;
  return `${Math.round(sec / 86400)} д`;
}
