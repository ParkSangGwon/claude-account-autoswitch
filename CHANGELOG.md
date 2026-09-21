# Changelog

All notable changes to Claude AutoSwitch are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the release workflow publishes the section that matches the tag as the release notes.

## [Unreleased]

## [0.4.0] - 2026-09-21

### Added

- **Keep the 5-hour window open.** Claude starts an account's five-hour window at its first request, so a window first touched at 16:30 runs to 21:30 and a day that could hold 4.8 back-to-back windows holds fewer the later each one starts. Switch this on and the app opens each account's next window itself, the moment the last one resets, by sending a single one-token request on that account — the windows then run on the clock whether or not anyone is at the Mac. The switch is in the popover under the reset timeline and under **Settings → Quota**, and it is off until you ask for it, since the request goes out on your own account. Accounts that could not take a request anyway are left alone, including one whose week is spent: a fresh five hours behind a spent week is five hours nobody can use. A sleeping Mac cannot send anything, so a reset that passes overnight is opened within a minute of waking rather than on time.

### Fixed

- A session that ran out of accounts stopped at `API Error: 429 · every account is out of rotation` and stayed there until somebody typed into it again — one terminal at a time, for as many terminals as were running. The refusal the proxy writes when nothing is left now carries the three lines the API's own refusal carries — the rejected status, the window claiming it, and the epoch second it reopens — so Claude Code shows its own limit banner and continues the task by itself at the reset, with no extra setting and nothing watching the terminals. The lines go out together or not at all, and only when a window reset is what the wait is actually for: a cool-down, a hold or a sign-in has no window to name, and naming one with nothing behind it is the noise the engine refuses to believe when a reply sends it the other way.
- The wait on that refusal could run half an hour past the moment the accounts came back. A 429 that names a closed window is remembered for thirty minutes, but the app forgets it along with the five-hour reading that carries it — so an account whose window reopened in ten minutes was back in ten, while the client had been told to wait thirty. The wait now ends when the window reopens.

## [0.3.1] - 2026-09-20

### Fixed

- **Make current** and the **Next available account** hotkey moved the cursor and left every terminal already running where it was. A session is pinned to the account that served it, and a pin outlives the cursor, so the switch reached new sessions only — while the app said "switched to …" and meant it. The sessions now move with the switch.
- A rolled-over window kept an account out of rotation until the app next looked at the engine. Readings were only ever swept where the app reads state, which is every 30 seconds with the popover closed and every five minutes with the display asleep; until then an account whose five hours had rolled over was still passed over, and with every account in that state the answer was 429 with nothing actually spent. Every request now sweeps before it chooses, so a window that rolled over is back on the next request rather than on the next poll.
- The `retry-after` on "every account is out of rotation" named the soonest reset of any kind, which is usually a five-hour rollover — and a five-hour rollover brings nothing back to an account whose week is what is spent. A client that waited that long was refused again. It now names when an account actually comes back: the soonest account for which the last of the holds on it has lifted, or a minute when what is left needs a person rather than the clock.
- An upstream that could not be reached was reported as a rate limit. With no account left to try, the request answered 429 `rate_limit_error` — the one error that sends the reader after a quota — however plainly the cause was a network failure. It now answers 502 with what went wrong.
- A usage probe could put an account back on numbers it had already spent past. The probe reads the usage endpoint, and a reply that arrived while it was in flight is the newer of the two readings; the probe overwrote it anyway, and the account came back into rotation until the next 429 took it out again. A probe now leaves alone any window a reply has touched since it left.
- Which account a session followed, on a window it had no pin for yet, was whichever pin its dictionary handed over first. Two sessions in the same state could be routed differently, and the same session differently from one request to the next. It now follows wherever it was last served.
- Claude Code announced a full limit for a moment every time rotation moved on. It draws its own limit banner from the `anthropic-ratelimit-unified-*` headers on each reply, and those were relayed exactly as the account that answered wrote them — so the account rotation was about to leave reported 98%, then 100%, to a client that was never going to spend it, and only the next reply, from the account that took over, took the message back. The allowance headers are now restated for the rotation before they reach the client: each metered window carries the reading of whichever account can take the next request and has spent least of it, and the status lines read `allowed` while anything can still serve. With nothing left in rotation the refusal reaches the client exactly as it came, limit and all. What the engine learns about each account from the same headers is unchanged.

## [0.3.0] - 2026-09-19

### Changed

