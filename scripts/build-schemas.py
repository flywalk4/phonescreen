#!/usr/bin/env python3
"""Writes schemas/*.schema.json (JSON Schema for view.json, manifest.json, theme.json) from the validator's rules,
so editors (VS Code etc.) autocomplete and check widget files. Add "$schema" to a file to use it:
    "$schema": "https://raw.githubusercontent.com/flywalk4/phonescreen/main/schemas/view.schema.json"

    python3 scripts/build-schemas.py          # write
    python3 scripts/build-schemas.py --check  # fail if the committed schemas are stale (CI)
"""
import json, sys, importlib.util
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
OUT = {}
spec=importlib.util.spec_from_file_location("v",ROOT/"scripts/validate-widget.py"); v=importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
spec=importlib.util.spec_from_file_location("vt",ROOT/"scripts/validate-theme.py"); vt=importlib.util.module_from_spec(spec); spec.loader.exec_module(vt)
binding={"type":"string","pattern":"\\{\\{.+\\}\\}"}
num={"anyOf":[{"type":"number"},binding]}
strv={"type":"string"}
boolv={"anyOf":[{"type":"boolean"},binding]}
color={"type":"string","description":"primary, secondary, tertiary, accent, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray, white, clear (no surface), #RRGGBB(AA) or a {{binding}}","examples":["secondary","accent","green","#FF6600"]}
desc={
 "vstack":"Children stacked vertically.","hstack":"Children side by side.","text":"Text; style or size/weight/design.","symbol":"An SF Symbol.",
 "gauge":"Ring, value 0…1.","progress":"Bar, value 0…1.","chart":"Chart of values: line, area or bar.","button":"Calls action(name) in provider.js.",
 "sprite":"Pixel animation: frames of equal-length strings, palette char → colour.","spacer":"Flexible space.","divider":"A line.",
 "list":"Repeats template for each of items (item / index bound); columns for a grid.","box":"A rounded panel on the theme's surface; fit hugs content; action makes it tappable; aspect keeps proportions.",
 "grid":"Children in columns.","layers":"Children on top of each other (first at the back).","scene":"Animated scene drawn by the phone (live wallpaper).",
}
props={
 "spacing":num,"align":strv,"children":{"type":"array","items":{"$ref":"#/$defs/node"}},"text":strv,
 "style":{"anyOf":[{"enum":sorted(v.STYLES)+sorted(v.CHART_STYLES)},binding]},"color":color,"lines":num,"size":num,
 "weight":{"anyOf":[{"enum":sorted(v.WEIGHTS)},binding]},"design":{"anyOf":[{"enum":sorted(v.DESIGNS)},binding]},
 "name":{"type":"string","description":"SF Symbol name"},"value":num,"label":strv,"values":{"anyOf":[{"type":"array","items":{"type":"number"}},binding]},
 "height":num,"title":strv,"symbol":strv,"action":{"type":"string","description":"action(name) in provider.js; may contain {{bindings}}"},
 "frames":{"anyOf":[{"type":"array"},binding]},"palette":{"anyOf":[{"type":"object"},binding]},"fps":num,
 "items":binding,"template":{"$ref":"#/$defs/node"},"columns":num,"padding":num,"background":color,"opacity":num,"radius":num,"fit":boolv,"fill":boolv,"aspect":num,
 "kind":{"anyOf":[{"enum":vt.ANIMATIONS},binding]},"colors":{"anyOf":[{"type":"array","items":strv},binding,{"type":"null"}]},
 "tints":{"anyOf":[{"type":"array","items":strv},binding,{"type":"null"}]},"speed":num,
}
nodes=[]
for t,keys in sorted(v.NODES.items()):
    p={"type":{"const":t},"if":{"type":"string","description":"Hide the node when the binding is empty / false / 0 / []"}}
    for k in sorted(keys): p[k]=props.get(k,{})
    req=["type"]+(["action"] if t=="button" else [])+(["template"] if t=="list" else [])
    nodes.append({"title":t,"description":desc.get(t,""),"type":"object","properties":p,"required":req,"additionalProperties":False})
view={"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://raw.githubusercontent.com/flywalk4/phonescreen/main/schemas/view.schema.json",
 "title":"PhoneScreen widget view.json","description":"Declarative UI for sizes full / medium / small. Any string may contain {{path}} bindings to refresh() data.",
 "type":"object","properties":{"$schema":{"type":"string"},"full":{"$ref":"#/$defs/node"},"medium":{"$ref":"#/$defs/node"},"small":{"$ref":"#/$defs/node"}},
 "additionalProperties":False,"$defs":{"node":{"oneOf":nodes}}}
