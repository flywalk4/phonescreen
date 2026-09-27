#!/usr/bin/env python3
"""Static checks for a PhoneScreen widget package (no app needed).

    python3 scripts/validate-widget.py path/to/com.author.widget

Checks the three files, manifest fields and permissions, and that view.json only uses known node types and
fields, with bindings that look right. Mirrors the rules of the app (WidgetManifest.validate, WidgetTemplate).
To actually run the widget in the real sandbox, use the Mac app:  PhoneScreen --widget-test <folder>
"""
import json
import re
import sys
from pathlib import Path

REQUIRED = ["manifest.json", "view.json", "provider.js"]
MAX_BYTES = 256 * 1024
SIZES = {"full", "medium", "small"}
NODES = {
    "vstack": {"spacing", "align", "children"},
    "hstack": {"spacing", "align", "children"},
    "text": {"text", "style", "color", "lines", "align", "size", "weight", "design"},
    "symbol": {"name", "color", "size"},
    "gauge": {"value", "label", "color"},
    "progress": {"value", "color"},
    "chart": {"values", "color", "style", "height"},
    "button": {"title", "symbol", "action"},
    "sprite": {"frames", "palette", "fps"},
    "spacer": set(),
    "divider": set(),
    "list": {"items", "template", "spacing", "align", "columns"},
    "box": {"children", "spacing", "align", "padding", "background", "opacity", "radius", "fit", "action", "aspect"},
    "grid": {"children", "columns", "spacing"},
    "layers": {"children", "align"},
    "scene": {"kind", "colors", "tints", "speed"},
}
WEIGHTS = {"ultraLight", "thin", "light", "regular", "medium", "semibold", "bold", "heavy", "black"}
DESIGNS = {"default", "rounded", "monospaced", "serif"}
CHART_STYLES = {"line", "area", "bar"}
COMMON = {"type", "if"}
STYLES = {"largeTitle", "title", "title2", "title3", "headline", "body", "callout", "subheadline", "footnote", "caption", "caption2"}
BINDING = re.compile(r"\{\{\s*([^}]+?)\s*\}\}")


