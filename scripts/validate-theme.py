#!/usr/bin/env python3
"""Checks a PhoneScreen theme (a folder with theme.json, or the file itself) the way the app does.

    python3 scripts/validate-theme.py catalog/themes/com.author.theme
"""
import json
import re
import sys
from pathlib import Path

STYLES = {"flat", "glass", "ascii"}
APPEARANCES = {"dark", "light"}
FONTS = {"system", "rounded", "monospaced", "serif"}
HEX = re.compile(r"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")
MAX_BYTES = 64 * 1024


def validate(path: Path) -> list:
    file = path / "theme.json" if path.is_dir() else path
    if not file.exists():
        return ["нет файла theme.json"]
    raw = file.read_bytes()
    if len(raw) > MAX_BYTES:
        return ["theme.json больше 64 КБ"]
    try:
        t = json.loads(raw)
    except json.JSONDecodeError as e:
        return [f"theme.json: не JSON ({e})"]
    errors = []
    for key in ("id", "name", "version", "author", "style", "appearance", "font", "radius", "background", "colors"):
        if key not in t:
            errors.append(f"нет поля «{key}»")
    if errors:
        return errors
    if not re.match(r"^[a-z0-9]+(\.[a-z0-9-]+)+$", str(t["id"])):
        errors.append(f"id: «{t['id']}» — обратный домен строчными буквами, например com.author.theme")
    if str(t["id"]).startswith("builtin."):
        errors.append("id не может начинаться с builtin.")
    if path.is_dir() and path.name != t["id"]:
        errors.append(f"папка называется {path.name}, а id — {t['id']}: они должны совпадать")
    if not (1 <= len(str(t["name"])) <= 40):
        errors.append("name: от 1 до 40 символов")
    if not re.match(r"^\d+\.\d+\.\d+$", str(t["version"])):
        errors.append("version: вида 1.2.3")
    for key, allowed in (("style", STYLES), ("appearance", APPEARANCES), ("font", FONTS)):
        if t[key] not in allowed:
            errors.append(f"{key}: одно из {', '.join(sorted(allowed))}")
    if not isinstance(t["radius"], (int, float)) or not 0 <= t["radius"] <= 40:
        errors.append("radius: число от 0 до 40")
    colors = []
    bg = t["background"]
    if not isinstance(bg, dict) or not isinstance(bg.get("colors"), list) or not 1 <= len(bg["colors"]) <= 4:
        errors.append("background.colors: от 1 до 4 цветов")
    else:
        colors += [("background.colors", c) for c in bg["colors"]]
        if "angle" in bg and not isinstance(bg["angle"], (int, float)):
            errors.append("background.angle: число (градусы)")
    c = t["colors"]
    for key in ("text", "secondary", "accent"):
        if key not in c:
            errors.append(f"нет поля «colors.{key}»")
        else:
            colors.append((f"colors.{key}", c[key]))
    for key in ("card", "border"):
        if key in c:
            colors.append((f"colors.{key}", c[key]))
    for key, value in (c.get("palette") or {}).items():
        colors.append((f"colors.palette.{key}", value))
    for key, value in colors:
        if not isinstance(value, str) or not HEX.match(value):
            errors.append(f"{key}: «{value}» — цвет вида #RRGGBB или #RRGGBBAA")
    return errors


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    problems = validate(Path(sys.argv[1]))
    for p in problems:
        print("✗", p)
    print("OK" if not problems else f"{len(problems)} проблем(ы)")
    sys.exit(1 if problems else 0)
