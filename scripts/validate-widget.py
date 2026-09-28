#!/usr/bin/env python3
"""Static checks for a Qwovi widget package (no app needed).

    python3 scripts/validate-widget.py path/to/com.author.widget [--hints]

--hints also prints advice that is not an error (hex colours themes can't recolour, buttons in small tiles).

Checks the three files, manifest fields and permissions, and that view.json only uses known node types and
fields, with bindings that look right. Mirrors the rules of the app (WidgetManifest.validate, WidgetTemplate).
To actually run the widget in the real sandbox, use the Mac app:  Qwovi --widget-test <folder>
"""
import json
import re
import sys
from pathlib import Path

REQUIRED = ["manifest.json", "view.json", "provider.js"]
OPTIONAL = ["strings.json"]
MAX_BYTES = 256 * 1024
SIZES = {"full", "medium", "small"}
NODES = {
    "vstack": {"spacing", "align", "children"},
    "hstack": {"spacing", "align", "children"},
    "text": {"text", "style", "color", "lines", "align", "size", "weight", "design"},
    "symbol": {"name", "color", "size"},
    "gauge": {"value", "label", "color", "text", "fill"},
    "progress": {"value", "color"},
    "chart": {"values", "color", "style", "height"},
    "button": {"title", "symbol", "action", "color"},
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


LANG = re.compile(r"^[a-z]{2}(-[A-Za-z]{2,4})?$")
PLURAL = {"zero", "one", "two", "few", "many", "other"}


def check_strings(folder: Path, manifest: dict, files: dict) -> list[str]:
    """strings.json: {"en": {"key": "text" | {"one": …, "other": …}}, …}; every key the view and script use exists."""
    path = folder / "strings.json"
    if not path.exists():
        return []
    errors = []
    try:
        strings = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        return [f"strings.json: {e}"]
    if not isinstance(strings, dict) or not strings:
        return ["strings.json: an object {\"en\": {…}, \"ru\": {…}}"]
    for lang, table in strings.items():
        if not LANG.match(lang):
            errors.append(f"strings.json: “{lang}” — a language code like en, ru, pt-BR")
        if not isinstance(table, dict):
            errors.append(f"strings.json.{lang}: an object of key → text")
            continue
        for key, value in table.items():
            if isinstance(value, dict):
                if not value or not set(value) <= PLURAL or not all(isinstance(v, str) for v in value.values()):
                    errors.append(f"strings.json.{lang}.{key}: forms are strings keyed {', '.join(sorted(PLURAL))}")
            elif not isinstance(value, str):
                errors.append(f"strings.json.{lang}.{key}: a string or forms {{\"one\": …, \"other\": …}}")
    # Keys used by view.json ({{t.key}}) and provider.js (t("key")) must exist in every language.
    text = lambda name: files.get(name, b"").decode("utf-8", "replace")
    used = set(re.findall(r"\{\{\s*t\.([\w.-]+)\s*\}\}", text("view.json")))
    used |= set(re.findall(r"\bt\(\s*[\"']([\w.-]+)[\"']", text("provider.js")))
    for lang, table in strings.items():
        if isinstance(table, dict):
            missing = sorted(k for k in used if k not in table)
            if missing:
                errors.append(f"strings.json.{lang}: missing keys {', '.join(missing[:8])}{' …' if len(missing) > 8 else ''}")
    return errors


def validate(folder: Path) -> list[str]:
    errors: list[str] = []
    files = {}
    for name in REQUIRED:
        p = folder / name
        if not p.is_file():
            errors.append(f"no file {name}")
            continue
        data = p.read_bytes()
        if len(data) > MAX_BYTES:
            errors.append(f"{name} is over 256 KB")
        files[name] = data
    if errors:
        return errors

    try:
        m = json.loads(files["manifest.json"])
    except json.JSONDecodeError as e:
        return [f"manifest.json: {e}"]
    if not re.fullmatch(r"[a-z0-9]+(\.[a-z0-9-]+)+", str(m.get("id", ""))) or len(m.get("id", "")) > 100:
        errors.append("manifest.id: must look like com.author.widget (lowercase Latin letters, digits, dots)")
    if folder.name != m.get("id"):
        errors.append(f"the folder must be named like the id: {m.get('id')}")
    if not str(m.get("name", "")).strip() or len(m.get("name", "")) > 40:
        errors.append("manifest.name is required, up to 40 characters")
    if not re.fullmatch(r"\d+\.\d+\.\d+", str(m.get("version", ""))):
        errors.append("manifest.version: like 1.2.3")
    if not m.get("author"):
        errors.append("manifest.author is required")
    perms = m.get("permissions") or {}
    for host in perms.get("network") or []:
        if not re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", host):
            errors.append(f"permissions.network: “{host}” — a domain only (api.example.com), no https://, path or *")
    for path in perms.get("files") or []:
        if not path.startswith("~/") or len(path) <= 2 or ".." in path.split("/") or "*" in path:
            errors.append(f"permissions.files: “{path}” — a path in the home folder: ~/folder/ or ~/folder/file, no .. or *")
    secret_keys = [s.get("key") for s in perms.get("secrets") or []]
    setting_keys = [s.get("key") for s in m.get("settings") or []]
    if len(set(secret_keys)) != len(secret_keys) or len(set(setting_keys)) != len(setting_keys):
        errors.append("secrets / settings keys repeat")
    for st in m.get("settings") or []:
        key, kind = st.get("key"), st.get("type", "text")
        if kind not in ("text", "choice", "toggle", "number"):
            errors.append(f"settings.{key}: type is text, choice, toggle or number")
        if st.get("default") is not None and not isinstance(st["default"], str):
            errors.append(f"settings.{key}: default is a string (\"true\", \"5\")")
        values = [o if isinstance(o, str) else (o or {}).get("value") for o in st.get("options") or []]
        if kind == "choice":
            if not values or not all(isinstance(v, str) for v in values):
                errors.append(f"settings.{key}: choice needs options — strings or {{value, title}}")
            elif st.get("default") is not None and st["default"] not in values:
                errors.append(f"settings.{key}: default “{st['default']}” isn't among the options")
        if kind == "toggle" and st.get("default") not in (None, "true", "false"):
            errors.append(f"settings.{key}: a toggle's default is \"true\" or \"false\"")
        if kind == "number":
            lo, hi = st.get("min"), st.get("max")
            if lo is not None and hi is not None and lo >= hi:
                errors.append(f"settings.{key}: min must be less than max")
    floor = 30 if perms.get("network") else 5
    if m.get("refresh") is not None and m["refresh"] < floor:
        errors.append(f"refresh under {floor} s will be raised to {floor}")

    errors += check_strings(folder, m, files)

    try:
        view = json.loads(files["view.json"])
    except json.JSONDecodeError as e:
        return errors + [f"view.json: {e}"]
    if not isinstance(view, dict) or not (set(view) & SIZES):
        errors.append("view.json: an object with the keys full / medium / small")
    else:
        for key in set(view) - SIZES - {"$schema"}:
            errors.append(f"view.json: unknown key “{key}” (expected full / medium / small)")
        for size in SIZES & set(view):
            check_node(view[size], f"view.{size}", errors)
            style_hints(view[size], f"view.{size}", size, WARNINGS)

    source = files["provider.js"].decode("utf-8", errors="replace")
    if not re.search(r"function\s+refresh\s*\(", source):
        errors.append("provider.js: no refresh(ctx) function")
    if re.search(r"files\.(read|modified|lines|list)\(", source) and not perms.get("files"):
        errors.append("provider.js reads files, but permissions.files is empty")
    if re.search(r"\b(require|import\s|XMLHttpRequest|WebSocket|process\.)", source):
        errors.append("provider.js: the sandbox has no require/import/XMLHttpRequest/WebSocket/process — use fetch")
    urls = re.findall(r"https?://([a-z0-9.-]+)", source)
    allowed = perms.get("network") or []
    for host in sorted(set(urls)):
        if not any(host == a or host.endswith("." + a) for a in allowed):
            errors.append(f"provider.js reaches {host}, but it isn't in permissions.network")
    if re.search(r"http://", source):
        errors.append("provider.js: http:// is not allowed, only https://")
    return errors


WARNINGS: list[str] = []
HEX = re.compile(r"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")


def style_hints(node, path: str, size: str, out: list[str]) -> None:
    """Not errors — things that usually look wrong on the phone or in some theme."""
    if not isinstance(node, dict):
        return
    t = node.get("type")
    for key in ("color", "background"):
        if t != "sprite" and HEX.match(str(node.get(key, ""))):
            out.append(f"{path}.{key}: {node[key]} — themes can't restyle hex; unless it's a brand colour, prefer a name (accent, green…)")
    kids = [k for k in node.get("children") or [] if isinstance(k, dict)]
    if t == "box" and "if" not in node and kids and all(k.get("if") for k in kids):
        out.append(f"{path}: all of the box's content is under if, but the box itself isn't; when the condition is false an empty backing remains — move the if to the box")
    if t == "button" and size == "small":
        out.append(f"{path}: a button in small is cramped; better a box with an action (the whole tile is tappable)")
    for i, child in enumerate(node.get("children") or []):
        style_hints(child, f"{path}.children[{i}]", size, out)
    if isinstance(node.get("template"), dict):
        style_hints(node["template"], f"{path}.template", size, out)


def check_node(node, path: str, errors: list[str]) -> None:
    if not isinstance(node, dict):
        errors.append(f"{path}: a node must be an object")
        return
    t = node.get("type")
    if t not in NODES:
        errors.append(f"{path}: unknown type “{t}” (there are: {', '.join(sorted(NODES))})")
        return
    for key in set(node) - NODES[t] - COMMON:
        errors.append(f"{path}: {t} has no field “{key}”")
    if t == "text" and "style" in node and not BINDING.search(str(node["style"])) and node["style"] not in STYLES:
        errors.append(f"{path}: style “{node['style']}” — there are: {', '.join(sorted(STYLES))}")
    for key, allowed in (("weight", WEIGHTS), ("design", DESIGNS)):
        if t == "text" and key in node and not BINDING.search(str(node[key])) and node[key] not in allowed:
            errors.append(f"{path}: {key} “{node[key]}” — there are: {', '.join(sorted(allowed))}")
    if t == "chart" and "style" in node and not BINDING.search(str(node["style"])) and node["style"] not in CHART_STYLES:
        errors.append(f"{path}: chart style “{node['style']}” — there are: {', '.join(sorted(CHART_STYLES))}")
    if t == "button" and not node.get("action"):
        errors.append(f"{path}: a button needs an action")
    if t == "list":
        if "template" not in node:
            errors.append(f"{path}: a list needs a template")
        else:
            check_node(node["template"], f"{path}.template", errors)
    for i, child in enumerate(node.get("children") or []):
        check_node(child, f"{path}.children[{i}]", errors)
    for key, value in node.items():
        if isinstance(value, str) and value.count("{{") != value.count("}}"):
            errors.append(f"{path}.{key}: an unclosed binding {{{{…}}}}")


if __name__ == "__main__":
    paths = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(paths) != 1:
        sys.exit(__doc__)
    problems = validate(Path(paths[0]).resolve())
    for p in problems:
        print("✗", p)
    for w in WARNINGS if "--hints" in sys.argv else []:
        print("⚠", w)
    print("OK" if not problems else f"{len(problems)} problem(s)")
    sys.exit(1 if problems else 0)
