// Runs on the Mac in a sandbox. Available: fetch (only hosts from permissions.network, HTTPS),
// secrets.get, ctx.settings, storage.get/set, files (from permissions.files), setTimeout/sleep, console,
// t(key, vars) — texts from strings.json in the user's language — and format, helpers for numbers and dates
// (format.number, percent, change, plural, date, relative…). Nothing else.

async function refresh(ctx) {
  const res = await fetch("https://api.example.com/v1/status");
  if (!res.ok) throw new Error(t("httpError", { status: res.status }));
  const data = await res.json();
  // Return only what view.json needs; format numbers and dates here.
  return {
    title: String(data.title ?? "—"),
    value: format.number(data.value, 1),          // «1 234,5»
    change: format.change(data.change),           // «▲ 2,41%»
    changeColor: format.changeColor(data.change), // green / red / secondary for "color" in view.json
    updated: format.time(),
  };
}

// Buttons: { "type": "button", "action": "name" } → action("name", ctx); refresh() is called by itself afterwards.
async function action(name, ctx) {}
