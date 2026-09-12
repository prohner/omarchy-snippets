# Security model

Omarchy plugins run unsandboxed inside `omarchy-shell`. This one is a fork of
the built-in clipboard overlay, so it inherits that overlay's job: watching the
clipboard forever and keeping two JSON files on disk in step with a picker. That
job is the whole attack surface, and this document is what the plugin does about
it.

The short version: **the shell process runs one executable and opens no files.**
Everything else happens in `bin/omarchy-snippets-helper`, which is the only
thing `Clipboard.qml` ever launches, and which is reached by an absolute path
derived from the plugin's own location rather than from `$PATH` or
`$OMARCHY_PATH`.

That is not a stylistic preference. QML can start a process and read a file, but
it cannot open a directory and hold it, cannot ask what a descriptor really
points at, cannot stop reading at a byte count, and cannot put a deadline on a
capture. Those are exactly the questions that have to be answered here, and they
are answerable one `exec` away. So they are answered there.

---

## 1. Validated executables, in a controlled environment

**Before:** startup and the two watchers ran bare `pkill`, `setpriv`, and
`wl-paste`; paste, open, and edit went to `$OMARCHY_PATH`-derived paths and to a
bare `omarchy-launch-editor`. All of it resolved through whatever `PATH` and
environment the shell happened to be holding.

**Now:** no bare name is executed anywhere, by the shell or by the helper.

- The shell launches exactly one program: `bin/omarchy-snippets-helper`, located
  from this file's own URL (`Qt.resolvedUrl`), so neither `PATH` nor
  `$OMARCHY_PATH` takes part in finding it.
- The helper resolves every program it needs out of a fixed list of directories
  (`/usr/bin`, `/bin`, `/usr/local/bin`) — never `PATH`, and never any directory
  under `$HOME`. Each one must be a regular executable file that only root or
  this user can rewrite, reached through a link and a directory that only root
  or this user can repoint. `stat(1)` itself is vetted with shell builtins
  before it is trusted to vet anything else.
- Symlinks are permitted, deliberately: Omarchy's own `bin/` is a directory of
  root-owned symlinks into `/usr/bin`, and a blanket "no symlinks" rule would
  refuse every helper this plugin legitimately calls. What is checked instead is
  the property that actually matters — that nobody but root and this user can
  influence where the name lands.
- `$OMARCHY_PATH` is still honoured, because a dev checkout is a real install,
  but only as a *candidate*: it must be absolute, free of `..`, a real
  non-symlinked directory with `bin/` and `shell/` in it, and every individual
  program taken out of it is validated again.
- Only four Omarchy helpers can be run at all, chosen from a fixed list in the
  helper — `paste-text`, `paste-file`, `open-entry`, `launch-editor`. The name
  is never passed through from QML.
- The **Open snippets.json in $EDITOR** button passes no path. The helper opens
  the snippets file it owns, so the button cannot be aimed at another file.
- The environment is built by name from a fixed allowlist in `Clipboard.qml`
  with `clearEnvironment: true`, not inherited. `PATH` is stated rather than
  passed through. The helper then unsets the loader and interpreter hooks that
  turn a trusted binary into an attacker-chosen one — `LD_PRELOAD`,
  `LD_LIBRARY_PATH`, `LD_AUDIT`, `BASH_ENV`, `ENV`, and the `PERL5*` family,
  which matter because `capture.sh` runs perl.
- Detached launches go through a `Process` with `startDetached()` rather than
  `Quickshell.execDetached()`, because a `Process` carries an environment and
  the bare call inherits the shell's.

## 2. Producer-side caps and deadlines on clipboard capture

**Before:** the watchers fed a newline-based `SplitParser` and the startup
snapshot used `StdioCollector(waitForEnd: true)` — hold everything the clipboard
had, for as long as it took, however much it was. A single large copy with no
newline in it could exhaust the shell before any display-side truncation ran.

