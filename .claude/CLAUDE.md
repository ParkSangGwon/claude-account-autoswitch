# Claude AutoSwitch — notes for Claude Code sessions in this repository

## Docs and screenshots move with the app

- `README.md` and its six translations (`README.ko.md`, `README.ja.md`, `README.zh-CN.md`, `README.de.md`, `README.es.md`, `README.fr.md`) describe the current UI and features. Change all seven in the same commit. `scripts/check-readmes.sh` runs in CI and fails when a translation's headings, code fences, images, table rows or bullets drift from `README.md`.
- README style: the pain points come first ("The problem"), then "The fix". Inside a paragraph every sentence is its own line ending in `<br>`; a blank line only where the topic changes. Multi-sentence bullets become a bold lead plus nested bullets. UI terms in a translation come from that language's `Localizable.strings`.
- The screenshots in `docs/assets/menubar/` (`menubar-item`, `popover-dark`, `settings-accounts`, `settings-rotation`, `settings-proxy`, `settings-general`) show the released app, not the working tree. **Do not re-shoot them when you change the menu bar item, the popover or a settings pane** — a picture of an unreleased build in the README claims a version nobody can download yet. `scripts/release.sh` re-shoots all six from the build the tag publishes, so they move with the version and never between. Leave `docs/assets/menubar/` alone in a feature commit; README wording still changes with the feature.
- `scripts/screenshots.sh` is what the release script calls. Run it by hand only to check a UI change on screen, and throw the result away: it uses example accounts and demo quota, parks the app's preferences and restores them, never real accounts.
- `docs/reference.md` documents the config document, the health endpoint (`/_autoswitch/health`) and the rotation rules. Change it together with the engine.
- Every user-facing string needs a row in all six `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings` tables; `testEverySourceStringHasATranslation` fails otherwise.

## Releasing

- `scripts/release.sh X.Y.Z` (or `make release V=X.Y.Z`) is the entry point, from a clean `main`. It refuses a version the changelog has no section for, writes `VERSION`, builds the bundle, re-shoots the six screenshots from that build, commits `chore(release): X.Y.Z`, and pushes `main` and the tag. Write the `CHANGELOG.md` section first; everything else is the script's.
- The tag is what the CI does the rest with: tests, `make app`, launch smoke test, zip + sha256, GitHub release, and the Homebrew cask bump in `ParkSangGwon/homebrew-tap` (secret `TAP_GITHUB_TOKEN`, a fine-grained PAT with Contents: write on the tap).
- The screenshots must be in the tagged commit, which is why they are shot locally rather than in the workflow: `screencapture -l <window>` and System Events need a logged-in GUI session, and a picture pushed after the tag would not be the one the release links to.
- `VERSION` feeds local `make app`; in CI the tag wins. The release script keeps them equal — do not bump `VERSION` by hand ahead of it.
- The bundle is ad-hoc signed; the README and the cask caveat carry the Gatekeeper note.

## Testing

- Engine tests run against loopback stand-ins for the Claude API. Never read or write real credentials in tests, and never put a token in a fixture, a log or a commit.
- A real-account check needs a scratch config (`CLAUDE_AUTOSWITCH_CONFIG=<0600 file>`) that is deleted afterwards. Refreshing a token here can invalidate the same refresh token held by another tool.
- The default port is 10912. `scripts/smoke.sh` launches the bundle and expects `/_autoswitch/health` on that port.
- The engine is the app's own design: typed `EngineState` in-process, no JSON control plane, config schema v1 (`listen`, `api`, `rotation`, `quota`, `accounts`). Do not reintroduce wire formats, key names or wording from other proxies.
