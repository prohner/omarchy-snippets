// Snippet store: parse, search, and edit the snippet library that lives in
// ~/.config/omarchy/snippets.json.
//
// All snippet behavior lives here rather than in Clipboard.qml on purpose.
// Clipboard.qml is a fork of the built-in omarchy.clipboard overlay, and every
// line of logic kept out of it is a line that never conflicts when upstream
// changes. See README.md ("Staying current with upstream").
//
// On-disk shape, with a `snippets` array of objects:
//
//   { "snippets": [ { "trigger": "thanks", "body": "Thanks, Preston",
//                     "notes": "casual sign-off" } ] }
//
// A bare top-level array is accepted too, so a hand-written file that skips
// the wrapper object still loads.
//
// Bounds
// ------
// Everything below is clamped before it becomes a model row, because the file
// is ordinary user-writable JSON and nothing upstream of here promises it is
// small: it can be hand-edited, synced from another machine, or written by
// some other tool. An unbounded array of unbounded strings turns into an
// unbounded number of QML rows holding unbounded text, inside the shell
// process that draws the whole desktop.
//
// The body limit is the one with a hard reason behind it rather than a
// judgement: the body is handed to omarchy-clipboard-paste-text as a single
// argument, and Linux refuses any single argument longer than 128 KiB. A body
// over that could not be pasted at all, so it is capped at half of it — still
// far past any snippet anyone writes by hand.
var maxSnippets = 512
var maxTriggerLength = 256
var maxBodyLength = 65536
var maxNotesLength = 4096
var maxRawLength = 8388608

function clamp(value, limit) {
  var text = String(value === undefined || value === null ? "" : value)
  return text.length > limit ? text.slice(0, limit) : text
}

function normalizeSnippet(value) {
  if (typeof value === "string")
    return value.trim().length > 0 ? { trigger: "", body: clamp(value, maxBodyLength), notes: "" } : null

  if (!value || typeof value !== "object") return null

  var body = clamp(value.body !== undefined ? value.body : (value.text !== undefined ? value.text : ""), maxBodyLength)
  var trigger = clamp(value.trigger !== undefined ? value.trigger : (value.keyword !== undefined ? value.keyword : ""), maxTriggerLength)
  var notes = clamp(value.notes !== undefined ? value.notes : "", maxNotesLength)

  // A snippet with neither a trigger nor a body is an empty row someone left
  // behind in the editor, not data worth keeping.
  if (trigger.trim().length === 0 && body.length === 0) return null

  return { trigger: trigger, body: body, notes: notes }
}

function parseSnippets(raw) {
  var text = String(raw || "")
  // Checked before the trim and before JSON.parse: a parser is the wrong place
  // to discover that the input was too big to hold.
  if (text.length > maxRawLength) return []
  text = text.trim()
  if (!text) return []

  try {
    var parsed = JSON.parse(text)
    var list = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.snippets) ? parsed.snippets : [])

    var next = []
    for (var i = 0; i < list.length && next.length < maxSnippets; i++) {
      var snippet = normalizeSnippet(list[i])
      if (snippet) next.push(snippet)
    }
    return next
  } catch (e) {
    // A malformed file must not wipe the user's library. Returning [] here
    // only hides the snippets for this load; the file itself is untouched
    // until an explicit save, and Clipboard.qml surfaces the parse failure.
    return []
  }
}

function serialize(snippets) {
  var list = Array.isArray(snippets) ? snippets : []
  var clean = []
  for (var i = 0; i < list.length && clean.length < maxSnippets; i++) {
    var snippet = normalizeSnippet(list[i])
    if (snippet) clean.push(snippet)
  }
  return JSON.stringify({ snippets: clean }, null, 2) + "\n"
}

// The label shown in the picker's left column: the trigger when there is one,
// otherwise the first line of the body so an untriggered snippet is still
// recognizable.
function label(snippet) {
  if (!snippet) return ""
  var trigger = String(snippet.trigger || "").trim()
  if (trigger) return trigger
  return String(snippet.body || "").split(/\r?\n/)[0]
}

function searchableText(snippet) {
  if (!snippet) return ""
  return [String(snippet.trigger || ""), String(snippet.body || ""), String(snippet.notes || "")].join(" ")
}

