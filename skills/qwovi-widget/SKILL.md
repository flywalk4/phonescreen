---
name: qwovi-widget
description: Write, test and publish widgets and themes for Qwovi (the iPhone side screen for the Mac) — a JavaScript data provider plus a declarative view, or a theme.json that restyles every widget. Use when asked to create, fix or port a Qwovi widget or theme, or to add one to the catalog.
---

# Writing a Qwovi widget

A widget is a folder of three files. `provider.js` runs **on the Mac** in a JavaScriptCore sandbox and returns plain data; `view.json` is a declarative template the Mac fills with that data and sends to the iPhone, which draws it natively. Nothing you write runs on the phone.

```
catalog/widgets/<id>/
  manifest.json   identity, refresh interval, permissions, settings
  view.json       UI for sizes full / medium / small
  provider.js     async function refresh(ctx) → data;  optional async function action(name, ctx)
```

The full reference (every field, node type and sandbox API) is `catalog/README.md` in the repository — read it before writing anything non-trivial. Working examples: `catalog/widgets/com.flywalk4.rates/` (network, settings, history, chart) and `catalog/widgets/com.flywalk4.claude-code/` (local files, animated sprite). A starting point is `template/` next to this file (`template-theme/` for themes).

## Workflow

1. **Pin down the data source.** Find an HTTPS API that serves what the widget shows. Prefer endpoints without auth; if a key is needed, declare it as a secret (never hard-code it, never ask the user to paste it into the code). Check the API's terms allow this use.
2. **Scaffold:** `node scripts/widget-dev.mjs new com.author.name --name "Name"` creates `catalog/widgets/<id>/` with a working widget (settings, `storage`, buttons, all three sizes, a passing fixture) — or copy `template/`. The folder name must equal `manifest.id` (lowercase). `schemas/*.schema.json` describe every field and node if your editor supports JSON Schema.
   Settings in `manifest.json` should use the right control: `"type": "choice"` with `options` for a fixed list (never list the values in the title), `"toggle"` for on/off (`"true"`/`"false"`), `"number"` with `min`/`max` for a slider; keep `title` short and put formats/examples in `hint`.
3. **Write `manifest.json`.** List every host `fetch` touches in `permissions.network` — bare domain only (`api.example.com`), subdomains are included automatically. Keep permissions minimal: users approve them before installing. Pick `refresh` for how often the data really changes (≥ 30 s with network, ≥ 5 s for local-only widgets; daily data → hours).
4. **Write `provider.js`.** `refresh(ctx)` fetches, then returns a small JSON object shaped for the view: format numbers and dates as strings in JS with the global `format` helpers (`format.number`, `compact`, `percent`, `change` + `changeColor`, `plural`, `time`, `date`, `duration`, `relative`, `bytes`, `level` — see `catalog/README.md`), pre-compute colours and flags (`"changeColor": "red"`, `"hasItems": true`), trim lists. Throw `new Error(t("someError"))` on failure — the user sees the message; texts go in `strings.json` (`en`, optionally `ru`), see "Languages" in `catalog/README.md`.
5. **Write `view.json`** for all three sizes. `full` is a whole phone page; `medium` half a page; `small` a quarter (≈ 170×170 pt): one number and a label. Bind data with `{{path}}`; repeat rows with `list` + `{{item.…}}`; hide optional parts with `"if": "{{flag}}"`.
6. **Validate:** `python3 scripts/validate-widget.py catalog/widgets/<id>` — fix every ✗.
7. **Run it for real** (needs the built Mac app): `Qwovi --widget-test catalog/widgets/<id>` (the binary is `Qwovi.app/Contents/MacOS/Qwovi`). It runs `refresh()` in the real sandbox and prints the data and resolved UI, or `FAIL …`. Secrets and settings come from the environment: `WIDGET_SECRET_<KEY>=… WIDGET_SETTING_<KEY>=…`. Iterate until it prints `OK` and the output looks right.
7b. **No Mac?** `node scripts/widget-dev.mjs run catalog/widgets/<id> --views` runs `refresh()` in an emulation of the sandbox and resolves the views the same way; answer `fetch` from a fixture (`--fixture NAME`), press buttons with `--action`, pin the clock with `--now`. `node scripts/widget-dev.mjs preview catalog/widgets/<id> out.png --theme dark|light|glass|ascii` draws an approximate PNG of all three sizes — look at it and iterate on the layout (check `ascii` and `light` too). `watch <widget>` redraws `preview.png` on every save.
7c. **Fixtures:** add `catalog/widgets/<id>/fixtures/*.json` scenarios (API answers, settings, storage, actions, `expect` paths or `error`; format at the top of `scripts/widget-dev.mjs`) — at least the happy path and the API failing; for games, a few moves. `node scripts/widget-dev.mjs test catalog/widgets/<id>` must pass (CI runs it on every pull request).
8. **Catalog:** `python3 scripts/build-catalog.py` (updates hashes in `catalog/index.json`), then commit the folder and the index together. Bump `version` whenever you change a published widget.

## Sandbox rules (the runtime enforces them — code that ignores them fails)

