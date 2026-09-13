#!/bin/bash
# Cuts a release: bumps VERSION, re-shoots the README screenshots from the very build the tag
# publishes, commits both, then pushes the tag the release workflow builds and ships to the cask.
#
#   scripts/release.sh 0.2.0
# This is the only place the screenshots move, so the pictures in the README always show the
# version you can download — never an unreleased build.
set -eu
cd "$(dirname "$0")/.."
V=${1:-}
case "$V" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "usage: scripts/release.sh X.Y.Z" >&2; exit 1 ;;
esac

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[ "$BRANCH" = main ] || { echo "release from main, not $BRANCH" >&2; exit 1; }
if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty; commit or stash first" >&2; git status --short >&2; exit 1
fi
if git rev-parse -q --verify "refs/tags/v$V" >/dev/null 2>&1; then
  echo "tag v$V already exists" >&2; exit 1
fi
scripts/release-notes.sh "$V" >/dev/null   # refuses a version the changelog has no section for
git pull --ff-only

echo "$V" > VERSION
make app
scripts/screenshots.sh

git add VERSION docs/assets/menubar
if git diff --cached --quiet; then
  echo "VERSION and the screenshots already match $V; tagging the current commit"
else
  git commit -m "chore(release): $V"
fi
git push origin main
git tag "v$V"
git push origin "v$V"
echo "pushed v$V; the release workflow now tests, publishes and bumps the Homebrew cask"
