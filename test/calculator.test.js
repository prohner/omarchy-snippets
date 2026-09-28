// Plain-node tests for Calculator.js — no framework, no dependencies.
//
//   node test/calculator.test.js
//
// Two things matter most here. The answers have to be right, which is the
// easy part. And a search must stay a search: the picker opens on your
// clipboard history and Enter pastes the top row, so a query that is not a
// calculation must not grow an answer on top of it, and one that is must not
// be answered by anything other than arithmetic.

var C = require("../Calculator.js")
var S = require("../Snippets.js")

var failures = 0

function eq(actual, expected, label) {
  var ok = JSON.stringify(actual) === JSON.stringify(expected)
  if (!ok) failures++
  console.log((ok ? "PASS  " : "FAIL  ") + label + " -> " + JSON.stringify(actual))
  if (!ok) console.log("      expected " + JSON.stringify(expected))
}

function text(query, options) {
  var r = C.evaluate(query, options)
  return r ? r.text : null
}

// --- standard arithmetic --------------------------------------------------
eq(text("2+2"), "4", "addition")
eq(text("2 + 3 * 4"), "14", "* binds tighter than +")
eq(text("(2 + 3) * 4"), "20", "parentheses")
eq(text("10 / 4"), "2.5", "division")
eq(text("7 - 10"), "-3", "negative result")
eq(text("2^10"), "1024", "power")
eq(text("2**10"), "1024", "** is power too")
eq(text("2^3^2"), "512", "power is right-associative")
eq(text("-2^2"), "-4", "unary minus binds looser than ^")
eq(text("2^-1"), "0.5", "negative exponent")
eq(text("3 * -2"), "-6", "unary minus after an operator")
eq(text("0.1 + 0.2"), "0.3", "floating-point noise is rounded away")
eq(text("1/3"), "0.333333333333333", "15 significant digits")
eq(text(".5 + .25"), "0.75", "leading decimal point")
eq(text("6 × 7"), "42", "× multiplies")
eq(text("84 ÷ 2"), "42", "÷ divides")
eq(text("50 − 8"), "42", "U+2212 minus")
eq(text("1e3 + 1"), "1001", "scientific notation in")
eq(text("1e20 * 100"), "1e+22", "scientific notation out")
eq(text("-0 * 5"), "0", "no negative zero")

// --- things that are searches, not sums ------------------------------------
eq(text("42"), null, "a bare number is a search")
eq(text("-42"), null, "a negated number is a search")
eq(text("(42)"), null, "a parenthesised number is a search")
eq(text("5%"), null, "a bare percentage is a search")
eq(text("hello"), null, "words are a search")
eq(text("git push"), null, "commands are a search")
eq(text("2 + two"), null, "a word inside a sum is not a sum")
eq(text("sqrt(16)"), null, "functions need the = prefix")
eq(text("pi * 2"), null, "constants need the = prefix")
eq(text("2 +"), null, "a trailing operator is incomplete")
eq(text("(2 + 3"), null, "an unclosed parenthesis is incomplete")
eq(text("2 3"), null, "two numbers with no operator")
eq(text("2(3)"), null, "no implicit multiplication")
eq(text(""), null, "empty")
eq(text("   "), null, "whitespace")
eq(text("="), null, "a lone =")
eq(text("1/0"), null, "division by zero answers nothing")
eq(text("=sqrt(-1)"), null, "NaN answers nothing")
eq(text("2 + 2; rm -rf ~"), null, "anything outside the grammar is rejected")
eq(text("constructor"), null, "no property lookups by name")
eq(text("=constructor(1)"), null, "no property lookups by name, advanced")
eq(text("=toString(1)"), null, "only the function table is callable")
eq(text("=__proto__"), null, "no prototype names as constants")

// --- percentages (standard mode) -------------------------------------------
eq(text("100 + 10%"), "110", "a + b% adds b percent of a")
eq(text("100 - 15%"), "85", "a - b% takes off b percent of a")
eq(text("200 * 15%"), "30", "a * b% is a times b/100")
eq(text("50 / 10%"), "500", "a / b% is a over b/100")
eq(text("10% + 5"), "5.1", "a leading b% is b/100")
eq(text("100 + (10%)"), "100.1", "a parenthesised percentage is just a number")

// --- currency symbols -------------------------------------------------------
eq(text("$120 - 15%"), "102", "dollar signs are skipped")
eq(text("€19.99 * 3"), "59.97", "euro signs are skipped")
eq(text("£5 + ¥10"), "15", "any mix of symbols is skipped")

// --- thousands separators ---------------------------------------------------
eq(text("1,299.99 * 2"), "2599.98", "grouped input")
eq(text("1,000,000 / 4"), "250000", "several groups")
eq(text("1,23 + 1"), null, "a comma that does not group thousands is an error, not a guess")
eq(text("1,2345 + 1"), null, "four digits after a group mark is an error")

