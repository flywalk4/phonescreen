// Выполняется на Mac в песочнице. Доступно: fetch (только хосты из permissions.network, HTTPS),
// secrets.get, ctx.settings, storage.get/set, files (из permissions.files), setTimeout/sleep, console
// и format — помощники для чисел и дат (format.number, percent, change, plural, date, relative…). Больше ничего нет.

async function refresh(ctx) {
  const res = await fetch("https://api.example.com/v1/status");
  if (!res.ok) throw new Error(`API ответил ${res.status}`);
  const data = await res.json();
  // Верните только то, что нужно view.json; числа и даты отформатируйте здесь.
  return {
    title: String(data.title ?? "—"),
    value: format.number(data.value, 1),          // «1 234,5»
    change: format.change(data.change),           // «▲ 2,41%»
    changeColor: format.changeColor(data.change), // green / red / secondary для "color" в view.json
    updated: format.time(),
  };
}

// Кнопки: { "type": "button", "action": "имя" } → action("имя", ctx); затем refresh() вызывается сам.
async function action(name, ctx) {}
