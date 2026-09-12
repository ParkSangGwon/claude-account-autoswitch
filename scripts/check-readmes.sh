#!/bin/sh
# Fails when a translated README drifts structurally from README.md:
# heading, code-fence, image, table-row and bullet counts must match.
set -eu
cd "$(dirname "$0")/.."
count() {
  printf '%s/%s/%s/%s/%s' "$(grep -c '^#' "$1" || true)" "$(grep -c '^```' "$1" || true)" \
    "$(grep -c '<img' "$1" || true)" "$(grep -c '^|' "$1" || true)" "$(grep -c '^ *- ' "$1" || true)"
}
want=$(count README.md); rc=0
for f in README.*.md; do
  got=$(count "$f")
  if [ "$got" != "$want" ]; then
    echo "$f: headings/fences/images/table-rows/bullets $got, README.md has $want"; rc=1
  fi
done
[ $rc -eq 0 ] && echo "README translations in sync with README.md ($want): $(ls README.*.md | tr '\n' ' ')"
exit $rc
