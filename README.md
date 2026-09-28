# PhoneScreen

**English** · [Русский](README.ru.md)

**Turn your iPhone into a side screen for your Mac.** Put it next to your display. It shows live widgets: music, system load, calendar, weather, crypto, your Claude Code limits, a photo frame, even small games. Move the Mac's cursor off the edge of your screen and it lands on the phone.

<p align="center"><img src="docs/images/hero.png" alt="PhoneScreen in the dark, Liquid Glass, light and ASCII themes" width="100%"></p>

- **Native, not a mirror.** The iPhone draws every widget in SwiftUI. The Mac sends only data, so it stays sharp, smooth and light on battery.
- **Any link that works.** USB, Wi-Fi, peer-to-peer Wi-Fi (AWDL) and Bluetooth LE all run at once, and traffic takes the best one. Pull the cable and the session carries on over Wi-Fi.
- **Widgets anyone can write.** A widget is three small files: a manifest, a declarative `view.json` and a `provider.js` that runs on the Mac in a sandbox. There is a catalog, live reload and a Node toolkit that works without a Mac.
- **Edge to edge, any way up.** Pages use the whole screen. Lay the phone sideways and every layout reflows: a 2×2 grid becomes a row of four tiles, and a full-page widget flows into two or three columns by itself.
- **Themes that restyle everything.** Dark, light, Liquid Glass (iOS 26), ASCII, and more from the catalog: Catppuccin, Dracula, Gruvbox, Nord, Tokyo Night, Solarized, Synthwave, a monochrome Graphite, pastel bento cards, amber and e-ink terminals, snow and rain scenes. Themes can have animated backgrounds: aurora, stars, Matrix rain, waves, bokeh, lava, snow, rain on glass, a drifting gradient.

## Widgets

<p align="center"><img src="docs/images/widgets.png" alt="Catalog widgets" width="100%"></p>

**Built in:** Music (Apple Music and Spotify, with album art), Mac monitor (CPU, GPU, RAM, network), Calendar and Reminders (iCloud, straight on the phone), Notes, Weather, a Launcher for Dock apps, Shortcuts and system actions, and a **Photo frame** that slideshows your Favorites with a slow Ken Burns drift.

**Catalog** (install from the Mac app with one click):

| | |
| --- | --- |
| **Claude Code** | A pixel crab that reacts to your session, with token use for the 5-hour block and the week |
| **Markets** | Crypto and Moscow Exchange stocks, with sparklines |
| **Rates** | Currency rates with a 30-day chart |
| **Rain** | "Rain in 35 min": minute-by-minute nowcast and hourly odds |
| **Air** | Air quality index, pollutants and a 24-hour forecast |
| **Sky** | Sunrise and sunset, day length and the moon phase |
| **World clock** | Your cities, who is at work and who is asleep |
| **Time** | Progress of the day, week, month and year, plus countdowns |
| **Month** | A month calendar with today, weekends and Russian public holidays, and the working days left |
| **Focus** | A Pomodoro timer with a daily tally |
| **Habits** | Tap to check off habits, with streaks and the last seven days as dots |
| **GitHub** | PRs waiting for your review, your open PRs and notifications |
| **Hacker News** | Top stories |
| **Live wallpaper** | Animated scenes with an optional clock |
| **Games** | Tic-tac-toe against the Mac, 2048, Minesweeper and Memory, played by tapping the phone |

Each widget has three layouts, `full` (a whole page), `medium` (half) and `small` (a tile), so you can mix them on a page. Pages come as one widget, two, one big and two small, a 2×2 grid, three stacked, or a 2×3 grid of six tiles:

<p align="center"><img src="docs/images/pages.png" alt="Pages mixing several widgets" width="100%"></p>

## Lying sideways

Put the phone on its side under or next to a display. Grids become a row of tiles, a trio becomes one half-width card and two tiles, and catalog widgets reflow their full-page layout into columns with no extra work from their authors.

<p align="center"><img src="docs/images/landscape.png" alt="Pages in landscape" width="100%"></p>

## Themes

<p align="center"><img src="docs/images/themes.png" alt="Catalog themes" width="100%"></p>

A theme is one `theme.json` with colours, font, corner radius, card style (`flat`, `glass` or `ascii`) and an optional animated background. It restyles built-in and catalog widgets alike. In the ASCII theme, bars become `[####....]`, rings become percentages, icons become characters and album art becomes ASCII art. Pick one in the Mac app under **Темы…** (Themes).

