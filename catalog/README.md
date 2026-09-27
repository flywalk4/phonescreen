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
5. Pull request. Ревьюер смотрит прежде всего `permissions` и куда ходит `fetch`.

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
| `refresh` | секунды между вызовами `refresh()`, минимум 30, по умолчанию 300 |
| `permissions.network` | домены, куда можно `fetch` (поддомены включены). Только HTTPS, редиректы тоже проверяются. Без схемы, пути и `*` |
| `permissions.secrets` | секреты (ключи API): пользователь вводит их в настройках, хранятся в Связке ключей Mac |
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

Доступно в песочнице — и больше ничего (нет `require`, `import`, файлов, процессов, `XMLHttpRequest`, `WebSocket`):

| API | |
| --- | --- |
| `fetch(url, {method, headers, body})` | как в браузере, упрощённо: `res.ok`, `res.status`, `res.headers.get(k)`, `await res.text()`, `await res.json()`. Только хосты из `permissions.network`, ответ до 2 МБ, таймаут 15 с |
| `secrets.get(key)` | строка или `null` (если не задан или не объявлен в манифесте) |
| `ctx.settings.<key>` | значения из `settings` (строки) |
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
| `text` | `text`, `style` (`largeTitle` `title` `title2` `title3` `headline` `body` `callout` `subheadline` `footnote` `caption` `caption2`), `color`, `lines`, `align` |
| `symbol` | `name` (SF Symbol), `color`, `size` |
| `gauge` | `value` (0…1), `label`, `color` — кольцо |
| `progress` | `value` (0…1), `color` — полоса |
| `chart` | `values` (массив чисел, до 200), `color` — линия |
| `button` | `title`, `symbol`, `action` → `action(name)` в provider.js; нажимается пальцем и курсором Mac |
| `list` | `items` (массив), `template` (узел), `spacing`, `align` |
| `spacer`, `divider` | — |

Цвета: `primary` `secondary` `tertiary` `accent` `red` `orange` `yellow` `green` `mint` `teal` `cyan` `blue` `indigo` `purple` `pink` `brown` `gray` `white` или `#RRGGBB`. Неизвестный `type` пропускается. Максимум 500 элементов и 2000 символов в тексте.

Пример целиком — [`widgets/com.flywalk4.rates`](widgets/com.flywalk4.rates).
