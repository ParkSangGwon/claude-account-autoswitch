#!/bin/sh
# Launches the built bundle against a scratch config and checks the listener answers its health check.
# Catches startup crashes that unit tests cannot see (toolchain-specific isolation traps, bundle layout).
set -eu
APP="${1:-dist/Claude AutoSwitch.app}"
PORT="${SMOKE_PORT:-10912}"
TMP=$(mktemp -d)
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
CLAUDE_AUTOSWITCH_CONFIG="$TMP/config.json" "$APP/Contents/MacOS/ClaudeAutoSwitch" >"$TMP/app.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true; rm -rf "$TMP"' EXIT
i=0
while [ $i -lt 30 ]; do
  if curl -sf -m 2 --noproxy '*' "http://127.0.0.1:$PORT/_autoswitch/health" >"$TMP/status.json"; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["ok"] and d["port"]==int(sys.argv[2]), d' "$TMP/status.json" "$PORT"
    echo "smoke ok: /_autoswitch/health answered on $PORT (pid $PID)"
    exit 0
  fi
  if ! kill -0 $PID 2>/dev/null; then
    echo "smoke failed: the app exited before answering"; cat "$TMP/app.log"; exit 1
  fi
  i=$((i+1)); sleep 1
done
echo "smoke failed: no answer on $PORT after 30s"; cat "$TMP/app.log"; exit 1
