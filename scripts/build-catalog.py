#!/usr/bin/env python3
"""Rebuilds catalog/index.json from catalog/widgets/*/ (validating each package and hashing its files).

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
        entries.append({
            "id": m["id"], "name": m["name"], "version": m["version"], "author": m["author"],
            "description": m.get("description"), "symbol": m.get("symbol"),
            "path": f"widgets/{folder.name}",
            "files": {n: hashlib.sha256((folder / n).read_bytes()).hexdigest() for n in validate.REQUIRED},
        })
        print(f"✓ {m['id']} {m['version']}")
    if failed:
        sys.exit("каталог не собран: исправьте ошибки выше")
    return {"widgets": entries}


if __name__ == "__main__":
    text = json.dumps(build(), ensure_ascii=False, indent=2) + "\n"
    index = ROOT / "index.json"
    if "--check" in sys.argv:
        if not index.exists() or index.read_text() != text:
            sys.exit("catalog/index.json устарел: запустите python3 scripts/build-catalog.py")
        print("index.json актуален")
    else:
        index.write_text(text)
        print(f"записан {index.relative_to(ROOT.parent)}")
