import Quickshell.Io

// One-at-a-time writer for one of the plugin's two JSON files.
//
// The payload goes to bin/omarchy-snippets-helper on stdin rather than being
// written from the shell, because the helper is where the retained directory
// descriptor, the size cap, and the atomic rename live. Writing from here
// instead would mean the shell process holding a path it cannot check and a
// rename it cannot make safe.
//
// Only the newest payload is ever worth writing. Both files are written whole,
// so a save that arrives while another is in flight replaces the one waiting
// rather than queueing behind it: a burst of edits in the snippet editor costs
// one write after the current one lands, not one per keystroke.
Process {
  id: writer

  required property string helper
  // "snippets" or "history" — the helper maps these to the two paths it owns,
  // so no path is ever passed in from here.
  required property string kind

  // The file this plugin most recently asked for, and the one currently being
  // handed over. They differ only while a write is in flight.
  property string pendingText: ""
  property string inFlightText: ""
  property bool hasPending: false

  // Set when the helper refuses or fails a write, so the picker can say so
  // rather than leaving the user thinking their edit was saved.
  property bool failed: false

  command: [writer.helper, "write-file", writer.kind]
  clearEnvironment: true

  function submit(text) {
    writer.pendingText = String(text)
    writer.hasPending = true
    writer.pump()
  }

  function pump() {
    if (writer.running || !writer.hasPending) return
    writer.inFlightText = writer.pendingText
    writer.hasPending = false
    writer.stdinEnabled = true
    writer.running = true
  }

  // Written on started rather than straight after setting running, because the
  // pipe does not exist until the process does.
  onStarted: {
    writer.write(writer.inFlightText)
    writer.stdinEnabled = false
  }

  onExited: function(exitCode) {
    writer.failed = exitCode !== 0
    // Nothing changed while that was in flight, so there is nothing to redo.
    if (writer.hasPending && writer.pendingText === writer.inFlightText) writer.hasPending = false
    writer.pump()
  }
}
