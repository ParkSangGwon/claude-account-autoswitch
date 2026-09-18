# Troubleshooting

Each section starts with what you see, then what to do.

## "Apple could not verify Claude AutoSwitch"

The app is ad-hoc signed, not notarized, so macOS asks on first launch.

- Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
- Or clear the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"`, then open the app again.

## The menu bar shows `—`

The listener is not running, almost always because the port is taken.

- **Settings → Proxy** names the program holding the port and offers **Use a free port**, which moves the listener and writes the new port down.
- Or quit that program and press **Try again**. To find it yourself: `lsof -nP -iTCP:10912 -sTCP:LISTEN`.
- After a port change nothing in the profile needs editing: the setup file is rewritten with the new port. Open a new terminal, or source it again.

## Claude Code still uses one account

Claude Code is not talking to the proxy.

- The popover says so on its own once the proxy has been up a while with nothing arriving.
- In the terminal you use, run `echo $HTTPS_PROXY`; it must print `http://127.0.0.1:10912` (or your port).
- `echo $ANTHROPIC_BASE_URL` must now print nothing. If it prints anything, see the next section.
- The source line belongs in the shell profile that terminal reads (`~/.zshrc` for zsh); open a new terminal after adding it.
- A `claude` alias or wrapper that sets its own environment wins over the profile; check `type claude`.
- Something that runs the binary directly never reads the profile at all. Point it at `claude-autoswitch` beside the setup file, which sources the variables and then execs `claude`.
- **Settings → Proxy → Open Terminal with Claude Code** opens a terminal with everything already set.

## Remote Control is off, or managed settings are not fetched

Something in that shell still sets `ANTHROPIC_BASE_URL`.

Claude Code turns Remote Control, server-managed settings and organization policy off whenever that variable points anywhere other than `api.anthropic.com`, so a profile line left over from an earlier version keeps them off even though rotation still works. `claude doctor` says so in as many words.

- Find it without changing anything: `grep -rn ANTHROPIC_BASE_URL ~/.zshrc ~/.zprofile ~/.bash_profile ~/.profile`.
- Remove that export, make sure the setup line from **Settings → Proxy** is there instead, and open a new terminal.
- The app notices this by itself: once a request arrives in the old form, the popover and the Proxy pane say which shell is still on it.
- It can also come from a `claude` wrapper or from `~/.claude/settings.json`; `claude doctor` reports the value it ended up with.

## Claude Code cannot reach the API, or reports a certificate error

`NODE_EXTRA_CA_CERTS` is missing, or points at a certificate that no longer exists.

- Check it in the terminal you use: the path it prints must be the one **Settings → Proxy → Certificate** shows.
- Reissuing the certificate replaces that file. Terminals opened before the reissue keep the old path until they source the setup file again.
- If you keep the setup in `~/.claude/settings.json` instead of a shell profile, its `env` block needs the same update — the app only writes its own file.

## Setting it up without touching a shell profile

The app writes the variables to its own file and never edits yours, but nothing stops you putting them somewhere else.

- **Settings → Proxy → Show all variables** lists them; **Copy all variables** gives the whole block.
- Claude Code also reads an `env` block in `~/.claude/settings.json`, which suits fish, nushell or a profile you would rather leave alone. The app will not write there.
- Remember `ANTHROPIC_BASE_URL` has to be unset wherever you put the rest.

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
| Shell setup file | `~/Library/Application Support/Claude AutoSwitch/env.sh` and `claude-autoswitch` |
| Local certificate | `ca.pem`, `leaf.pem` and `leaf.key` in the same folder. Nothing was added to the system keychain, so deleting the folder is all it takes for Claude Code to stop trusting it |
| Preferences | `defaults` domain `com.parksanggwon.claudeautoswitch` |

Homebrew: `brew uninstall --cask claude-autoswitch` removes the app; add `--zap` to remove the folder and the preferences too.
Manual install: quit the app, delete `/Applications/Claude AutoSwitch.app`, then the folder and the preferences above.

## Reporting a bug

**Settings → Advanced → Export diagnostics…** writes the engine's state, the config with every secret replaced and the app's state to a folder in Downloads.
Attach that folder to the issue; it carries no tokens.
