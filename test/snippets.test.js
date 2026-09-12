// Plain-node tests for Snippets.js — no framework, no dependencies.
//
//   node test/snippets.test.js
//
// Snippets.js is deliberately free of QML imports so the search ranking and
// the file parsing can be tested without starting a shell. The ranking is the
// part most worth guarding: the whole plugin exists so that typing a trigger
// and pressing Enter pastes that snippet, and a naive substring search breaks
// exactly that (a snippet whose notes read "casual sign-off" matches "sig"
// and, ordered by position, outranks the snippet actually named `sig`).

var S = require("../Snippets.js")

var failures = 0

function eq(actual, expected, label) {
  var ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures++
  console.log((ok ? "PASS  " : "FAIL  ") + label + " -> " + JSON.stringify(actual))
  if (!ok) console.log("      expected " + JSON.stringify(expected))
}

var lib = [
  { trigger: "thanks", body: "Thanks, Preston", notes: "Casual sign-off for internal mail and chat." },
  { trigger: "sig", body: "Preston Rohner\nx@y.com", notes: "Full signature." },
  { trigger: "shrug", body: "shruggie", notes: "" },
  { trigger: "signature-long", body: "long one", notes: "" }
]

function names(query) {
  return S.displayRows(lib, query, 50).map(function(row) { return row.previewText })
}

// --- ranking ---------------------------------------------------------------
eq(names("sig"), ["sig", "signature-long", "thanks"], "exact trigger beats prefix and notes")
eq(names("thanks"), ["thanks"], "exact trigger match")
eq(names("sign"), ["signature-long", "thanks", "sig"], "prefix beats notes; notes tie keeps author order")
eq(names("SIG"), ["sig", "signature-long", "thanks"], "query is case-insensitive")
eq(names("Preston"), ["thanks", "sig"], "body ties keep author order")
eq(names(""), ["thanks", "sig", "shrug", "signature-long"], "empty query keeps author order")
eq(names("ZZZ"), [], "no match yields no rows")
eq(S.displayRows(lib, "", 2).length, 2, "limit is respected")

// --- row shape -------------------------------------------------------------
var row = S.displayRows(lib, "sig", 1)[0]
eq(row.entryType, "snippet", "rows are tagged as snippets")
eq(row.index, -1, "snippet rows carry no history index")
eq(row.snippetIndex, 1, "snippet rows point back at their library position")
eq(row.fullText, "Preston Rohner\nx@y.com", "body survives verbatim, newlines included")

// --- parsing ---------------------------------------------------------------
eq(S.parseSnippets("{bad json").length, 0, "malformed file yields an empty library")
eq(S.parseSnippets("").length, 0, "missing file yields an empty library")
eq(S.parseSnippets(JSON.stringify([{ trigger: "a", body: "b" }])).length, 1, "bare top-level array is accepted")
eq(S.parseSnippets(JSON.stringify({ snippets: [{ trigger: "", body: "" }, { trigger: "k", body: "v" }] })).length, 1,
   "rows with neither trigger nor body are dropped")

// --- labels ----------------------------------------------------------------
eq(S.label({ trigger: "t", body: "b" }), "t", "trigger is the label when present")
eq(S.label({ trigger: "", body: "first line\nsecond" }), "first line", "untriggered falls back to the first body line")

// --- editing ---------------------------------------------------------------
var edited = S.updateSnippet(lib, 0, "body", "changed")
eq(edited[0].body, "changed", "updateSnippet writes the field")
eq(lib[0].body, "Thanks, Preston", "updateSnippet does not mutate the input array")
eq(S.removeSnippetAt(lib, 0).length, lib.length - 1, "removeSnippetAt drops one row")
eq(S.removeSnippetAt(lib, 99).length, lib.length, "removeSnippetAt ignores an out-of-range index")
eq(S.addSnippet(lib, S.emptySnippet()).length, lib.length + 1, "addSnippet appends")

// --- serialization ---------------------------------------------------------
eq(S.parseSnippets(S.serialize(lib)).length, lib.length, "serialize round-trips through parse")
eq(S.serialize([{ trigger: "t", body: "a\nb", notes: "" }]).indexOf("\\n") > 0, true, "newlines are escaped, not literal")


