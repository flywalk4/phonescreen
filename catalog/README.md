# Каталог виджетов PhoneScreen

Виджет — папка из трёх файлов. Логика (`provider.js`) выполняется **на Mac** в песочнице JavaScriptCore, интерфейс (`view.json`) — декларативный: Mac подставляет в него данные и отправляет на iPhone готовое дерево элементов, которое телефон рисует нативно. На телефоне чужой код не выполняется.

```
catalog/widgets/com.author.mywidget/
  manifest.json   — кто, что, какие разрешения
  view.json       — вёрстка для размеров full / medium / small
  provider.js     — async function refresh(ctx) { … return data }
```

## Как добавить виджет в каталог

1. Создайте папку `catalog/widgets/<id>/` (имя папки = `id` из манифеста).
2. Проверьте: `python3 scripts/validate-widget.py catalog/widgets/<id>`
3. Запустите по-настоящему (нужен собранный Mac-агент): `PhoneScreen --widget-test catalog/widgets/<id>` — выполнит `refresh()` в той же песочнице, что и приложение, и напечатает данные и итоговое дерево.
4. Обновите индекс: `python3 scripts/build-catalog.py` (хеши SHA-256 всех файлов; приложение не установит файл с другим хешем).
5. Добавьте сценарии в `fixtures/` (хотя бы «всё хорошо» и «API недоступен») и проверьте: `node scripts/widget-dev.mjs test catalog/widgets/<id>`.
6. Pull request. Ревьюер смотрит прежде всего `permissions` и куда ходит `fetch`.

**Без Mac** (Linux, Windows, CI, ИИ-агент в облаке) — `scripts/widget-dev.mjs` на Node 18+:

```bash
node scripts/widget-dev.mjs run catalog/widgets/<id> --fixture ok --views   # refresh() в эмуляции песочницы + дерево для телефона
node scripts/widget-dev.mjs preview catalog/widgets/<id> out.png --theme glass # примерный PNG всех трёх размеров (нужен Playwright)
node scripts/widget-dev.mjs test                                             # все сценарии fixtures/ всех виджетов
```

Сценарии лежат в `catalog/widgets/<id>/fixtures/*.json` (в приложение не скачиваются): ответы API (`fetch`), настройки, секреты, `storage`, файлы, нажатия (`actions`), время (`now`, `timezone`) и что должно получиться (`expect` по путям в данных или `error`). Формат — в начале `scripts/widget-dev.mjs`. Pull request в каталог проверяется автоматически: валидаторы, актуальность `index.json` и все сценарии. Эмуляция повторяет API и лимиты песочницы, но окончательная проверка — `--widget-test` на Mac.

Во время разработки удобнее **Настройки → Виджеты → «Папка разработки…»**: сохраните файл — виджет перезагрузится на iPhone сам. Журнал `console.log` и ошибок — там же.

## manifest.json

```json
{
  "id": "com.author.mywidget",
  "name": "Мой виджет",
  "version": "1.0.0",
  "author": "author",
  "description": "Одна-две фразы для каталога.",
  "symbol": "sparkles",
  "refresh": 300,
  "permissions": {
    "network": ["api.example.com"],
    "secrets": [{ "key": "token", "title": "API-токен" }]
  },
  "settings": [{ "key": "city", "title": "Город", "default": "Москва" }]
}
```

| Поле | |
| --- | --- |
| `id` | обратный домен, строчные латинские буквы, цифры, точки: `com.author.widget` |
| `name` | до 40 символов |
| `version` | `1.2.3`; для обновления в каталоге — поднимайте |
| `symbol` | имя SF Symbol |
| `refresh` | секунды между вызовами `refresh()`, по умолчанию 300; минимум 30 с сетью и 5 без неё |
| `permissions.network` | домены, куда можно `fetch` (поддомены включены). Только HTTPS, редиректы тоже проверяются. Без схемы, пути и `*` |
| `permissions.secrets` | секреты (ключи API): пользователь вводит их в настройках, хранятся в Связке ключей Mac |
| `permissions.files` | чтение (только чтение) файлов в домашней папке: `~/folder/` (папка целиком) или `~/folder/file`. Символические ссылки наружу не пройдут |
| `settings` | обычные текстовые настройки со значениями по умолчанию |

