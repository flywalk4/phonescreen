#!/bin/bash
# Real screenshots of the iPhone app in the Simulator (DEBUG demo mode, no Mac agent needed):
#   widgets/<id>.png          every catalog widget full screen (dark theme)
#   pages/<theme>-<n>.png     mixed pages (grid, trio, split, games, built-ins) in each built-in theme
#   catalog-themes/<id>.png   each catalog theme on a grid page
#   landscape/<theme>-<n>.png mixed pages lying sideways
# Needs Xcode, xcodegen and Node. Usage: scripts/screenshots.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-screenshots}
ORIENT=${ORIENT:-portrait}
BUNDLE_ID=com.flywalk4.qwovi.ios
mkdir -p "$OUT/widgets" "$OUT/pages" "$OUT/catalog-themes" build

# A 6.1" iPhone from the newest runtime (the demo pages assume a regular-size phone).
DEV=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
runtimes = json.load(sys.stdin)["devices"]
phones = [d for rt, ds in sorted(runtimes.items(), reverse=True) if "iOS" in rt for d in ds if d["name"].startswith("iPhone")]
pick = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]] or phones
print(pick[0]["udid"])')
echo "simulator: $(xcrun simctl list devices | grep "$DEV" | sed 's/^ *//')"

xcodegen generate >/dev/null
xcodebuild -project Qwovi.xcodeproj -scheme QwoviiOS -configuration Debug -destination "id=$DEV" \
  -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO build > build/sim.log 2>&1 || { grep -E "error:" build/sim.log; exit 1; }
APP=build/sim/Build/Products/Debug-iphonesimulator/Qwovi.app

xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl ui "$DEV" appearance dark
xcrun simctl install "$DEV" "$APP"
xcrun simctl location "$DEV" set 55.7558,37.6173 || true # Moscow, so the weather page has a place
for service in calendar reminders location photos; do xcrun simctl privacy "$DEV" grant "$service" "$BUNDLE_ID" || true; done
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data)
mkdir -p "$DATA/Documents"
# The photo frame's demo pictures: the Simulator's own sample photos (its photo library can't be unlocked from here).
mkdir -p "$DATA/Documents/demo-photos"
find "$HOME/Library/Developer/CoreSimulator/Devices/$DEV/data/Media/DCIM" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.heic' -o -iname '*.png' \) 2>/dev/null \
  | head -8 | while read -r f; do cp "$f" "$DATA/Documents/demo-photos/"; done || true
echo "demo photos: $(ls "$DATA/Documents/demo-photos" | wc -l | tr -d ' ')"
node scripts/widget-dev.mjs bundle "$DATA/Documents/demo.json" > build/bundle.txt
cat build/bundle.txt

mkdir -p "$OUT/crashes"
shot() { # shot <file> <launch args…>
  local file=$1; shift
  xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE_ID" --demo --demo-orientation "$ORIENT" -language "${LANG_CODE:-en}" "$@" >/dev/null
  sleep 6
  xcrun simctl io "$DEV" screenshot "$file" >/dev/null 2>&1
  # The app hides the status bar; if it is gone from the process list, it crashed — keep the report.
  # (not grep -q: it exits early, launchctl gets SIGPIPE and pipefail turns that into a false "crash")
  if ! xcrun simctl spawn "$DEV" launchctl list | grep "$BUNDLE_ID" >/dev/null; then
    echo "  ✗ $file: the app isn't running"
    find ~/Library/Logs/DiagnosticReports -name 'Qwovi*' -newer build/bundle.txt -exec cp {} "$OUT/crashes/" \; 2>/dev/null || true
  else
    echo "  $file"
  fi
}

# Every widget full screen.
grep -E '^  [0-9]+: single custom:' build/bundle.txt | while read -r line; do
  n=$(echo "$line" | sed -E 's/^ *([0-9]+):.*/\1/'); id=$(echo "$line" | sed -E 's/.*custom:([^ ,]+).*/\1/')
  shot "$OUT/widgets/$id.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme builtin.dark --page "$n"
done

# Layout debug overlay (page and card frames with sizes) on the mixed pages.
mkdir -p "$OUT/debug"
for n in $(grep -E '^  [0-9]+: (grid|trio|split|stack|six)' build/bundle.txt | sed -E 's/^ *([0-9]+):.*/\1/'); do
  shot "$OUT/debug/layout-$n.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme builtin.dark --page "$n" --debug-layout
done

# Mixed pages in each built-in theme.
MIXED=$(grep -E '^  [0-9]+: (grid|trio|split|stack|six)' build/bundle.txt | sed -E 's/^ *([0-9]+):.*/\1/')
for theme in dark light glass ascii; do
  for n in $MIXED; do shot "$OUT/pages/$theme-$n.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme "builtin.$theme" --page "$n"; done
done

# Lying sideways: the mixed pages in landscape (dark and glass).
mkdir -p "$OUT/landscape"
for n in $MIXED; do
  theme=$([ $((n % 2)) -eq 0 ] && echo dark || echo glass)
  ORIENT=landscapeIslandLeft shot "$OUT/landscape/$theme-$n.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme "builtin.$theme" --page "$n"
done

# Catalog themes, each on the next mixed page, so the picture shows many widgets rather than one page over and over.
PAGES=($MIXED)
i=0
for theme in catalog/themes/*/; do
  id=$(basename "$theme")
  node scripts/widget-dev.mjs bundle "$DATA/Documents/theme.json" --theme "$theme" >/dev/null
  shot "$OUT/catalog-themes/$id.png" --demo-bundle "$DATA/Documents/theme.json" --page "${PAGES[$((i % ${#PAGES[@]}))]}"
  i=$((i + 1))
done
echo "done: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') screenshots in $OUT"
