# Troubleshooting

Each section starts with what you see, then what to do.

## "Apple could not verify Claude AutoSwitch"

The app is ad-hoc signed, not notarized, so macOS asks on first launch.

- Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
- Or clear the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"`, then open the app again.

## The menu bar shows `—`

The listener is not running, almost always because the port is taken.

- See who holds it: `lsof -nP -iTCP:10912 -sTCP:LISTEN`.
- Quit that program, or change the port under **Settings → Proxy**; the listener moves at once.
- After a port change, update the `ANTHROPIC_BASE_URL` line in your shell profile.

## Claude Code still uses one account

Claude Code is not talking to the proxy.

- In the terminal you use, run `echo $ANTHROPIC_BASE_URL`; it must print `http://127.0.0.1:10912` (or your port).
- The line belongs in the shell profile that terminal reads (`~/.zshrc` for zsh); open a new terminal after adding it.
- A `claude` alias or wrapper that sets its own base URL wins over the profile; check `type claude`.
- **Settings → Proxy → Open Terminal with Claude Code** opens a terminal with the variable already set.

## An account says "needs a new sign-in"

The refresh token was rejected, so the app cannot get new access tokens for it.

- Remove the account and add it again (**Settings → Accounts → Add account…**).
- The usual cause: the same account was signed in elsewhere (Claude Code's own `/login`, another tool) and that sign-in invalidated the refresh token this app held. Keep one tool in charge of each account's login.

## The bars stay empty

- Windows fill in from the first reply an account serves and from the background probe. Check **Settings → Quota**: the probe interval must not be 0, and each account's last probe should read `ok`.
- A probe error of `401` means the token is stale; the app refreshes it on the next attempt. A persistent error means the account needs a new sign-in.
- API-key accounts have token and request allowances instead of windows; they show under **Tok** and **Req**.

## Rotation never switches

- Rotation happens when a window reaches the switch threshold (**Settings → Rotation**, 98% by default). Below it, the current account keeps serving.
- A better-ranked account preempts the current one only when its rank is strictly lower.
- The popover's **Next request** line says where the next request will land and why.

## No notifications

- **System Settings → Notifications → Claude AutoSwitch** must allow alerts.
- Notifications can be paused for an hour from the right-click menu; the menu shows **Resume Notifications** while paused.
- Each kind of notification has its own switch under **Settings → General → Notifications**.

## Where is my data, and how do I uninstall

| What | Where |
| --- | --- |
| Config with tokens | `~/Library/Application Support/Claude AutoSwitch/config.json` |
| History | `~/Library/Application Support/Claude AutoSwitch/history.json` |
| Preferences | `defaults` domain `com.parksanggwon.claudeautoswitch` |

Homebrew: `brew uninstall --cask claude-autoswitch` removes the app; add `--zap` to remove the folder and the preferences too.
Manual install: quit the app, delete `/Applications/Claude AutoSwitch.app`, then the folder and the preferences above.

## Reporting a bug

**Settings → Advanced → Export diagnostics…** writes the engine's state, the config with every secret replaced and the app's state to a folder in Downloads.
Attach that folder to the issue; it carries no tokens.
