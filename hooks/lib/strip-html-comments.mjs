// strip-html-comments.mjs — remove HTML-comment regions (<!-- ... -->) from text so a line-anchored
// `### [`-card / header parser cannot match an EXAMPLE that lives INSIDE a comment. Pure text→text,
// ZERO project / sop-validate coupling — the reusable form the follow-up R-comment-blind-parsers
// imports (ESM here; a .cjs require()-interop wrapper + a bash-native strip are THAT wave's job).
//
// Semantics: each <!-- ... --> region (possibly multi-line) is replaced by an equal-width run of
// SPACES with its NEWLINES PRESERVED — so downstream line numbers AND line-anchored (^) matching are
// unchanged, and a same-line `--> ### [x]` leaves leading whitespace before ### (so ^### no longer
// matches = correctly NOT a card: the documented degenerate case). An UNCLOSED <!-- runs to EOF
// (everything after is treated as commented — mirrors the HTML "comment extends to --> or EOF" rule),
// so a truncated comment can never re-expose an example card. Nesting is not special-cased (HTML has
// no nested comments) but never throws. null / undefined / non-string → ''.
export function stripHtmlComments(text) {
  return String(text ?? '').replace(/<!--[\s\S]*?-->|<!--[\s\S]*$/g, (m) => m.replace(/[^\n]/g, ' '));
}