**Now:** nothing is capped after it arrives, because nothing arrives uncapped.

| Bound | Value | What it bounds |
| --- | --- | --- |
| `MAX_CLIP_TEXT_BYTES` | 128 KiB | clipboard text taken per copy |
| `MAX_CLIP_IMAGE_BYTES` | 64 MiB | clipboard image taken per copy |
| `MAX_CAPTURE_OUTPUT_BYTES` | 1 MiB | JSON coming back out of `capture.sh` |
| `CAPTURE_DEADLINE` | 10 s | how long any one capture may take |
| `MAX_FILE_BYTES` | 8 MiB | either JSON file, per read and per write |
| `MAX_ARGV_BYTES` | 128 KiB | arguments handed to an Omarchy helper |

- Text past the cap is **truncated**; a shortened entry is still useful. An
  image past the cap is **dropped**, because half a PNG on disk is not an image,
  it is a corrupt file the picker would offer forever.
- The cap is applied by reading up to the limit and then *draining the rest*.
  Stopping at the limit and closing would `SIGPIPE` the producer, which for
  `wl-paste` means a dead watcher rather than a truncated entry.
- Every capture runs under `timeout`, so a wedged `capture.sh` is a missing
  entry rather than a stuck watcher.
- The startup snapshot now selects the type and pulls the payload itself, so it
  goes through the same caps as every later capture instead of being read whole
  inside `capture.sh`. `StdioCollector(waitForEnd: true)` is gone; all three
  clipboard readers are the same one-line-per-event reader.
- Every line the helper emits is JSON-encoded, which is what makes it exactly
  one newline-terminated line whatever the payload contains. A clipboard entry
  with no newline in it can no longer leave the reader waiting on a line that is
  never coming.

## 3. Bounded, descriptor-safe reads

**Before:** both files were read whole by a `FileView` under the inherited
`$HOME`, with no regular-file, owner, or symlink check, and no read-time size
limit — and no way to perform one from QML.

**Now:** the shell opens neither path. The helper watches both and sends each
change up as one bounded line.

- The directory is opened **once** and kept. Everything afterwards is addressed
  through `/proc/self/fd/<fd>`, so the descriptor pins the inode that was
  checked and replacing a path component later cannot redirect anything.
- The directory must be a real directory, owned by this user, not group- or
  world-writable, and not a symlink. It is created `0700` if missing.
- A file is type-checked **before** the open and validated again **on the
  descriptor** after it. Both earn their place. The check before matters because
  `open(2)` on a fifo blocks until a writer arrives — a watcher that opened one
  would stop reporting forever, with nothing on screen to say so. The check
  after matters because the name is not what gets read; the descriptor is, and
  only the descriptor can say what was really on the other end of it.
- Anything that is not a plain file this user owns — a fifo, a device, a
  symlink, a dangling symlink — is refused and reported as unreadable, which the
  picker says in its header rather than showing an empty library.
- Reads stop at `MAX_FILE_BYTES`.

## 4. Atomic writes under a retained private directory

**Before:** `FileView.atomicWrites` established no owned, no-follow directory
boundary, so a directory component planted or swapped between the check and the
write could redirect it.

**Now:** writes go out through the same retained descriptor as reads.

- The temporary file is created by `mktemp` (mode `0600`) in that same
  directory, addressed through the held descriptor, so the replacement is a
  `rename(2)` and not a copy, and a reader never sees a partial file.
- `rename(2)` does not follow a symlink at the destination, so a symlink planted
  where the file goes is *replaced by the real file* rather than written
  through. `test/helper.test.sh` asserts exactly this.
- A directory planted at the path after the descriptor was opened receives
  nothing: it is simply not the directory being written to.
- Saves are coalesced to one in flight (`GuardedWriter.qml`). Both files are
  written whole, so when several edits queue up only the newest is worth
  writing.

## 5. Bounded schema

**Before:** snippet and history arrays, and the field lengths inside them, were
unbounded before `JSON.parse` and before model allocation.

