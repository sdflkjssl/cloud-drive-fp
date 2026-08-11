#!/usr/bin/env bash
# End-to-end check of the reference server's identity contract.
#
# The extension's correctness rests on three properties. This asserts all three,
# including the negative case — a check that only ever passes is not evidence.
#
#   1. An id survives rename and reparent.
#   2. An id survives an overwrite (save-in-place).
#   3. An id does NOT survive delete-and-recreate. Different item, different id.
#
#   ./verify.sh [port]
set -u

PORT="${1:-18080}"
B="http://127.0.0.1:${PORT}/dav"
A=(-u alice:secret -s)
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok ()   { echo "  PASS  $1"; pass=$((pass+1)); }
bad ()  { echo "  FAIL  $1"; fail=$((fail+1)); }
check () { [ "$2" = "$3" ] && ok "$1" || bad "$1 (got '$2', want '$3')"; }
differs () { [ "$2" != "$3" ] && ok "$1" || bad "$1 (both '$2')"; }

getid () {
  curl "${A[@]}" -X PROPFIND -H "Depth: 0" "$1" \
    | grep -o '<D:fileid>[^<]*' | head -1 | cut -d'>' -f2
}
code () { curl "${A[@]}" -o /dev/null -w '%{http_code}' "$@"; }

if ! curl "${A[@]}" -o /dev/null -X PROPFIND "$B/" 2>/dev/null; then
  echo "No server on ${B} — start it with: node plinth-server.js --port ${PORT}"
  exit 1
fi

echo "plinth reference server contract — ${B}"

echo "auth"
check "unauthenticated request is refused" \
      "$(curl -s -o /dev/null -w '%{http_code}' -X PROPFIND "$B/")" "401"

echo "identity survives rename and reparent"
printf 'one\n' > "$TMP/a"
code -X PUT --data-binary "@$TMP/a" "$B/doc.txt" >/dev/null
ID="$(getid "$B/doc.txt")"
code -X MOVE -H "Destination: $B/renamed.txt" "$B/.id/$ID" >/dev/null
check "rename keeps the id"   "$(getid "$B/renamed.txt")" "$ID"
code -X MKCOL "$B/folder" >/dev/null
FOLDER="$(getid "$B/folder")"
code -X MOVE -H "Destination: $B/.id/$FOLDER/moved.txt" "$B/.id/$ID" >/dev/null
check "reparent keeps the id" "$(getid "$B/.id/$ID")" "$ID"

echo "identity survives save-in-place"
printf 'two, which is longer\n' > "$TMP/b"
check "overwrite returns 204" "$(code -X PUT --data-binary "@$TMP/b" "$B/.id/$ID")" "204"
check "overwrite keeps the id" "$(getid "$B/.id/$ID")" "$ID"
check "re-read by original id" "$(code -X PROPFIND -H 'Depth: 0' "$B/.id/$ID")" "207"
printf 'three\n' > "$TMP/c"
code -X PUT --data-binary "@$TMP/c" "$B/.id/$ID" >/dev/null
check "shorter overwrite truncates" "$(curl "${A[@]}" "$B/.id/$ID")" "three"

echo "identity does NOT survive delete and recreate"
printf 'x\n' > "$TMP/d"
code -X PUT --data-binary "@$TMP/d" "$B/probe.txt" >/dev/null
FIRST="$(getid "$B/probe.txt")"
code -X DELETE "$B/.id/$FIRST" >/dev/null
check "stale id 404s" "$(code -X PROPFIND -H 'Depth: 0' "$B/.id/$FIRST")" "404"
code -X PUT --data-binary "@$TMP/d" "$B/probe.txt" >/dev/null
differs "recreated file gets a new id" "$FIRST" "$(getid "$B/probe.txt")"

echo "parent linkage"
check "root child reports an empty parent" \
      "$(curl "${A[@]}" -X PROPFIND -H 'Depth: 0' "$B/folder" | grep -c '<D:parentid></D:parentid>')" "1"
check "nested child reports its folder" \
      "$(curl "${A[@]}" -X PROPFIND -H 'Depth: 0' "$B/.id/$ID" | grep -o '<D:parentid>[^<]*' | cut -d'>' -f2)" "$FOLDER"

echo
echo "${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
