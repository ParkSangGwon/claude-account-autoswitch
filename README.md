<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Claude AutoSwitch icon">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  Several Claude subscriptions, one Claude Code. A menu bar app that rotates your accounts<br>
  automatically as their limits fill, and shows every account's quota at a glance.
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="No Node, no CLI to install" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 languages" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  English · <a href="README.ko.md">한국어</a> · <a href="README.ja.md">日本語</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="The menu bar item: 3h18m 33% next to the system items">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="The popover: accounts table, fleet bars, routing, sessions and the rotation log">
</p>

## The problem

**One $200 Max plan is not enough anymore, so you pay for two or three.**<br>
Here is what that looks like from the inside.

#### The freelancer with two Max plans

> "Every afternoon it's the same line: `You've hit your usage limit · resets at 4pm`.<br>
> Browser, sign out, sign in, back to the terminal, find where I was."

Two or three times a day, five minutes each.<br>
That is half a day gone every month.

#### The one who installed an account switcher

> "It saves me a click. It does not tell me when to click.<br>
> I still watch the limit and flip by hand."

#### The one running a rotating TUI

> "Switching is automatic now. Seeing what is left is not.<br>
> That is another terminal and another command, next to the one I actually work in."

**"Can't I just…"**

- **…use two accounts?** You can. Every time a limit hits, you are the switch.
- **…install a switcher app?** It shortens the flip to a click. Knowing when to flip, and to which account, is still on you.
- **…run one of the TUIs that rotate?** They rotate. They also keep usage in a terminal you have to keep open.

**Sound familiar?**

- [ ] You pay for more than one Max plan.
- [ ] A limit message sends you straight to the browser.
- [ ] You sometimes forget which account a terminal is on.
- [ ] You open a terminal just to see how much is left.
- [ ] The weekly limit surprises you every time.

Three or more, and the next section is for you.

## The fix

Claude AutoSwitch is a local proxy with a menu bar.<br>
Sign in with two or more Claude accounts and put the proxy in front of Claude Code.<br>
Every request goes out with the token of an account that still has room.<br>
When one account reaches its 5-hour or weekly limit, the next request simply uses another one.<br>
Claude Code never logs out, never restarts, and never knows.<br>
The limit it reads is the rotation's, not one account's, so no limit banner appears while another account still has room.<br>
Every account's quota sits in the menu bar, so you never open a terminal just to look.

It is not an account *switcher*: nothing is swapped in the Keychain and no session is interrupted.<br>
Rotation happens per request, before the limit is hit, and several terminals can be on different accounts at the same time.

## Install

Requirements: macOS 14 Sonoma or later and Claude Code.<br>
There is no Node, no npm package and no other proxy to install.

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

If macOS refuses to open the app afterwards, clear the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"` (or use Open Anyway, described below).

### GitHub release

Download `Claude-AutoSwitch-vX.Y.Z.zip` from the [latest release](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest).<br>
Unzip it and drag **Claude AutoSwitch.app** to `/Applications`.

### From source

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

The app is ad-hoc signed, not notarized.<br>
On first launch macOS may say it cannot verify the developer.<br>
Open **System Settings → Privacy & Security** and click **Open Anyway**, or right-click the app → **Open**.

## Set up in three steps

1. **Add accounts.** Settings → Accounts → *Add account…*
   - Sign in through the browser.
   - Paste a code when the browser cannot reach this Mac.
   - Import the login Claude Code already has (Keychain).
2. **Put the proxy in front of Claude Code.** One line, shown with a Copy button under Settings → Proxy:
   ```sh
   [ -f "$HOME/Library/Application Support/Claude AutoSwitch/env.sh" ] && source "$HOME/Library/Application Support/Claude AutoSwitch/env.sh"
   ```
   Put it in your shell profile, or use *Open Terminal with Claude Code*.
   For an editor or launcher that runs the binary directly, point it at `claude-autoswitch` in the same folder instead of `claude`.
3. **Turn on Launch at login** (Settings → General) so the proxy is there whenever Claude Code is.