// --- merge order ------------------------------------------------------------
// With an empty box the picker stays a clipboard picker: history leads and
// snippets sit underneath, out of the way. Typing flips it, because then the
// user is searching and the best-matching snippet should lead.
var snips = [{ id: "s1" }, { id: "s2" }]
var hist = [{ id: "h1" }, { id: "h2" }]
var ids = function(rows) { return rows.map(function(r) { return r.id }) }

eq(ids(S.mergeRows(snips, hist, "")), ["h1", "h2", "s1", "s2"], "empty query puts history first")
eq(ids(S.mergeRows(snips, hist, "   ")), ["h1", "h2", "s1", "s2"], "whitespace-only query counts as empty")
eq(ids(S.mergeRows(snips, hist, "x")), ["s1", "s2", "h1", "h2"], "a query puts snippets first")
eq(ids(S.mergeRows([], hist, "")), ["h1", "h2"], "no snippets is fine")
eq(ids(S.mergeRows(snips, [], "x")), ["s1", "s2"], "no history is fine")
eq(ids(S.mergeRows(null, null, "")), [], "null inputs are tolerated")


// --- bounds ------------------------------------------------------------------
// Both JSON files are ordinary user-writable files under $HOME. Nothing that
// reaches these parsers has promised to be small, and what they return goes
// straight into QML models inside the process drawing the whole desktop, so
// every array and every string is clamped on the way through. New clipboard
// entries are already capped by bin/omarchy-snippets-helper before the shell
// sees them; these limits are what catches a file written before that, or by
// something else entirely.
var H = require("../ClipboardHistory.js")

function repeat(character, count) { return new Array(count + 1).join(character) }

var tooMany = { snippets: [] }
for (var n = 0; n < S.limits.snippets + 200; n++) tooMany.snippets.push({ trigger: "t" + n, body: "b" })
eq(S.parseSnippets(JSON.stringify(tooMany)).length, S.limits.snippets, "snippet count is capped")

var oversized = S.parseSnippets(JSON.stringify({ snippets: [{
  trigger: repeat("t", S.limits.trigger + 500),
  body: repeat("b", S.limits.body + 500),
  notes: repeat("n", S.limits.notes + 500)
}] }))[0]
eq(oversized.trigger.length, S.limits.trigger, "trigger length is capped")
eq(oversized.body.length, S.limits.body, "body length is capped")
eq(oversized.notes.length, S.limits.notes, "notes length is capped")

// The body cap is not a taste judgement: the body is handed to
// omarchy-clipboard-paste-text as one argument, and Linux refuses any single
// argument longer than 128 KiB, so a body above that could not be pasted.
eq(S.limits.body <= 131072, true, "a capped body still fits in one exec argument")

eq(S.parseSnippets("[" + repeat(" ", S.limits.raw) + "]").length, 0,
   "a file past the raw size cap is refused without being parsed")
// Serializing is the other direction over the same cap: a library that arrived
// oversized must not be written back oversized.
eq(S.parseSnippets(S.serialize(tooMany.snippets)).length, S.limits.snippets,
   "serialize writes back no more snippets than the cap allows")

var longHistory = []
for (var h = 0; h < H.limits.entries + 200; h++) longHistory.push({ type: "text", text: "e" + h })
eq(H.parseHistory(JSON.stringify(longHistory)).length, H.limits.entries, "history entry count is capped")
eq(H.normalizeEntry({ type: "text", text: repeat("x", H.limits.text + 500) }).text.length, H.limits.text,
   "history entry text is capped")

var bigImage = H.normalizeEntry({
  type: "image",
  path: repeat("p", H.limits.path + 500),
  mime: repeat("m", H.limits.mime + 500),
  capturedAt: repeat("c", 500)
})
eq(bigImage.path.length, H.limits.path, "image path is capped")
eq(bigImage.mime.length, H.limits.mime, "image mime is capped")
eq(H.parseHistory("[" + repeat(" ", H.limits.raw) + "]").length, 0,
   "a history file past the raw size cap is refused without being parsed")

// Clamping must not turn a valid entry into a dropped one.
eq(H.normalizeEntry({ type: "text", text: repeat("x", H.limits.text + 10) }).type, "text",
   "an oversized entry is shortened, not discarded")
eq(S.parseSnippets(JSON.stringify({ snippets: [{ trigger: "keep", body: repeat("b", S.limits.body + 10) }] }))[0].trigger,
   "keep", "an oversized snippet is shortened, not discarded")

console.log(failures === 0 ? "\nAll tests passed." : "\n" + failures + " test(s) failed.")
process.exit(failures === 0 ? 0 : 1)
