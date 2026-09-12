import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ClipboardHistory.js" as ClipboardHistory
import "Snippets.js" as Snippets // +snippets

// FORK of the built-in omarchy.clipboard overlay (Omarchy 4.0.2-1).
//
// Every deviation from upstream is marked `+snippets` so this file can be
// re-synced by diffing against the stock plugin and re-applying the marked
// hunks. Keep it that way: new behavior belongs in Snippets.js or
// SnippetsEditor.qml, not here. See README.md.
Item {
  id: root

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool clearConfirmOpen: false
  property var history: []

  property var snippets: [] // +snippets
  property bool editorOpen: false // +snippets
  // +snippets: set when snippets.json exists but does not parse. Surfaced in
  // the picker so a typo in a hand-edited file is visible instead of silently
  // showing an empty library.
  property bool snippetsBroken: false
  // +hardened: set when the helper reports the file is there but is not a
  // plain file this user owns — a fifo, a device, a symlink out of the
  // directory. A different failure from a syntax error, and worth saying so.
  property bool snippetsUnreadable: false
  // +hardened: set when the long-lived helper processes keep dying. Without it
  // a broken install looks exactly like an empty clipboard.
  property bool helperFailing: false

  // +hardened: this plugin runs exactly one executable, and finds it from this
  // file's own location rather than from $PATH or $OMARCHY_PATH. Every
  // external program it runs, every byte it reads from disk, and every byte it
  // writes to disk goes through that one file, which is where the executable
  // validation, the size caps, and the atomic writes live. Neither of the two
  // JSON paths appears here any more: the shell process no longer opens them,
  // so it no longer has to be the thing that decides they are safe to open.
  // See SECURITY.md.
  readonly property string pluginDir: root.localDir(Qt.resolvedUrl("."))
  readonly property string helper: root.pluginDir + "/bin/omarchy-snippets-helper"

  // +hardened: the environment every child gets. Built by name from the list
  // below rather than inherited whole, and PATH is stated here rather than
  // passed through, so nothing a child goes on to run can be chosen by
  // something that was already in the shell's environment.
  readonly property var inheritedEnvironment: [
    "HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE",
    "XDG_RUNTIME_DIR", "XDG_STATE_HOME", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP",
    "WAYLAND_DISPLAY", "DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE",
    "DBUS_SESSION_BUS_ADDRESS", "OMARCHY_PATH"
  ]
  readonly property var childEnvironment: root.buildEnvironment()

  // +hardened: the header line. A plugin that has quietly stopped working looks
  // exactly like a plugin with nothing to show, so each way it can stop working
  // gets said out loud, most fundamental first.
  readonly property string statusHint: root.helperFailing ? "snippets helper is not running"
    : root.snippetsUnreadable ? "snippets.json could not be read"
    : root.snippetsBroken ? "snippets.json has a syntax error"
    : (snippetsWriter.failed || historyWriter.failed) ? "could not save — see the shell log"
    : "Ctrl+E snippets"
  readonly property bool statusUrgent: root.statusHint !== "Ctrl+E snippets"
  // Shares the [menu] surface tokens — themes that style the menu also
  // style the clipboard. Selected-row colors composed in the
  // singleton so consumers drop them straight into Rectangle bindings.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(875), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(50), Style.font.body + Style.font.caption + Style.spacing.rowPaddingX * 2)
  property int historyLimit: 300

  function open(payloadJson) {
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = true
    root.editorOpen = false // +snippets
    root.disarmPointer()
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.cancelClearHistory()
    root.editorOpen = false // +snippets
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // +hardened: the plugin's own directory, from this file's URL. Percent
  // decoding matters because a URL spells a space "%20" and a path does not.
  function localDir(url) {
    var path = String(url)
    if (path.indexOf("file://") === 0) path = path.substring(7)
    try { path = decodeURIComponent(path) } catch (e) {}
    while (path.length > 1 && path.charAt(path.length - 1) === "/") path = path.substring(0, path.length - 1)
    return path
  }

  function buildEnvironment() {
    var env = { "PATH": "/usr/bin:/bin" }
    for (var i = 0; i < root.inheritedEnvironment.length; i++) {
      var name = root.inheritedEnvironment[i]
      var value = Quickshell.env(name)
      if (value !== undefined && value !== null && String(value).length > 0) env[name] = String(value)
    }
    return env
  }

  // +hardened: detached launches go through a Process rather than
  // Quickshell.execDetached(), because a Process carries an environment with
  // it and the bare call inherits the shell's.
  function runDetached(args) {
    detachedProc.command = [root.helper].concat(args)
    detachedProc.startDetached()
  }

  function normalizeEntry(value) {
    return ClipboardHistory.normalizeEntry(value)
  }

  function entryKey(entry) {
    return ClipboardHistory.entryKey(entry)
  }

  function loadHistory(raw) {
    root.history = ClipboardHistory.parseHistory(raw)
    if (root.opened) root.rebuildDisplay()
  }

  function saveHistory() {
    historyWriter.submit(JSON.stringify(root.history.slice(0, root.historyLimit), null, 2) + "\n")
  }

  // +hardened: one line per change arrives from the helper — the file's
  // contents as a JSON string, "" when it is absent, or null when it is there
  // but is not a plain file this user owns. Encoding it as JSON is what makes
  // it one line whatever the file holds, so a file with no newline in it can
  // never leave the reader waiting on a line that is not coming.
  function decodeWatchLine(line) {
    try { return JSON.parse(String(line)) } catch (e) { return null }
  }

  function onHistoryLine(line) {
    root.noteWatcherAlive()
    var raw = root.decodeWatchLine(line)
    root.loadHistory(raw === null ? "[]" : String(raw))
  }

  function onSnippetsLine(line) {
    root.noteWatcherAlive()
    var raw = root.decodeWatchLine(line)
    if (raw === null) {
      root.snippets = []
      root.snippetsBroken = false
      root.snippetsUnreadable = true
      if (root.opened) root.rebuildDisplay()
      return
    }
    root.snippetsUnreadable = false
    root.loadSnippets(String(raw))
  }

  function noteWatcherAlive() {
    watchRestartTimer.backoff = 1000
    root.helperFailing = false
  }

  function addClipboardEntry(entry) {
    var normalized = ClipboardHistory.normalizeEntry(entry)
    if (!normalized) return

    root.history = ClipboardHistory.addEntry(root.history, normalized, root.historyLimit)
    root.saveHistory()
    if (root.opened) root.rebuildDisplay()
  }

  function addClipboardJson(line) {
    root.addClipboardEntry(ClipboardHistory.parseEntryJson(line))
  }

  // +snippets: snippet library load / save / edit ------------------------
  function loadSnippets(raw) {
    root.snippets = Snippets.parseSnippets(raw)
    var text = String(raw || "").trim()
    root.snippetsBroken = text.length > 0 && root.snippets.length === 0
    if (root.opened) root.rebuildDisplay()
  }

  function saveSnippets(list) {
    root.snippets = Array.isArray(list) ? list : []
    root.snippetsBroken = false
    root.snippetsUnreadable = false
    snippetsWriter.submit(Snippets.serialize(root.snippets))
    if (root.opened) root.rebuildDisplay()
  }

  function openEditor() {
    root.cursorActive = false
    root.editorOpen = true
  }

  function closeEditor() {
    root.editorOpen = false
    root.cursorActive = root.displayCount() > 0
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function displayCount() {
    return displayModel.count
  }

  // Hands the raw file to the user's editor in a terminal. The helper watches
  // the path, so saving in $EDITOR refreshes the picker with no further action.
  //
  // +hardened: no path is passed and no launcher is named. The helper opens
  // the snippets file it owns, using the copy of omarchy-launch-editor it
  // found and validated, so this button cannot be aimed at another file and
  // cannot reach a launcher of that name that happens to be earlier in $PATH.
  function editSnippetsExternally() {
    root.opened = false
    root.runDetached(["run", "launch-editor"])
  }
  // +snippets end ---------------------------------------------------------

  function requestClearHistory() {
    if (root.history.length === 0) return
    clearConfirm.selectedIndex = 1
    root.clearConfirmOpen = true
  }

  function cancelClearHistory() {
    root.clearConfirmOpen = false
    root.disarmPointer()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmClearHistory() {
    root.history = ClipboardHistory.clearHistory()
    root.saveHistory()
    root.selectedIndex = 0
    root.cursorActive = false
    root.disarmPointer()
    root.clearConfirmOpen = false
    root.rebuildDisplay()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function removeDisplayIndex(index) {
    if (index < 0 || index >= displayModel.count) return

    var row = displayModel.get(index)
    // +snippets: Delete prunes clipboard history. Removing a snippet is a
    // destructive edit to authored config, so it stays in the editor behind a
    // confirmation rather than being one keystroke away in the picker.
    if (row.entryType === "snippet") return
    root.history = ClipboardHistory.removeEntryAt(root.history, row.historyIndex)
    root.saveHistory()

    if (displayModel.count <= 1) {
      root.selectedIndex = 0
      root.cursorActive = false
    } else if (root.selectedIndex >= displayModel.count - 1) {
      root.selectedIndex = displayModel.count - 2
    }

    root.disarmPointer()
    root.rebuildDisplay()
  }

  function rebuildDisplay() {
    // +snippets: both lists are filtered by the same query; Snippets.mergeRows
    // decides which leads (history when the box is empty, snippets once the
    // user starts searching). Snippets are never subject to the history cap.
    var rows = Snippets.mergeRows(
      Snippets.displayRows(root.snippets, root.filterText, 50),
      ClipboardHistory.displayRows(root.history, root.filterText, 50),
      root.filterText)

    displayModel.clear()
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      displayModel.append({
        entryType: row.entryType,
        fullText: row.fullText,
        previewText: row.previewText,
        previewImage: row.previewImage ? Util.fileUrl(row.previewImage) : "",
        path: row.path,
        mime: row.mime,
        historyIndex: row.index,
        // +snippets: every row carries both fields so the ListModel roles stay
        // uniform. -1 marks a row that came from clipboard history.
        snippetIndex: row.snippetIndex === undefined ? -1 : row.snippetIndex,
        notes: row.notes === undefined ? "" : row.notes
      })
    }

    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0

    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectAbsolute(index) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    root.cursorActive = true
    root.selectedIndex = Math.max(0, Math.min(index, displayModel.count - 1))
    resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  function activateIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.applySelected(row)
  }

  function copyIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.copySelected(row)
  }

  function openIndex(index) {
    if (index < 0 || index >= displayModel.count) return
    var row = displayModel.get(index)
    root.openSelected(row)
  }

  function applySelected(row) {
    if (!row) return
    root.opened = false
    // +snippets: a snippet has no history index, so its body is passed
    // literally. --shift-insert still copies first and pastes via the
    // clipboard rather than synthesizing keystrokes, which is both faster and
    // lossless for long or multi-line bodies.
    if (row.entryType === "snippet") {
      if (row.fullText) root.runDetached(["run", "paste-text", "--shift-insert", row.fullText])
    } else if (row.entryType === "image") {
      root.runDetached(["run", "paste-file", row.mime, row.path])
    } else if (row.fullText) {
      root.runDetached(["run", "paste-text", "--shift-insert", "--history-index", String(row.historyIndex)])
    }
  }

  function copySelected(row) {
    if (!row) return
    root.opened = false
    if (row.entryType === "snippet") { // +snippets
      if (row.fullText) root.runDetached(["run", "paste-text", "--copy-only", row.fullText])
    } else if (row.entryType === "image") {
      root.runDetached(["run", "paste-file", "--copy-only", row.mime, row.path])
    } else if (row.fullText) {
      root.runDetached(["run", "paste-text", "--copy-only", "--history-index", String(row.historyIndex)])
    }
  }

  function openSelected(row) {
    if (!row) return
    // +snippets: Alt+Enter on a snippet edits it instead of opening a history
    // entry in an external viewer.
    if (row.entryType === "snippet") {
      snippetsEditor.selectedIndex = row.snippetIndex
      root.openEditor()
      return
    }
    root.opened = false
    root.runDetached(["run", "open-entry", "--history-index", String(row.historyIndex)])
  }

  Component.onCompleted: reapProc.running = true

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  // +hardened: the object every detached launch borrows. It exists only to
  // carry the controlled environment, which Quickshell.execDetached() on its
  // own would not.
  Process {
    id: detachedProc
    environment: root.childEnvironment
    clearEnvironment: true
  }

  // +hardened: both files used to be read and written by a FileView here, and
  // both are now read by a helper that watches them and writes them on this
  // process's behalf. A FileView reads whatever a path resolves to, all of it,
  // into this process — the one drawing the desktop — with no way from QML to
  // first ask whether the path is a plain file, whether it is this user's, or
  // how much is behind it, and its atomic write has no directory it can hold
  // on to between the check and the rename. All four of those questions are
  // answerable from a process that can hold a descriptor, so they are answered
  // there instead. See SECURITY.md.
  Process {
    id: historyWatchProc
    command: [root.helper, "watch-file", "history"]
    environment: root.childEnvironment
    clearEnvironment: true
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(line) { root.onHistoryLine(line) }
    }
  }

  // +snippets: watching the file means an edit in $EDITOR (or a sync from
  // another machine) shows up in the picker without restarting the shell.
  Process {
    id: snippetsWatchProc
    command: [root.helper, "watch-file", "snippets"]
    environment: root.childEnvironment
    clearEnvironment: true
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(line) { root.onSnippetsLine(line) }
    }
  }

  GuardedWriter {
    id: historyWriter
    helper: root.helper
    kind: "history"
    environment: root.childEnvironment
  }

  GuardedWriter {
    id: snippetsWriter
    helper: root.helper
    kind: "snippets"
    environment: root.childEnvironment
  }

  // Reap watchers left behind by a previous shell instance, then start our
  // own. The pdeathsig the helper puts on itself makes the kernel kill the
  // watchers whenever the shell exits, however it exits, so no further
  // lifecycle management.
  //
  // +hardened: this was `pkill -f "wl-paste .*--watch .*capture\.sh"`, which
  // kills by resemblance — every process of this user whose command line
  // happens to match that pattern dies, including one that merely mentions it
  // in an argument. The helper kills only process groups a previous shell
  // recorded, and only while the pid, the start time recorded with it, and the
  // command line all still agree that it is the process that was recorded.
  Process {
    id: reapProc
    command: [root.helper, "reap"]
    environment: root.childEnvironment
    clearEnvironment: true
    onExited: function(exitCode) {
      if (exitCode !== 0) root.helperFailing = true
      captureOnceProc.running = true
      textWatchProc.running = true
      imageWatchProc.running = true
      historyWatchProc.running = true
      snippetsWatchProc.running = true
    }
  }

  // +hardened: the startup snapshot used to be capture.sh straight into a
  // StdioCollector that waited for the stream to end, which is to say: hold
  // everything the clipboard had, for as long as it took, however much it was.
  // The helper caps the payload and puts a deadline on the capture before
  // either reaches this process, and frames the result as one line, so this
  // side is the same newline-delimited reader as the two watchers below.
  Process {
    id: captureOnceProc
    command: [root.helper, "capture-once"]
    environment: root.childEnvironment
    clearEnvironment: true
    stdout: SplitParser {
      onRead: function(data) { root.addClipboardJson(data) }
    }
  }

  Process {
    id: textWatchProc
    command: [root.helper, "watch-clipboard", "text"]
    environment: root.childEnvironment
    clearEnvironment: true
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.noteWatcherAlive(); root.addClipboardJson(data) }
    }
  }

  Process {
    id: imageWatchProc
    command: [root.helper, "watch-clipboard", "image/png"]
    environment: root.childEnvironment
    clearEnvironment: true
    onExited: watchRestartTimer.restart()
    stdout: SplitParser {
      onRead: function(data) { root.noteWatcherAlive(); root.addClipboardJson(data) }
    }
  }

  // A watcher that dies takes clipboard history with it, silently: copying still
  // works, the picker still opens, and the old entries are all still there, so
  // nothing recorded until the next shell reload. Bring it back instead.
  //
  // +hardened: with a backoff, and saying so once the retries stop being
  // plausibly transient. A helper that cannot start — the file lost its
  // executable bit, the plugin folder moved — would otherwise be retried once
  // a second forever with nothing on screen to explain the empty picker.
  Timer {
    id: watchRestartTimer
    property int backoff: 1000

    interval: backoff
    repeat: false
    onTriggered: {
      if (backoff >= 8000) root.helperFailing = true
      backoff = Math.min(backoff * 2, 30000)
      if (!textWatchProc.running) textWatchProc.running = true
      if (!imageWatchProc.running) imageWatchProc.running = true
      if (!historyWatchProc.running) historyWatchProc.running = true
      if (!snippetsWatchProc.running) snippetsWatchProc.running = true
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        z: root.clearConfirmOpen ? 20 : 0
        focus: !root.editorOpen // +snippets: yield the keyboard to the editor

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.clearConfirmOpen) {
            if (clearConfirm.handleKey(event)) event.accepted = true
            return
          }

          // +snippets: the editor owns the keyboard while it is up. This
          // handler must not swallow characters headed for its text fields.
          if (root.editorOpen) return

          // +snippets: Ctrl+E edits the highlighted snippet, or opens the
          // editor on the library when the cursor is on a history row. Adding
          // it here rather than as a Hyprland binding keeps the plugin
          // self-contained — a plugin cannot install a keybinding.
          if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_E) {
            var cursorRow = root.cursorActive && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null
            snippetsEditor.selectedIndex = cursorRow && cursorRow.entryType === "snippet" ? cursorRow.snippetIndex : 0
            root.openEditor()
            event.accepted = true
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.close()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (event.modifiers & Qt.ShiftModifier) root.requestClearHistory()
            else root.removeDisplayIndex(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectAbsolute(0)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectAbsolute(displayModel.count - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive && (event.modifiers & Qt.AltModifier)) root.openIndex(root.selectedIndex)
            else if (root.cursorActive && (event.modifiers & Qt.ShiftModifier)) root.copyIndex(root.selectedIndex)
            else if (root.cursorActive) root.activateIndex(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }

        ConfirmDialog {
          id: clearConfirm

          anchors.fill: parent
          opened: root.clearConfirmOpen
          z: 10
          message: "Delete entire clipboard history?"
          confirmText: "Delete"
          background: root.background
          foreground: root.foreground
          scrim: root.scrim
          selectedBackground: root.selectedBackground
          selectedText: root.selectedText
          fontFamily: root.fontFamily
          cornerRadius: root.cornerRadius
          onCanceled: root.cancelClearHistory()
          onConfirmed: root.confirmClearHistory()
        }
      }

      // +snippets: the editor replaces the picker inside the same card.
      SnippetsEditor {
        id: snippetsEditor

        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        visible: root.editorOpen
        z: 5

        snippets: root.snippets
        background: root.background
        foreground: root.foreground
        border: root.border
        selectedBackground: root.selectedBackground
        selectedText: root.selectedText
        fontFamily: root.fontFamily
        contentMargin: root.contentMargin
        cornerRadius: root.cornerRadius

        onChanged: function(list) { root.saveSnippets(list) }
        onClosed: root.closeEditor()
        onOpenInExternalEditor: root.editSnippetsExternally()
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing
        visible: !root.editorOpen // +snippets

        Rectangle {
          width: parent.width
          height: root.headerHeight
          radius: root.cornerRadius
          color: "transparent"

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: hint.left // +snippets: leave room for the hint
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            // +snippets: snippets are searched alongside history, so say so.
            text: root.filterText || "Search clipboard and snippets…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          // +snippets: the only discoverability the editor gets, since the
          // plugin cannot advertise itself with a keybinding.
          Text {
            id: hint
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.statusHint
            color: root.statusUrgent ? Color.urgent : root.foreground
            opacity: root.statusUrgent ? 1 : 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          Row {
            anchors.fill: parent
            spacing: 0

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              ListView {
                id: resultList
                anchors.fill: parent
                anchors.rightMargin: root.contentMargin
                model: displayModel
                clip: true
                spacing: Style.space(4)
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: row
                  required property int index
                  required property string entryType
                  required property string previewText
                  required property string fullText
                  required property string previewImage

                  readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: hasCursor ? root.selectedBackground : "transparent"

                  Row {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    anchors.topMargin: Style.space(8)
                    anchors.bottomMargin: Style.space(8)
                    spacing: Style.space(10)

                    // +snippets: marks a pinned snippet apart from the
                    // clipboard entries it sits above.
                    Text {
                      id: snippetMark
                      visible: row.entryType === "snippet"
                      width: visible ? implicitWidth : 0
                      height: parent.height
                      text: "󰅇"
                      color: row.hasCursor ? root.selectedText : root.foreground
                      opacity: row.hasCursor ? 1.0 : 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      verticalAlignment: Text.AlignVCenter
                    }

                    Image {
                      visible: parent.parent.previewImage.length > 0
                      width: visible ? parent.height : 0
                      height: parent.height
                      source: parent.parent.previewImage
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true
                      smooth: true
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width - (parent.parent.previewImage.length > 0 ? parent.height + parent.spacing : 0)
                              - (snippetMark.visible ? snippetMark.width + parent.spacing : 0) // +snippets
                      height: parent.height
                      text: parent.parent.previewText
                      color: parent.parent.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      opacity: parent.parent.entryType === "image" || parent.parent.entryType === "file" ? 0.72 : 1.0
                      elide: Text.ElideRight
                      wrapMode: Text.NoWrap
                      verticalAlignment: Text.AlignVCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onPositionChanged: function(mouse) {
                      root.selectFromPointer(row.index, row, mouse)
                    }
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.activateIndex(row.index)
                    }
                  }
                }
              }
            }

            Item {
              width: parent.width / 2
              height: parent.height
              clip: true

              property var activeRow: displayModel.count > 0 && root.selectedIndex >= 0 && root.selectedIndex < displayModel.count ? displayModel.get(root.selectedIndex) : null

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Style.normalBorderWidth
                color: Util.alpha(root.border, 0.28)
              }

              // +snippets: a snippet's notes get their own strip under the
              // body, so the preview answers "what is this for?" and not just
              // "what does it paste?".
              readonly property string activeNotes: activeRow && activeRow.entryType === "snippet" ? String(activeRow.notes || "") : ""

              Column {
                id: notesPanel
                visible: parent.activeNotes.length > 0
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.leftMargin: root.contentMargin
                spacing: Style.space(4)

                Rectangle {
                  width: parent.width
                  height: Style.normalBorderWidth
                  color: Util.alpha(root.border, 0.28)
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  topPadding: Style.space(6)
                  text: notesPanel.parent.activeNotes
                  color: root.foreground
                  opacity: 0.65
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  maximumLineCount: 4
                  elide: Text.ElideRight
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: parent.activeRow && !parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                // +snippets: yield the bottom of the pane to the notes strip.
                anchors.bottomMargin: notesPanel.visible ? notesPanel.height + Style.space(8) : 0
                text: parent.activeRow ? parent.activeRow.fullText : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                verticalAlignment: Text.AlignTop
              }

              Image {
                visible: parent.activeRow && parent.activeRow.previewImage
                anchors.fill: parent
                anchors.leftMargin: root.contentMargin
                anchors.rightMargin: 0
                anchors.topMargin: 0
                anchors.bottomMargin: 0
                source: parent.activeRow ? parent.activeRow.previewImage : ""
                fillMode: Image.PreserveAspectFit
                verticalAlignment: Image.AlignTop
                asynchronous: true
                smooth: true
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.space(8)
            visible: displayModel.count === 0

            Text {
              text: "󰅌"
              color: root.selectedText
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.history.length === 0 ? "Clipboard is empty" : "No matches for “" + root.filterText + "”"
              color: root.foreground
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              horizontalAlignment: Text.AlignHCenter
              width: parent.width
            }
          }
        }
      }
    }
  }
}
