// Inline calculator for the clipboard picker, after Alfred's.
//
// Type arithmetic into the search box and the answer is the first row: Enter
// pastes it, Shift+Enter copies it, and typing `=` after the expression
// replaces the expression with its answer so the calculation can carry on.
//
// Like Snippets.js, everything here is plain JavaScript with no QML imports,
// so it is tested in node (test/calculator.test.js) and kept out of
// Clipboard.qml, which is a fork of the upstream overlay.
//
// Two modes, as in Alfred:
//
//   standard   2+2, 1,299.99 * 3, (4 - 1) ^ 2, $120 - 15%
//              Needs at least one operator between two numbers, so a search
//              for "42" or "2026" is still a search. `%` is a percentage:
//              `a + b%` and `a - b%` add or take off b percent of a, and
//              anywhere else `b%` is b/100. (Alfred's own calculator rejects
//              `%` here; this is what its users keep asking it to do.)
//
//   advanced   =sqrt(2), =sin(dtor(30)), =17 % 5, =pi
//              A leading `=` turns on the functions and constants below, and
//              makes `%` modulo, exactly as Alfred's does. Any valid
//              expression answers, a lone constant included.
//
// Currency symbols are skipped, so figures pasted from a web page or a
// spreadsheet work as they are. Numbers follow the locale Clipboard.qml passes
// in: with a decimal comma, "1.234,5" is one thousand two hundred and
// thirty-four and a half. A group separator is only accepted where it
// actually groups thousands; "1,23" is an error rather than a guess.
//
// Why a parser and not eval()
// ---------------------------
// This runs inside the process that draws the desktop, on every keystroke, on
// whatever text is in the search box, and that text can be pasted. eval() or
// Function() would make the search box a way to run JavaScript in the shell.
// Nothing here can do anything but arithmetic: the grammar has numbers,
// operators, parentheses, and a fixed table of Math functions, and the input
// length and nesting depth are capped so that no query can make it do much of
// that either.
var maxInputLength = 256
var maxDepth = 32

// Enough digits to hide binary floating-point noise (0.1 + 0.2 is 0.3, not
// 0.30000000000000004), and no more: a double carries 15 to 17.
var precision = 15

var currencySymbols = "$€£¥₹₩₽₺₪฿₫¢₱₴₦₿"

// Alfred's advanced function list, less `near` (undocumented) and with `cbrt`.
// Trigonometry is in radians; dtor and rtod convert.
var functions = {
  sin: Math.sin, cos: Math.cos, tan: Math.tan,
  asin: Math.asin, acos: Math.acos, atan: Math.atan,
  sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
  asinh: Math.asinh, acosh: Math.acosh, atanh: Math.atanh,
  log: Math.log10, log2: Math.log2, ln: Math.log, exp: Math.exp,
  abs: Math.abs, sqrt: Math.sqrt, cbrt: Math.cbrt,
  ceil: Math.ceil, floor: Math.floor, round: Math.round, trunc: Math.trunc,
  rint: roundHalfEven,
  dtor: function(x) { return x * Math.PI / 180 },
  rtod: function(x) { return x * 180 / Math.PI }
}

var constants = { pi: Math.PI, "π": Math.PI, e: Math.E }

