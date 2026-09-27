// Выполняется на Mac в песочнице. Доступно: fetch (только хосты из permissions.network, HTTPS),
// secrets.get, ctx.settings, storage.get/set, setTimeout/sleep, console. Больше ничего нет.

async function refresh(ctx) {
  const res = await fetch("https://api.example.com/v1/status");
  if (!res.ok) throw new Error(`API ответил ${res.status}`);
  const data = await res.json();
  // Верните только то, что нужно view.json; числа и даты отформатируйте здесь.
  return {
    title: String(data.title ?? "—"),
    value: Number(data.value ?? 0).toFixed(1),
  };
}

// Кнопки: { "type": "button", "action": "имя" } → action("имя", ctx); затем refresh() вызывается сам.
async function action(name, ctx) {}