OUT["view"]=view
manifest={"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://raw.githubusercontent.com/flywalk4/phonescreen/main/schemas/manifest.schema.json",
 "title":"PhoneScreen widget manifest.json","type":"object","required":["id","name","version","author"],
 "properties":{"$schema":{"type":"string"},
  "id":{"type":"string","pattern":"^[a-z0-9]+(\\.[a-z0-9-]+)+$","description":"Reverse DNS, same as the folder name: com.author.widget"},
  "name":{"type":"string","maxLength":40},"version":{"type":"string","pattern":"^\\d+\\.\\d+\\.\\d+$"},"author":{"type":"string"},
  "description":{"type":"string"},"symbol":{"type":"string","description":"SF Symbol for menus"},
  "refresh":{"type":"number","minimum":5,"description":"Seconds between refresh() calls (≥ 30 with network, ≥ 5 without; default 300)"},
  "permissions":{"type":"object","additionalProperties":False,"properties":{
    "network":{"type":"array","items":{"type":"string","pattern":"^[a-z0-9-]+(\\.[a-z0-9-]+)+$"},"description":"HTTPS hosts fetch may reach (subdomains included)"},
    "secrets":{"type":"array","items":{"type":"object","required":["key","title"],"properties":{"key":{"type":"string"},"title":{"type":"string"}}}},
    "files":{"type":"array","items":{"type":"string","pattern":"^~/"},"description":"Read-only paths: ~/folder/ or ~/folder/file"}}},
  "settings":{"type":"array","items":{"type":"object","required":["key","title"],"additionalProperties":False,"properties":{
    "key":{"type":"string","description":"ctx.settings.<key>"},"title":{"type":"string","description":"Short label in Settings"},
    "default":{"type":"string","description":"Values are always strings; toggle: \"true\" / \"false\""},
    "type":{"enum":["text","choice","toggle","number"],"description":"Control in Settings (default text): choice → drop-down, toggle → switch, number → slider (min+max) or stepper"},
    "hint":{"type":"string","description":"Grey line under the control: format, examples"},
    "options":{"type":"array","minItems":1,"items":{"anyOf":[{"type":"string"},{"type":"object","required":["value"],"additionalProperties":False,"properties":{"value":{"type":"string"},"title":{"type":"string"}}}]},"description":"For choice: \"value\" or {\"value\", \"title\"}"},
    "min":{"type":"number"},"max":{"type":"number"},"step":{"type":"number","exclusiveMinimum":0},"unit":{"type":"string","description":"Shown after a number: мин, %"}}}}},
 "additionalProperties":False}
OUT["manifest"]=manifest
hexc={"type":"string","pattern":"^#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$"}
theme={"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://raw.githubusercontent.com/flywalk4/phonescreen/main/schemas/theme.schema.json",
 "title":"PhoneScreen theme.json","type":"object","required":["id","name","version","author","style","appearance","font","radius","background","colors"],
 "properties":{"$schema":{"type":"string"},"id":{"type":"string","pattern":"^[a-z0-9]+(\\.[a-z0-9-]+)+$"},"name":{"type":"string","maxLength":40},
  "version":{"type":"string","pattern":"^\\d+\\.\\d+\\.\\d+$"},"author":{"type":"string"},"description":{"type":"string"},
  "style":{"enum":["flat","glass","ascii"]},"appearance":{"enum":["dark","light"]},"font":{"enum":["system","rounded","monospaced","serif"]},
  "radius":{"type":"number","minimum":0,"maximum":40},
  "background":{"type":"object","required":["colors"],"additionalProperties":False,"properties":{
    "colors":{"type":"array","items":hexc,"minItems":1,"maxItems":4},"angle":{"type":"number"},
    "animation":{"enum":vt.ANIMATIONS+["photo"],"description":"Animated background, or photo: a Favorites photo from the phone, blurred"},"tints":{"type":"array","items":hexc,"maxItems":6},
    "speed":{"type":"number","minimum":0.1,"maximum":5}}},
  "colors":{"type":"object","required":["text","secondary","accent"],"additionalProperties":False,"properties":{
    "text":hexc,"secondary":hexc,"accent":hexc,"card":hexc,"border":hexc,"palette":{"type":"object","additionalProperties":hexc}}},
  "layout":{"type":"object","additionalProperties":False,"description":"Page layout around the cards (all optional)","properties":{
    "gap":{"type":"number","minimum":0,"maximum":24,"description":"Between cards, pt"},
    "margin":{"type":"number","minimum":0,"maximum":24,"description":"Around the page, pt"},
    "padding":{"type":"number","minimum":6,"maximum":24,"description":"Inside cards, pt"},
    "dots":{"type":"boolean","description":"Page dots under the cards"},
    "cardOpacity":{"type":"number","minimum":0,"maximum":1,"description":"Card fill opacity (flat)"},
    "textSize":{"enum":["small","medium","large","xlarge"],"description":"Text size (Dynamic Type)"},
    "status":{"type":"boolean","description":"Time and date beside the Dynamic Island (default true)"},
    "shadow":{"type":"boolean","description":"Soft shadow under cards"},
    "autoPage":{"type":"number","minimum":0,"maximum":600,"description":"Turn pages by themselves every N seconds (0 = off)"},
    "haptics":{"type":"boolean","description":"Light vibration on taps (default true)"},
    "loop":{"type":"boolean","description":"Pages go round: after the last comes the first"},
    "homeOnConnect":{"type":"boolean","description":"Back to the first page on every (re)connection"}}}},
 "additionalProperties":False}
OUT["theme"]=theme
stale=[]
for name, schema in OUT.items():
    path = ROOT / "schemas" / f"{name}.schema.json"
    text = json.dumps(schema, ensure_ascii=False, indent=1) + "\n"
    if "--check" in sys.argv:
        if not path.is_file() or path.read_text() != text: stale.append(path.name)
    else:
        path.parent.mkdir(exist_ok=True); path.write_text(text)
if stale: sys.exit(f"устарели: {', '.join(stale)} — запустите python3 scripts/build-schemas.py")
print(f"schemas: {len(nodes)} node kinds" + (" — OK" if "--check" in sys.argv else " written"))