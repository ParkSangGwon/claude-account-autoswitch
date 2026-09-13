# Changelog

All notable changes to Claude AutoSwitch are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the release workflow publishes the section that matches the tag as the release notes.

## [Unreleased]

### Fixed

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

[Unreleased]: https://github.com/ParkSangGwon/claude-account-autoswitch/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.2
[0.1.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.1