Пользователь видит все разрешения до установки.

## provider.js

```js
// Обязательно: вернуть данные для view.json. Можно async.
async function refresh(ctx) {
  const res = await fetch("https://api.example.com/v1/items", {
    headers: { Authorization: `Bearer ${secrets.get("token")}` },
  });
  if (!res.ok) throw new Error(`API ответил ${res.status}`); // текст ошибки увидит пользователь
  const items = await res.json();
  return { count: items.length, items: items.slice(0, 5).map((i) => ({ title: i.name })) };
}

// Необязательно: нажатие кнопки { "type": "button", "action": "…" }. После него refresh() вызывается сам.
async function action(name, ctx) {
  if (name === "clear") storage.set("seen", []);
}
```

Доступно в песочнице — и больше ничего (нет `require`, `import`, процессов, `XMLHttpRequest`, `WebSocket`, файлов вне `permissions.files`):

| API | |
| --- | --- |
| `fetch(url, {method, headers, body})` | как в браузере, упрощённо: `res.ok`, `res.status`, `res.headers.get(k)`, `await res.text()`, `await res.json()`. Только хосты из `permissions.network`, ответ до 2 МБ, таймаут 15 с |
| `secrets.get(key)` | строка или `null` (если не задан или не объявлен в манифесте) |
| `ctx.settings.<key>` | значения из `settings` (строки) |
| `files.read("~/…")` / `files.modified("~/…")` | текст файла (до 1 МБ) или `null`; время изменения (секунды Unix) или `null`. Только пути из `permissions.files` |
| `files.lines("~/…", {offset, length})` | целые строки начиная с байта `offset` (не больше `length`, до 1 МБ): `{ lines, next, size }`. `next` передайте в следующий вызов — так читаются большие журналы по кускам и только новые строки. Строка длиннее лимита пропускается |
| `files.list("~/…/")` | содержимое папки: `[{ name, dir, size, modified }]` (скрытые пропускаются, до 2000) или `null` |
| `storage.get(key)` / `storage.set(key, value)` | маленькое постоянное хранилище (JSON, до 64 КБ на виджет) — история, кэш |
| `setTimeout(fn, ms)`, `sleep(ms)` | задержки (до 60 с) |
| `console.log/warn/error` | в журнал виджета в настройках |

Ограничения: код выполняется не дольше 2 с подряд (ожидание `fetch` не считается), весь `refresh()` — не дольше 20 с. Числа форматируйте в JS сами (`toFixed`), даты — строками.

## view.json

Ключи — размеры: `full` (страница целиком), `medium` (половина страницы), `small` (четверть). Хватит одного: недостающий размер возьмётся из ближайшего. Маленькие — показывайте главное.

```json
{
  "full": { "type": "vstack", "spacing": 12, "children": [
    { "type": "text", "text": "Задач: {{count}}", "style": "title" },
    { "type": "list", "items": "{{items}}", "template": { "type": "text", "text": "• {{item.title}}" } },
    { "type": "button", "title": "Очистить", "symbol": "trash", "action": "clear" }
  ]},
  "small": { "type": "text", "text": "{{count}}", "style": "largeTitle" }
}
```

**Привязки.** В любой строке — `{{путь}}` к данным из `refresh()`: `{{a.b}}`, `{{rows.0.name}}`. Если строка — только привязка (`"{{ratio}}"`), сохраняется тип значения (число, массив); иначе подставляется текстом. Внутри `list` доступны `{{item.…}}` и `{{index}}`. Нет значения — пустая строка.

**`"if": "{{путь}}"`** на любом узле — узел скрывается, если значение пустое / `false` / `0` / пустой массив.

