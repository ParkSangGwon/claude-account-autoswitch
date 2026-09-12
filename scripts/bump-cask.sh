#!/bin/sh
# Points a Homebrew cask at a release: bump-cask.sh <version> <sha256> <cask.rb>
set -eu
VERSION=$1 SHA=$2 CASK=$3
perl -pi -e 's/^(\s*version ")[^"]*"/${1}'"$VERSION"'"/; s/^(\s*sha256 ")[^"]*"/${1}'"$SHA"'"/' "$CASK"
grep -q "version \"$VERSION\"" "$CASK"
grep -q "sha256 \"$SHA\"" "$CASK"
