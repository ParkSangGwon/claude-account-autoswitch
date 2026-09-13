# Changelog

All notable changes to Claude AutoSwitch are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the release workflow publishes the section that matches the tag as the release notes.

## [Unreleased]

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

[Unreleased]: https://github.com/ParkSangGwon/claude-account-autoswitch/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.2.0
[0.1.2]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.2
[0.1.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.1