That is the whole setup.<br>
Claude Code keeps its own login, and it keeps talking to `api.anthropic.com`, so Remote Control, managed settings and organization policy keep working.<br>
The proxy replaces the token on the way out and leaves everything else in the request untouched.

## The certificate

The proxy sits in front of `api.anthropic.com`, which means it has to hold the TLS for that host, which means it needs a certificate Claude Code accepts.<br>
The app creates a certificate authority on this Mac and points only Claude Code at it, through the `NODE_EXTRA_CA_CERTS` variable in the setup file.<br>
It is **not** added to the system keychain: no browser, no other app and no other tool trusts it, and by default nothing at all is pointed at it.<br>
While Claude Code does trust it, the proxy decrypts and re-encrypts that process's Claude API traffic — that is the mechanism by which it swaps the token, and the `ANTHROPIC_BASE_URL` releases before it saw the same requests in the clear.<br>
Anything holding the CA's **private key** could issue certificates that Claude Code would accept, so that key is never written to disk; the chain is regenerated instead, and the only secret stored is a leaf key for one host.<br>
Delete the app's folder and the trust is gone with it, leaving nothing behind in the system keychain.

## What you get

- **A menu bar item that reads as usage.**
  - `1h12m 42%` is the fleet's 5-hour window: time until it resets, then how much is used. The bars under it are 5-hour and weekly.
  - Orange when a bar runs ahead of its window, red at the switch threshold or when nothing can serve.
  - `→ par` for six seconds on a rotation, `—` when the listener is down.
- **Every account at a glance.**
  - Session, weekly and per-family (Fable, Sonnet) bars, with the number and reset under each.
  - Tier, priority, throttle countdowns and the sessions pinned to the account.
  - A row menu: make current, enable, skip for a while, priority, remove.
- **Where the next request goes, and why.**
  - The old account's reason, a better priority, or "stays on ted".
- **Fleet totals and the reset timeline.**
  - Tier-weighted aggregates that count only the accounts still able to spend the window.
  - Every coming window reset, with `↑` on the ones that bring an account back.
- **Windows that run on the clock, not on when you sit down.**
  - Claude starts a 5-hour window at your first request, so one entered at 16:30 runs to 21:30 and the day holds fewer of them than it could.
  - *Keep the 5-hour window open*, in the popover under the reset timeline, opens each account's next window the moment the last one resets.
  - It is off until you ask for it, because the request goes out on your account, and a Mac that was asleep opens a reset it slept through within a minute of waking.
- **Rotation that handles the real cases.**
  - A 429 that names a closed window throttles the account for its retry-after.
  - A 429 that names no window moves the request on but leaves the account in rotation; only repeats sideline it.
  - An expired token is refreshed once and retried.
  - 403 and 5xx fail over.
  - When every account is out, requests can hold for a configurable time instead of failing.
  - The refusal that follows names the window that is closed and when it reopens, so Claude Code waits it out and picks the task up itself instead of stopping at an error.
  - A restart resumes where rotation left off, rather than sending the first request to an account that was already spent.
- **Sessions.**
  - Each Claude Code session stays on its account per weekly bucket.
  - Optional even distribution spreads new sessions over the least loaded account.
- **When something is off, it says so.**
  - A config file it cannot read is never overwritten, and the error names the key to go and fix.
  - A taken port names the program holding it and offers a free one; a proxy nobody is talking to says so.
- **Switch from anywhere.**
  - The account menu in the popover, the right-click menu, or `⌃⌥⌘N` for the next account that can serve.
  - `⌃⌥⌘T` opens the popover.
- **Notifications that mean something.**
  - Fleet thresholds, a rotation with its reason, an account leaving or re-entering rotation.
  - A re-login needed, the probe failing, a hold, overage billing.
  - Pause them for an hour.
- **Seven days of history.**
  - A sample a minute while the app runs: fleet sparklines and a state strip per account, kept locally.
- **Speaks your language.**
  - English, 한국어, 日本語, 简体中文, Español, Deutsch, Français.
  - Follows the Mac's language list and is switchable in place.