- Only `fetch` over **HTTPS** to hosts in `permissions.network`; redirects elsewhere are refused. Responses ≤ 2 MB, 15 s timeout.
- No `require`, `import`, `XMLHttpRequest`, `WebSocket`, `process`, shell, and no files beyond `permissions.files`. Plain modern JavaScript (async/await, `Intl`, `JSON`, `Date` work).
- `secrets.get(key)` returns `null` for keys not declared in the manifest.
- `storage.get/set` — JSON, ≤ 64 KB per widget (history for charts, caches).
- `files.read("~/…")` / `files.modified("~/…")` / `files.lines(path, {offset, length})` / `files.list("~/…/")` — read-only, only paths declared in `permissions.files` (`~/folder/` or `~/file`); symlinks out of them are refused. `files.lines` returns whole lines from a byte offset plus `next` — read big logs in chunks and only what's new (see how `com.flywalk4.claude-code` reads Claude Code's session logs). Use for local data other apps write. Local-only widgets may set `refresh` as low as 5 s.
- A synchronous stretch of code may run ≤ 2 s; a whole `refresh()` ≤ 20 s.

## View cheatsheet

Nodes: `vstack` / `hstack` (`children`, `spacing`, `align`), `text` (`text`, `style`, `color`, `lines`, `align`, plus `size` / `weight` / `design` for big rounded numbers), `symbol` (SF Symbol `name`, `color`, `size`), `gauge` / `progress` (`value` 0…1), `chart` (`values` array, `style`: `line` | `area` | `bar`, `height`), `button` (`title`, `symbol`, `action` — may contain bindings like `"tap:{{index}}"`), `box` (a rounded panel: `children`, `padding`, `radius`, `background` + `opacity` or the theme's surface; `fit` to hug content; `action` makes it tappable; `aspect` keeps proportions), `grid` (`children`, `columns`), `list` (`items`, `template`, `columns` for a grid), `sprite` (pixel animation: `frames` = arrays of equal-length strings, `palette` char → colour, `fps`; draw frames in code, see `com.flywalk4.claude-code`), `spacer`, `divider`. Any node may have `"if"`.
Text styles: `largeTitle title title2 title3 headline body callout subheadline footnote caption caption2`. Colours: system names (`green`, `secondary`, `accent`, …) or `#RRGGBB`. Prefer names: themes restyle them (`primary`/`secondary` are the theme's text colours; a theme's `palette` can remap any name), while `#RRGGBB` stays fixed in every theme — keep hex for things like a mascot's own colours.

## Design (make it look like the rest of the catalog)

Read "Making it look good" in `catalog/README.md` and copy the patterns from `com.flywalk4.markets`: a small uppercase caption header with a coloured symbol; one hero number (`size` 40–84, `weight: bold`, `design: rounded`); changes and statuses as pills (`box` with `fit: true`, `background` = status colour, `opacity: 0.18`); groups in `box`, secondary figures as tiles (`list` with `columns: 2`); `area` charts for trends, `bar` for hourly forecasts; colour names rather than hex so themes can restyle them. Design all three sizes separately — don't just shrink `full`.

Games and other interactive widgets: every tap is `action(name)` on the Mac, then `refresh()` — good for turn-based games. Board cells: `list` with `columns` and a `box` template with `"aspect": 1, "action": "tap:{{index}}"`. Keep state in `storage` and save a freshly created game immediately (otherwise a random board changes between refreshes). Keep each synchronous step well under 2 s (prune searches — see the alpha-beta in `com.flywalk4.tictactoe`).

## Quality bar

- Russian UI text (the app is in Russian), short labels; units in the text (`84.3 ₽`, `12 °C`).
- `small` must stay readable: 1–3 lines, the main number large.
- Handle empty and error states: an API that returns nothing should give a clear message, not a blank card.
- Don't poll faster than the data changes; respect API rate limits.
- Never exfiltrate: send nothing to APIs beyond what the widget needs to fetch its data.

## Themes

A theme is a folder with one file, `catalog/themes/<id>/theme.json` (folder name = `id`), that restyles the whole phone — built-in and JavaScript widgets. No code, so no permissions. Full format: the "Themes" section of `catalog/README.md`; start from `template-theme/` next to this file; examples in `catalog/themes/`. Fields: `style` (`flat` | `glass` | `ascii`), `appearance` (`dark` | `light`), `font` (`system` | `rounded` | `monospaced` | `serif`), `radius` (0…40), `background.colors` (1 colour or a 2–4 colour gradient, `angle` in degrees), `background.animation` (`aurora` | `stars` | `matrix` | `waves` | `bokeh` | `lava` | `snow` | `rain` | `gradient`, with `tints` — up to 6 colours of the moving parts — and `speed` 0.1…5), `colors.text/secondary/accent` (required), `colors.card/border`, `colors.palette` (remap widget colour names, e.g. `{"green": "#72F1B8"}`). Colours are `#RRGGBB` or `#RRGGBBAA`.

1. **Copy the template** to `catalog/themes/<id>/` and set `id`, `name`, `author`, `description`.
2. **Pick colours for readability**: `text` needs 4.5:1 contrast against every background colour and the card, `secondary` 3:1. For `glass`, use a vivid but dark-enough gradient (white text must read on every stop) and a translucent `card`. For `ascii`, remap the palette so widget colours fit the terminal look.
3. **Validate:** `python3 scripts/validate-theme.py catalog/themes/<id>` — fix every ✗ and every ⚠ (the contrast warnings).
4. **Run it for real** (needs the built Mac app): `Qwovi --theme-test catalog/themes/<id>` prints the theme as the app reads it and `OK`, or `FAIL …`. With a phone: Settings → Themes → “Development folder…” — every save recolours the phone.
5. **Catalog:** `python3 scripts/build-catalog.py`, commit the folder with `catalog/index.json`. Bump `version` whenever you change a published theme.
