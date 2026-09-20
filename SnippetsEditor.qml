import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Snippets.js" as Snippets

// Master-detail snippet editor, shown in place of the picker list when the
// overlay is in edit mode.
//
//   ┌─ Snippets ─────────┬─ detail ──────────────────────┐
//   │ thanks             │ Trigger  [ thanks           ] │
//   │ sig                │ Body     [ Thanks, Preston  ] │
//   │ addr        scroll │                               │
//   │                    ├───────────────────────────────┤
//   │ [+ New] [Delete]   │ Notes    [ casual sign-off  ] │
//   └────────────────────┴───────────────────────────────┘
//
// Field text is NOT two-way bound to the model. Rewriting the snippet array on
// every keystroke would replace the array the fields are bound to and bounce
// the caret to the end of the line on every character. Instead the fields are
// loaded on selection change and committed at boundaries — switching rows,
// creating, deleting, saving, or closing.
Item {
  id: root

  property var snippets: []
  property int selectedIndex: 0

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int cornerRadius: Style.cornerRadius
  property int rowHeight: Math.max(Style.space(34), Style.font.body + Style.spacing.rowPaddingX)

  // Emitted with the full replacement list; the parent owns the array and
  // persists it.
  signal changed(var list)
  signal closed()
  signal openInExternalEditor()

  property bool deleteConfirmOpen: false

  // Guards the reload-on-model-change hook while this component is itself the
  // source of the change, so committing does not clobber the caret.
  property bool _selfEditing: false

  // A snippet being created lives here, not in the file, until it holds
  // something the file would keep. A row with no trigger and no body is
  // dropped on serialize, so writing a blank one and reading it back deletes
  // it — and used to take the open form down with it a second later, when the
  // watcher reported our own write.
  property var _draft: null

  // What the editor shows: the saved snippets, plus the unsaved draft on the
  // end. Only `snippets` is ever written.
  //
  // These are functions, and the properties below are bindings onto them,
  // because a handler for snippetsChanged can run before a binding that
  // derives from `snippets` has been re-evaluated. Imperative code reading
  // such a binding gets the previous value — which here meant loading the
  // fields from a stale list, blanking them, and then committing the blanks
  // over a real snippet. Called as functions they are always current, and the
  // bindings still track their dependencies, since QML captures whatever a
  // binding reads while it runs, including inside a function it calls.
  function persistedCount() {
    return Array.isArray(root.snippets) ? root.snippets.length : 0
  }

  function rowList() {
    var list = Array.isArray(root.snippets) ? root.snippets : []
    return root._draft ? list.concat([root._draft]) : list
  }

  function rowAt(index) {
    var list = root.rowList()
    return (index >= 0 && index < list.length) ? list[index] : null
  }

  function draftIsSelected() {
    return root._draft !== null && root.selectedIndex === root.persistedCount()
  }

  readonly property var rows: root.rowList()
  readonly property int draftIndex: root._draft ? root.persistedCount() : -1
  readonly property bool draftSelected: root.draftIsSelected()
  readonly property var current: root.rowAt(root.selectedIndex)

  function loadFields() {
    var snippet = root.rowAt(root.selectedIndex)
    triggerField.text = snippet ? String(snippet.trigger || "") : ""
    bodyField.text = snippet ? String(snippet.body || "") : ""
    notesField.text = snippet ? String(snippet.notes || "") : ""
  }

  // Push the field values back into the model if any of them actually moved.
  // Returns the list the caller should keep working against.
  function commit() {
    var list = Array.isArray(root.snippets) ? root.snippets.slice() : []
    var updated = {
      trigger: triggerField.text,
      body: bodyField.text,
      notes: notesField.text
    }

    if (root.draftIsSelected()) {
      // Still nothing the file would keep, so it stays a draft. Notes alone
      // does not count: serialize drops a row with no trigger and no body
      // whatever is in its notes.
      if (updated.trigger.trim().length === 0 && updated.body.length === 0) {
        root._draft = updated
        return list
      }
      list.push(updated)
      root._draft = null
      root._selfEditing = true
      root.changed(list)
      root._selfEditing = false
      return list
    }

    var i = root.selectedIndex
    if (i < 0 || i >= list.length) return list

    var currentSnippet = list[i]
    if (String(currentSnippet.trigger || "") === updated.trigger
        && String(currentSnippet.body || "") === updated.body
        && String(currentSnippet.notes || "") === updated.notes)
      return list

    list[i] = updated
    root._selfEditing = true
    root.changed(list)
    root._selfEditing = false
    return list
  }

  function selectSnippet(index) {
    if (index === root.selectedIndex) return
    var leavingDraft = root.draftIsSelected()
    root.commit()
    // An untouched draft is abandoned by clicking away from it; a filled one
    // was just promoted into the list by commit() and is no longer a draft.
    if (leavingDraft && root._draft) root._draft = null
    root.selectedIndex = Math.max(0, Math.min(index, root.rowList().length - 1))
    root.loadFields()
  }

  function addSnippet() {
    root.commit()
    // Ctrl+N on an already-blank draft keeps the one that is open rather than
    // stacking another blank row behind it.
    if (!root._draft) root._draft = Snippets.emptySnippet()
    root.selectedIndex = root.rowList().length - 1
    root.loadFields()
    Qt.callLater(function() { triggerField.forceActiveFocus() })
  }

  function requestDelete() {
    if (!root.rowAt(root.selectedIndex)) return
    // An unsaved draft has nothing to confirm and nothing to lose.
    if (root.draftIsSelected()) {
      root._draft = null
      root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.rowList().length - 1))
      root.loadFields()
      Qt.callLater(function() { editorKeys.forceActiveFocus() })
      return
    }
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function confirmDelete() {
    var list = Snippets.removeSnippetAt(root.snippets, root.selectedIndex)
    root._selfEditing = true
    root.changed(list)
    root._selfEditing = false
    root.deleteConfirmOpen = false
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.rowList().length - 1))
    root.loadFields()
    Qt.callLater(function() { editorKeys.forceActiveFocus() })
  }

  function cancelDelete() {
    root.deleteConfirmOpen = false
    Qt.callLater(function() { editorKeys.forceActiveFocus() })
  }

  function close() {
    root.commit()
    root.closed()
  }

  // An external edit can shorten the library under a selection, so the index
  // is clamped before the fields are read through it.
  onSnippetsChanged: {
    if (root._selfEditing) return
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.rowList().length - 1))
    root.loadFields()
  }

  // Reload fields whenever the editor is shown, so reopening after an external
  // edit to snippets.json does not display stale text.
  onVisibleChanged: {
    if (!visible) {
      // Nothing carries an abandoned blank row over to the next time the
      // editor is opened.
      root._draft = null
      return
    }
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, root.rowList().length - 1))
    root.loadFields()
    Qt.callLater(function() { editorKeys.forceActiveFocus() })
  }

  FocusScope {
    id: editorKeys
    anchors.fill: parent
    focus: root.visible

    Keys.onPressed: function(event) {
      if (root.deleteConfirmOpen) {
        if (deleteConfirm.handleKey(event)) event.accepted = true
        return
      }

      if (event.key === Qt.Key_Escape) {
        root.close()
        event.accepted = true
      } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_S) {
        root.commit()
        event.accepted = true
      } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
        root.addSnippet()
        event.accepted = true
      }
    }

    Column {
      anchors.fill: parent
      spacing: root.contentMargin

      // ---- header -------------------------------------------------------
      Item {
        width: parent.width
        height: headerText.implicitHeight

        Text {
          id: headerText
          textFormat: Text.PlainText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "Edit snippets"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.heading
        }

        Text {
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "Esc back · Ctrl+N new · Ctrl+S save"
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- body: list | detail -------------------------------------------
      Item {
        width: parent.width
        height: parent.height - headerText.implicitHeight - footer.height - root.contentMargin * 2

        Row {
          anchors.fill: parent
          spacing: 0

          // ---- left: scrolling snippet list -----------------------------
          Item {
            width: Math.round(parent.width * 0.34)
            height: parent.height

            Column {
              anchors.fill: parent
              anchors.rightMargin: root.contentMargin
              spacing: Style.space(8)

              ListView {
                id: snippetList
                width: parent.width
                height: parent.height - newRow.height - Style.space(8)
                model: root.rows
                clip: true
                spacing: Style.space(2)
                boundsBehavior: Flickable.StopAtBounds
                currentIndex: root.selectedIndex

                delegate: Rectangle {
                  id: listRow
                  required property int index
                  required property var modelData

                  readonly property bool isCurrent: index === root.selectedIndex

                  width: ListView.view.width
                  height: root.rowHeight
                  radius: root.cornerRadius
                  color: isCurrent ? root.selectedBackground : "transparent"

                  Text {
                    textFormat: Text.PlainText
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    text: Snippets.label(listRow.modelData) || "(untitled)"
                    color: listRow.isCurrent ? root.selectedText : root.foreground
                    opacity: Snippets.label(listRow.modelData) ? 1.0 : 0.5
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                    verticalAlignment: Text.AlignVCenter
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectSnippet(listRow.index)
                  }
                }
              }

              Row {
                id: newRow
                width: parent.width
                spacing: Style.space(6)

                Button {
                  text: "+ New"
                  bordered: true
                  foreground: root.foreground
                  accent: root.selectedText
                  fontFamily: root.fontFamily
                  onClicked: root.addSnippet()
                }

                Button {
                  text: "Delete"
                  bordered: true
                  foreground: root.foreground
                  accent: root.selectedText
                  fontFamily: root.fontFamily
                  onClicked: root.requestDelete()
                }
              }
            }
          }

          // ---- right: detail --------------------------------------------
          Item {
            width: parent.width - Math.round(parent.width * 0.34)
            height: parent.height

            Rectangle {
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Style.normalBorderWidth
              color: Util.alpha(root.border, 0.28)
            }

            Column {
              anchors.fill: parent
              anchors.leftMargin: root.contentMargin
              spacing: Style.space(6)
              visible: root.current !== null

              Text {
                id: triggerCaption
                textFormat: Text.PlainText
                text: "Trigger"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              TextField {
                id: triggerField
                width: parent.width
                placeholderText: "thanks"
                foreground: root.foreground
                accent: root.selectedText
                onEditingFinished: root.commit()
                KeyNavigation.tab: bodyField
              }

              Item { width: 1; height: Style.space(4) }

              Text {
                id: bodyCaption
                textFormat: Text.PlainText
                text: "Body"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              SnippetTextArea {
                id: bodyField
                width: parent.width
                // Body takes the slack; notes keeps a fixed, smaller box.
                //
                // Measured from what the siblings actually are, because
                // guessing overran the column: this counted six Column gaps
                // where eight children make seven, and took a caption to be
                // Style.font.caption tall when a Text is a line height tall.
                // The notes box then hung past the bottom and swallowed the
                // margin the footer sits in, leaving Done against its edge.
                height: parent.height - triggerCaption.implicitHeight - triggerField.height
                        - bodyCaption.implicitHeight - notesCaption.implicitHeight
                        - notesField.height
                        - Style.space(4) * 2 - Style.space(6) * 7
                placeholderText: "Thanks, Preston"
                foreground: root.foreground
                accent: root.selectedText
                KeyNavigation.tab: notesField
                KeyNavigation.backtab: triggerField
              }

              Item { width: 1; height: Style.space(4) }

              Text {
                id: notesCaption
                textFormat: Text.PlainText
                text: "Notes"
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              SnippetTextArea {
                id: notesField
                width: parent.width
                height: root.rowHeight * 2
                placeholderText: "What this is for, where you use it…"
                foreground: root.foreground
                accent: root.selectedText
                KeyNavigation.backtab: bodyField
              }
            }

            // Empty state, shown when the library has no snippets at all.
            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)
              visible: root.current === null

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
                text: "No snippets yet — press Ctrl+N"
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

      // ---- footer ---------------------------------------------------------
      Item {
        id: footer
        width: parent.width
        height: doneButton.implicitHeight

        Button {
          text: "Open snippets.json in $EDITOR"
          bordered: true
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          foreground: root.foreground
          accent: root.selectedText
          fontFamily: root.fontFamily
          onClicked: {
            root.commit()
            root.openInExternalEditor()
          }
        }

        Button {
          id: doneButton
          text: "Done"
          bordered: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          foreground: root.foreground
          accent: root.selectedText
          fontFamily: root.fontFamily
          onClicked: root.close()
        }
      }
    }

    ConfirmDialog {
      id: deleteConfirm

      anchors.fill: parent
      opened: root.deleteConfirmOpen
      z: 10
      message: "Delete snippet “" + (root.current ? (Snippets.label(root.current) || "untitled") : "") + "”?"
      confirmText: "Delete"
      background: root.background
      foreground: root.foreground
      scrim: Color.menu.scrim
      selectedBackground: root.selectedBackground
      selectedText: root.selectedText
      fontFamily: root.fontFamily
      cornerRadius: root.cornerRadius
      onCanceled: root.cancelDelete()
      onConfirmed: root.confirmDelete()
    }
  }
}
