# Claude AutoSwitch reference

What the app stores, what it listens on, and how it picks an account. The README covers installation and everyday use; [troubleshooting.md](troubleshooting.md) covers what to do when something is off.

## The config file

`~/Library/Application Support/Claude AutoSwitch/config.json`, or the path in `CLAUDE_AUTOSWITCH_CONFIG` when that variable is set before the app launches.
The file is written atomically (temp file, fsync, rename) with `0600` permissions.
Every setting applies live; nothing needs a restart.
Tokens live in this file and nowhere else.

```json
{
  "version": 1,
  "listen": { "port": 10912 },
  "api": { "baseURL": "https://api.anthropic.com" },
  "rotation": {
    "switchAt": 0.98,
    "switchAtByWindow": { "weekly": 0.9 },
    "spreadSessions": false,
    "waitWhenExhaustedSeconds": 0
  },
  "quota": { "refreshEverySeconds": 300, "keepSessionOpen": false },
  "observed": {
    "lastActive": "6f1c…",
    "accounts": [
      { "id": "6f1c…", "windows": { "readings": ["weekly", { "used": 0.99, "resetsAt": "2026-09-18T09:00:00Z" }] } }
    ]
  },
  "accounts": [
    {
      "id": "6f1c…",
      "label": "ted",
      "rank": 0,
      "enabled": true,
      "cap": { "uniform": { "_0": 0.9 } },
      "plan": { "max": { "multiplier": 20 } },
      "skipUntil": "2026-09-14T18:00:00Z",
      "planText": "default_claude_max_20x",
      "organization": { "name": "Example Org", "id": "org-…" },
      "claudeAccountID": "acct-…",
      "credential": { "oauth": { "_0": { "access": "…", "refresh": "…", "expiresAt": "2026-09-12T12:00:00Z" } } }
    }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `listen.port` | Local port for the listener. 1–65535; anything else falls back to 10912. |
| `api.baseURL` | Where requests are forwarded. |
| `rotation.switchAt` | Usage (0–1) at which rotation leaves an account. |
| `rotation.switchAtByWindow` | Per-window overrides, keyed by window name: `session`, `weekly`, `weeklyFable`, `weeklySonnet`. A missing window uses `switchAt`; a name the app does not know is skipped. |
| `rotation.spreadSessions` | Give each new Claude Code session the least loaded account among the best-ranked ones. |
| `rotation.waitWhenExhaustedSeconds` | When every account is out, hold the request this long before answering 429. |
| `quota.refreshEverySeconds` | Background refresh of idle accounts from the usage endpoint. 0 turns it off; the minimum is 30. |
| `quota.keepSessionOpen` | Open each account's next five-hour window as soon as the last one resets, by sending one minimal request on that account. Off by default. |
| `observed` | The engine's own notes, not a setting: the account it left off on and each account's last known windows. Written when rotation moves, after a probe, and on quit. |
| `accounts[].rank` | Lower is preferred. A strictly lower rank preempts a healthy current account. |
| `accounts[].enabled` | Off takes the account out of rotation without removing it. |
| `accounts[].skipUntil` | Set aside until this time, then back in rotation on its own. The switch above stays on. |
| `accounts[].cap` | A hard ceiling per window (`uniform` for all, or `perWindow`). At the cap the account takes nothing. |
| `accounts[].plan` | `max` (multiplier 5 or 20), `pro`, `team` (multiplier), or `unknown`. Weights the fleet total. |
| `accounts[].credential` | `oauth` (access, refresh, expiresAt) or `apiKey`. |

Missing sections take their defaults, so a hand-written file needs only what it changes.

A section the app cannot parse stops it from writing the file at all: the settings screens show what went wrong and which key to look at, the accounts pane says the accounts are unknown rather than showing none, and the JSON editor stays closed.
Otherwise a file it never read would be replaced by the empty defaults it fell back to, and the tokens in it would be gone.
Fix the file, then Advanced → Config file → Reload from disk.

## Windows

Claude meters a subscription on a rolling five-hour window (`session`), a rolling week (`weekly`), and a separate week for model families it meters on their own (`weeklyFable`, `weeklySonnet`).
The app learns each account's windows from the `anthropic-ratelimit-*` headers on every reply and from the usage endpoint the background probe calls.
A window whose reset has passed is forgotten, so a stale number never keeps an account out.
An API key has token and request allowances instead of windows.

### Keeping the five-hour window open

Claude starts an account's five-hour window at its first request, not on a fixed schedule.
A window first touched at 16:30 therefore runs to 21:30, and a day that could hold 4.8 back-to-back windows holds fewer the later each one starts.

With `quota.keepSessionOpen` on, the engine opens the next window itself.
Once a minute — or exactly at the next reset, when that is sooner — it looks for accounts whose `session` reading is gone, which is precisely the ones whose window has rolled over, and sends a one-token `/v1/messages` request on each.
The reply's `anthropic-ratelimit-*` headers are absorbed like any other, so the new window and its reset are known immediately; the request itself is the proof that the window opened.
An account that cannot take a request anyway is left alone: disabled, held by `skipUntil`, capped, cooling down, needing a login, or with its week spent, since a fresh five hours behind a spent week is five hours nobody can use.
A try that opened nothing is not repeated for five minutes.
The request does not go through the rotation: no session is pinned to the account, the current account does not move, and the account's traffic counters stay a record of what the client sent.

The setting is off by default because the request goes out on the user's own account.
A sleeping Mac cannot send anything, so a reset that passes overnight is opened within a minute of waking rather than on time — the gap this closes is the one during the day.

## The fleet total

The fleet bars average every enabled account's window, weighted by what its plan is worth: a Max 20x counts for twenty Pro plans, and an account whose tier is unknown counts for nothing.

An account only counts on a window it can still spend before that window rolls over.
A blocker that outlasts the window strands the allowance behind it: an account at its weekly threshold gets a fresh five-hour window every five hours and can use none of them, so it is left out of the five-hour and family totals while staying in the weekly one, which is the number that explains it.
A blocker that lifts sooner changes nothing — an account whose five hours are spent is back long before the week turns, so the weekly total still counts it and does not swing with ordinary rotation.
When nothing can spend a window, its bar reads 100% and counts down to the first blocker that lifts.

The reset timeline marks a reset with `↑` when it is the one that brings its account back, not merely because the account is out.

## How an account is chosen

For every request the engine checks each account, in this order, and skips it on the first blocker it finds:

1. turned off in Settings
2. skipped by hand until a time that has not passed yet
3. at its usage cap on any window
4. cooling down after a 429 (until the upstream's `retry-after` passes)
5. spent, says the upstream
6. needs a new sign-in (the refresh token was rejected)
7. session or weekly window at the switch threshold
8. token or request allowance at the switch threshold (API keys)
9. the family window the request draws on (Fable, Sonnet) at its threshold
10. the upstream refused its last request on a window it confirmed

Among the accounts that can serve, the choice is:

1. the account the session is already on, while it can serve and nothing outranks it
2. with spreading on, the least loaded account among the best-ranked ones (new sessions only)
3. the current account, while it can serve and nothing outranks it
4. the best-ranked account, ties broken by the weekly window that resets soonest, then config order

A successful reply makes its account the current one and pins the session to it for that weekly window.
A request on a window the session has no pin for follows the account that served it last.
Every check above is made against readings the request refreshes itself, so a window that rolled over is back in rotation on the next request rather than on the app's next poll.

**Make current** and **Next available account** move the sessions already running as well as the cursor: a pin outlives the cursor, so a switch that left them alone would reach new sessions only.

A restart picks up where the last run left off: the current account and every account's last known windows come back from `observed`, so the first request is not sent to an account that was already spent when the app quit.
Windows whose reset passed while the app was closed are forgotten on the way in, so an account that rolled over is preferred again straight away.

## What a reply does

| Upstream said | What happens |
| --- | --- |
| 2xx | The account is current; its windows are updated from the headers; the session is pinned. |
| 429 naming a shared window | The account cools down for `retry-after` (1 s–1 h); the request moves on. |
| 429 naming Fable's window only | The account is marked refused; the request moves on. |
| 429 naming no window | The request moves on, but the account stays in rotation: nothing said its quota was gone. Three in a row are its own problem and it cools down for `retry-after` (1–60 s, 5 s when the reply gives none). |
| 401 | A subscription account refreshes its token once and retries; then the request moves on. |
| 403 | The request moves on. |
| 5xx | The request moves on once. |
| nothing at all | The request moves on; with nowhere left to move it answers 502, not 429 — nobody refused it, it never arrived. |
| nothing left | The request waits up to `waitWhenExhaustedSeconds`, then answers 429 with a `retry-after`. |

When every account is out and the wait is over, the last upstream reply is relayed as it came.

The `retry-after` is when an account actually comes back: the soonest account for which every hold on it has lifted, which is the *last* of its own holds to go.
A five-hour rollover on an account whose week is what is spent brings nothing back, and is not what the client is told to wait for.
A minute stands in when no account comes back on its own — when what is left needs a new sign-in or a person.

## What the client reads

Claude Code draws its own limit banner from the `anthropic-ratelimit-unified-*` headers on every reply.
Relayed untouched those headers describe the one account that answered, so the account rotation is about to leave announces a limit the client is never going to hit, and the next reply takes it back.

On the way out the allowance headers are restated for the rotation: `-utilization` and `-reset` on the `5h`, `7d` and `7d_oi` windows carry the reading of whichever account that can take the next request has spent least of that window, `-status` reads `allowed` and `-surpassed-threshold` reads `false`.
Each value keeps the shape the upstream wrote it in — a percentage stays a percentage, an epoch stays an epoch — and a header the upstream did not send is not invented.
With nothing left in rotation there is nothing to restate, and the refusal reaches the client exactly as it came.
What the engine itself learned from those headers is the account's own reading, untouched by this.

## The listener

The listener is an HTTP proxy on `127.0.0.1` only, reached through `HTTPS_PROXY`.
It reads each connection's request line as raw bytes and takes one of three routes:

When the configured port is taken the listener does not start, and the Proxy pane names what holds it and offers a free port nearby.

- `CONNECT api.anthropic.com:443` is terminated locally with the app's own leaf, and what comes out of the tunnel is forwarded to `api.baseURL` with the chosen account's credential in place of the client's. ALPN offers `http/1.1` alone: Remote Control's channel is a WebSocket, and over HTTP/2 that would need RFC 8441 extended CONNECT.
- Any other `CONNECT` is a blind TCP tunnel — the MCP servers, telemetry and npm all inherit the proxy and arrive here. Names that resolve back to this listener, to loopback or to link-local are refused with 403; a dial that fails answers 502.
- An origin-form request is served directly. `GET /_autoswitch/health` answers `{"ok":true,"version":"…","port":10912,"accounts":2,"startedAt":"…"}` and is the only endpoint the app itself serves; anything else in that form is a client still pointed here with `ANTHROPIC_BASE_URL`, which is served as before and counted so the app can say that session has Remote Control switched off. An absolute-form request is refused with 501.
- Paths under `/v1/code/` and `/api/oauth/` go through with the client's own credential, and so does a request that asks to upgrade the protocol: a WebSocket handshake is relayed to `api.baseURL` byte for byte, headers untouched, and never reaches the rotation path.

Hop-by-hop headers, `authorization`, `x-api-key`, `accept-encoding` and `content-length` are rebuilt on the way out; connection headers and `content-encoding` are dropped on the way back.
`metadata.user_id` in the request body is rewritten to name the account whose token went out.
Bodies over 64 MiB are refused with 413.
Replies stream back as they arrive; `message_start` and `message_delta` events are read on the way past to count tokens.

## Signing in

Sign-in uses Claude Code's own OAuth client: PKCE against `claude.ai`, tokens from `platform.claude.com`, identity and usage from `api.anthropic.com`.
The browser flow opens a loopback callback on a random port; the paste flow uses Anthropic's own callback page and accepts the code, `code#state`, or the whole URL.
Tokens refresh five minutes before they expire, one refresh per account at a time; a refresh token the server rejects is never sent again and the account waits for a new sign-in.
Importing reads the Keychain item Claude Code writes (`Claude Code-credentials`, through `security`) or a credentials JSON file.

