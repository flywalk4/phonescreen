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
ANIMATIONS = ["aurora", "stars", "matrix", "waves", "bokeh", "lava", "snow", "rain", "gradient"]
HEX = re.compile(r"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")
MAX_BYTES = 64 * 1024


def rgba(h):
    v = h[1:] + ("FF" if len(h) == 7 else "")
    return [int(v[i:i + 2], 16) / 255 for i in (0, 2, 4, 6)]


def over(top, below):
    a = top[3]
    return [top[i] * a + below[i] * (1 - a) for i in range(3)] + [1]


def luminance(c):
    ch = [x / 12.92 if x <= 0.03928 else ((x + 0.055) / 1.055) ** 2.4 for x in c[:3]]
    return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2]


def contrast(a, b):
    l1, l2 = luminance(a), luminance(b)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)


def contrast_warnings(t) -> list:
    """Same check as Theme.contrastWarnings() in the app: text ≥ 4.5:1, secondary ≥ 3:1 on background and cards."""
    backs = [over(rgba(c), [0, 0, 0, 1]) for c in t["background"]["colors"]]
    surfaces = [("the background", b) for b in backs]
    card = t["colors"].get("card")
    if card and t["style"] != "glass":
        surfaces += [("a card", over(rgba(card), b)) for b in backs]
    out = []
    for name, minimum in (("text", 4.5), ("secondary", 3.0)):
        fg = rgba(t["colors"][name])
        where, worst = min(((n, contrast(over(fg, s), s)) for n, s in surfaces), key=lambda x: x[1])
        if worst < minimum:
            out.append(f"colors.{name} reads poorly on {where}: contrast {worst:.1f}:1, needs at least {minimum:.1f}:1")
    return out


def validate(path: Path) -> list:
    file = path / "theme.json" if path.is_dir() else path
    if not file.exists():
        return ["no theme.json file"]
    raw = file.read_bytes()
    if len(raw) > MAX_BYTES:
        return ["theme.json is over 64 KB"]
    try:
        t = json.loads(raw)
    except json.JSONDecodeError as e:
        return [f"theme.json: not JSON ({e})"]
    errors = []
    for key in ("id", "name", "version", "author", "style", "appearance", "font", "radius", "background", "colors"):
        if key not in t:
            errors.append(f"no field “{key}”")
    if errors:
        return errors
    if not re.match(r"^[a-z0-9]+(\.[a-z0-9-]+)+$", str(t["id"])):
        errors.append(f"id: “{t['id']}” — a lowercase reverse domain, e.g. com.author.theme")
    if str(t["id"]).startswith("builtin."):
        errors.append("id can't start with builtin.")
    if path.is_dir() and path.name != t["id"]:
        errors.append(f"the folder is named {path.name} but the id is {t['id']}: they must match")
    if not (1 <= len(str(t["name"])) <= 40):
        errors.append("name: 1 to 40 characters")
    if not re.match(r"^\d+\.\d+\.\d+$", str(t["version"])):
        errors.append("version: like 1.2.3")
    loc = t.get("localized")
    if loc is not None:
        if not isinstance(loc, dict) or not all(isinstance(v, dict) for v in loc.values()):
            errors.append('localized: an object {"ru": {"name": …, "description": …}}')
        else:
            for lang, table in loc.items():
                if set(table) - {"name", "description"} or not all(isinstance(v, str) for v in table.values()):
                    errors.append(f"localized.{lang}: only name and description, as strings")
                elif not 0 < len(table.get("name", "x")) <= 40:
                    errors.append(f"localized.{lang}.name: 1 to 40 characters")
    for key, allowed in (("style", STYLES), ("appearance", APPEARANCES), ("font", FONTS)):
        if t[key] not in allowed:
            errors.append(f"{key}: one of {', '.join(sorted(allowed))}")
    if not isinstance(t["radius"], (int, float)) or not 0 <= t["radius"] <= 40:
        errors.append("radius: a number from 0 to 40")
    layout = t.get("layout") or {}
    for key, lo, hi in (("gap", 0, 24), ("margin", 0, 24), ("padding", 6, 24), ("cardOpacity", 0, 1), ("autoPage", 0, 600)):
        v = layout.get(key)
        if v is not None and (not isinstance(v, (int, float)) or not lo <= v <= hi):
            errors.append(f"layout.{key}: a number from {lo} to {hi}")
    if layout.get("textSize") not in (None, "small", "medium", "large", "xlarge"):
        errors.append("layout.textSize: small, medium, large or xlarge")
    for key in ("dots", "status", "shadow", "haptics", "loop", "homeOnConnect"):
        if key in layout and not isinstance(layout[key], bool):
            errors.append(f"layout.{key}: true or false")
    colors = []
    bg = t["background"]
    if not isinstance(bg, dict) or not isinstance(bg.get("colors"), list) or not 1 <= len(bg["colors"]) <= 4:
        errors.append("background.colors: 1 to 4 colours")
    else:
        colors += [("background.colors", c) for c in bg["colors"]]
        colors += [("background.tints", c) for c in bg.get("tints") or []]
        if "animation" in bg and bg["animation"] not in ANIMATIONS + ["photo"]:
            errors.append(f"background.animation: one of {', '.join(ANIMATIONS)} or photo (a photo from the iPhone's Favorites)")
        if "speed" in bg and not (isinstance(bg["speed"], (int, float)) and 0.1 <= bg["speed"] <= 5):
            errors.append("background.speed: a number from 0.1 to 5")
        if len(bg.get("tints") or []) > 6:
            errors.append("background.tints: at most 6 colours")
        if "angle" in bg and not isinstance(bg["angle"], (int, float)):
            errors.append("background.angle: a number (degrees)")
    c = t["colors"]
    for key in ("text", "secondary", "accent"):
        if key not in c:
            errors.append(f"no field “colors.{key}”")
        else:
            colors.append((f"colors.{key}", c[key]))
    for key in ("card", "border"):
        if key in c:
            colors.append((f"colors.{key}", c[key]))
    for key, value in (c.get("palette") or {}).items():
        colors.append((f"colors.palette.{key}", value))
    for key, value in colors:
        if not isinstance(value, str) or not HEX.match(value):
            errors.append(f"{key}: “{value}” — a colour like #RRGGBB or #RRGGBBAA")
    return errors


# Colour names widgets use; one the palette lacks falls back along RELATIVES (like the app), else the system colour.
WIDGET_COLORS = ["red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink"]
RELATIVES = {"mint": "green", "teal": "cyan", "cyan": "blue", "indigo": "blue", "pink": "purple", "brown": "orange", "grey": "gray"}


def palette_warnings(t: dict) -> list:
    """Widget colours the palette doesn't cover: they stay the bright system colour and may clash with the theme."""
    palette = (t.get("colors") or {}).get("palette") or {}
    if not palette:
        return []  # no palette at all: the theme deliberately keeps system colours
    missing = []
    for name in WIDGET_COLORS:
        key = name
        while key and key not in palette:
            key = RELATIVES.get(key)
        if not key:
            missing.append(name)
    return [f"the palette doesn't set {', '.join(missing)} — these colours stay system (bright) ones"] if missing else []


def warnings(path: Path) -> list:
    file = path / "theme.json" if path.is_dir() else path
    t = json.loads(file.read_text())
    return contrast_warnings(t) + palette_warnings(t)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    problems = validate(Path(sys.argv[1]))
    for p in problems:
        print("✗", p)
    if not problems:
        for w in warnings(Path(sys.argv[1])):
            print("⚠", w)
    print("OK" if not problems else f"{len(problems)} problem(s)")
    sys.exit(1 if problems else 0)
