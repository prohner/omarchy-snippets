#!/usr/bin/bash
#
# Tests for bin/omarchy-snippets-helper.
#
#   test/helper.test.sh
#
# Everything runs against a sandbox HOME, so the real snippet library and the
# real clipboard history are never touched. The clipboard itself is not touched
# either: the capture path is driven by feeding the helper on stdin exactly the
# way wl-paste would.
#
# These cover the security properties rather than the features, because the
# features are already covered in plain node by snippets.test.js and these are
# the parts that cannot be. What each case is really asserting is in its name.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

HELPER=$PWD/bin/omarchy-snippets-helper
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

failures=0
run() {
  env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin \
    XDG_RUNTIME_DIR="$SANDBOX/run" OMARCHY_PATH=/usr/share/omarchy \
    "$HELPER" "$@"
}
ok() {
  if [[ $1 == "$2" ]]; then
    printf 'PASS  %s\n' "$3"
  else
    failures=$(( failures + 1 ))
    printf 'FAIL  %s\n        expected %q\n        actual   %q\n' "$3" "$2" "$1"
  fi
}
config=$SANDBOX/home/.config/omarchy
mkdir -p "$SANDBOX/home" "$SANDBOX/run"

# --- the subcommand surface is closed ---------------------------------------
run >/dev/null 2>&1
ok "$?" 1 "an unknown subcommand is refused"
run run rm -rf / >/dev/null 2>&1
ok "$?" 1 "only the named Omarchy helpers can be run, never an arbitrary program"

# --- writes -----------------------------------------------------------------
printf '{"snippets":[{"trigger":"t","body":"b"}]}\n' | run write-file snippets
ok "$?" 0 "a write into a directory that does not exist yet creates it"
ok "$(stat -c %a "$config")" 700 "the directory it creates is private"
ok "$(stat -c %a "$config/snippets.json")" 600 "the file it writes is private"

head -c 12000000 /dev/zero | tr '\0' 'z' | run write-file snippets
ok "$(stat -c %s "$config/snippets.json")" 8388608 "a write is capped, not refused, at the file size limit"

# A symlink planted where the file goes must be replaced, not written through:
# rename(2) does not follow one, which is why the write is a rename.
printf 'ORIGINAL' > "$SANDBOX/outside"
rm -f "$config/snippets.json"
ln -s "$SANDBOX/outside" "$config/snippets.json"
printf 'PAYLOAD' | run write-file snippets
ok "$(cat "$SANDBOX/outside")" "ORIGINAL" "a symlink at the destination does not redirect the write"
ok "$(cat "$config/snippets.json")" "PAYLOAD" "the symlink is replaced by the real file"

# --- directory boundary -----------------------------------------------------
rm -rf "$config"
mkdir -p "$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere" "$config"
printf 'x' | run write-file snippets 2>/dev/null
ok "$?" 1 "a symlinked config directory is refused"
rm -f "$config"

mkdir -m 775 "$config"
printf 'x' | run write-file snippets 2>/dev/null
ok "$?" 1 "a config directory others can write to is refused"
chmod 700 "$config"

# --- reads ------------------------------------------------------------------
# One line per emission: the contents as a JSON string, "" when absent, null
# when present but not a plain file this user owns.
first_line() { timeout 6 "$@" 2>/dev/null | head -1; }

rm -f "$config/snippets.json"
ok "$(first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets)" '""' \
  "an absent file reads as empty"

printf 'hello\n' > "$config/snippets.json"
ok "$(first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets)" '"hello\n"' \
  "a plain file reads back as one JSON-encoded line"

# A fifo is the case that matters most here: open(2) on one blocks until a
# writer arrives, so a watcher that opened it would stop reporting forever.
rm -f "$config/snippets.json"
mkfifo "$config/snippets.json"
ok "$(first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets)" 'null' \
  "a fifo in place of the file is refused rather than opened"
rm -f "$config/snippets.json"

ln -s /nonexistent "$config/snippets.json"
ok "$(first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets)" 'null' \
  "a dangling symlink is reported as unreadable, not as absent"
rm -f "$config/snippets.json"

# --- clipboard capture caps -------------------------------------------------
# Driven the way wl-paste drives it: payload on stdin, mime as the argument.
capped=$(head -c 200000 /dev/zero | tr '\0' 'T' | run capture-stream text)
ok "$(printf '%s' "$capped" | wc -l)" 0 "a capture is exactly one line, with no newline inside it"
ok "$(printf '%s' "$capped" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["text"]))')" \
  131072 "clipboard text past the cap is truncated to it"

short=$(printf 'hello snippets' | run capture-stream text)
ok "$(printf '%s' "$short" | python3 -c 'import json,sys; print(json.load(sys.stdin)["text"])')" \
  "hello snippets" "clipboard text under the cap survives whole"

oversized_image=$(head -c 70000000 /dev/zero | run capture-stream image/png)
ok "$oversized_image" "" "an image past the cap is dropped, because half a PNG is a corrupt file"

ok "$(ls -A "$SANDBOX/run/omarchy-snippets" | grep -c '^capture\.' || true)" 0 \
  "no capture temporaries are left behind"

# --- watcher identity -------------------------------------------------------
# The property being tested is the one the old `pkill -f` could not have: a
# process is killed because it is the one that was recorded, not because its
# command line resembles a watcher's.
starttime() { local l; l=$(< "/proc/$1/stat"); l=${l#*') '}; set -f; set -- $l; set +f; printf '%s' "${20}"; }

bash -c "set -m; exec -a 'wl-paste --type text --watch $HELPER capture-stream text' sleep 30 & echo \$! > '$SANDBOX/ours'; sleep 30" &
bash -c "set -m; exec -a 'wl-paste --type text --watch /usr/share/omarchy/shell/plugins/clipboard/capture.sh text' sleep 30 & echo \$! > '$SANDBOX/lookalike'; sleep 30" &
sleep 1
ours=$(cat "$SANDBOX/ours"); lookalike=$(cat "$SANDBOX/lookalike")
mkdir -p "$SANDBOX/run/omarchy-snippets"; chmod 700 "$SANDBOX/run/omarchy-snippets"
{
  printf 'group %s %s\n' "$ours" "$(starttime "$ours")"
  printf 'group %s %s\n' "$lookalike" "$(starttime "$lookalike")"
} > "$SANDBOX/run/omarchy-snippets/watchers"

run reap
sleep 0.5
alive() { [[ -r /proc/$1/stat ]] || { printf 'gone'; return; }; local l; l=$(< "/proc/$1/stat"); l=${l#*') '}; [[ ${l%% *} == Z ]] && printf 'dead' || printf 'alive'; }
ok "$(alive "$ours")" "dead" "a recorded watcher is reaped"
ok "$(alive "$lookalike")" "alive" "a process that merely matches the old pkill pattern is left alone"
ok "$(stat -c %s "$SANDBOX/run/omarchy-snippets/watchers")" 0 "the record is cleared after reaping"
kill -TERM "$ours" "$lookalike" 2>/dev/null
wait 2>/dev/null

if (( failures == 0 )); then
  printf '\nAll tests passed.\n'
else
  printf '\n%d test(s) failed.\n' "$failures"
fi
exit $(( failures == 0 ? 0 : 1 ))
