#!/usr/bin/bash
#
# Runs test/picker.test.qml against the real Clipboard.qml.
#
#   test/picker.test.sh
#
# The picker cannot be loaded without starting its helper, and the helper is
# what pastes: it writes to your clipboard and types into the focused window.
# So this copies the plugin into a sandbox and swaps the helper for a stub that
# serves a fixed snippet library and writes every request it gets to a log.
# The QML side checks the rows; this side checks the log for what the picker
# asked to have pasted.
#
# Runs twice: once in the C locale, once in German, where the decimal mark is
# a comma.
#
# Unlike editor.test.sh this needs a Wayland session: Clipboard.qml is a layer
# shell PanelWindow, and quickshell has no offscreen backend for one. Nothing
# appears on screen, because the overlay is only visible once opened and this
# never opens it. The instance gets its own HOME and runtime directory, with
# only the compositor socket linked across (see README, "Trying a change
# without restarting your shell"). Skips rather than fails where there is no
# Wayland session, no quickshell, or no Omarchy shell.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SHELL_DIR=${OMARCHY_SHELL:-/usr/share/omarchy/shell}

if ! command -v quickshell >/dev/null 2>&1; then
  printf 'SKIP  picker tests: quickshell is not installed\n'
  exit 0
fi
if [[ ! -d $SHELL_DIR ]]; then
  printf 'SKIP  picker tests: no Omarchy shell at %s (set OMARCHY_SHELL)\n' "$SHELL_DIR"
  exit 0
fi

if [[ -z ${WAYLAND_DISPLAY:-} || -z ${XDG_RUNTIME_DIR:-} || ! -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]; then
  printf 'SKIP  picker tests: no Wayland session\n'
  exit 0
fi

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

root=$SANDBOX/root
plugin=$root/plugin
mkdir -p "$plugin/bin" "$SANDBOX/home" "$SANDBOX/run" || exit 1
ln -s "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" "$SANDBOX/run/$WAYLAND_DISPLAY" || exit 1

for dir in Commons Ui services; do
  [[ -d $SHELL_DIR/$dir ]] && ln -s "$SHELL_DIR/$dir" "$root/$dir"
done
# A copy, not a symlink: Clipboard.qml finds its helper next to itself.
cp ./*.qml ./*.js "$plugin/" || exit 1
cp test/picker.test.qml "$root/shell.qml" || exit 1

log=$SANDBOX/home/calls.log
cat > "$plugin/bin/omarchy-snippets-helper" <<'STUB'
#!/usr/bin/bash
# Stand-in for the real helper. HOME is the sandbox's, passed through by the
# picker's environment allowlist.
printf '%s\n' "$*" >> "$HOME/calls.log"
case ${1:-} in
  watch-file)
    if [[ ${2:-} == snippets ]]; then
      printf '%s\n' '"{\"snippets\":[{\"trigger\":\"1+1\",\"body\":\"one plus one\"}]}"'
    else
      printf '%s\n' '""'
    fi
    exec sleep 600 ;;
  watch-clipboard) exec sleep 600 ;;
  write-file) cat > /dev/null ;;
esac
exit 0
STUB
chmod +x "$plugin/bin/omarchy-snippets-helper"

failed=0
run() { # locale, expected decimal mark
  : > "$log"
  local out status
  out=$(env -u LC_NUMERIC HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/run" \
    LANG="$1" LC_ALL="$1" EXPECT_DECIMAL="$2" QT_QPA_PLATFORM=wayland \
    timeout 60 quickshell -n -p "$root" 2>&1)
  status=$?
  printf '%s\n' "--- $1"
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -E 'PASS |FAIL |All tests passed|failed\.' \
    | sed -e 's/^ *DEBUG *qml: *//' -e 's/^ *WARN *qml: *//' -e 's/^ *INFO *qml: *//'
  if [[ $status -ne 0 ]] || ! grep -q 'All tests passed' <<<"$out"; then
    printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'rror|Fatal' | head -20
    failed=1
  fi

  local answer=42
  check "Enter asked for the answer to be pasted" "run paste-text --shift-insert $answer"
  check "Shift+Enter asked for it to be copied" "run paste-text --copy-only $answer"
  check "Ctrl+C asked for the formula, as typed, to be copied" "run paste-text --copy-only =sqrt(16) * 3"
  refute "Ctrl+C during a search copied nothing" "--copy-only hello"
  refute "Alt+Enter on an answer opened nothing" "run open-entry"
  refute "Delete on an answer wrote no history" "write-file history"
}

check() {
  if grep -qxF -- "$2" "$log"; then printf 'PASS  %s\n' "$1"
  else printf 'FAIL  %s (no "%s" in the log)\n' "$1" "$2"; failed=1; fi
}
refute() {
  if grep -qF -- "$2" "$log"; then printf 'FAIL  %s\n' "$1"; failed=1
  else printf 'PASS  %s\n' "$1"; fi
}

run C.UTF-8 .
run de_DE.UTF-8 ,

# Nothing the instance started should have outlived it.
sleep 0.5
if pgrep -f "$SANDBOX" >/dev/null; then
  printf 'FAIL  processes outlived the instance:\n'; pgrep -af "$SANDBOX"; failed=1
else
  printf 'PASS  nothing outlived the instance\n'
fi

exit $failed
