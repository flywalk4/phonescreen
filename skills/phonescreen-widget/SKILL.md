---
name: phonescreen-widget
description: Write, test and publish widgets for PhoneScreen (the iPhone side screen for the Mac) — a JavaScript data provider plus a declarative view. Use when asked to create, fix or port a PhoneScreen widget, or to add one to the catalog.
---

# Writing a PhoneScreen widget

A widget is a folder of three files. `provider.js` runs **on the Mac** in a JavaScriptCore sandbox and returns plain data; `view.json` is a declarative template the Mac fills with that data and sends to the iPhone, which draws it natively. Nothing you write runs on the phone.

```
catalog/widgets/<id>/
  manifest.json   identity, refresh interval, permissions, settings
  view.json       UI for sizes full / medium / small
  provider.js     async function refresh(ctx) → data;  optional async function action(name, ctx)
```

The full reference (every field, node type and sandbox API) is `catalog/README.md` in the repository — read it before writing anything non-trivial. A working example is `catalog/widgets/com.flywalk4.rates/`. A starting point is `template/` next to this file.

## Workflow

1. **Pin down the data source.** Find an HTTPS API that serves what the widget shows. Prefer endpoints without auth; if a key is needed, declare it as a secret (never hard-code it, never ask the user to paste it into the code). Check the API's terms allow this use.
2. **Copy the template** to `catalog/widgets/<id>/`. The folder name must equal `manifest.id` (`com.author.name`, lowercase).
3. **Write `manifest.json`.** List every host `fetch` touches in `permissions.network` — bare domain only (`api.example.com`), subdomains are included automatically. Keep permissions minimal: users approve them before installing. Pick `refresh` for how often the data really changes (≥ 30 s; daily data → hours).
4. **Write `provider.js`.** `refresh(ctx)` fetches, then returns a small JSON object shaped for the view: format numbers (`toFixed`) and dates as strings in JS, pre-compute colours and flags (`"changeColor": "red"`, `"hasItems": true`), trim lists. Throw `new Error("понятный текст")` on failure — the user sees the message.
5. **Write `view.json`** for all three sizes. `full` is a whole phone page; `medium` half a page; `small` a quarter (≈ 170×170 pt): one number and a label. Bind data with `{{path}}`; repeat rows with `list` + `{{item.…}}`; hide optional parts with `"if": "{{flag}}"`.
6. **Validate:** `python3 scripts/validate-widget.py catalog/widgets/<id>` — fix every ✗.
7. **Run it for real** (needs the built Mac app): `PhoneScreen --widget-test catalog/widgets/<id>` (the binary is `PhoneScreen.app/Contents/MacOS/PhoneScreen`). It runs `refresh()` in the real sandbox and prints the data and resolved UI, or `FAIL …`. Secrets and settings come from the environment: `WIDGET_SECRET_<KEY>=… WIDGET_SETTING_<KEY>=…`. Iterate until it prints `OK` and the output looks right.
8. **Catalog:** `python3 scripts/build-catalog.py` (updates hashes in `catalog/index.json`), then commit the folder and the index together. Bump `version` whenever you change a published widget.

## Sandbox rules (the runtime enforces them — code that ignores them fails)

- Only `fetch` over **HTTPS** to hosts in `permissions.network`; redirects elsewhere are refused. Responses ≤ 2 MB, 15 s timeout.
- No `require`, `import`, `XMLHttpRequest`, `WebSocket`, `process`, files or shell. Plain modern JavaScript (async/await, `Intl`, `JSON`, `Date` work).
- `secrets.get(key)` returns `null` for keys not declared in the manifest.
- `storage.get/set` — JSON, ≤ 64 KB per widget (history for charts, caches).
- A synchronous stretch of code may run ≤ 2 s; a whole `refresh()` ≤ 20 s.

## View cheatsheet

Nodes: `vstack` / `hstack` (`children`, `spacing`, `align`), `text` (`text`, `style`, `color`, `lines`, `align`), `symbol` (SF Symbol `name`, `color`, `size`), `gauge` / `progress` (`value` 0…1), `chart` (`values` array), `button` (`title`, `symbol`, `action`), `list` (`items`, `template`), `spacer`, `divider`. Any node may have `"if"`.
Text styles: `largeTitle title title2 title3 headline body callout subheadline footnote caption caption2`. Colours: system names (`green`, `secondary`, `accent`, …) or `#RRGGBB`.

## Quality bar

- Russian UI text (the app is in Russian), short labels; units in the text (`84.3 ₽`, `12 °C`).
- `small` must stay readable: 1–3 lines, the main number large.
- Handle empty and error states: an API that returns nothing should give a clear message, not a blank card.
- Don't poll faster than the data changes; respect API rate limits.
- Never exfiltrate: send nothing to APIs beyond what the widget needs to fetch its data.
