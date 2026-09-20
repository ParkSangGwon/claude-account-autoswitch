# Documentation

| Page | What it answers |
| --- | --- |
| [README](../README.md) | What the app is, how to install it, the three-step setup, features and shortcuts. Also in [한국어](../README.ko.md), [日本語](../README.ja.md), [简体中文](../README.zh-CN.md), [Deutsch](../README.de.md), [Español](../README.es.md), [Français](../README.fr.md). |
| [troubleshooting.md](troubleshooting.md) | Something is not working: Gatekeeper, a taken port, Claude Code not using the proxy, re-login, empty bars, notifications, uninstalling. |
| [reference.md](reference.md) | The config file, the windows, how an account is chosen, what each upstream reply does, the listener, sign-in, files and environment. |
| [CHANGELOG](../CHANGELOG.md) | What changed in each release. |

## How these pages are kept

- `README.md` and its six translations change together, in the same commit. `scripts/check-readmes.sh` runs in CI and fails when a translation's headings, code fences, images, table rows or bullets drift from the English.
- The pages under `docs/` are English only.
- Screenshots under `assets/menubar/` come from `scripts/screenshots.sh` (example accounts, demo quota, a second instance beside any installed app rather than in place of it). They are re-shot once per version, by `scripts/release.sh`, from the build the tag publishes — so the pictures always show the release you can download, never a change still waiting for one.
- Every release has a section in `CHANGELOG.md`; the release workflow uses it as the release notes and refuses a tag without one.
- Wording: one sentence per line; inside a paragraph the lines end in `<br>`; UI terms exactly as the app shows them.