- **The proxy now sits in front of Claude Code instead of replacing its endpoint, and the setup line changes with it.** Since 2.1.196 Claude Code switches off Remote Control, server-managed settings and organization policy whenever `ANTHROPIC_BASE_URL` points anywhere other than `api.anthropic.com` — which is exactly what the old one-line setup did, so every session through this app lost all three while rotation itself kept working. The app now asks for `HTTPS_PROXY` and a local certificate instead: Claude Code keeps dialling `api.anthropic.com`, the proxy terminates that connection on loopback, and the three features come back. Replace `export ANTHROPIC_BASE_URL=…` in your shell profile with the line under **Settings → Proxy** — it sources a file the app writes, so a port change never leaves it stale — and open a new terminal. Leaving the old export in place keeps Remote Control off even after updating; the app now notices such a session and says so in the popover and the Proxy pane.
- Everything Claude Code reaches other than the API host is tunnelled without being decrypted — the MCP servers, telemetry and npm all inherit the proxy and pass straight through.

### Added

- A local certificate authority, created on this Mac and trusted by nothing but the Claude Code processes the setup file points at. It is never added to the system keychain, and the CA's private key is never written to disk: renewal mints the whole chain again, so the only secret stored is a leaf key for one host. **Settings → Proxy → Certificate** shows what it covers, its fingerprint and its expiry, and reissues it.
- `claude-autoswitch`, a wrapper beside the setup file that sources it and execs `claude`. A shell profile does not reach an editor or launcher that runs the binary directly, and those let you name which binary; this is the one to name.
- Remote Control's WebSocket is relayed to the API untouched, with the client's own credential rather than a rotated one, since that session is paired to the identity that asked for it.

## [0.2.1] - 2026-09-15

### Fixed

- Two healthy accounts could both drop out of rotation at once, leaving "no account can take this request" on screen while both still had most of their quota. A 429 that named no window — a burst, a busy upstream, anything the account's own windows knew nothing about — was treated exactly like a spent account and sidelined it for a full minute, and since whatever refused the first account refused its sibling a moment later, two accounts emptied the rotation in two hops. Such a 429 now moves the request on without taking the account out; only three in a row, which is the account's own problem rather than the moment's, earn a wait, and that wait is seconds rather than the minute a missing `retry-after` used to cost.
- A rejection that no window confirmed held the account out for half an hour. The unified status line alone was read as proof, though the comment beside it said the opposite and the code that classifies the same reply for rotation read it as noise — so one reply could both leave the account in rotation and mark it refused. Both now want a window to say so.
- `rotation.waitWhenExhaustedSeconds` did nothing for the request that emptied the rotation on its way through. The wait only ever applied to requests that arrived to find every account already out; one that was refused down to the last account returned 429 immediately, however long the setting was.

- Opening Settings quit the app. The notifications section asks whether the Mac is set to show alerts at all, and that check reads `getNotificationSettings`, whose completion handler runs on the notification centre's own queue — a closure that inherited `@MainActor` traps there under Swift 6, taking the menu bar item down with it every time the gear was clicked. The call now sits outside the main actor, where the handler is free to answer on whichever queue the centre uses, and only the authorization status crosses back.

## [0.2.0] - 2026-09-13

### Added

- Restarting picks up where the last run left off. The proxy now remembers the account it was on and what it last knew about every account's windows, so the first request after a restart is not sent to an account that was already spent when the app quit — it used to take a 429 before rotation noticed. Windows whose reset passed while the app was closed are forgotten on the way in, so an account that rolled over is preferred again straight away.
- Accounts can be set aside for a while: **Skip for 1 hour / 8 hours / until the weekly reset**, from the account card or the popover's row menu. Unlike the on/off switch this lifts itself, so "save this one for the demo" does not depend on anyone remembering to switch it back.
- An account that needs a new sign-in has a **Sign in again…** button. It updates the account in place, keeping its priority, cap and switch — removing and re-adding, which is what the docs used to say, lost all three.
- The plan (Pro, Max 5x, Max 20x, Team) can be set by hand. An account whose tier Claude never reported counted for nothing in the fleet totals, and the only way to fix it was the raw JSON editor.
- **Use a free port** when the configured one is taken: the Proxy pane names the program holding it and can move the listener to a port that is free, writing the new port down.
- The app says when it is up but has never been asked for anything — the usual sign that `ANTHROPIC_BASE_URL` never reached the shell that runs Claude Code. Everything else reads green in that state.
- **Check for updates** in About, and a quiet check once a day. A menu bar app is left running for months; installing stays manual.

