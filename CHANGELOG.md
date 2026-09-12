# Changelog

All notable changes to Claude AutoSwitch are recorded here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the release workflow publishes the section that matches the tag as the release notes.

## [Unreleased]

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

[Unreleased]: https://github.com/ParkSangGwon/claude-account-autoswitch/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/ParkSangGwon/claude-account-autoswitch/releases/tag/v0.1.1