## Files and environment

| What | Where |
| --- | --- |
| Config | `~/Library/Application Support/Claude AutoSwitch/config.json` (`CLAUDE_AUTOSWITCH_CONFIG` overrides) |
| History | `~/Library/Application Support/Claude AutoSwitch/history.json`, seven days, one sample a minute |
| Preferences, alert state, rotation journal | `defaults` domain `com.parksanggwon.claudeautoswitch` |
| Terminal launcher | `~/Library/Application Support/Claude AutoSwitch/claude.command` |
| Shell setup file | `~/Library/Application Support/Claude AutoSwitch/env.sh`, rewritten on every start; a shell profile sources it |
| Wrapper | `~/Library/Application Support/Claude AutoSwitch/claude-autoswitch` (`0755`), sources the setup file and execs `claude`, for launchers that run the binary directly |
| Local CA and leaf | `ca.pem` and `leaf.pem` (`0644`), `leaf.key` (`0600`), beside the config. The CA private key is never written; renewal mints the whole chain again |

Debug hooks for screenshots and UI work: `AUTOSWITCH_DEBUG_DEMO_QUOTA=1` seeds plausible windows without a login, `AUTOSWITCH_DEBUG_WINDOW=<section>` opens a settings pane and the popover, `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` pins the appearance, `AUTOSWITCH_DEBUG_SIDECAR=<tag>` moves preferences to the `<domain>.<tag>` suite and the menu bar slot to its own key, `AUTOSWITCH_DEBUG_BIND_PORT=<port>` listens there while the panes keep showing the configured port. The last two let a second instance run beside an installed app without touching it.