function roundHalfEven(x) {
  var r = Math.round(x)
  // Math.round sends every .5 up; rint sends it to the even neighbour.
  return Math.abs(x % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r
}

// { decimalMark, groupMark } from whatever the caller passes, falling back to
// "." and "," for anything unusable — a mark that is empty, longer than one
// character, a digit, an operator, or the same as the other mark.
function normalizeOptions(options) {
  var o = options || {}
  var bad = /[0-9+\-*\/^%()=a-zA-Z]/
  var decimal = typeof o.decimalMark === "string" && o.decimalMark.length === 1 && !bad.test(o.decimalMark) ? o.decimalMark : "."
  var group = typeof o.groupMark === "string" && o.groupMark.length === 1 && !bad.test(o.groupMark) ? o.groupMark : (decimal === "," ? "." : ",")
  if (group === decimal) group = decimal === "," ? "." : ","
  return { decimalMark: decimal, groupMark: group }
}

function escapeRegExp(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

// ---------------------------------------------------------------------------
// Tokens: { t: "num", v } | { t: "op", v } | { t: "id", v }. Returns null on
// anything that is not part of the grammar.
function tokenize(src, opts) {
  var d = escapeRegExp(opts.decimalMark)
  var g = escapeRegExp(opts.groupMark)
  // Grouped first, so "1,234" is one number rather than an error at the comma.
  var grouped = new RegExp("^\\d{1,3}(?:" + g + "\\d{3})+(?:" + d + "\\d+)?")
  var plain = new RegExp("^(?:\\d+(?:" + d + "\\d*)?|" + d + "\\d+)")
  var exponent = /^[eE][+-]?\d+/
  var ident = /^[a-zA-Zπ][a-zA-Z0-9]*/

  var tokens = []
  var i = 0
  while (i < src.length) {
    var c = src.charAt(i)
    var rest = src.substring(i)

    if (/\s/.test(c) || currencySymbols.indexOf(c) >= 0) { i++; continue }

    var m = rest.match(grouped) || rest.match(plain)
    if (m) {
      var text = m[0]
      var e = rest.substring(text.length).match(exponent)
      if (e) text += e[0]
      var normalized = text.split(opts.groupMark).join("").split(opts.decimalMark).join(".")
      if (normalized.charAt(normalized.length - 1) === ".") normalized = normalized.slice(0, -1)
      tokens.push({ t: "num", v: Number(normalized) })
      i += text.length
      continue
    }

    m = rest.match(ident)
    if (m) {
      tokens.push({ t: "id", v: m[0].toLowerCase() })
      i += m[0].length
      continue
    }

    if (rest.indexOf("**") === 0) { tokens.push({ t: "op", v: "^" }); i += 2; continue }
    if (c === "×" || c === "·" || c === "⋅") c = "*"
    else if (c === "÷") c = "/"
    else if (c === "−") c = "-"
    if ("+-*/^%()".indexOf(c) >= 0) { tokens.push({ t: "op", v: c }); i++; continue }

    return null
  }
  return tokens
}

// ---------------------------------------------------------------------------
// Recursive descent, lowest precedence first:
//
//   expr    := term (("+" | "-") term)*
//   term    := unary (("*" | "/" | "%"[advanced]) unary)*
//   unary   := ("+" | "-") unary | power
//   power   := postfix ("^" unary)?            right-associative
//   postfix := primary ("%"[standard])*
//   primary := number | "(" expr ")" | constant | function "(" expr ")"
//
// Unary minus binds looser than ^, so -2^2 is -4, as in written maths.
//
// Every level returns { v, pct }: pct is true when the value came from a bare
// `b%`, which is what lets expr() read `a + b%` as "a plus b percent of a"
// while `a * b%` stays a times b/100.
function Parser(tokens, advanced) {
  this.tokens = tokens
  this.pos = 0
  this.depth = 0
  this.advanced = advanced
  this.binaryOps = 0
}

Parser.prototype.peek = function() {
  return this.pos < this.tokens.length ? this.tokens[this.pos] : null
}

Parser.prototype.isOp = function(v) {
  var tok = this.peek()
  return tok !== null && tok.t === "op" && tok.v === v
}

Parser.prototype.fail = function() {
  throw new Error("syntax")
}

Parser.prototype.expr = function() {
  var left = this.term()
  while (this.isOp("+") || this.isOp("-")) {
    var op = this.tokens[this.pos++].v
    var right = this.term()
    this.binaryOps++
    var amount = right.pct ? left.v * right.v : right.v
    left = { v: op === "+" ? left.v + amount : left.v - amount, pct: false }
  }
  return left
}

Parser.prototype.term = function() {
  var left = this.unary()
  while (this.isOp("*") || this.isOp("/") || (this.advanced && this.isOp("%"))) {
    var op = this.tokens[this.pos++].v
    var right = this.unary()
    this.binaryOps++
    var v = op === "*" ? left.v * right.v : op === "/" ? left.v / right.v : left.v % right.v
    left = { v: v, pct: false }
  }
  return left
}

Parser.prototype.unary = function() {
  if (this.isOp("-") || this.isOp("+")) {
    var negate = this.tokens[this.pos++].v === "-"
    this.enter()
    var operand = this.unary()
    this.depth--
    return { v: negate ? -operand.v : operand.v, pct: operand.pct }
  }
  return this.power()
}

Parser.prototype.power = function() {
  var base = this.postfix()
  if (this.isOp("^")) {
    this.pos++
    this.enter()
    var exponent = this.unary()
    this.depth--
    this.binaryOps++
    return { v: Math.pow(base.v, exponent.v), pct: false }
  }
  return base
}

Parser.prototype.postfix = function() {
  var value = this.primary()
  while (!this.advanced && this.isOp("%")) {
    this.pos++
    value = { v: value.v / 100, pct: true }
  }
  return value
}

Parser.prototype.primary = function() {
  var tok = this.peek()
  if (tok === null) this.fail()

  if (tok.t === "num") {
    this.pos++
    return { v: tok.v, pct: false }
  }

  if (tok.t === "op" && tok.v === "(") {
    this.pos++
    var inner = this.group()
    return { v: inner, pct: false }
  }

  if (tok.t === "id" && this.advanced) {
    this.pos++
    if (Object.prototype.hasOwnProperty.call(constants, tok.v)) return { v: constants[tok.v], pct: false }
    if (Object.prototype.hasOwnProperty.call(functions, tok.v) && this.isOp("(")) {
      this.pos++
      return { v: functions[tok.v](this.group()), pct: false }
    }
  }

  this.fail()
}

// The inside of a parenthesis, the opening one already consumed.
Parser.prototype.group = function() {
  this.enter()
  var inner = this.expr().v
  this.depth--
  if (!this.isOp(")")) this.fail()
  this.pos++
  return inner
}

Parser.prototype.enter = function() {
  if (++this.depth > maxDepth) this.fail()
}

// ---------------------------------------------------------------------------
// The answer to a search-box query, or null when it is not a calculation.
//
//   { mode: "standard" | "advanced", expression, value, text, display }
//
// `text` is what gets pasted and what `=` puts back in the box: no grouping,
// the locale's decimal mark. `display` is the same number grouped for reading.
function evaluate(query, options) {
  var raw = String(query === undefined || query === null ? "" : query)
  if (raw.length > maxInputLength) return null

  var opts = normalizeOptions(options)
  var src = raw.trim()
  var advanced = src.charAt(0) === "="
  if (advanced) src = src.substring(1).trim()
  if (!src) return null

  var tokens = tokenize(src, opts)
  if (!tokens || tokens.length === 0) return null

  var parser = new Parser(tokens, advanced)
  var result
  try {
    result = parser.expr()
  } catch (e) {
    return null
  }
  if (parser.pos !== tokens.length) return null
  if (!advanced && parser.binaryOps === 0) return null
  if (typeof result.v !== "number" || !isFinite(result.v)) return null

  return {
    mode: advanced ? "advanced" : "standard",
    expression: src,
    value: result.v,
    text: formatNumber(result.v, opts),
    display: formatGrouped(result.v, opts)
  }
}

function round(value) {
  var v = Number(value.toPrecision(precision))
  return v === 0 ? 0 : v // no "-0"
}

function formatNumber(value, options) {
  var opts = normalizeOptions(options)
  return String(round(value)).replace(".", opts.decimalMark)
}

// Grouped for the preview pane. Exponent notation is left alone: grouping the
// mantissa of 1.5e+21 would only make it harder to read.
function formatGrouped(value, options) {
  var opts = normalizeOptions(options)
  var text = String(round(value))
  if (/e/i.test(text)) return text.replace(".", opts.decimalMark)
  var negative = text.charAt(0) === "-"
  if (negative) text = text.substring(1)
  var parts = text.split(".")
  var whole = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, opts.groupMark)
  return (negative ? "-" : "") + whole + (parts.length > 1 ? opts.decimalMark + parts[1] : "")
}

// What the search box becomes when `=` is typed after a calculation, or null
// when the box does not hold one (and `=` should just be typed). The advanced
// prefix is kept, so a run of `=` steps stays in the mode it started in.
function continued(query, options) {
  var result = evaluate(query, options)
  if (!result) return null
  return (result.mode === "advanced" ? "=" : "") + result.text
}

// A picker row, shaped like the rows Snippets.js and ClipboardHistory.js build
// so that one delegate draws all three.
function displayRow(result) {
  return {
    entryType: "calc",
    fullText: result.text,
    previewText: result.text,
    previewImage: "",
    path: "",
    mime: "text/plain",
    index: -1,
    snippetIndex: -1,
    notes: "",
    expression: result.expression,
    display: result.display
  }
}

// Put the answer on top of the merged rows. Typing an expression means you
// want its answer — with one exception, because the snippet README promises
// that an exact trigger always wins: if a snippet is literally named what was
// typed, it keeps first place and the answer is second.
function withResult(rows, query, options) {
  var list = Array.isArray(rows) ? rows : []
  var result = evaluate(query, options)
  if (!result) return list
  var row = displayRow(result)
  if (list.length > 0 && list[0].exactTrigger) return [list[0], row].concat(list.slice(1))
  return [row].concat(list)
}

if (typeof module !== "undefined") {
  module.exports = {
    limits: { input: maxInputLength, depth: maxDepth },
    evaluate: evaluate,
    continued: continued,
    formatNumber: formatNumber,
    formatGrouped: formatGrouped,
    displayRow: displayRow,
    withResult: withResult,
    functionNames: Object.keys(functions)
  }
}