### Fixed

- Quitting lost the last thing that happened. The app asked the engine to shut down and exited without waiting, so the most recent rotation and up to five minutes of history went missing on every quit, and the listener's socket lingered.
- A config file the app could not parse could be replaced by an empty one. Opening Settings cleared the error banner, showed no accounts, and offered the JSON editor on a blank document — saving that, or adding an account, overwrote a file that still held every account and token. The app now refuses to write anything while the file cannot be read, says the accounts are unknown rather than showing none, and keeps the editor closed until the file is fixed.
- `rotation.switchAtByWindow` is read and written as `{"weekly": 0.9}`, the shape the reference always documented. The app used to write a flat array and refuse the documented form, so following the docs stopped the proxy from starting. Files written by earlier versions still load.
- A config error now names the key to go and look at — `listen.port is not the shape the app expects` — instead of printing a Swift decoder dump.
- Switching to an account by hand reported success even when a better-ranked account would take the very next request anyway. It now says which account that is.
- Numbers typed into the settings fields were dropped when the field lost focus without Enter, with nothing on screen to show it. Priority and the alert levels silently ignored anything that did not parse; all of them now apply on a button and explain what was wrong.
- Clicking a notification does nothing no longer: it opens the popover. When notifications are turned off for the app in System Settings, the Notifications section says so instead of listing ten switches that cannot fire.
- A global shortcut another app had already claimed failed silently, leaving its switch on. The Shortcuts section now names the chord that could not be registered.
- The rotation log keeps 500 switches instead of 50 — fifty filled up in half a day — asks before clearing, and is included in the diagnostics export.
- The account cards label request counts as "since launch", which is what they always were; a restart resetting them to zero read as broken routing.
- The fleet totals counted allowances no account could reach. An account at its weekly threshold is out of rotation until the week turns, but its untouched five-hour window still went into the five-hour total: two Max 20x accounts, one of them spent for the week, read "session 11%" when the only account that could take a request was already 19% into its own five hours. A window now counts an account only while it can spend it before that window rolls over, so the weekly total still holds a session-capped account and does not swing with ordinary rotation.
- A window its account cannot spend is drawn inert rather than green, so a fresh five hours behind a spent week no longer reads as room to work.
- `↑` in the reset timeline marked every reset on an account that was out of rotation, including ones that brought nothing back. It now marks the reset that actually lifts the blocker.

## [0.1.2] - 2026-09-13

### Fixed

- Usage numbers and the blocker line in the popover were hard to read. The popover is a vibrancy material, so the window behind it bleeds through: amber text sat at 2.7:1 on a light backdrop and fell further over a dark one, well short of the 4.5:1 small text needs. Those numbers and the blocker line now sit on an opaque chip, which holds their contrast whatever is behind the popover.
- The system yellow used by the cap marker and two account badges is the first colour to disappear on a light material; all three moved to the same ramp.

## [0.1.1] - 2026-09-12

First public release.

### Added

- A menu bar proxy that rotates Claude Code across several Claude accounts per request, before a limit is hit.
- The menu bar item shows the time until the 5-hour window resets and how much of it is used (`1h12m 42%`), with bars for the 5-hour and weekly windows.
- The popover: every account's windows, where the next request lands and why, fleet totals weighted by plan, the reset timeline, per-family targets, sessions and the rotation journal.
- Accounts: browser sign-in, pasted code, Claude Code's own Keychain login, a credentials file, or an API key.
- Rotation rules: switch thresholds (overall and per window), usage caps, session affinity, optional spreading of new sessions, a hold when every account is out.
- Notifications for fleet thresholds, rotations with their reason, accounts leaving and re-entering rotation, re-login needed, probe failures, exhaustion and overage billing.
- Seven days of local history with fleet sparklines and a state strip per account.
- Seven languages: English, 한국어, 日本語, 简体中文, Español, Deutsch, Français.
- Homebrew cask (`ParkSangGwon/tap/claude-autoswitch`) and GitHub releases.

[Unreleased]: https://github.com/ParkSangGwon/claude-account-autoswitch/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.4.0
[0.3.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.3.1
[0.3.0]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.3.0
[0.2.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.2.1
[0.2.0]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.2.0
[0.1.2]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.2
[0.1.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.1
