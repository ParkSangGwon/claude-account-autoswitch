#!/bin/bash
# Re-shoots the six screenshots the README references, from the built bundle, with two example
# accounts and demo quota, so no real account ever appears. Run `make app` first.
#
#   scripts/screenshots.sh
# Runs beside an installed Claude AutoSwitch rather than in place of it: the instance shot here binds
# its own port, keeps its preferences in a scratch domain and takes its own menu bar slot, so the
# proxy this Mac's Claude Code sessions go through is never stopped.
set -eu
cd "$(dirname "$0")/.."
APP="dist/Claude AutoSwitch.app/Contents/MacOS/ClaudeAutoSwitch"
[ -x "$APP" ] || { echo "no dist/Claude AutoSwitch.app; run make app first"; exit 1; }
OUT=${SHOTS_OUT:-docs/assets/menubar}
DOMAIN=com.parksanggwon.claudeautoswitch
SIDECAR=shots
# What the panes show. The listener itself binds BIND_PORT, so the installed app keeps this one.
PORT=${SHOTS_PORT:-10912}
BIND_PORT=${SHOTS_BIND_PORT:-19912}
TMP=$(mktemp -d)
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy

cat > "$TMP/config.json" <<JSON
{ "version": 1, "listen": { "port": $PORT },
  "accounts": [
    { "id": "a1", "label": "ted", "rank": 0, "enabled": true, "plan": { "max": { "multiplier": 20 } },
      "organization": { "name": "Example Org", "id": "org-1" },
      "credential": { "oauth": { "_0": { "access": "x", "refresh": "y" } } } },
    { "id": "b2", "label": "ParkSangGwon", "rank": 1, "enabled": true, "plan": { "max": { "multiplier": 20 } },
      "organization": { "name": "Example Org", "id": "org-1" },
      "credential": { "oauth": { "_0": { "access": "x", "refresh": "y" } } } } ] }
JSON
chmod 600 "$TMP/config.json"

# A few switch events for the popover's journal; dates are seconds since 2001-01-01, as JSONEncoder writes them.
REF=$(( $(date +%s) - 978307200 ))
printf '{"events":[{"at":%d,"from":"ParkSangGwon","to":"ted","cause":{"manual":{}}},{"at":%d,"from":"ted","to":"ParkSangGwon","cause":{"blocked":{"_0":{"windowFull":{"_0":"session","resetsAt":%d}}}}},{"at":%d,"from":"ParkSangGwon","to":"ted","cause":{"outranked":{"newRank":0,"oldRank":1}}}]}' \
  $((REF - 90000)) $((REF - 14400)) $((REF - 10800)) $((REF - 3600)) > "$TMP/log.json"

# The sidecar's own preference domain, and the two slot keys AppKit writes to the standard domain
# under its autosave name. Deleting a key at a time leaves every other key of a running app alone.
cleanup() {
  defaults delete "$DOMAIN.$SIDECAR" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$DOMAIN.$SIDECAR.plist"   # `defaults delete` empties it but leaves the file
  defaults delete "$DOMAIN" "NSStatusItem Preferred Position claudeAutoSwitch.$SIDECAR" 2>/dev/null || true
  defaults delete "$DOMAIN" "NSStatusItem Visible claudeAutoSwitch.$SIDECAR" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
# The journal goes in as an argument, not a written key: the argument domain outranks every other, so
# the installed app's real switch history — real account labels — can never reach a public screenshot.
JOURNAL="<$(xxd -p "$TMP/log.json" | tr -d '\n')>"

capture() {  # section appearance popover-file settings-file
  local log="$TMP/run-$1-$2.log" pid w p
  CLAUDE_AUTOSWITCH_CONFIG="$TMP/config.json" AUTOSWITCH_DEBUG_DEMO_QUOTA=1 AUTOSWITCH_DEBUG_WINDOW="$1" \
    AUTOSWITCH_DEBUG_APPEARANCE="$2" AUTOSWITCH_DEBUG_SIDECAR="$SIDECAR" AUTOSWITCH_DEBUG_BIND_PORT="$BIND_PORT" \
    "$APP" -language en -journal "$JOURNAL" >"$log" 2>&1 &
  pid=$!
  sleep 7
  w=$(grep -o 'settings window [0-9]*' "$log" | grep -o '[0-9]*$' || true)
  p=$(grep -o 'popover window [0-9]*' "$log" | grep -o '[0-9]*$' || true)
  if [ -n "$3" ] && [ -n "$p" ]; then screencapture -l "$p" -o -x "$3"; fi
  if [ "$1" = general ] && [ "$2" = light ]; then
    # Crop the menu bar around our item: 190 pt of system items to its left, 8 pt to its right.
    read -r fx _ fw fh scale <<<"$(sed -n 's/.*status item frame \([-0-9]*\) \([-0-9]*\) \([0-9]*\) \([0-9]*\) scale \([0-9]*\).*/\1 \2 \3 \4 \5/p' "$log" | head -1)"
    [ -n "${scale:-}" ] || { echo "no status item frame in $log"; cat "$log"; exit 1; }
    screencapture -x -D 1 "$TMP/display.png"
    sips -c $((fh * scale)) $(( (fw + 198) * scale )) --cropOffset 0 $(( (fx - 190) * scale )) "$TMP/display.png" --out "$OUT/menubar-item.png" >/dev/null
  fi
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true   # Esc closes the popover
  sleep 1
  if [ -n "$4" ] && [ -n "$w" ]; then screencapture -l "$w" -o -x "$4"; fi
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; sleep 1
  echo "$1/$2: settings=${w:-none} popover=${p:-none}"
}

for s in accounts rotation proxy general; do capture "$s" light "" "$OUT/settings-$s.png"; done
capture general dark "$OUT/popover-dark.png" ""
ls -la "$OUT"
