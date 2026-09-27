#!/bin/bash
# Real screenshots of the iPhone app in the Simulator (DEBUG demo mode, no Mac agent needed):
#   widgets/<id>.png          every catalog widget full screen (dark theme)
#   pages/<theme>-<n>.png     mixed pages (grid, trio, split, games, built-ins) in each built-in theme
#   catalog-themes/<id>.png   each catalog theme on a grid page
# Needs Xcode, xcodegen and Node. Usage: scripts/screenshots.sh [out-dir]
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-screenshots}
BUNDLE_ID=com.flywalk4.phonescreen.ios
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
xcodebuild -project PhoneScreen.xcodeproj -scheme PhoneScreeniOS -configuration Debug -destination "id=$DEV" \
  -derivedDataPath build/sim CODE_SIGNING_ALLOWED=NO build > build/sim.log 2>&1 || { grep -E "error:" build/sim.log; exit 1; }
APP=build/sim/Build/Products/Debug-iphonesimulator/PhoneScreen.app

xcrun simctl boot "$DEV" 2>/dev/null || true
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl ui "$DEV" appearance dark
xcrun simctl install "$DEV" "$APP"
for service in calendar reminders location; do xcrun simctl privacy "$DEV" grant "$service" "$BUNDLE_ID" || true; done
DATA=$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" data)
mkdir -p "$DATA/Documents"
node scripts/widget-dev.mjs bundle "$DATA/Documents/demo.json" > build/bundle.txt
cat build/bundle.txt

shot() { # shot <file> <launch args…>
  local file=$1; shift
  xcrun simctl launch --terminate-running-process "$DEV" "$BUNDLE_ID" --demo "$@" >/dev/null
  sleep 4
  xcrun simctl io "$DEV" screenshot "$file" >/dev/null 2>&1
  echo "  $file"
}

# Every widget full screen.
grep -E '^  [0-9]+: single custom:' build/bundle.txt | while read -r line; do
  n=$(echo "$line" | sed -E 's/^ *([0-9]+):.*/\1/'); id=$(echo "$line" | sed -E 's/.*custom:([^ ,]+).*/\1/')
  shot "$OUT/widgets/$id.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme builtin.dark --page "$n"
done

# Mixed pages in each built-in theme.
MIXED=$(grep -E '^  [0-9]+: (grid|trio|split)' build/bundle.txt | sed -E 's/^ *([0-9]+):.*/\1/')
for theme in dark light glass ascii; do
  for n in $MIXED; do shot "$OUT/pages/$theme-$n.png" --demo-bundle "$DATA/Documents/demo.json" --demo-theme "builtin.$theme" --page "$n"; done
done

# Catalog themes on the first mixed page.
FIRST=$(echo "$MIXED" | head -1)
for theme in catalog/themes/*/; do
  id=$(basename "$theme")
  node scripts/widget-dev.mjs bundle "$DATA/Documents/theme.json" --theme "$theme" >/dev/null
  shot "$OUT/catalog-themes/$id.png" --demo-bundle "$DATA/Documents/theme.json" --page "$FIRST"
done
echo "готово: $(find "$OUT" -name '*.png' | wc -l | tr -d ' ') снимков в $OUT"