| type | поля |
| --- | --- |
| `vstack`, `hstack` | `children`, `spacing`, `align` (vstack: `leading`/`center`/`trailing`; hstack: `top`/`center`/`bottom`/`baseline`) |
| `text` | `text`, `style` (`largeTitle` `title` `title2` `title3` `headline` `body` `callout` `subheadline` `footnote` `caption` `caption2`), `color`, `lines`, `align`; свой шрифт: `size` (пт), `weight` (`light` `regular` `medium` `semibold` `bold` `heavy` `black`…), `design` (`rounded` `monospaced` `serif`; по умолчанию — шрифт темы) |
| `symbol` | `name` (SF Symbol), `color`, `size` |
| `gauge` | `value` (0…1), `label`, `color` — кольцо |
| `progress` | `value` (0…1), `color` — полоса |
| `chart` | `values` (массив чисел, до 200), `color`, `style` (`line` — линия, `area` — линия с заливкой-градиентом, `bar` — столбики), `height` |
| `button` | `title`, `symbol`, `action` → `action(name)` в provider.js; нажимается пальцем и курсором Mac. В `action` можно привязку: `"tap:{{index}}"` |
| `box` | плашка: `children` столбиком на скруглённой подложке. `padding` (12), `spacing`, `align`, `radius`; `background` + `opacity` — свой цвет, без них — подложка в стиле темы (стекло в Liquid Glass, рамка в ASCII). `fit: true` — по размеру содержимого («таблетки»), иначе на всю ширину. `action` — вся плашка кнопка (клетки игр, плитки). `aspect` — пропорции (1 — квадрат) |
| `grid` | `children` в `columns` колонок (1–12), `spacing` |
| `list` | `items` (массив), `template` (узел), `spacing`, `align`; `columns` — сеткой в N колонок |
| `sprite` | пиксельная анимация: `frames` — массив кадров, кадр — массив строк одинаковой длины (до 48×48, до 16 кадров); `palette` — символ → цвет (`.` и пробел прозрачные); `fps`. Масштабируется под место. Кадры удобно рисовать кодом в provider.js |
| `spacer`, `divider` | — |

Цвета: `primary` `secondary` `tertiary` `accent` `red` `orange` `yellow` `green` `mint` `teal` `cyan` `blue` `indigo` `purple` `pink` `brown` `gray` `white` или `#RRGGBB`. Неизвестный `type` пропускается. Максимум 500 элементов и 2000 символов в тексте.

### Как сделать красиво

Все виджеты каталога следуют одним правилам — так страницы смотрятся цельно:

- **Шапка** — маленькая: цветной символ + подпись `caption`, `weight: semibold`, `color: secondary`, заглавными (`"РЫНКИ"`). Справа — второстепенное (город, время обновления) или кнопка.
- **Главное число** — крупно: `size` 40–84, `weight: bold`, `design: rounded`. Одно на виджет.
- **Изменения и статусы** — «таблеткой»: `box` с `fit: true`, `padding` 5–7, `radius` 8, `background` цвета статуса, `opacity: 0.18`, внутри текст того же цвета.
- **Группы данных** — в `box` (подложка возьмёт стиль темы), мелкие показатели — плитками: `list` с `columns: 2` и `box` в шаблоне.
- **Графики** — `style: area` для курсов и трендов, `bar` для прогнозов по часам.
- **Цвета** — имена (`green`, `orange`, `secondary`, `accent`), а не `#RRGGBB`: темы их перекрашивают. Hex — только для «своих» цветов (логотип, пиксельный персонаж).
- **Три размера по-разному**: `full` — всё с подробностями; `medium` — главное число, график, 3–4 показателя; `small` — одно число и подпись крупно, остальное мелко внизу.

Примеры целиком: [`widgets/com.flywalk4.markets`](widgets/com.flywalk4.markets) (сеть, плитки, график-область), [`widgets/com.flywalk4.claude-code`](widgets/com.flywalk4.claude-code) (локальные файлы, анимированный спрайт), [`widgets/com.flywalk4.focus`](widgets/com.flywalk4.focus) (кнопки и состояние), [`widgets/com.flywalk4.game2048`](widgets/com.flywalk4.game2048) и [`widgets/com.flywalk4.minesweeper`](widgets/com.flywalk4.minesweeper) (игры: поле из нажимаемых плашек).

