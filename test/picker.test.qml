import QtQuick
import Quickshell
import "plugin" as P

// Tests for the calculator inside the real Clipboard.qml.
//
//   test/picker.test.sh
//
// Calculator.js is tested in plain node; this is for the part node cannot
// reach — that the picker actually builds the answer row, puts it where it
// belongs, continues a calculation on `=`, and hands the answer to the helper
// to paste or copy rather than doing anything else with it.
//
// The plugin here is a copy whose bin/omarchy-snippets-helper is a stub (see
// picker.test.sh). The stub feeds the watchers a fixed snippet library, and
// every paste or copy the picker asks for is written to a log instead of
// reaching your clipboard or being typed into whatever window has focus.
// picker.test.sh reads that log after this exits.
ShellRoot {
  P.Clipboard { id: plugin }

  Item {
    id: root
    property int step: 0
    property int failures: 0

    function ok(cond, label) {
      if (!cond) root.failures++
      console.log((cond ? "PASS  " : "FAIL  ") + label)
    }

    function row(i) {
      var r = plugin.rowAt(i)
      return r ? r.entryType + ":" + r.fullText : "none"
    }

    function calcRows() {
      var n = 0
      for (var i = 0; i < plugin.displayCount(); i++) if (plugin.rowAt(i).entryType === "calc") n++
      return n
    }

    Timer {
      // The first tick waits for the stub's watchers to deliver the library.
      interval: root.step === 0 ? 1500 : 200
      running: true
      repeat: true
      onTriggered: {
        root.step++
        // A step that throws would otherwise just stop short, silently.
        try { root.runStep() } catch (e) { root.ok(false, "step " + root.step + " threw: " + e) }
      }
    }

    function runStep() {
      switch (root.step) {
      case 1:
        root.ok(plugin.snippets.length === 1, "the stub delivered the snippet library")
        plugin.setFilter("2+2")
        root.ok(root.row(0) === "calc:4", "an answer is the first row (" + root.row(0) + ")")
        root.ok(plugin.rowAt(0).expression === "2+2", "and carries its expression")
        root.ok(plugin.rowAt(0).help.indexOf("Start with =") >= 0, "and a pointer to the = functions")
        plugin.setFilter("1234567*2")
        var group = plugin.calcOptions.groupMark
        root.ok(root.row(0) === "calc:2469134", "the answer pasted is ungrouped")
        root.ok(plugin.rowAt(0) !== null && plugin.rowAt(0).display === "2" + group + "469" + group + "134",
                "the answer shown is grouped in the locale")
        break

      case 2:
        plugin.setFilter("1+1")
        root.ok(root.row(0) === "snippet:one plus one" && root.row(1) === "calc:2",
                "an exact trigger keeps first place (" + root.row(0) + ", " + root.row(1) + ")")
        break

      case 3:
        plugin.setFilter("hello")
        root.ok(root.calcRows() === 0, "a search grows no answer")
        root.ok(!plugin.continueCalculation() && plugin.filterText === "hello",
                "= after a search does nothing but get typed")
        plugin.setFilter("2026")
        root.ok(root.calcRows() === 0, "a bare number grows no answer")
        break

      case 4:
        plugin.setFilter("2+2")
        root.ok(plugin.continueCalculation() && plugin.filterText === "4", "= replaces the sum with its answer")
        plugin.setFilter(plugin.filterText + "*3")
        root.ok(root.row(0) === "calc:12", "and the next operator carries on from it")
        plugin.setFilter("=sqrt(16)")
        root.ok(root.row(0) === "calc:4", "advanced mode answers")
        root.ok(plugin.rowAt(0).help.indexOf("atanh") >= 0, "and carries the full function reference")
        root.ok(plugin.continueCalculation() && plugin.filterText === "=4", "= keeps the advanced prefix")
        break

      case 5:
        var expected = Quickshell.env("EXPECT_DECIMAL") || "."
        root.ok(plugin.calcOptions.decimalMark === expected,
                "the locale's decimal mark is used (" + plugin.calcOptions.decimalMark + ")")
        plugin.setFilter("10/4")
        root.ok(root.row(0) === "calc:2" + expected + "5", "answers are written in the locale (" + root.row(0) + ")")
        break

      case 6:
        plugin.setFilter("6*7")
        var before = plugin.displayCount()
        plugin.removeDisplayIndex(0)
        root.ok(plugin.displayCount() === before && root.row(0) === "calc:42", "Delete leaves an answer alone")
        plugin.openIndex(0)
        plugin.copyIndex(0)
        break

      case 7:
        plugin.setFilter("6*7")
        plugin.activateIndex(0)
        break

      case 8:
        plugin.setFilter("hello")
        root.ok(!plugin.copyFormula(), "Ctrl+C during a search copies nothing")
        plugin.setFilter("=sqrt(16) * 3")
        root.ok(plugin.copyFormula(), "Ctrl+C copies the formula")
        break

      case 12:
        // Leave the detached stub time to write its log.
        console.log(root.failures === 0 ? "\nAll tests passed." : "\n" + root.failures + " failed.")
        Qt.exit(root.failures === 0 ? 0 : 1)
      }
    }
  }
}