**Now** — checked in `Snippets.js` and `ClipboardHistory.js`, and covered by
`test/snippets.test.js`:

| | Cardinality | Field limits |
| --- | --- | --- |
| Snippets | 512 | trigger 256 · body 64 KiB · notes 4 KiB |
| History | 300 | text 128 KiB · path 4 KiB · mime 128 |

The raw text is length-checked *before* `JSON.parse`, since a parser is the
wrong place to discover that its input was too big to hold. Oversized values are
shortened rather than dropped, so a too-long snippet stays a snippet.

The 64 KiB body limit is the one with a hard reason rather than a judgement
behind it: the body is handed to `omarchy-clipboard-paste-text` as a single
argument, and Linux refuses any single argument longer than 128 KiB. A body
above that could not be pasted at all, so capping it well under is the
difference between a clear limit and an opaque `E2BIG`.

## 6. Recorded process identity instead of pattern killing

**Before:** startup ran

```
pkill -f 'wl-paste .*--watch .*/shell/plugins/clipboard/capture\.sh'
```

which kills by resemblance. Every process of this user whose command line
happens to match dies — including one that merely mentions that string in an
argument. (While testing this change, that pattern matched four processes on the
author's machine, one of them the shell running the test.)

**Now:** watchers are killed because they are the ones that were recorded.

- Each watcher is recorded in a private `0700` directory under
  `$XDG_RUNTIME_DIR` as `(pid, start time)` — start time being field 22 of
  `/proc/<pid>/stat`, which is the part a recycled pid cannot forge.
- On startup the helper kills a recorded entry only when the pid still exists,
  its start time still matches what was recorded, **and** its command line still
  names this very helper. All three must hold.
- Nothing anywhere matches a command line with a pattern.
- Job control puts each `wl-paste` in its own process group, so the group can be
  named, recorded, and later killed whole, including the capture children
  `wl-paste` spawns per event.

### Watchers do not outlive the shell

Three independent things have to fail before a watcher is left running:

1. The helper re-execs itself through `setpriv --pdeathsig TERM`, so the kernel
   terminates the supervisor when the shell exits, however it exits.
2. `wl-paste` gets its **own** `--pdeathsig TERM`, so the kernel terminates it
   when the supervisor dies — for any reason, including `SIGKILL`. This is not
   redundancy for its own sake: Quickshell kills its children outright on the
   way out, which never gives a trap the chance to run. Asking the kernel needs
   no cooperation from anybody.
3. The supervisor also traps and kills the whole process group on the way out,
   which covers the per-event capture children.

`reap` is what remains for the case where all of that was bypassed.

---

## Consequences worth knowing about

- **Clipboard text is capped at 128 KiB per copy.** Copying more stores the
  first 128 KiB. Previously it stored all of it.
- **Clipboard images are capped at 64 MiB** and dropped past that, rather than
  stored truncated.
- **Snippet bodies are capped at 64 KiB.** A longer body loaded from disk is
  shortened, and saving an edit afterwards writes the shortened form back.
- **Live reload is a one-second poll**, not inotify. inotify has to re-arm after
  every event it reports, and a save landing inside that window is not reported
  at all — so it needs a timed re-check behind it anyway, which is the poll,
  plus a second way for the loop to be wrong. One `stat` of one file per second
  costs nothing measurable and cannot miss a change.
- **`bin/omarchy-snippets-helper` must keep its executable bit.** If it cannot
  start, the picker says `snippets helper is not running` in its header rather
  than looking like an empty clipboard.

## Running the tests

```bash
node test/snippets.test.js   # search ranking, parsing, and the schema bounds
test/helper.test.sh          # the helper, against a sandbox HOME
```

`test/helper.test.sh` never touches the real snippet library, the real clipboard
history, or the clipboard itself — the capture path is driven by feeding the
helper on stdin exactly the way `wl-paste` does.
