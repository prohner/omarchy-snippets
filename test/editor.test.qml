import QtQuick
import Quickshell
import "plugin" as P
import "plugin/Snippets.js" as Snippets

// Tests for SnippetsEditor.qml.
//
//   test/editor.test.sh
//
// Run under quickshell rather than plain `qml`, because the editor imports
// Omarchy's qs.Ui and qs.Commons, and those need Quickshell's own types.
// Nothing here touches the real snippet library, the clipboard, or the helper:
// the editor's only contact with the outside world is its `changed` signal and
// its `snippets` property, and this file stands in for Clipboard.qml on both.
//
// What it is really guarding is the round trip through the file. The editor
// does not own its list — it is handed one, hands back a replacement, and then
// sees the file watcher report that write back about a second later. Every bug
// these cases cover came from that echo arriving while the editor was open:
//
//   * a brand new snippet is empty, serialize drops an empty row, so the echo
//     deleted the row the open form was pointing at and the form vanished;
//   * loadFields() read `current`, a binding derived from `snippets`, from
//     inside the handler for snippets changing — which QML may run before that
//     binding is re-evaluated, so it loaded a stale list, blanked the fields,
//     and the next commit wrote the blanks over a real snippet;
//   * the echo reloaded the fields from the stored text, throwing away
//     whatever had been typed since the last commit.
//
// The fields are located by their placeholder text, so that the component
// under test needs no seams cut into it for the benefit of this file.
ShellRoot {
  FloatingWindow {
    id: win
    implicitWidth: 900
    implicitHeight: 620
    visible: true

    Item {
      id: root
      anchors.fill: parent

      property var snippets: []
      property string lastWritten: ""
      property int step: 0
      property int failures: 0

      // Both of these mirror Clipboard.qml. If they drift from it the harness
      // stops testing the thing that ships.
      function save(list) {
        var text = Snippets.serialize(Array.isArray(list) ? list : [])
        root.snippets = Snippets.parseSnippets(text)
        root.lastWritten = text
        echo.restart()
      }

      function load(raw) {
        if (root.lastWritten.length > 0 && String(raw) === root.lastWritten) return
        root.snippets = Snippets.parseSnippets(raw)
      }

      // The watcher handing back whatever the file now holds — our own write
      // included, which is the case that has to be recognised.
      Timer {
        id: echo
        interval: 250
        onTriggered: root.load(root.lastWritten)
      }

      function ok(cond, label) {
        if (!cond) root.failures++
        console.log((cond ? "PASS  " : "FAIL  ") + label)
      }

      // Find a descendant by a property value, so the component under test needs
      // no test seam cut into it.
      function find(item, prop, value) {
        if (!item) return null
        if (item[prop] !== undefined && item[prop] === value) return item
        var kids = item.children || []
        for (var i = 0; i < kids.length; i++) {
          var hit = root.find(kids[i], prop, value)
          if (hit) return hit
        }
        return null
      }

      P.SnippetsEditor {
        id: editor
        anchors.fill: parent
        anchors.margins: 18
        snippets: root.snippets
        visible: true
        onChanged: function(list) { root.save(list) }
      }

      property var triggerField: null
      property var bodyField: null

      Timer {
        id: steps
        interval: 400
        repeat: true
        running: true
        onTriggered: {
          root.step++
          switch (root.step) {

          case 1:
            root.snippets = [{ trigger: "thanks", body: "Thanks, Preston", notes: "" },
                             { trigger: "sig", body: "— Preston", notes: "" }]
            root.triggerField = root.find(editor, "placeholderText", "thanks")
            root.bodyField = root.find(editor, "placeholderText", "Thanks, Preston")
            root.ok(root.triggerField !== null && root.bodyField !== null,
                    "harness can reach the fields")
            break

          case 2:
            // The selected snippet must be in the fields without anyone asking:
            // whatever is there is what the next commit writes.
            root.ok(root.triggerField.text === "thanks" && root.bodyField.text === "Thanks, Preston",
                    "a library arriving from the file lands in the fields")
            break

          case 3:
            editor.addSnippet()
            root.ok(editor.current !== null, "+ New opens a form straight away")
            root.ok(editor.draftSelected, "the new row is selected")
            root.ok(root.snippets.length === 2, "+ New writes nothing to the file")
            break

          case 4:
            // Past the echo interval: this is where the form used to vanish.
            root.ok(editor.current !== null, "the new form is still open after the file echo")
            root.ok(editor.draftSelected, "the draft is still selected after the file echo")
            root.ok(root.snippets.length === 2, "and the library is still intact")
            break

          case 5:
            root.triggerField.text = "brb"
            editor.commit()
            root.ok(root.snippets.length === 3, "a draft with a trigger is saved")
            root.ok(!editor.draftSelected, "and stops being a draft")
            root.ok(editor.current && editor.current.trigger === "brb", "the saved row stays selected")
            break

          case 6:
            // Type a body WITHOUT committing, the way a user mid-sentence has,
            // and only then let the watcher report the previous write back. The
            // echo has to land AFTER the typing or this proves nothing.
            root.bodyField.text = "back in five"
            root.load(root.lastWritten)
            root.ok(root.bodyField.text === "back in five",
                    "text typed after the last save survives the file echo")
            break

          case 7:
            break

          case 8:
            editor.commit()
            root.ok(root.snippets.length === 3 && root.snippets[2].body === "back in five",
                    "and is saved on the next commit")
            break

          case 9:
            editor.addSnippet()
            editor.selectSnippet(0)
            root.ok(!editor.draftSelected && editor.rowList().length === 3,
                    "an untouched draft is dropped when another row is picked")
            root.ok(root.triggerField.text === "thanks", "and the picked row is in the fields")
            break

          case 10:
            // A real external edit — different bytes — must still come through.
            editor.selectSnippet(2)
            root.load(JSON.stringify({ snippets: [{ trigger: "thanks", body: "Thanks, Preston", notes: "" }] }))
            root.ok(root.snippets.length === 1, "an external edit is not mistaken for our own write")
            root.ok(editor.current !== null, "an external shrink does not leave a dead selection")
            break

          case 11:
            root.ok(root.snippets.length === 1 && root.snippets[0].trigger === "thanks",
                    "and nothing was overwritten on the way")
            root.ok(root.triggerField.text === "thanks",
                    "the fields followed the external edit")
            break

          case 12:
            // Layout: the notes box must not hang past its column and crowd the
            // footer. Measured in the editor's own coordinates.
            var notes = root.find(editor, "placeholderText", "What this is for, where you use it\u2026")
            var done = root.find(editor, "text", "Done")
            while (done && done.width === 0 && done.parent) done = done.parent
            root.ok(notes !== null && done !== null, "harness can reach the notes box and Done")
            if (notes && done) {
              var notesBottom = notes.mapToItem(editor, 0, notes.height).y
              var doneTop = done.mapToItem(editor, 0, 0).y
              console.log("  notes bottom=" + Math.round(notesBottom)
                + "  Done top=" + Math.round(doneTop)
                + "  gap=" + Math.round(doneTop - notesBottom))
              root.ok(doneTop > notesBottom, "Done starts below the notes box")
              root.ok(doneTop - notesBottom >= 8, "with a visible gap between them")
            }
            break

          default:
            console.log(root.failures === 0 ? "\nAll tests passed." : "\n" + root.failures + " failed.")
            Qt.exit(root.failures === 0 ? 0 : 1)
          }
        }
      }
    }
  }
}
