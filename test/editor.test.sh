#!/usr/bin/bash
#
# Runs test/editor.test.qml.
#
#   test/editor.test.sh
#
# The editor cannot be tested in plain node the way Snippets.js can: it is a
# QML component, and it imports Omarchy's qs.Ui and qs.Commons, which need
# Quickshell's own types. So this builds the smallest tree quickshell will load
# — the Omarchy shell's modules symlinked in beside this plugin — and runs it
# offscreen. It draws nothing, touches no file of yours, and starts no helper.
#
# Skips rather than fails when quickshell or the Omarchy shell is not installed,
# so the other two suites still run somewhere that has neither.

set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SHELL_DIR=${OMARCHY_SHELL:-/usr/share/omarchy/shell}

if ! command -v quickshell >/dev/null 2>&1; then
  printf 'SKIP  editor tests: quickshell is not installed\n'
  exit 0
fi
if [[ ! -d $SHELL_DIR ]]; then
  printf 'SKIP  editor tests: no Omarchy shell at %s (set OMARCHY_SHELL)\n' "$SHELL_DIR"
  exit 0
fi

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

root=$SANDBOX/root
mkdir -p "$root" "$SANDBOX/run" || exit 1

# quickshell exposes the directory it is given as the `qs` module, which is how
# `import qs.Ui` inside the plugin resolves.
for dir in Commons Ui services; do
  [[ -d $SHELL_DIR/$dir ]] && ln -s "$SHELL_DIR/$dir" "$root/$dir"
done
ln -s "$PWD" "$root/plugin"
cp test/editor.test.qml "$root/shell.qml"

# An isolated runtime directory: this never starts the helper, but nothing here
# should be able to reach the record your running shell keeps there either.
out=$(env HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/run" \
  QT_QPA_PLATFORM=offscreen \
  timeout 120 quickshell -n -p "$root" 2>&1)
status=$?

# quickshell prefixes its own log lines; the assertions are the qml ones.
printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E 'PASS |FAIL |notes bottom=|All tests passed|failed\.' \
  | sed -e 's/^ *DEBUG *qml: *//' -e 's/^ *WARN *qml: *//'

if [[ $status -ne 0 ]]; then
  # A load failure produces no assertions at all, so say what happened.
  printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'rror|Fatal' | head -20
  exit 1
fi
exit 0
