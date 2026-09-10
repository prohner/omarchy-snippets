import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Multi-line sibling of qs.Ui.TextField. The kit ships only a single-line
// input, and a snippet body needs wrapping and newlines, so this mirrors
// TextField.qml's structure against Qt Quick Controls' TextArea and reuses the
// same Style / Color / Border primitives. Anything the kit restyles flows
// through here for free.
TextArea {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color selectionTint: Style.selectionFillFor(foreground, accent)
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  // Panel-cursor flag, matching TextField: when set (and not already focused)
  // the background paints the shared hover/cursor state.
  property bool hasCursor: false

  readonly property bool _focused: activeFocus
  readonly property bool _hot: hovered || hasCursor
  readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : (_hot ? "hover-cursor" : "normal"), root.foreground, root.accent)

  font.family: Style.font.family
  font.pixelSize: Style.font.body
  color: foreground
  selectionColor: selectionTint
  selectedTextColor: foreground
  placeholderTextColor: Qt.darker(foreground, 1.6)
  wrapMode: TextArea.Wrap
  selectByMouse: true

  // Tab moves between fields rather than inserting a tab character. A snippet
  // body that genuinely needs a tab is better pasted in or written in $EDITOR
  // than typed here, and losing keyboard navigation across a three-field form
  // costs more than it gains.
  KeyNavigation.priority: KeyNavigation.BeforeItem

  leftPadding: horizontalPadding + Border.left(_borderSpec)
  rightPadding: horizontalPadding + Border.right(_borderSpec)
  topPadding: verticalPadding + Border.top(_borderSpec)
  bottomPadding: verticalPadding + Border.bottom(_borderSpec)

  background: BorderSurface {
    color: Style.controlFill(root._focused, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }
}