## Gallery

#### Accounts
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="Accounts pane">

#### Rotation
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="Rotation pane: switch threshold, per-bucket thresholds, session distribution, hold">

#### Proxy
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="Proxy pane: listener state and the line Claude Code needs">

#### General
<img src="docs/assets/menubar/settings-general.png" width="780" alt="General pane: menu bar style, language, refresh, shortcuts, notifications">

## The menu bar item

| Title | Meaning |
| --- | --- |
| `1h12m 42%` | The fleet's 5-hour window resets in 1h12m and is 42% used. The bars below are 5-hour (top) and weekly (bottom). |
| `ted 1h12m 42%` | Pinned to the current account (Settings → General): its three-letter tag leads. |
| `1h12m 42% · 3d12h 61%` | The *Bars + 5h · 7d* style: the weekly window too. |
| `1h12m 93%!` | Critical: at the switch threshold, or nothing can serve. |
| `→ par` | A rotation just happened; shown for six seconds. |
| `—` | The listener is down (usually the port is taken). |
| `0%` | No accounts yet. |

## Shortcuts

| Keys | Where | Does |
| --- | --- | --- |
| `⌃⌥⌘N` | anywhere | Switch to the next account that can serve |
| `⌃⌥⌘T` | anywhere | Show or hide the popover |
| `⌘R` `⌘T` `⌘,` `⌘Q` | popover | Refresh · Open Terminal with Claude Code · Settings · Quit |
| right-click the item | menu bar | Switch, refresh, reload config, pause notifications |

## How it works

- The app runs a proxy on `127.0.0.1` (SwiftNIO) and Claude Code reaches it through `HTTPS_PROXY`.
- It terminates `CONNECT api.anthropic.com:443` itself and forwards each request upstream with the chosen account's `Authorization` in place of the client's; every other host is tunnelled untouched.
- Every other header passes through, and `metadata.user_id` names the account whose token went out.
- Replies stream back as they arrive.
- Accounts are chosen by priority, then by the weekly window that resets soonest.
- Any account that is disabled, throttled, capped, in error, or at its threshold for the request's model family is skipped.
- The `anthropic-ratelimit-*` headers on every reply keep each account's windows current.
- A background probe of the usage endpoint fills in the idle ones.
- Tokens refresh five minutes before they expire.
- Config lives in `~/Library/Application Support/Claude AutoSwitch/config.json`, written atomically with `0600` permissions.
- Tokens are in that file and nowhere else.

The reference for the config file, the health endpoint and the rotation rules is in [docs/reference.md](docs/reference.md).

## Privacy

Only two hosts are ever contacted: the Claude API (your requests, the usage probe, token refresh) and, during sign-in, claude.ai / platform.claude.com.<br>
Traffic to any other host passes through the proxy without being decrypted.<br>
No telemetry, no update checks.<br>
Diagnostics export replaces every secret before writing.

## A note on terms of service

Rotating requests across several personal subscriptions may sit outside what Anthropic's consumer terms intend.<br>
This project shows you your own accounts' quota and lets you decide how to use them.<br>
Read the terms that apply to your plan.

## Documentation

- [docs/troubleshooting.md](docs/troubleshooting.md): Gatekeeper, a taken port, re-login, tokens shared with other tools.
- [docs/reference.md](docs/reference.md): the config file, the health endpoint, the rotation rules.
- [CHANGELOG.md](CHANGELOG.md): what changed in each release.

## Development

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore`: the model (accounts, windows, blockers), the rules (scheduling, pace, fleet totals), localization and the config document.
- `AutoSwitchEngine`: the proxy, with accounts, OAuth, quota, rotation and the listener.
- `ClaudeAutoSwitch`: the app.
- Strings live in `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings`, keyed by the English text.
- A test fails if a string in the sources has no row there.
- `AUTOSWITCH_DEBUG_WINDOW=<section>` and `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` open a settings pane and the popover for screenshots.
- `README.md` and the six translations next to it change together; `scripts/check-readmes.sh` fails when their structure drifts.

## License

MIT.
