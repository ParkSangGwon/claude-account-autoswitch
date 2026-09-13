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
  "quota": { "refreshEverySeconds": 300 },
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
| `rotation.switchAtByWindow` | Per-window overrides: `session`, `weekly`, `weeklyFable`, `weeklySonnet`. A missing window uses `switchAt`. |
| `rotation.spreadSessions` | Give each new Claude Code session the least loaded account among the best-ranked ones. |
| `rotation.waitWhenExhaustedSeconds` | When every account is out, hold the request this long before answering 429. |
| `quota.refreshEverySeconds` | Background refresh of idle accounts from the usage endpoint. 0 turns it off; the minimum is 30. |
| `observed` | The engine's own notes, not a setting: the account it left off on and each account's last known windows. Written when rotation moves, after a probe, and on quit. |
| `accounts[].rank` | Lower is preferred. A strictly lower rank preempts a healthy current account. |
| `accounts[].enabled` | Off takes the account out of rotation without removing it. |
| `accounts[].cap` | A hard ceiling per window (`uniform` for all, or `perWindow`). At the cap the account takes nothing. |
| `accounts[].plan` | `max` (multiplier 5 or 20), `pro`, `team` (multiplier), or `unknown`. Weights the fleet total. |
| `accounts[].credential` | `oauth` (access, refresh, expiresAt) or `apiKey`. |

Missing sections take their defaults, so a hand-written file needs only what it changes.

## Windows

Claude meters a subscription on a rolling five-hour window (`session`), a rolling week (`weekly`), and a separate week for model families it meters on their own (`weeklyFable`, `weeklySonnet`).
The app learns each account's windows from the `anthropic-ratelimit-*` headers on every reply and from the usage endpoint the background probe calls.
A window whose reset has passed is forgotten, so a stale number never keeps an account out.
An API key has token and request allowances instead of windows.

## How an account is chosen

For every request the engine checks each account, in this order, and skips it on the first blocker it finds:

1. turned off in Settings
2. at its usage cap on any window
3. cooling down after a 429 (until the upstream's `retry-after` passes)
4. spent, says the upstream
5. needs a new sign-in (the refresh token was rejected)
6. session or weekly window at the switch threshold
7. token or request allowance at the switch threshold (API keys)
8. the family window the request draws on (Fable, Sonnet) at its threshold
9. the upstream refused its last request on a window it confirmed

Among the accounts that can serve, the choice is:

1. the account the session is already on, while it can serve and nothing outranks it
2. with spreading on, the least loaded account among the best-ranked ones (new sessions only)
3. the current account, while it can serve and nothing outranks it
4. the best-ranked account, ties broken by the weekly window that resets soonest, then config order

A successful reply makes its account the current one and pins the session to it for that weekly window.

A restart picks up where the last run left off: the current account and every account's last known windows come back from `observed`, so the first request is not sent to an account that was already spent when the app quit.
Windows whose reset passed while the app was closed are forgotten on the way in, so an account that rolled over is preferred again straight away.

## What a reply does

| Upstream said | What happens |
| --- | --- |
| 2xx | The account is current; its windows are updated from the headers; the session is pinned. |
| 429 naming a shared window | The account cools down for `retry-after` (1 s–1 h); the request moves on. |
| 429 naming Fable's window only | The account is marked refused; the request moves on. |
| plain 429 | The account steps aside for up to a minute; the request moves on. |
| 401 | A subscription account refreshes its token once and retries; then the request moves on. |
| 403 | The request moves on. |
| 5xx | The request moves on once. |
| nothing left | The request waits up to `waitWhenExhaustedSeconds`, then answers 429 with a `retry-after`. |

When every account is out and the wait is over, the last upstream reply is relayed as it came.

## The listener

The listener speaks HTTP/1.1 on `127.0.0.1` only.
Every path is forwarded to `api.baseURL` with the chosen account's credential in place of the client's, except:

- `GET /_autoswitch/health` answers `{"ok":true,"version":"…","port":10912,"accounts":2,"startedAt":"…"}` and is the only endpoint the app itself serves.
- Paths under `/v1/code/` and `/api/oauth/` go through with the client's own credential.

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

Debug hooks for screenshots and UI work: `AUTOSWITCH_DEBUG_DEMO_QUOTA=1` seeds plausible windows without a login, `AUTOSWITCH_DEBUG_WINDOW=<section>` opens a settings pane and the popover, `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` pins the appearance.