// How well a snippet answers the query, highest first; -1 means no match.
//
// Plain substring matching over every field is not good enough for the flow
// this plugin exists to serve — type a trigger, press Enter. Searching notes
// means an unrelated snippet can match incidentally (a note reading "casual
// sign-off" matches "sig") and, sorted by position alone, outrank the snippet
// actually named `sig`. Whatever the user typed the exact name of has to come
// first.
function matchScore(snippet, needle) {
  if (!needle) return 0

  var trigger = String(snippet.trigger || "").toLowerCase()
  var body = String(snippet.body || "").toLowerCase()
  var notes = String(snippet.notes || "").toLowerCase()

  if (trigger && trigger === needle) return 100
  if (trigger && trigger.indexOf(needle) === 0) return 80
  if (trigger && trigger.indexOf(needle) >= 0) return 60
  if (body.indexOf(needle) >= 0) return 40
  if (notes.indexOf(needle) >= 0) return 20
  return -1
}

// Rows shaped to match ClipboardHistory.displayRows() so Clipboard.qml can
// concatenate the two lists and render them through one delegate.
function displayRows(snippets, query, limit) {
  var values = Array.isArray(snippets) ? snippets : []
  var needle = String(query || "").trim().toLowerCase()
  var max = limit === undefined || limit === null ? 50 : Number(limit)
  if (isNaN(max)) max = 50
  max = Math.max(0, max)
  if (max === 0) return []

  var scored = []

  for (var i = 0; i < values.length; i++) {
    var snippet = normalizeSnippet(values[i])
    if (!snippet) continue

    var score = matchScore(snippet, needle)
    if (score < 0) continue

    scored.push({
      score: score,
      row: {
        entryType: "snippet",
        fullText: String(snippet.body || ""),
        previewText: label(snippet),
        previewImage: "",
        path: "",
        mime: "text/plain",
        index: -1,
        snippetIndex: i,
        notes: String(snippet.notes || "")
      }
    })
  }

  // Best match first, and within one score band keep the author's own order.
  // The explicit index tiebreak does not rely on Array.sort being stable.
  scored.sort(function(a, b) {
    if (a.score !== b.score) return b.score - a.score
    return a.row.snippetIndex - b.row.snippetIndex
  })

  var rows = []
  for (var j = 0; j < scored.length && rows.length < max; j++) rows.push(scored[j].row)
  return rows
}

// Interleave the two row lists for display.
//
// With an empty query this is still a clipboard picker: history leads and
// snippets sit underneath, out of the way, so opening and pressing Enter
// pastes the most recent copy exactly as the built-in picker does. The moment
// anything is typed the intent is search, so the best-matching snippet leads.
function mergeRows(snippetRows, historyRows, query) {
  var snippets = Array.isArray(snippetRows) ? snippetRows : []
  var history = Array.isArray(historyRows) ? historyRows : []
  return String(query || "").trim() ? snippets.concat(history) : history.concat(snippets)
}

function emptySnippet() {
  return { trigger: "", body: "", notes: "" }
}

function addSnippet(snippets, snippet) {
  var next = Array.isArray(snippets) ? snippets.slice() : []
  next.push(snippet ? snippet : emptySnippet())
  return next
}

function updateSnippet(snippets, index, field, value) {
  var next = Array.isArray(snippets) ? snippets.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= next.length) return next

  // Copy before mutating: the caller holds the old array as a QML property,
  // and editing in place would not trigger a binding update.
  var updated = {
    trigger: String(next[target].trigger || ""),
    body: String(next[target].body || ""),
    notes: String(next[target].notes || "")
  }
  updated[field] = String(value === undefined || value === null ? "" : value)
  next[target] = updated
  return next
}

function removeSnippetAt(snippets, index) {
  var next = Array.isArray(snippets) ? snippets.slice() : []
  var target = Number(index)
  if (isNaN(target) || target < 0 || target >= next.length) return next
  next.splice(target, 1)
  return next
}

if (typeof module !== "undefined") {
  module.exports = {
    limits: {
      snippets: maxSnippets,
      trigger: maxTriggerLength,
      body: maxBodyLength,
      notes: maxNotesLength,
      raw: maxRawLength
    },
    normalizeSnippet: normalizeSnippet,
    parseSnippets: parseSnippets,
    serialize: serialize,
    label: label,
    searchableText: searchableText,
    displayRows: displayRows,
    mergeRows: mergeRows,
    emptySnippet: emptySnippet,
    addSnippet: addSnippet,
    updateSnippet: updateSnippet,
    removeSnippetAt: removeSnippetAt
  }
}