def validate(folder: Path) -> list[str]:
    errors: list[str] = []
    files = {}
    for name in REQUIRED:
        p = folder / name
        if not p.is_file():
            errors.append(f"нет файла {name}")
            continue
        data = p.read_bytes()
        if len(data) > MAX_BYTES:
            errors.append(f"{name} больше 256 КБ")
        files[name] = data
    if errors:
        return errors

    try:
        m = json.loads(files["manifest.json"])
    except json.JSONDecodeError as e:
        return [f"manifest.json: {e}"]
    if not re.fullmatch(r"[a-z0-9]+(\.[a-z0-9-]+)+", str(m.get("id", ""))) or len(m.get("id", "")) > 100:
        errors.append("manifest.id: нужен вид com.author.widget (строчные латинские буквы, цифры, точки)")
    if folder.name != m.get("id"):
        errors.append(f"папка должна называться как id: {m.get('id')}")
    if not str(m.get("name", "")).strip() or len(m.get("name", "")) > 40:
        errors.append("manifest.name обязателен, до 40 символов")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(m.get("version", ""))):
        errors.append("manifest.version: вид 1.2.3")
    if not m.get("author"):
        errors.append("manifest.author обязателен")
    perms = m.get("permissions") or {}
    for host in perms.get("network") or []:
        if not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", host):
            errors.append(f"permissions.network: «{host}» — только домен (api.example.com), без https://, пути и *")
    for path in perms.get("files") or []:
        if not path.startswith("~/") or len(path) <= 2 or ".." in path.split("/") or "*" in path:
            errors.append(f"permissions.files: «{path}» — путь в домашней папке: ~/folder/ или ~/folder/file, без .. и *")
    secret_keys = [s.get("key") for s in perms.get("secrets") or []]
    setting_keys = [s.get("key") for s in m.get("settings") or []]
    if len(set(secret_keys)) != len(secret_keys) or len(set(setting_keys)) != len(setting_keys):
        errors.append("ключи secrets / settings повторяются")
    floor = 30 if perms.get("network") else 5
    if m.get("refresh") is not None and m["refresh"] < floor:
        errors.append(f"refresh меньше {floor} с будет поднят до {floor}")

    try:
        view = json.loads(files["view.json"])
    except json.JSONDecodeError as e:
        return errors + [f"view.json: {e}"]
    if not isinstance(view, dict) or not (set(view) & SIZES):
        errors.append("view.json: объект с ключами full / medium / small")
    else:
        for key in set(view) - SIZES:
            errors.append(f"view.json: неизвестный ключ «{key}» (нужны full / medium / small)")
        for size in SIZES & set(view):
            check_node(view[size], f"view.{size}", errors)

    source = files["provider.js"].decode("utf-8", errors="replace")
    if not re.search(r"function\s+refresh\s*\(", source):
        errors.append("provider.js: нет функции refresh(ctx)")
    if re.search(r"files\.(read|modified|lines|list)\(", source) and not perms.get("files"):
        errors.append("provider.js читает файлы, но permissions.files пуст")
    if re.search(r"\b(require|import\s|XMLHttpRequest|WebSocket|process\.)", source):
        errors.append("provider.js: require/import/XMLHttpRequest/WebSocket/process в песочнице нет — используйте fetch")
    urls = re.findall(r"https?://([a-z0-9.-]+)", source)
    allowed = perms.get("network") or []
    for host in sorted(set(urls)):
        if not any(host == a or host.endswith("." + a) for a in allowed):
            errors.append(f"provider.js обращается к {host}, но его нет в permissions.network")
    if re.search(r"http://", source):
        errors.append("provider.js: http:// запрещён, только https://")
    return errors


def check_node(node, path: str, errors: list[str]) -> None:
    if not isinstance(node, dict):
        errors.append(f"{path}: узел должен быть объектом")
        return
    t = node.get("type")
    if t not in NODES:
        errors.append(f"{path}: неизвестный type «{t}» (есть: {', '.join(sorted(NODES))})")
        return
    for key in set(node) - NODES[t] - COMMON:
        errors.append(f"{path}: у {t} нет поля «{key}»")
    if t == "text" and "style" in node and not BINDING.search(str(node["style"])) and node["style"] not in STYLES:
        errors.append(f"{path}: style «{node['style']}» — есть: {', '.join(sorted(STYLES))}")
    for key, allowed in (("weight", WEIGHTS), ("design", DESIGNS)):
        if t == "text" and key in node and not BINDING.search(str(node[key])) and node[key] not in allowed:
            errors.append(f"{path}: {key} «{node[key]}» — есть: {', '.join(sorted(allowed))}")
    if t == "chart" and "style" in node and not BINDING.search(str(node["style"])) and node["style"] not in CHART_STYLES:
        errors.append(f"{path}: style графика «{node['style']}» — есть: {', '.join(sorted(CHART_STYLES))}")
    if t == "button" and not node.get("action"):
        errors.append(f"{path}: у button нужен action")
    if t == "list":
        if "template" not in node:
            errors.append(f"{path}: у list нужен template")
        else:
            check_node(node["template"], f"{path}.template", errors)
    for i, child in enumerate(node.get("children") or []):
        check_node(child, f"{path}.children[{i}]", errors)
    for key, value in node.items():
        if isinstance(value, str) and value.count("{{") != value.count("}}"):
            errors.append(f"{path}.{key}: незакрытая привязка {{{{…}}}}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    problems = validate(Path(sys.argv[1]).resolve())
    for p in problems:
        print("✗", p)
    print("OK" if not problems else f"{len(problems)} проблем(ы)")
    sys.exit(1 if problems else 0)
