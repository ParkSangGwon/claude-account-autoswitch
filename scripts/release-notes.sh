#!/bin/sh
# Prints the CHANGELOG section for a version: release-notes.sh 0.1.1
# Fails when the section is missing, so a release without notes cannot be cut.
set -eu
VERSION=$1
awk -v v="$VERSION" '
  /^## \[/ { if (found) exit; found = ($0 ~ "^## \\[" v "\\]") ; next }
  found { print }
' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "${TMPDIR:-/tmp}/release-notes.$$"
if [ ! -s "${TMPDIR:-/tmp}/release-notes.$$" ]; then
  echo "CHANGELOG.md has no section for $VERSION" >&2
  rm -f "${TMPDIR:-/tmp}/release-notes.$$"
  exit 1
fi
cat "${TMPDIR:-/tmp}/release-notes.$$"
rm -f "${TMPDIR:-/tmp}/release-notes.$$"
