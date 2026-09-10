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

  readonly property var current: (selectedIndex >= 0 && selectedIndex < (snippets ? snippets.length : 0)) ? snippets[selectedIndex] : null

  function loadFields() {
    var snippet = root.current
    triggerField.text = snippet ? String(snippet.trigger || "") : ""
    bodyField.text = snippet ? String(snippet.body || "") : ""
    notesField.text = snippet ? String(snippet.notes || "") : ""
  }

  // Push the field values back into the model if any of them actually moved.
  // Returns the list the caller should keep working against.
  function commit() {
    var list = Array.isArray(root.snippets) ? root.snippets.slice() : []
    var i = root.selectedIndex
    if (i < 0 || i >= list.length) return list

    var updated = {
      trigger: triggerField.text,
      body: bodyField.text,
      notes: notesField.text
    }
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
    root.commit()
    root.selectedIndex = Math.max(0, Math.min(index, (root.snippets ? root.snippets.length : 1) - 1))
    root.loadFields()
  }

  function addSnippet() {
    var list = root.commit()
    list = Snippets.addSnippet(list, Snippets.emptySnippet())
    root._selfEditing = true
    root.changed(list)
    root._selfEditing = false
    root.selectedIndex = list.length - 1
    root.loadFields()
    Qt.callLater(function() { triggerField.forceActiveFocus() })
  }

  function requestDelete() {
    if (!root.current) return
    deleteConfirm.selectedIndex = 1
    root.deleteConfirmOpen = true
  }

  function confirmDelete() {
    var list = Snippets.removeSnippetAt(root.snippets, root.selectedIndex)
    root._selfEditing = true
    root.changed(list)
    root._selfEditing = false
    root.deleteConfirmOpen = false
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, list.length - 1))
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

  onSnippetsChanged: if (!root._selfEditing) root.loadFields()

  // Reload fields whenever the editor is shown, so reopening after an external
  // edit to snippets.json does not display stale text.
  onVisibleChanged: {
    if (!visible) return
    root.selectedIndex = Math.max(0, Math.min(root.selectedIndex, (root.snippets ? root.snippets.length : 1) - 1))
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
                model: root.snippets
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
                height: parent.height - triggerField.height - notesField.height
                        - Style.space(4) * 2 - Style.space(6) * 6
                        - Style.font.caption * 3
                placeholderText: "Thanks, Preston"
                foreground: root.foreground
                accent: root.selectedText
                KeyNavigation.tab: notesField
                KeyNavigation.backtab: triggerField
              }

              Item { width: 1; height: Style.space(4) }

              Text {
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