**Игры и всё интерактивное.** Каждое нажатие — `action(name)` на Mac, затем `refresh()` сам, так что подходят пошаговые игры. Состояние храните в `storage`, новую партию сохраняйте сразу при создании (иначе поле будет меняться между обновлениями). Клетки поля — `list` с `columns` и шаблоном `{"type": "box", "aspect": 1, "action": "tap:{{index}}", …}`.

## Темы

Тема меняет вид всего телефона: фон страниц, карточки, текст, акцент, шрифт — у встроенных виджетов и у виджетов из каталога. Выбирается на Mac: **«Темы…»** в меню. Встроенные: **Тёмная**, **Светлая**, **Liquid Glass** (стекло iOS 26; на старых iOS — матовое стекло), **ASCII** (всё как в терминале).

Тема — папка с одним файлом (кода в ней нет, только цвета и настройки):

```
catalog/themes/com.author.mytheme/
  theme.json      — стиль, цвета, фон, шрифт
```

### Как добавить тему в каталог

1. Создайте папку `catalog/themes/<id>/` (имя папки = `id` из `theme.json`). Начать удобно с шаблона [`skills/phonescreen-widget/template-theme`](../skills/phonescreen-widget/template-theme/theme.json).
2. Проверьте: `python3 scripts/validate-theme.py catalog/themes/<id>` — ошибки (✗) нужно исправить, предупреждения о контрасте (⚠) — очень желательно: текст должен читаться и на фоне, и на карточках.
3. Посмотрите на телефоне: **Настройки → Темы → «Папка разработки…»** — сохраните `theme.json`, iPhone перекрасится сам. Проверка без телефона: `PhoneScreen --theme-test catalog/themes/<id>` — прочитает тему так же, как приложение при установке.
4. Обновите индекс: `python3 scripts/build-catalog.py` (хеш SHA-256 `theme.json`; приложение не установит файл с другим хешем).
5. Pull request. В каталоге тема появится с превью — у всех в **Темы → Каталог**.

### theme.json

```json
{
  "id": "com.author.paper",
  "name": "Бумага",
  "version": "1.0.0",
  "author": "author",
  "description": "Светлая, с засечками",
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

| Поле | |
| --- | --- |
| `style` | `flat` — залитые карточки; `glass` — Liquid Glass поверх фона (красивее всего на градиенте); `ascii` — рамки `+--+`, полосы `[####....]`, графики из `*`, кнопки `[ Обновить ]` |
| `appearance` | `dark` / `light` — системные элементы (переключатели, поля ввода) подстраиваются под неё |
| `font` | `system`, `rounded`, `monospaced`, `serif` |
| `radius` | скругление карточек, 0…40 |
| `background.colors` | 1 цвет — заливка, 2–4 — линейный градиент; `angle` — направление в градусах (0 — сверху вниз) |
| `colors.text` / `secondary` / `accent` | основной текст, второстепенный, акцент (кнопки, полосы без своего цвета) |
| `colors.card` / `border` | заливка карточки (для `glass` — оттенок стекла) и обводка (для `ascii` — цвет рамки) |
| `colors.palette` | замена цветов, которые называют виджеты: `{"green": "#…"}` перекрасит всё «зелёное» во всех виджетах |

Цвета — `#RRGGBB` или `#RRGGBBAA` (с прозрачностью). Обновляя опубликованную тему, поднимайте `version` — у пользователей появится «Обновить до …».

**Авторам виджетов:** чтобы виджет хорошо выглядел в любой теме, используйте имена цветов (`primary`, `secondary`, `accent`, `green`…), а не `#RRGGBB` — имена тема может заменить. `primary` и `secondary` — цвета текста темы.
