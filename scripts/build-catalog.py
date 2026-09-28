#!/usr/bin/env python3
"""Rebuilds catalog/index.json from catalog/widgets/*/ and catalog/themes/*/ (validating each and hashing its files).

    python3 scripts/build-catalog.py          # rewrite the index
    python3 scripts/build-catalog.py --check  # fail if the index is out of date (for CI / pull requests)

The app downloads each file listed here and refuses it if its SHA-256 differs.
"""
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "catalog"
spec = importlib.util.spec_from_file_location("validate", Path(__file__).with_name("validate-widget.py"))
validate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate)
spec = importlib.util.spec_from_file_location("validate_theme", Path(__file__).with_name("validate-theme.py"))
validate_theme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validate_theme)


def build() -> dict:
    entries, failed = [], False
    for folder in sorted(p for p in (ROOT / "widgets").iterdir() if p.is_dir()):
        problems = validate.validate(folder)
        if problems:
            failed = True
            print(f"✗ {folder.name}")
            for p in problems:
                print("   ", p)
            continue
        m = json.loads((folder / "manifest.json").read_text())
        names = [n for n in validate.REQUIRED + validate.OPTIONAL if (folder / n).exists()]
        entry = {
            "id": m["id"], "name": m["name"], "version": m["version"], "author": m["author"],
            "description": m.get("description"), "symbol": m.get("symbol"),
            "path": f"widgets/{folder.name}",
            "files": {n: hashlib.sha256((folder / n).read_bytes()).hexdigest() for n in names},
        }
        # Name and description per language, so the catalog shows them translated before installing.
        if (folder / "strings.json").exists():
            strings = json.loads((folder / "strings.json").read_text())
            entry["localized"] = {lang: {k: table[f"manifest.{k}"] for k in ("name", "description") if f"manifest.{k}" in table}
                                  for lang, table in sorted(strings.items())}
        entries.append(entry)
        print(f"✓ {m['id']} {m['version']}")
    themes = []
    for folder in sorted(p for p in (ROOT / "themes").iterdir() if p.is_dir()) if (ROOT / "themes").exists() else []:
        problems = validate_theme.validate(folder)
        if problems:
            failed = True
            print(f"✗ {folder.name}")
            for p in problems:
                print("   ", p)
            continue
        t = json.loads((folder / "theme.json").read_text())
        themes.append({
            "id": t["id"], "name": t["name"], "version": t["version"], "author": t["author"],
            "description": t.get("description"), "symbol": "paintpalette",
            "path": f"themes/{folder.name}",
            "files": {"theme.json": hashlib.sha256((folder / "theme.json").read_bytes()).hexdigest()},
            **({"localized": t["localized"]} if t.get("localized") else {}),
        })
        print(f"✓ theme {t['id']} {t['version']}")
        for w in validate_theme.contrast_warnings(t):
            print(f"    ⚠ {w}")
    if failed:
        sys.exit("the catalog wasn't built: fix the errors above")
    return {"name": "Qwovi", "widgets": entries, "themes": themes}


if __name__ == "__main__":
    text = json.dumps(build(), ensure_ascii=False, indent=2) + "\n"
    index = ROOT / "index.json"
    if "--check" in sys.argv:
        if not index.exists() or index.read_text() != text:
            sys.exit("catalog/index.json is stale: run python3 scripts/build-catalog.py")
        print("index.json is up to date")
    else:
        index.write_text(text)
        print(f"wrote {index.relative_to(ROOT.parent)}")
