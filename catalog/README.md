# PhoneScreen widget catalog

**English** · [Русский](README.ru.md)

A widget is a folder of three files. The logic (`provider.js`) runs **on the Mac** in a JavaScriptCore sandbox; the interface (`view.json`) is declarative: the Mac fills in the data and sends the phone a finished tree of elements, which the phone draws natively. No third-party code runs on the phone.

```
catalog/widgets/com.author.mywidget/
  manifest.json   — who, what, which permissions
  view.json       — layout for the full / medium / small sizes
  provider.js     — async function refresh(ctx) { … return data }
  strings.json    — optional: texts in several languages
```

## Adding a widget to the catalog

1. Create a folder `catalog/widgets/<id>/` (folder name = the manifest's `id`). The easiest start is the template: `node scripts/widget-dev.mjs new com.you.widget --name "Name"` (a working widget with all three sizes, a setting, `storage`, buttons and a scenario).
2. Check it: `python3 scripts/validate-widget.py catalog/widgets/<id>` (with `--hints`, advice too: hex colours themes can't restyle, buttons in a small tile).
3. Run it for real (needs a built Mac agent): `PhoneScreen --widget-test catalog/widgets/<id>` runs `refresh()` in the same sandbox as the app and prints the data and the final tree.
4. Update the index: `python3 scripts/build-catalog.py` (SHA-256 hashes of every file; the app won't install a file with a different hash).
5. Add scenarios to `fixtures/` (at least "all good" and "API down") and check them: `node scripts/widget-dev.mjs test catalog/widgets/<id>`.
6. Open a pull request. The reviewer looks at `permissions` and where `fetch` goes first of all.

**Without a Mac** (Linux, Windows, CI, an AI agent in the cloud): `scripts/widget-dev.mjs` on Node 18+:

```bash
node scripts/widget-dev.mjs new com.you.widget --name "Name"                 # a starter widget + fixtures/ok.json
node scripts/widget-dev.mjs watch catalog/widgets/<id> --theme ascii          # on every save: refresh() + preview.png
node scripts/widget-dev.mjs run catalog/widgets/<id> --fixture ok --views     # refresh() in an emulated sandbox + the tree for the phone
node scripts/widget-dev.mjs preview catalog/widgets/<id> out.png --theme glass # an approximate PNG of all three sizes (needs Playwright)
node scripts/widget-dev.mjs test                                              # every fixtures/ scenario of every widget
```

Add `--lang ru` to `run`, `preview`, `watch` or `bundle` to see the widget in another language.

Scenarios live in `catalog/widgets/<id>/fixtures/*.json` (the app doesn't download them): API answers (`fetch`), settings, secrets, `storage`, files, taps (`actions`), time (`now`, `timezone`), language (`lang`) and what should come out (`expect` by paths in the data, or `error`). The format is described at the top of `scripts/widget-dev.mjs`. A pull request to the catalog is checked automatically: validators, an up-to-date `index.json` and every scenario. The emulation mirrors the sandbox's API and limits, but the final check is `--widget-test` on a Mac.

**Editor hints.** `schemas/` holds JSON Schemas for `view.json`, `manifest.json` and `theme.json` (every node, field, style and colour). VS Code picks them up for `catalog/` through `.vscode/settings.json`; in your own file a first line is enough: `"$schema": "https://raw.githubusercontent.com/flywalk4/phonescreen/main/schemas/view.schema.json"`. The schemas are generated from the validator's rules: `python3 scripts/build-schemas.py`.

While developing on a Mac, **Settings → Widgets → "Development folder…"** is handier: save a file and the widget reloads on the iPhone by itself. The `console.log` and error log is there too.

## manifest.json

```json
{
  "id": "com.author.mywidget",
  "name": "My widget",
  "version": "1.0.0",
  "author": "author",
  "description": "A sentence or two for the catalog.",
  "symbol": "sparkles",
  "refresh": 300,
  "permissions": {
    "network": ["api.example.com"],
    "secrets": [{ "key": "token", "title": "API token" }]
  },
  "settings": [
    { "key": "city", "title": "City", "default": "London", "hint": "or coordinates “51.5, -0.12”" },
    { "key": "units", "title": "Units", "type": "choice", "default": "c",
      "options": [{ "value": "c", "title": "°C" }, { "value": "f", "title": "°F" }] },
    { "key": "wind", "title": "Show wind", "type": "toggle", "default": "true" },
    { "key": "days", "title": "Forecast days", "type": "number", "min": 1, "max": 7, "default": "3" }
  ]
}
```

| Field | |
| --- | --- |
| `id` | reverse domain; lowercase Latin letters, digits, dots: `com.author.widget` |
| `name` | up to 40 characters |
| `version` | `1.2.3`; bump it to publish an update in the catalog |
| `symbol` | an SF Symbol name |
| `refresh` | seconds between `refresh()` calls, 300 by default; at least 30 with network access and 5 without |
| `permissions.network` | domains `fetch` may reach (subdomains included). HTTPS only, redirects are checked too. No scheme, path or `*` |
| `permissions.secrets` | secrets (API keys): the user enters them in the settings; they're kept in the Mac's Keychain |
| `permissions.files` | read-only access to files in the home folder: `~/folder/` (the whole folder) or `~/folder/file`. Symbolic links pointing outside won't pass |
| `settings` | settings the user changes on the Mac. `type`: `text` (a field, the default), `choice` (a pop-up menu; `options` are strings or `{ "value", "title" }`, up to three short ones become a segmented control), `toggle` (a switch, value `"true"` / `"false"`), `number` (a slider when `min` and `max` are set, otherwise a stepper field; also `step` and `unit`). `title` is a short label; explanations and examples go in `hint`. Values reach the script as strings |

The user sees every permission before installing.

## provider.js

```js
// Required: return the data for view.json. May be async.
async function refresh(ctx) {
  const res = await fetch("https://api.example.com/v1/items", {
    headers: { Authorization: `Bearer ${secrets.get("token")}` },
  });
  if (!res.ok) throw new Error(t("httpError", { status: res.status })); // the user sees the error text
  const items = await res.json();
  return { count: items.length, items: items.slice(0, 5).map((i) => ({ title: i.name })) };
}

// Optional: a tap on { "type": "button", "action": "…" }. refresh() is called by itself afterwards.
async function action(name, ctx) {
  if (name === "clear") storage.set("seen", []);
}
```

Available in the sandbox, and nothing else (no `require`, `import`, processes, `XMLHttpRequest`, `WebSocket`, or files outside `permissions.files`):

| API | |
| --- | --- |
| `fetch(url, {method, headers, body})` | like in a browser, simplified: `res.ok`, `res.status`, `res.headers.get(k)`, `await res.text()`, `await res.json()`. Only hosts from `permissions.network`, answers up to 2 MB, a 15 s timeout |
| `secrets.get(key)` | a string, or `null` (not set, or not declared in the manifest) |
| `ctx.settings.<key>` | values from `settings` (strings) |
| `ctx.lang` | the widget's language: `"en"`, `"ru"`… (also `format.lang`) |
| `t(key, vars)` | the widget's text `key` in the current language from `strings.json` (see [Languages](#languages)) |
| `files.read("~/…")` / `files.modified("~/…")` | the file's text (up to 1 MB) or `null`; the modification time (Unix seconds) or `null`. Only paths from `permissions.files` |
| `files.lines("~/…", {offset, length})` | whole lines starting at byte `offset` (at most `length`, up to 1 MB): `{ lines, next, size }`. Pass `next` to the next call — that's how large logs are read in chunks, and only new lines. A line longer than the limit is skipped |
| `files.list("~/…/")` | a folder's contents: `[{ name, dir, size, modified }]` (hidden files skipped, up to 2000) or `null` |
| `storage.get(key)` / `storage.set(key, value)` | a small persistent store (JSON, up to 64 KB per widget) — history, a cache |
| `setTimeout(fn, ms)`, `sleep(ms)` | delays (up to 60 s) |
| `console.log/warn/error` | to the widget's log in the settings |

Limits: code runs for at most 2 s in a row (waiting for `fetch` doesn't count), the whole `refresh()` for at most 20 s.

**`format`**: ready-made helpers for numbers and dates in the widget's language (a global object, the same in the app and in `widget-dev`; the code is `Mac/Widgets/prelude.js`). Examples in English / Russian:

| | |
| --- | --- |
| `format.number(1234.5)` / `format.number(x, 2)` | `"1,234.5"` / `"1 234,5"`; exactly 2 digits after the point |
| `format.compact(1234567)` | `"1.2M"`, `"12K"` / `"1,2 млн"`, `"12 тыс."` |
| `format.percent(0.421)` / `format.percent(0.421, 1)` | `"42%"` / `"42.1%"` |
| `format.change(-1.07)` + `format.changeColor(-1.07)` | `"▼ 1.07%"` and `"red"` (for `color` in `view.json`) |
| `format.plural(5, {one: "day", other: "days"})` | `"5 days"`; Russian forms also work as `format.plural(5, "день", "дня", "дней")` |
| `format.time(date)` / `format.date(date, "short" \| "long" \| "weekday" \| "full")` | `"14:05"` / `"Sep 27"`, `"September 27"`, `"Sunday, September 27"`, `"September 27, 2026"` |
| `format.duration(7500)` / `format.relative(date)` | `"2 h 5 min"` / `"5 min ago"`, `"in 2 h"`, `"yesterday"` |
| `format.bytes(1572864)` / `format.level(0.9)` | `"1.5 MB"` / `"red"` (green → orange → red) |

## Languages

The app is in English by default and in Russian when the user picks it (the Mac's settings, at the foot of the sidebar). A widget speaks the user's language through an optional `strings.json`:

```json
{
  "en": {
    "manifest.name": "My widget",
    "settings.city.title": "City",
    "header": "ITEMS",
    "httpError": "The API answered {status}",
    "items": { "one": "{n} item", "other": "{n} items" }
  },
  "ru": {
    "manifest.name": "Мой виджет",
    "settings.city.title": "Город",
    "header": "ЗАДАЧИ",
    "httpError": "API ответил {status}",
    "items": { "one": "{n} задача", "few": "{n} задачи", "many": "{n} задач", "other": "{n} задачи" }
  }
}
```

- In `provider.js`: `t("httpError", { status: 500 })`; a plural string picks its form by `n`: `t("items", { n: 3 })`. Don't name a local variable `t`: it would hide the function.
- In `view.json`: `"{{t.header}}"`, mixed with data as usual: `"{{count}} {{t.unit}}"`. For a phrase with numbers inside, build it in `provider.js` and bind the result.
- The manifest's texts: `manifest.name`, `manifest.description`, `settings.<key>.title`, `settings.<key>.hint`, `settings.<key>.unit`, `settings.<key>.options.<value>`, `secrets.<key>.title`. Keep `manifest.json` itself in English.
- A language the widget doesn't have falls back to English; a key missing in one language is taken from English. A missing key shows up as the key itself, so a gap is visible.
- Numbers, dates and durations: use `format`, which already follows the language. Pass `format.lang` to APIs that take a language (a geocoder's `language=`).

## view.json

The keys are sizes: `full` (the whole page), `medium` (half a page), `small` (a quarter). One is enough: a missing size is taken from the nearest one. Small ones should show only what matters most.

```json
{
  "full": { "type": "vstack", "spacing": 12, "children": [
    { "type": "text", "text": "{{t.tasks}}: {{count}}", "style": "title" },
    { "type": "list", "items": "{{items}}", "template": { "type": "text", "text": "• {{item.title}}" } },
    { "type": "button", "title": "{{t.clear}}", "symbol": "trash", "action": "clear" }
  ]},
  "small": { "type": "text", "text": "{{count}}", "style": "largeTitle" }
}
```

**Bindings.** Any string may hold `{{path}}` into the data from `refresh()`: `{{a.b}}`, `{{rows.0.name}}`; `{{t.key}}` is a text from `strings.json`. If a string is only a binding (`"{{ratio}}"`), the value keeps its type (a number, an array); otherwise it's inserted as text. Inside `list`, `{{item.…}}` and `{{index}}` are available. No value, an empty string.

**`"if": "{{path}}"`** on any node hides it when the value is empty / `false` / `0` / an empty array.

| type | fields |
| --- | --- |
| `vstack`, `hstack` | `children`, `spacing`, `align` (vstack: `leading`/`center`/`trailing`; hstack: `top`/`center`/`bottom`/`baseline`) |
| `text` | `text`, `style` (`largeTitle` `title` `title2` `title3` `headline` `body` `callout` `subheadline` `footnote` `caption` `caption2`), `color`, `lines`, `align`; a font of your own: `size` (pt), `weight` (`light` `regular` `medium` `semibold` `bold` `heavy` `black`…), `design` (`rounded` `monospaced` `serif`; the theme's font by default) |
| `symbol` | `name` (SF Symbol), `color`, `size` |
| `gauge` | `value` (0…1), `label`, `color`: a ring |
| `progress` | `value` (0…1), `color`: a bar |
| `chart` | `values` (an array of numbers, up to 200), `color`, `style` (`line`, `area` — a line with a gradient fill, `bar`), `height` |
| `button` | `title`, `symbol`, `action` → `action(name)` in provider.js; pressed with a finger or the Mac's cursor. `action` may hold a binding: `"tap:{{index}}"` |
| `box` | a panel: `children` in a column on a rounded backing. `padding` (12), `spacing`, `align`, `radius`; `background` + `opacity` for a colour of your own, without them a backing in the theme's style (glass in Liquid Glass, a frame in ASCII). `fit: true` sizes it to the content ("pills"), otherwise it's full width. `action` makes the whole panel a button (game cells, tiles). `aspect` keeps proportions (1 is a square) |
| `grid` | `children` in `columns` columns (1–16), `spacing` |
| `list` | `items` (an array), `template` (a node), `spacing`, `align`; `columns` for a grid of N columns |
| `sprite` | pixel animation: `frames` is an array of frames, a frame is an array of equal-length strings (up to 48×48, up to 16 frames); `palette` maps a character to a colour (`.` and space are transparent); `fps`. Scales to fit. Frames are easy to draw in code in provider.js |
| `spacer`, `divider` | — |

Colours: `primary` `secondary` `tertiary` `accent` `red` `orange` `yellow` `green` `mint` `teal` `cyan` `blue` `indigo` `purple` `pink` `brown` `gray` `white`, `clear` (a `box` without backing) or `#RRGGBB`. An unknown `type` is skipped. At most 500 elements and 2000 characters per text.

### Making it look good

Every catalog widget follows the same rules, so pages look of a piece:

- **Header**: small: a coloured symbol + a `caption` label, `weight: semibold`, `color: secondary`, in capitals (`"MARKETS"`). On the right, something secondary (a city, the update time) or a button.
- **The main number**: large: `size` 40–84, `weight: bold`, `design: rounded`. One per widget.
- **Changes and statuses** as a "pill": a `box` with `fit: true`, `padding` 5–7, `radius` 8, `background` in the status colour, `opacity: 0.18`, with text of the same colour inside.
- **Groups of data** in a `box` (the backing takes the theme's style); small figures as tiles: a `list` with `columns: 2` and a `box` in the template.
- **Charts**: `style: area` for rates and trends, `bar` for hourly forecasts.
- **Colours**: names (`green`, `orange`, `secondary`, `accent`), not `#RRGGBB`: themes restyle them. Hex only for colours of your own (a logo, a pixel character).
- **Three sizes, three designs**: `full` has everything in detail; `medium` the main number, a chart, 3–4 figures; `small` one number and a label large, the rest small below.

Complete examples: [`widgets/com.flywalk4.markets`](widgets/com.flywalk4.markets) (network, tiles, an area chart), [`widgets/com.flywalk4.claude-code`](widgets/com.flywalk4.claude-code) (local files, an animated sprite), [`widgets/com.flywalk4.focus`](widgets/com.flywalk4.focus) (buttons and state), [`widgets/com.flywalk4.habits`](widgets/com.flywalk4.habits) (two languages with plurals), [`widgets/com.flywalk4.game2048`](widgets/com.flywalk4.game2048) and [`widgets/com.flywalk4.minesweeper`](widgets/com.flywalk4.minesweeper) (games: a board of tappable panels).

**Games and anything interactive.** Every tap is `action(name)` on the Mac followed by `refresh()` by itself, so turn-based games fit well. Keep the state in `storage` and save a new game as soon as it's created (otherwise the board changes between refreshes). The board's cells are a `list` with `columns` and a template like `{"type": "box", "aspect": 1, "action": "tap:{{index}}", …}`.

## Themes

A theme changes the look of the whole phone: the page background, cards, text, accent, font — for built-in widgets and catalog widgets alike. It's chosen on the Mac: **"Themes…"** in the menu. Built in: **Dark**, **Light**, **Liquid Glass** (iOS 26 glass; frosted glass on older iOS), **ASCII** (everything as in a terminal).

A theme is a folder with a single file (no code in it, only colours and settings):

```
catalog/themes/com.author.mytheme/
  theme.json      — style, colours, background, font
```

### Adding a theme to the catalog

1. Create a folder `catalog/themes/<id>/` (folder name = the `id` from `theme.json`). The template [`skills/phonescreen-widget/template-theme`](../skills/phonescreen-widget/template-theme/theme.json) is a good start.
2. Check it: `python3 scripts/validate-theme.py catalog/themes/<id>`. Errors (✗) must be fixed; contrast warnings (⚠) very much should be: text must read both on the background and on the cards.
3. Look at it on the phone: **Settings → Themes → "Development folder…"**: save `theme.json` and the iPhone recolours itself. A check without a phone: `PhoneScreen --theme-test catalog/themes/<id>` reads the theme exactly as the app does on install.
4. Update the index: `python3 scripts/build-catalog.py` (the SHA-256 of `theme.json`; the app won't install a file with a different hash).
5. Open a pull request. The theme shows up in the catalog with a preview, for everyone in **Themes → Catalog**.

### theme.json

```json
{
  "id": "com.author.paper",
  "name": "Paper",
  "version": "1.0.0",
  "author": "author",
  "description": "Light, with serifs",
  "localized": { "ru": { "name": "Бумага", "description": "Светлая, с засечками" } },
  "style": "flat",
  "appearance": "light",
  "font": "serif",
  "radius": 14,
  "background": { "colors": ["#FAF7F0", "#EFE8DA"], "angle": 0 },
  "colors": {
    "text": "#222222",
    "secondary": "#777777",
    "accent": "#C0392B",
    "card": "#FFFFFF",
    "border": "#00000014",
    "palette": { "green": "#2E7D32", "orange": "#C0392B" }
  }
}
```

| Field | |
| --- | --- |
| `localized` | optional: the name and description in other languages, `{"ru": {"name": …, "description": …}}` |
| `style` | `flat` — filled cards; `glass` — Liquid Glass over the background (loveliest on a gradient); `ascii` — `+--+` frames, `[####....]` bars, charts of `*`, `[ Refresh ]` buttons |
| `appearance` | `dark` / `light`: system controls (switches, text fields) follow it |
| `font` | `system`, `rounded`, `monospaced`, `serif` |
| `radius` | card corner radius, 0…40 |
| `background.colors` | 1 colour is a fill, 2–4 a linear gradient; `angle` is the direction in degrees (0 is top to bottom) |
| `background.animation` | a live background (`aurora`, `stars`, `matrix`, `waves`, `bokeh`, `lava`, `snow`, `rain`, `gradient`) or `photo`: a photo from the iPhone's Favorites, blurred and dimmed (`colors` show until it loads) |
| `colors.text` / `secondary` / `accent` | the main text, secondary text, the accent (buttons, bars without a colour of their own) |
| `colors.card` / `border` | the card fill (for `glass`, the glass tint) and outline (for `ascii`, the frame colour) |
| `colors.palette` | replacements for colours widgets name: `{"green": "#…"}` recolours everything "green" in every widget. A colour not set is taken from its nearest relative: `mint` → `green`, `teal` → `cyan` → `blue`, `indigo` → `blue`, `pink` → `purple`, `brown` → `orange` |
| `layout` | optional: `gap` between cards (0…24), `margin` around the screen (0…24), `padding` inside cards (6…24), `dots` — page dots (`true`/`false`), `cardOpacity` — card opacity 0…1 (0.6–0.8 looks good with a live background), `textSize` — `small`, `medium`, `large`, `xlarge`, `status` — the time and date by the Dynamic Island (`true` by default), `shadow` — a soft shadow under cards, `autoPage` — turn pages by themselves every N seconds (0 — off), `haptics` — a tap vibration (`true` by default), `loop` — page around in a circle, `homeOnConnect` — return to the first page on connecting |

Colours are `#RRGGBB` or `#RRGGBBAA` (with transparency). When updating a published theme, bump `version`: users get "Update to …".

**For widget authors:** to look good in any theme, use colour names (`primary`, `secondary`, `accent`, `green`…) rather than `#RRGGBB`: a theme can replace names. `primary` and `secondary` are the theme's text colours.