// --- advanced mode (= prefix) ----------------------------------------------
eq(text("=sqrt(16)"), "4", "sqrt")
eq(text("=pi"), "3.14159265358979", "a lone constant answers in advanced mode")
eq(text("=e"), "2.71828182845905", "e")
eq(text("=π * 2"), "6.28318530717959", "π")
eq(text("=17 % 5"), "2", "% is modulo in advanced mode")
eq(text("= 2 + 2"), "4", "space after the =")
eq(text("=42"), "42", "a lone number answers in advanced mode")
eq(text("=sin(dtor(30))"), "0.5", "degrees to radians")
eq(text("=rtod(pi)"), "180", "radians to degrees")
eq(text("=log(1000)"), "3", "log is base 10")
eq(text("=log2(1024)"), "10", "log2")
eq(text("=ln(e)"), "1", "ln")
eq(text("=exp(0)"), "1", "exp")
eq(text("=abs(-3)"), "3", "abs")
eq(text("=floor(2.7) + ceil(2.1)"), "5", "floor and ceil")
eq(text("=round(2.5)"), "3", "round sends .5 up")
eq(text("=rint(2.5)"), "2", "rint sends .5 to even")
eq(text("=rint(3.5)"), "4", "rint sends .5 to even, odd case")
eq(text("=trunc(-2.7)"), "-2", "trunc")
eq(text("=SQRT(9)"), "3", "function names are case-insensitive")
eq(text("=sqrt 16"), null, "functions need parentheses")
eq(text("=nosuch(1)"), null, "unknown function")

// Every function Alfred documents, less `near`.
var alfred = ["sin", "cos", "tan", "log", "log2", "ln", "exp", "abs", "sqrt", "asin", "acos", "atan",
  "sinh", "cosh", "tanh", "asinh", "acosh", "atanh", "ceil", "floor", "round", "trunc", "rint", "dtor", "rtod"]
eq(alfred.filter(function(f) { return C.functionNames.indexOf(f) < 0 }), [], "every Alfred function is present")

// --- locale -----------------------------------------------------------------
var de = { decimalMark: ",", groupMark: "." }
eq(text("1.234,5 + 0,5", de), "1235", "decimal comma, point grouping")
eq(text("10 / 4", de), "2,5", "answers use the locale's decimal mark")
eq(text("1,5 * 2", de), "3", "decimal comma in")
eq(C.evaluate("1234567.5 * 1").display, "1,234,567.5", "display groups thousands")
eq(C.evaluate("1234567,5 * 1", de).display, "1.234.567,5", "display groups in the locale")
eq(C.evaluate("-1234567 * 1").display, "-1,234,567", "grouping keeps the sign")
eq(C.evaluate("1e20 * 100").display, "1e+22", "exponent notation is not grouped")
eq(text("2+2", { decimalMark: "+" }), "4", "an operator as a mark falls back to the default")
eq(text("1,5 + 1", { decimalMark: ",", groupMark: "," }), "2,5", "clashing marks fall back")

// --- = continues a calculation ----------------------------------------------
eq(C.continued("2+2"), "4", "= replaces the expression with its answer")
eq(C.continued("=sqrt(16)"), "=4", "= keeps the advanced prefix")
eq(C.continued("hello"), null, "= after a search is just typed")
eq(C.continued("1e20 * 100"), "1e+22", "an exponent answer...")
eq(text("1e+22 / 1e20"), "100", "...can be calculated with again")
eq(C.continued("10 / 4", de), "2,5", "continuation in the locale...")
eq(text("2,5 * 2", de), "5", "...reads back in the locale")

// --- bounds -----------------------------------------------------------------
var long = "1" + new Array(C.limits.input).join("+1")
eq(long.length > C.limits.input, true, "(the long query is over the limit)")
eq(text(long), null, "input over the length limit is ignored")
eq(text("1" + new Array(100).join("+1")), "100", "a long sum under the limit")
function nested(n) { return new Array(n + 1).join("(") + "1+1" + new Array(n + 1).join(")") }
eq(text(nested(C.limits.depth - 1)), "2", "nesting under the depth limit")
eq(text(nested(C.limits.depth + 1)), null, "nesting over the depth limit is refused")
eq(text(new Array(60).join("-") + "1+1"), null, "a run of unary minus is bounded too")

// --- rows -------------------------------------------------------------------
var result = C.evaluate("1234.5 * 2")
var row = C.displayRow(result)
eq(row.entryType, "calc", "rows are tagged calc")
eq(row.fullText, "2469", "fullText is what gets pasted")
eq(row.expression, "1234.5 * 2", "the row carries its expression")
eq(Object.keys(row).sort(), Object.keys(C.displayRow(C.evaluate("=1"))).sort(), "every row has the same fields")

var lib = [
  { trigger: "1+1", body: "one plus one", notes: "" },
  { trigger: "sum", body: "1+1 is two", notes: "" }
]
var history = [{ entryType: "text", fullText: "1+1=2", previewText: "1+1=2", index: 0 }]

function merged(query) {
  var rows = S.mergeRows(S.displayRows(lib, query, 50), history, query)
  return C.withResult(rows, query).map(function(r) { return r.entryType + ":" + r.previewText })
}

eq(merged("2+2"), ["calc:4", "text:1+1=2"], "the answer leads")
eq(merged("1 + 1"), ["calc:2", "text:1+1=2"], "the answer leads a body match")
eq(merged("1+1"), ["snippet:1+1", "calc:2", "snippet:sum", "text:1+1=2"], "an exact trigger still wins")
eq(merged("sum"), ["snippet:sum", "text:1+1=2"], "no answer for a search")
eq(C.withResult([], "3*3").map(function(r) { return r.fullText }), ["9"], "an answer with nothing else to show")

console.log(failures === 0 ? "\nAll tests passed." : "\n" + failures + " test(s) failed.")
process.exit(failures === 0 ? 0 : 1)
