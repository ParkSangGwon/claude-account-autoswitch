# Claude AutoSwitch — notes for Claude Code sessions in this repository

## Docs and screenshots move with the app

- `README.md` and its six translations (`README.ko.md`, `README.ja.md`, `README.zh-CN.md`, `README.de.md`, `README.es.md`, `README.fr.md`) describe the current UI and features. Change all seven in the same commit. `scripts/check-readmes.sh` runs in CI and fails when a translation's headings, code fences, images, table rows or bullets drift from `README.md`.
- README style: the pain points come first ("The problem"), then "The fix". Inside a paragraph every sentence is its own line ending in `<br>`; a blank line only where the topic changes. Multi-sentence bullets become a bold lead plus nested bullets. UI terms in a translation come from that language's `Localizable.strings`.
- The screenshots in `docs/assets/menubar/` (`menubar-item`, `popover-dark`, `settings-accounts`, `settings-rotation`, `settings-proxy`, `settings-general`) must show the app as it is. Whenever the menu bar item, the popover or a settings pane changes, rebuild and re-shoot: `make app && scripts/screenshots.sh`. The script uses example accounts and demo quota, parks the app's preferences and restores them; never shoot with real accounts.
- `docs/reference.md` documents the config document, the health endpoint (`/_autoswitch/health`) and the rotation rules. Change it together with the engine.
- Every user-facing string needs a row in all six `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings` tables; `testEverySourceStringHasATranslation` fails otherwise.

## Releasing

- `git tag vX.Y.Z && git push origin vX.Y.Z` does everything: tests, `make app`, launch smoke test, zip + sha256, GitHub release, and the Homebrew cask bump in `ParkSangGwon/homebrew-tap` (secret `TAP_GITHUB_TOKEN`, a fine-grained PAT with Contents: write on the tap).
- `VERSION` feeds local `make app`; in CI the tag wins. Keep them equal after a release.
- The bundle is ad-hoc signed; the README and the cask caveat carry the Gatekeeper note.

## Testing

- Engine tests run against loopback stand-ins for the Claude API. Never read or write real credentials in tests, and never put a token in a fixture, a log or a commit.
- A real-account check needs a scratch config (`CLAUDE_AUTOSWITCH_CONFIG=<0600 file>`) that is deleted afterwards. Refreshing a token here can invalidate the same refresh token held by another tool.
- The default port is 10912. `scripts/smoke.sh` launches the bundle and expects `/_autoswitch/health` on that port.
- The engine is the app's own design: typed `EngineState` in-process, no JSON control plane, config schema v1 (`listen`, `api`, `rotation`, `quota`, `accounts`). Do not reintroduce wire formats, key names or wording from other proxies.
