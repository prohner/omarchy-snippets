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

# --- descriptor validation --------------------------------------------------
# Nothing is checked by name before it is opened any more: every open is
# no-follow and nonblocking, and the descriptor is what gets validated. So a
# file planted before the call reaches exactly the code a file swapped in
# during it would, and these cases are deterministic rather than races.
watch_once() { first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets; }

printf 'SECRET' > "$SANDBOX/other-file"
ln -s "$SANDBOX/other-file" "$config/snippets.json"
ok "$(watch_once)" 'null' "a symlink to another of the user's files is refused, not followed"
rm -f "$config/snippets.json"

ln "$SANDBOX/other-file" "$config/snippets.json"
ok "$(watch_once)" 'null' "a hard link to another of the user's files is refused too"
rm -f "$config/snippets.json"

printf 'h\xc3\xa9llo \xff' > "$config/snippets.json"
ok "$(watch_once)" '"héllo �"' "UTF-8 survives and a malformed byte becomes U+FFFD, as jq -Rs did"
rm -f "$config/snippets.json"

# And the race itself, which planting cannot reach: a swapper keeps replacing
# the file with a symlink to a secret, and with a fifo, while it is read. A
# helper that checks the name and then opens the name loses this race often —
# the version before this test leaked the secret on 115 reads out of 300 — and
# a fifo won at the wrong moment blocks it until the timeout.
printf 'real' > "$config/snippets.json"
touch "$config/.race"
python3 - "$config" "$SANDBOX/other-file" <<'PY' &
import os, sys, time
c, secret = sys.argv[1], sys.argv[2]
tmp, tgt = c + "/.swap", c + "/snippets.json"
end = time.time() + 120
while time.time() < end and os.path.exists(c + "/.race"):
    for make in (lambda: open(tmp, "w").write("real"), lambda: os.symlink(secret, tmp), lambda: os.mkfifo(tmp)):
        try:
            if os.path.lexists(tmp): os.unlink(tmp)
            make(); os.rename(tmp, tgt)
        except OSError: pass
PY
swapper=$!
leaked=0 blocked=0
for ((i = 0; i < 20; i++)); do
  line=$(watch_once)
  [[ $line == *SECRET* ]] && leaked=$((leaked + 1))
  [[ -z $line ]] && blocked=$((blocked + 1))
done
rm -f "$config/.race"; wait "$swapper" 2>/dev/null
rm -f "$config/snippets.json" "$config/.swap"
ok "$leaked" 0 "a file swapped for a symlink mid-read is never followed"
ok "$blocked" 0 "a file swapped for a fifo mid-read never blocks the watcher"

# The retained directory itself: a fifo swapped in for it must fail the open
# at once rather than block the watcher.
mv "$config" "$config.real"
mkfifo "$config"
timeout 5 env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets >/dev/null 2>&1
ok "$?" 1 "a fifo in place of the directory is refused at once, not blocked on"
rm -f "$config"
mv "$config.real" "$config"

# A directory planted where the file goes must not receive the write.
mkdir "$config/snippets.json"
printf 'PAYLOAD' | run write-file snippets 2>/dev/null
ok "$?" 1 "a directory at the destination makes the write fail"
ok "$(ls -A "$config/snippets.json" | wc -l)" 0 "and nothing is moved into it"
ok "$(ls -A "$config" | grep -c '^\.snippets\.json\.' || true)" 0 "and no temporary is left behind"
rmdir "$config/snippets.json"

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

ok "$(ls -A "$SANDBOX/run/omarchy-snippets" | grep -c 'capture\.' || true)" 0 \
  "no capture temporaries are left behind"

# An image under the cap has to reach capture.sh intact through the unlinked
# temporary: a short PNG signature comes back as an image entry.
png=$(printf '\x89PNG\r\n\x1a\n0123456789' | run capture-stream image/png)
ok "$(printf '%s' "$png" | python3 -c 'import json,sys; print(json.load(sys.stdin)["type"])')" image \
  "an image under the cap reaches capture.sh"
ok "$(find "$SANDBOX/home/.local/state/omarchy/clipboard-images" -type f -size 18c | wc -l)" 1 \
  "byte for byte"

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

# The watcher record, planted with the things a check-then-open cannot survive.
record=$SANDBOX/run/omarchy-snippets/watchers
rm -f "$record"
mkfifo "$record"
timeout 5 env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" reap
ok "$?" 0 "a fifo in place of the watcher record does not block startup"
ok "$(stat -c %F "$record")" "regular empty file" "and is replaced by an empty record"

printf 'KEEP ME\n' > "$SANDBOX/other-file"
rm -f "$record"
ln -s "$SANDBOX/other-file" "$record"
run reap
ok "$(cat "$SANDBOX/other-file")" "KEEP ME" "resetting the record never truncates through a symlink"
ok "$(stat -c %F "$record")" "regular empty file" "the symlink is replaced instead"

rm -f "$record"
ln -s "$SANDBOX/other-file" "$record"
first_line env -i HOME="$SANDBOX/home" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$SANDBOX/run" \
  OMARCHY_PATH=/usr/share/omarchy "$HELPER" watch-file snippets >/dev/null
ok "$(cat "$SANDBOX/other-file")" "KEEP ME" "recording a watcher never appends through a symlink"
rm -f "$record"

if (( failures == 0 )); then
  printf '\nAll tests passed.\n'
else
  printf '\n%d test(s) failed.\n' "$failures"
fi
exit $(( failures == 0 ? 0 : 1 ))