**Make it yours.** Under the list of themes, **Тонкая настройка** (fine-tuning) adjusts whichever theme you picked: accent colour, card style (fill, glass, ASCII), font, corner radius, the animated background and its speed (or a blurred photo from the phone's Favorites), the gaps between cards, the page margins, the padding inside cards, card opacity (let the live background show through), a soft shadow under cards, text size, turning pages by themselves, a light vibration on taps, the time and date beside the Dynamic Island, and the page dots. Any page can also drop its cards so the widgets sit straight on the background. Themes can set the same through an optional `layout` block in `theme.json`.

**Widget settings are real controls.** A widget's `manifest.json` declares each setting as `text`, `choice` (a drop-down), `toggle` (a switch) or `number` (a slider with `min`/`max`, or a stepper), with a short title and a hint. The Mac app draws them, and changes reach the phone at once.

## Getting started

Requirements: macOS 14+, iOS 18+, Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/flywalk4/phonescreen.git && cd phonescreen
xcodegen generate
open PhoneScreen.xcodeproj
```

1. **Mac:** run the `PhoneScreenMac` scheme. A menu bar icon appears. The first time it fetches a track, macOS asks for permission to control Music or Spotify.
2. **iPhone:** run the `PhoneScreeniOS` scheme on your phone. Set your team in Xcode → Signing, or run `DEVELOPMENT_TEAM=XXXXXXXXXX xcodegen generate`. With a free Apple ID the build lasts 7 days; after that, build again. Allow **Local Network** access when iOS asks. USB works without it.
3. **Place the phone:** menu bar → **Расположение iPhone…** (iPhone position). The interface is in Russian for now. As in System Settings → Displays, drag the phone to any edge of any screen. The cursor crosses to the phone over the green segment. Press `R` to rotate it.
4. **Add widgets and themes:** menu bar → **Виджеты…** / **Темы…** (Widgets / Themes).

Hotkeys: `⌃⌥←` / `⌃⌥→` switch pages; `⌃⌥1…9` jump to a page.

## Write a widget

```bash
node scripts/widget-dev.mjs new com.you.hello --name "Hello"      # a working starter widget
node scripts/widget-dev.mjs watch catalog/widgets/com.you.hello   # re-renders preview.png on every save
node scripts/widget-dev.mjs test catalog/widgets/com.you.hello    # runs its fixtures
```

```js
// provider.js runs on the Mac in a JavaScriptCore sandbox; it may fetch only the hosts listed in its manifest
async function refresh(ctx) {
  const res = await fetch("https://api.example.com/price");
  const { price, change } = await res.json();
  return { price: format.number(price, 2), change: format.change(change), color: format.changeColor(change) };
}
```

```json
{ "full": { "type": "vstack", "children": [
  { "type": "text", "text": "{{price}}", "size": 64, "weight": "bold", "design": "rounded" },
  { "type": "text", "text": "{{change}}", "color": "{{color}}" } ] } }
```

- 16 node types: stacks, grids, lists, boxes, text, SF Symbols, gauges, progress bars, line, area and bar charts, buttons, pixel sprites, layers and animated scenes. Every node follows the theme.
- Settings are typed: `"type": "choice"` with `options`, `"toggle"`, `"number"` with `min`/`max`/`step`/`unit`, or plain text.
- The sandbox gives you `fetch` (declared hosts only), Keychain secrets, settings, 64 KB of storage, read-only access to declared files, and number and date helpers in `format`.
- JSON Schemas in [`schemas/`](schemas) give autocomplete for `view.json`, `manifest.json` and `theme.json` in VS Code.
- In the Mac app, **Виджеты → Папка разработки…** (development folder) live-reloads a widget on the phone every time you save.
- CI validates every catalog widget and theme, runs its fixtures, builds both apps and takes real Simulator screenshots.

Full reference: [`catalog/README.md`](catalog/README.md) (in Russian). For AI agents there is a skill at [`skills/phonescreen-widget`](skills/phonescreen-widget/SKILL.md).

## How it works

```
Mac (menu bar agent)                                   iPhone
┌──────────────────────────────┐   USB · Wi-Fi ·    ┌──────────────────────────┐
│ providers: music, system, …  │   AWDL · BLE       │ pages of widgets         │
│ JS widgets in JavaScriptCore │ ─────────────────▶ │ SwiftUI, themed          │
│   provider.js → data         │   JSON frames      │ view.json + data → UI    │
│ pointer capture at the edge  │ ◀───────────────── │ taps, actions, pointer   │
└──────────────────────────────┘                    └──────────────────────────┘
```

- `Packages/PhoneScreenKit`: the shared protocol (`Message`, length-prefixed JSON frames), channels, widget templates and themes.
- `Mac/`: the menu bar agent, with usbmuxd, Bonjour and BLE links, data providers, the widget runtime, pointer handoff and hotkeys.
- `iOS/`: the phone app, with the listener, pages, built-in widgets, the themed renderer for custom widgets, and animated scenes.
- `catalog/`: widgets and themes with an `index.json` of SHA-256 hashes. The app refuses any file whose hash doesn't match.

```bash
cd Packages/PhoneScreenKit && swift test        # protocol, templates, themes
node scripts/widget-dev.mjs test                # every widget scenario, no Mac needed
```
