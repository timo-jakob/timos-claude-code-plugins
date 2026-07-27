#!/usr/bin/env zsh
#
# Suite-lint detector (#1011, extended #1067): find assertions that are SILENTLY
# INERT because of where — or how — they are written.
#
# TWO RULES, reported with their own tag so the advice can differ:
#   * `bracket`  — a `[[ ... ]]` assertion inside a scanned block (#1011). The
#     fix is a helper from tests/assertions.bash.
#   * `and-tail` — an assertion-helper call that is the LEFT operand of `&&`
#     (#1067). The fix is one assertion per line.
# Both are inert for the SAME reason at bottom — a status errexit never sees —
# but they reach it differently, which is why they are separate rules: the
# `bracket` inertness is bash-3.2-specific, the `and-tail` inertness is the POSIX
# AND-list exemption and therefore holds on EVERY bash.
#
# bash 3.2 — macOS `/bin/bash`, and what `#!/usr/bin/env bash` resolves to on
# this repo's primary platform — does not apply errexit to a failing `[[ ]]`, so
# its exit status only matters when it happens to be the block's last statement.
# Verified on bash 3.2.57: a false `[[ ! -f <existing> ]]` on a non-final line of
# an `@test` reports `ok`, while the same assertion written `[ ! -f <existing> ]`
# fails correctly. bash >= 4 (4.4 and 5.2 checked) catches BOTH — which is the
# real argument for the ban: the idiom's meaning depends on the platform, so the
# `bats (macos-latest)` and `bats (ubuntu-latest)` legs disagree about what a
# given test proves. The bats version is not a factor (1.10.0 through 1.14.0 all
# behave identically on a given bash). The inertness survives an `&&` tail (the
# AND-list errexit
# exemption, which applies to `[ ... ]` and to a function call identically — which
# is exactly why the `and-tail` rule below exists) and
# `=~`. A `|| return 1` tail is NOT inert — the command after the final `||` is
# exactly what errexit catches — but it is flagged anyway so the fix stays
# uniform.
#
# DETECTION RULE (`bracket`): a `[[` that OPENS A COMMAND inside a scanned
# block — either
# the first token of the line, or the first token after a `;`, `&&` or `||` on
# the same line (ignoring one inside a quoted string). Generally: a `[[` that is
# neither the first token of a line nor immediately preceded by `;`, `&&` or
# `||` is NOT seen — so a `[[` after `then`, `do`, or a `case` arm's `)`, or
# inside `( … )` / `{ …; }` grouping, is a blind spot. None are present in this
# suite. Keep assertions one per line and the rule holds.
#
# DETECTION RULE (`and-tail`, #1067): an assertion helper from
# tests/assertions.bash — the roster is the awk `H` variable below, and is
# deliberately not restated in this prose — that OPENS A COMMAND (the same opener
# rule as above) inside a
# scanned block, with an unquoted `&&` anywhere AFTER it on the line. That helper
# call is then a non-final member of an AND-list, which errexit does not see:
#
#   contains "$output" "a" && contains "$output" "b"   # a failing FIRST call is
#                                                      # SWALLOWED
#
# tests/assertions.bats pins this empirically; #1011 documented it in prose but
# nothing enforced it, so the belief "calling a helper makes position stop
# mattering" could reintroduce it silently. Only the LEFT operand is inert — a
# helper that ends the list (`true && contains …`, `false || contains …`) IS the
# status errexit catches, so it is deliberately not flagged. Neither is
# `<helper> … || …`: unlike a `[[ ]]`, whose `|| return 1` tail is flagged for
# uniformity with the ban on the idiom itself, a helper call has no idiom to ban
# — but `<helper> … || true` IS inert, so that exemption is a blind spot, not a
# blessing (see FALSE NEGATIVES).
#
# The helper roster lives in the awk `H` variable — the only copy outside
# tests/assertions.bash that a machine has to keep. The two bats files DERIVE it
# from the library (public, non-`_`-prefixed top-level functions), so their
# greps and loops cannot drift, and a roster-sync test fails if `H` and the
# library disagree in either direction.
#
# ADDING A HELPER therefore means editing, in order:
#   1. tests/assertions.bash — the definition, plus the LITERAL-vs-REGEX
#      paragraph, which owes every helper a verdict. Nothing checks that.
#   2. this `H`. The roster-sync test reds until you do.
#   3. tests/README.md — the contributor-facing roster ARCHITECTURE.md
#      designates the source of truth. A guard test reds until each name is
#      named there.
#   4. the PER-HELPER enumerations in tests/assertions.bats (the mismatch
#      diagnostic and the success-path silence). These are deliberately NOT
#      derived: each helper reaches the shared printer through a different
#      construct, so only a human can write the case. A roster-size tripwire in
#      that file reds until you update its count — the red is the instruction,
#      not a check that you wrote the cases.
# Steps 2 and 3 are verified. Step 4 is prompted but not verified, and the
# LITERAL-vs-REGEX paragraph is on you alone.
#
# CONDITIONS are control flow, not assertions: their status is consumed by the
# construct, so they are not inert and must NOT be converted (rewriting
# `if [[ -f x ]]` as `if contains …` in a file lacking `load assertions` would
# make the condition silently false via 127 instead of failing loudly). A line
# whose first token is `if`, `elif`, `while` or `until` is therefore exempt —
# including the second half of a compound condition such as
# `if [[ -f a ]] && [[ -f b ]]; then`, which the separator rule would otherwise
# flag with advice that does not apply. The exemption covers BOTH rules for the
# same reason: `if contains "$x" "a" && contains "$x" "b"; then` is a compound
# condition, not two swallowed assertions.
#
# The exemption runs to the LAST top-level `fi`/`done` closer on the line, not
# to end of line (#1068): what follows a closed construct is a new command, so
# `if …; then …; fi; [[ -f a ]]` has its trailing assertion judged like any
# other block line. A line that has NOT closed its condition — one ending in
# `; then` or `; do` — stays exempt in full however many nested constructs it
# contains, because every token on it is still part of the condition list whose
# status the construct consumes.
#
# WHERE it is inert — the scoping rule this detector implements:
#   * `@test` bodies, and `setup` / `teardown` / `setup_file` / `teardown_file`
#     (`setup` verified inert on bash 3.2.57; the other three hooks are scanned
#     on the same reasoning) are SCANNED — when the opener is written on one
#     line ending in `{`, and closed by a `}` at column 0. A self-contained
#     one-line block (`teardown() { rm -rf "$W"; }`) never OPENS a block — there
#     is nothing left to scan on a later line — but its interior IS judged for an
#     offender (#1068), same as any other block line; a single-statement one-liner
#     with no offender in it is unaffected either way.
#   * a helper function defined OUTSIDE any scanned block (top-level) is NOT
#     scanned. For `bracket` that is a sanctioned fix WHEN the `[[ ]]`'s status is
#     what the function returns — its last command, or one carrying an explicit
#     `|| return` — because the call site is then a simple command errexit
#     catches; `contains() { [ … ]; }` and friends are the answer rather than the
#     defect. A `[[ ]]` whose status the function DISCARDS is as inert as one in a
#     test body and, being unscanned, is missed (FALSE NEGATIVES, below). For
#     `and-tail` the unscanned-ness is a plain false negative in every case —
#     wrapping `contains … && true` in a function does not rescue it, it only
#     hides it. tests/assertions.bash is the shared helper library and the
#     reference for the idiom. A helper function defined INSIDE a scanned block
#     is scoped the same way (#1068): its own body is suppressed from judgement
#     — spread across lines, tracked from its opener (any SINGLE-LINE spelling:
#     `name() {`, `name () {`, `function name() {`, `function name {`) to its
#     own close, an INDENTED `}` which may carry a `;` or a redirection tail —
#     for exactly the same reason a top-level one is. A heredoc inside that
#     body is tracked too, so its payload is skipped rather than read as code;
#     a close the scanner never finds is a desync (below) on all three ways it
#     can go unfound — the enclosing block closes first, a new block opener
#     arrives first, or the file simply ends — never a silently unscanned
#     block. The one-liner and brace-on-the-next-line spellings are
#     NOT scoped this way — see FALSE POSITIVES.
#   * heredoc bodies are payload, not assertions — a test that *writes* a script
#     containing `[[ ]]` is fine — so heredocs are skipped, including one opened
#     on a condition line, or with a `|` (which also covers `||`) or an `&&`
#     tail — those two with or without the downstream command on the same line,
#     so the continuation spellings `cat <<EOF |` and `cat <<EOF &&` are
#     tracked too — or with the `; then`/`; do` a condition line ENDS IN, which
#     unlike the other two is anchored: `<<EOF; then :; fi` all on one line
#     matches nothing and is untracked (#1068);
#   * full-line comments are prose, never code — but only OUTSIDE an open
#     multi-line quoted literal; a continuation line starting with `#` is text
#     the literal owns, not a real comment (#1068 carries quote parity across
#     lines, so this is judged correctly either way).
#
# No positional exemption: a trailing `[[ ]]` is safe only by accident of
# position and goes inert the moment anyone appends a line below it, so a
# final-line occurrence is flagged like any other (subject to the detection rule
# and blind spots above).
#
# Known, accepted limits — narrow, and none of these shapes exists in this
# suite. They run in BOTH directions, so read the direction before acting on a
# flag. (#1068 closed five limits that used to be listed here — limit 4
# CONDITIONALLY; see its FALSE NEGATIVES entry for which literals it covers — a
# self-contained one-line block with several statements, the condition
# exemption skipping a post-construct assertion, a nested in-block helper
# definition's own `[[` line, per-line-only quote tracking, and the
# still-silent heredoc-opener shapes: an opener on a condition line, and one
# whose tail is a `|` pipe (covering `||` too) or an `&&` — those two with or
# without the downstream command on the same line — or the `; then`/`; do` a
# condition line ENDS IN — within this same awk state machine. A heredoc opener with any OTHER
# tail (a generic `; <cmd>`, a backgrounding `&`) is still untracked, and is
# listed below with the rest of the remaining limits.)
#
# FALSE POSITIVES (a safe `[[ ]]` or helper call is flagged — do NOT convert it;
# restructure the line so the detector can see it, or leave it alone):
#   * `and-tail` judges the WHOLE line, so a helper call followed later on the
#     same line by an `&&` belonging to a *closed* construct
#     (`contains "$x" a; if …; then …; fi && y`) is flagged even though the
#     helper's own status is caught;
#   * a heredoc opened on a line one of the OFFENDER rules (6/6b) flags and
#     `next`s on (`contains … && cat > "$f" <<EOF`) is not tracked, so its
#     payload is scanned as code and a payload line beginning with `[[` is
#     reported as an offender. Here the verdict is not a false clean — the line
#     that caused it is itself reported (exit 1) — and if the misread payload
#     carries a MALFORMED opener shape, or a `<<` whose phantom heredoc never
#     terminates, the scan additionally trips a desync (exit 2) and suppresses
#     the list. Non-zero either way. Read the sub-cases before trusting an
#     offender list from such a scan, though: a WELL-FORMED column-0 opener in
#     the payload is not a desync at all — rule 3 adopts it as a new block, the
#     exit stays 1 with the list intact, and the real test's lines after the
#     payload's own `}` are then out of block and go unjudged. A
#     CONDITION line (rule 5) is the exception to the whole entry: it judges its
#     post-closer remainder and still tracks its heredoc, so a flagged condition
#     line's payload is correctly skipped;
#   * a nested in-block helper written as a self-contained ONE-LINER
#     (`h() { rm -f x; [[ -f "$1" ]]; }`) is NOT recognized as a helper
#     definition — rule 4c wants the line to END at `{`, and `judge_oneliner`
#     is reached only from rule 3, which claims `@test` and the four hook names
#     alone. It is therefore judged WHOLE-LINE by rules 6/6b, so a `[[` that a
#     separator makes visible is flagged even though it sits inside a helper
#     definition. Two consequences worth knowing before acting on such a flag:
#     the same helper written with the `[[` FIRST (`h() { [[ -f "$1" ]]; }`) is
#     silently accepted, because `{ ` is not a command separator; and an
#     `&&`-swallowed helper call in that one-liner is missed for the same
#     reason. Spell a nested helper across lines and it is scoped properly;
#   * a nested helper whose `{` sits on the NEXT line is not recognized either
#     (rule 4c admits only single-line openers), so its body is judged as
#     ordinary block code and its `[[ ]]` flagged;
#   * a second function defined INSIDE a nested helper's body closes the outer
#     one at its own indented `}` — the nested-helper model is one level deep.
#
# FALSE NEGATIVES (an inert assertion is missed):
#   * `and-tail` is per line, so an AND-list continued onto the next line with a
#     trailing `\` hides its left operand from the rule;
#   * `and-tail` knows only the names in `H`, so a project-local wrapper
#     around a helper is not recognized as one;
#   * `and-tail` inside a named helper function is not scanned, so
#     `h() { contains … && true; }` is missed even though it is just as inert as
#     the same line in a test body;
#   * a `[ … ]` assertion swallowed by an `&&` — `[ -n "$a" ] && [ -f "$b" ]` —
#     is missed by BOTH rules: `bracket` keys on `[[`, `and-tail` on the helper
#     roster. The AND-list exemption is not about helpers, so this is inert on
#     every bash; it is convention, not lint, that keeps it out of the suite;
#   * `<helper> … || true` (any `||` tail that cannot fail) discards the
#     assertion, and the `||` exemption above means nothing flags it;
#   * `<helper> … | <cmd>` — a pipeline's status is its LAST command's, and bats
#     test bodies do not run under `pipefail`, so a piped assertion is discarded
#     exactly like `|| true`. `and_after` keys on `&&` only, so nothing flags it;
#   * a needle ending in a literal backslash inside SINGLE quotes
#     (`contains "$o" 'x\' && true`): the quote-parity helper treats a backslash
#     as an escape everywhere, but the shell does not inside single quotes, so
#     the closing quote is swallowed, the rest of the line reads as string, and
#     the real `&&` is missed. Shared with the `bracket` rule, which has the same
#     model; no such literal exists in this suite. Since #1068 a line the model
#     reads as leaving a literal OPEN also carries that state forward, so the
#     miss can extend past its own line — every line until the phantom closes
#     is swallowed as string and never judged. That is bounded ONLY when the
#     phantom stays open to end of file, where the desync guard below turns it
#     into exit 2. If any later line carries an odd count of the same quote
#     kind the phantom closes mid-file, scanning resumes, and the swallowed
#     span — offenders included — is silently skipped at exit 0. A full-line
#     comment can do it: rule 1b consumes continuation lines BEFORE the comment
#     rule, so a comment holding one apostrophe flips the parity like any other
#     line;
#   * the flat quote-parity model cannot see that `$( … )` and backticks restart
#     the shell's quoting context, so a balanced line using them can count odd.
#     Such a line is therefore never allowed to OPEN a carried literal (nor is
#     one containing a `)`, the shape that CLOSES a multi-line substitution).
#     Read the cost precisely, because it is where limit 4's closure is
#     CONDITIONAL: when the refused line was a GENUINE multi-line literal
#     opener, that literal reverts to the pre-#1068 behaviour — its
#     continuation lines are judged as code. Only the ESTABLISHING line is
#     screened, so what happens next splits in two:
#       - a column-0 `}` inside the literal, reached before any odd-parity
#         line, clears the block and every later assertion in that test goes
#         unscanned at exit 0. Nothing bounds this one — no carry was ever
#         established, so the end-of-file guard below has nothing to report.
#         This is the residual false clean with no bounding shape at all;
#       - otherwise the literal's own CLOSING line (one unmatched quote, and
#         typically none of the screened characters) establishes a carry after
#         all. That carry is reported at end of file — so a "never closed"
#         diagnostic can be the symptom of a refused OPENER rather than of a
#         genuinely unterminated literal, and is worth reading that way before
#         hunting for an unclosed quote that does not exist — but ONLY if no
#         later line flips the parity first. One that does (a comment holding a
#         single quote suffices, since rule 1b consumes continuation lines
#         before the comment rule) closes the phantom mid-file, and this
#         degenerates into the second residual gap below: the swallowed span is
#         skipped silently at exit 0.
#     So limit 4 is closed for literals whose OPENING line carries none of
#     `$(`, a backtick or `)`, and open for the rest. The screens are also
#     quote-blind — one of those characters inside the literal being opened
#     refuses it too;
#   * code following the closing quote on a continuation line of a multi-line
#     literal (`two"; [[ -f a ]]`) is read as string, not judged: rule 1b treats
#     the whole continuation line as text once it has established the literal is
#     open. The pre-#1068 per-line model missed the same remainder, via the odd
#     prefix parity, so this is a carried-over limit rather than a new one;
#   * a `[[ ]]` inside a named helper function whose status the function
#     DISCARDS (not its last command, no `|| return`) is as inert as one in a
#     test body — and function bodies are not scanned, so it is missed. Only the
#     status-returning shape is the sanctioned fix. This now also covers a
#     nested in-block helper (#1068 suppresses judgement of its whole body,
#     status-returning or not — the same tradeoff a top-level helper always
#     had), including its `and-tail` exposure;
#   * exactly ONE heredoc opener per line is tracked, and WHICH one follows the
#     alternation order rather than position — the end-anchored redirection
#     alternative is tried first, so:
#       - `cat <<A <<B` tracks `A` (that alternative matches leftmost, absorbing
#         ` <<B` into its redirection group). The scan resumes at `A` while the
#         shell is still reading body B, so body B is read as code and a
#         column-0 `}` in it clears the block;
#       - `cat <<A | cat <<B` tracks `B` — the ` | cat ` tail defeats the
#         end-anchored alternative at `<<A`, so its leftmost match is `<<B`, and
#         the `|` alternative is never consulted. The scan then skips body A,
#         terminator `A` and body B together, which happens to agree with the
#         shell; it goes wrong only if body A contains a line spelling `B`,
#         closing the tracked heredoc early;
#       - `cat <<A | cat <<B | tee x` tracks `A` again (no opener sits at end of
#         line, so the `|` alternative matches leftmost), losing body B as above.
#     None of these is a rejected opener: the recognizer accepted the line,
#     tracked one heredoc, and saw it terminate, so no desync guard has
#     anything to report;
#   * a heredoc opener whose DELIMITER does not match
#     `[A-Za-z_][A-Za-z_0-9.-]*` (`cat <<'1EOF'`, `cat <<'!'`) is not tracked on
#     ANY tail, so its payload is read as code and a column-0 `}` in it clears
#     the block. Exotic — no such delimiter exists in this suite;
#   * a heredoc opener whose tail is neither a redirection, a `|`, an `&&`, nor
#     the `; then`/`; do` a condition line ENDS IN — a generic `; <cmd>` tail
#     (`cat <<EOF; echo after`), a backgrounding `&`, or a condition whose
#     construct continues on the same line (`<<EOF; then :; fi`) — is not
#     tracked. The
#     accepted tails do NOT COMPOSE either: a redirection followed by one of
#     the others (`cat <<EOF > "$f" | tee x`) matches no alternative, since the
#     redirection form must run to end of line and the others must follow the
#     delimiter directly. In every such case its
#     payload is scanned as code and a column-0 `}` in it clears the block;
#   * a one-liner interior whose own text starts with a condition
#     (`@test "x" { if true; then :; fi; [[ -f a ]]; }`) is exempt in full: the
#     post-closer re-judging of limit 2 applies to whole condition LINES, not to
#     an extracted one-liner interior, so this intersection of limits 1 and 2 is
#     still missed;
#
# Both the offender rules and the heredoc-opener rule judge the line with any
# trailing comment removed and skip a `<<`/`[[` that sits inside a string, so an
# assertion or comment ABOUT either idiom is text, not code.
#
# EXIT 0 IS A VERDICT, NOT A SHRUG. A parse desync would otherwise report
# "clean" for a file it stopped reading, so the desync shapes are hard errors
# (exit 2) rather than silent passes: a heredoc still open at end of file; a
# block opener the scanner could not recognize — counted PER OPENER, so one
# malformed `@test` among well-formed siblings is still caught; and, since
# #1068, the two states that change how many LINES get read — a carried
# multi-line quoted literal still open at end of file, and a nested helper
# function whose close was never recognized, counted per helper and caught on
# all three ways it can happen: the enclosing block closes first (rule 4), a
# NEW block opener arrives first (rule 3), or the file ends inside the body
# (flush_file). Both states suppress whole spans of a block, so leaving any of
# those silent would be the same false clean the first two guard against.
#
# FOUR gaps remain, none covered by these guards, all documented rather than
# closed. Two live in the quote-parity model:
#   * a literal whose opening line was refused a carry (the `$(`/backtick/`)`
#     screen) is never tracked, so a column-0 `}` inside it clears the block
#     with nothing left open to report;
#   * a phantom carry opened by a parity misread and closed again mid-file by a
#     later odd-quote line swallows the span between them and then resumes.
# The other two live in the heredoc recognizer, not the parity model:
#   * a heredoc opener the recognizer does not accept — a tail that is neither
#     a redirection, a `|`, an `&&` nor a `; then`/`; do` (a generic `; <cmd>`,
#     a backgrounding `&`), or a delimiter outside
#     `[A-Za-z_][A-Za-z_0-9.-]*` — is untracked, so its payload is read as code
#     and a column-0 `}` in it clears the block.
#   * a line carrying TWO heredoc openers tracks only one of them (which one
#     depends on the alternation order — see the entry above), so a body the
#     scan never accounts for MAY be read as code, depending on the spelling.
#     Unlike the shape above the
#     recognizer ACCEPTED an opener and saw it terminate, so no desync fires.
# All four exit 0. See their FALSE NEGATIVES entries. They are the places exit 0
# can still follow a block the scanner stopped reading that are known today —
# each was found by constructing a shape the previous enumeration missed, so
# treat the list as the current state of the audit rather than a proof.
#
# Usage: find-inert-bracket-assertions.zsh [<file>...]
#   With no arguments, scans tests/**/*.bats next to this script.
#
# Output: one `<file>:<line>: <rule>: <text>` per offender on stdout, where
#         `<rule>` is `bracket` or `and-tail`; diagnostics on stderr. The tag is
#         what lets the guard print advice that fits the offender — "convert to a
#         helper" is wrong advice for a line that already calls one.
# Exit:   0 = no offenders, 1 = offenders found, 2 = usage or scan error.
#         Exit 2 takes precedence: when the scan desynced the offender list is
#         suppressed, because it cannot be trusted.
#
# Behavioural tests: tests/no-inert-bracket-assertions.bats (named for the
# invariant it enforces, following the #829 guard's precedent).

emulate -L zsh
setopt err_exit nounset pipefail

local -a files
if (( $# )); then
  files=("$@")
else
  local self_dir="${0:A:h}"
  files=("$self_dir"/**/*.bats(N))
fi

if (( ! ${#files} )); then
  print -u2 "find-inert-bracket-assertions.zsh: no .bats files to scan"
  exit 2
fi

local f
local -a scan
for f in "${files[@]}"; do
  if [[ ! -f "$f" || ! -r "$f" ]]; then
    print -u2 "find-inert-bracket-assertions.zsh: cannot read: $f"
    exit 2
  fi
  # A bare relative path containing `=` would be parsed by awk as a variable
  # assignment rather than a file, scanning nothing and reporting a false clean.
  [[ "$f" == /* || "$f" == ./* ]] || f="./$f"
  scan+=("$f")
done

# awk does the block tracking. Rule order matters: consume heredocs and comments
# first, then track block boundaries, then flag — and only then run the GENERAL
# heredoc-opener rule (7), so a line that is itself an assertion can never be
# mistaken for a heredoc opener. Rules 4, 4b and 5 open a heredoc of their own
# before that, each for a reason its own comment gives: a close line and a
# condition line can both carry an opener, and neither reaches rule 7.
# Records are tab-separated and typed: O = offender,
# D = diagnostic.
local out awk_status=0
out="$(awk '
  # True when the prefix leaves an unclosed quote — i.e. whatever follows it on
  # the line is inside a string literal rather than being code. Counts from
  # 0,0, NOT from carry_sq/carry_dq: every line that reaches a judging rule
  # starts at parity 0,0, because rule 1b consumes any line that begins inside
  # a literal before judging runs, and rule 3 resets the carry on a block
  # opener. Seeding from the carry instead was a #1068 regression — the carry
  # is advanced to this line'"'"'s END parity before the judging rules run, so an
  # offender sitting BEFORE a literal-opening quote read as quoted and went
  # unreported (a false clean, the worst direction). A backslash escapes the
  # next character so an escaped quote does not flip parity.
  function in_quotes(prefix,   n_s, n_d, i, c) {
    n_s = 0; n_d = 0
    for (i = 1; i <= length(prefix); i++) {
      c = substr(prefix, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"" && n_s % 2 == 0) n_d++
      else if (c == "'"'"'" && n_d % 2 == 0) n_s++
    }
    return (n_s % 2) || (n_d % 2)
  }

  # Walks `text` from the CURRENT carry_sq/carry_dq and overwrites them with
  # the parity at end of `text` (#1068). This is the single place quote state
  # crosses a line boundary, and the ONLY place that legitimately seeds from
  # the carry: a continuation line (rule 1b) must resume mid-literal to learn
  # whether the literal closes on it. A fresh line enters with the carry at
  # 0,0 anyway, so the same seed is correct there. `in_quotes` deliberately
  # does NOT seed from the carry — see its comment: by the time the judging
  # rules run, this function has already advanced the carry past the current
  # line, so seeding judgement from it inverts the verdict on any line with
  # odd quote parity.
  function apply_quote_carry(text,   n_s, n_d, i, c) {
    n_s = carry_sq; n_d = carry_dq
    for (i = 1; i <= length(text); i++) {
      c = substr(text, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"" && n_s % 2 == 0) n_d++
      else if (c == "'"'"'" && n_d % 2 == 0) n_s++
    }
    carry_sq = n_s % 2
    carry_dq = n_d % 2
  }

  # The EARLIEST position at which an assertion helper opens a command, as the
  # first token of the line or the first token after `;`, `&&` or `||`; 0 when
  # there is none. Returns the position just PAST the token, which is where the
  # `&&` that would swallow it has to be. Earliest is enough: an `&&` after a
  # later opener is also after this one, so no other opener can widen the match.
  function helper_open(line,   p, abs, mlen) {
    # Position 1 can never be inside a string — rule 1b consumes every line
    # that STARTS inside a literal before any judging rule runs — so the
    # line-start case needs no in_quotes check.
    if (match(line, "^[[:blank:]]*" H "[[:blank:]]")) return RSTART + RLENGTH
    p = 1
    while (match(substr(line, p), "(;|&&|\\|\\|)[[:blank:]]*" H "[[:blank:]]")) {
      abs = p + RSTART - 1
      mlen = RLENGTH
      if (!in_quotes(substr(line, 1, abs - 1))) return abs + mlen
      p = abs + mlen
    }
    return 0
  }

  # An unquoted `&&` at or after `from` — the tail that makes the helper call a
  # non-final member of an AND-list. A quoted one is text: nearly every fixture
  # in this suite is a printf string that quotes exactly this shape.
  function and_after(line, from,   p, abs, mlen) {
    p = from
    while (match(substr(line, p), /&&/)) {
      abs = p + RSTART - 1
      mlen = RLENGTH
      if (!in_quotes(substr(line, 1, abs - 1))) return 1
      p = abs + mlen
    }
    return 0
  }

  # A `[[` opening a command after a separator, ignoring any that sit inside a
  # quoted string. Scans EVERY match, not just the leftmost: a quoted one early
  # on the line must not mask a real one later.
  function sep_bracket(line,   p, abs, mlen) {
    p = 1
    while (match(substr(line, p), /(;|&&|\|\|)[[:blank:]]*\[\[/)) {
      abs = p + RSTART - 1
      mlen = RLENGTH
      if (!in_quotes(substr(line, 1, abs - 1))) return 1
      p = abs + mlen
    }
    return 0
  }

  # Drop a trailing comment, but only a real one: a `#` inside quotes is text.
  # This repo names the issue in almost every test title (`@test "… (#1011)" {`),
  # so a naive strip would eat the opening brace and report every opener as
  # malformed. Always called with carry_sq == carry_dq == 0 (rule 1b intercepts
  # every continuation line before this ever runs), so it starts its OWN quote
  # count fresh rather than seeding from the carry.
  function strip_comment(line,   i, c, prev, n_s, n_d) {
    n_s = 0; n_d = 0
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"" && n_s % 2 == 0) { n_d++; continue }
      if (c == "'"'"'" && n_d % 2 == 0) { n_s++; continue }
      # A `#` starts a comment only at a WORD BOUNDARY, as in the shell.
      # Without that, an unquoted expansion carrying a `#` (`${#a[@]}`,
      # `${v#prefix}`, `$#`) would truncate the judged code and hide an
      # offender or a heredoc opener later on the same line.
      prev = (i == 1) ? "" : substr(line, i - 1, 1)
      if (c == "#" && n_s % 2 == 0 && n_d % 2 == 0 &&
          (i == 1 || prev ~ /[[:blank:]();&|]/)) return substr(line, 1, i - 1)
    }
    return line
  }

  # The shared offender judgement (#1068): a condition is exempt (the caller
  # may ALSO invoke this on the remainder after a closed construct — see rule
  # 5 — where the exemption still correctly applies to a NESTED condition on
  # that remainder), then the two offender rules in the same order and with
  # the same one-report-per-line precedence rules 6/6b always had. `report` is
  # what gets attributed to the offending line — always the RAW line (leading
  # blank trimmed), even when `jcode` is a substring of it (a one-liner
  # interior, or a post-construct remainder), so the operator sees the source
  # verbatim exactly as every other offender report does.
  function judge_code(jcode, report,   h) {
    if (jcode ~ /^[[:blank:]]*(if|elif|while|until)[[:blank:]]/) return 0
    if (jcode ~ /^[[:blank:]]*\[\[/ || sep_bracket(jcode)) {
      printf "O\t%s\t%d\tbracket\t%s\n", FILENAME, FNR, report
      return 1
    }
    h = helper_open(jcode)
    if (h && and_after(jcode, h)) {
      printf "O\t%s\t%d\tand-tail\t%s\n", FILENAME, FNR, report
      return 1
    }
    return 0
  }

  # Limit 1 (#1068): a self-contained one-line block (`@test "x" { ...; }`) has
  # a body after all — unlike the true one-liner hooks this shares its caller
  # with (`teardown() { rm -rf "$W"; }`), which have nothing to hide an
  # assertion in. Extract the text between the FIRST `{` and the trailing `}`
  # and judge it exactly as a normal block line would be; a fixture with no
  # offender in that interior stays unflagged either way, so the single-
  # statement one-liner needs no special case.
  # The opening `{` is found by a quote-aware walk, not index(): this repo puts
  # the issue number in almost every `@test` title, and a title may equally
  # carry a brace (`@test "expands {a}" { … }`). index() would take the title'"'"'s
  # brace, so the extracted interior would start mid-title, inherit the title'"'"'s
  # unmatched closing quote, and then read the rest of the line as string —
  # hiding a real offender behind a confident clean. The walk mirrors
  # strip_comment'"'"'s parity model (a backslash escapes the next character).
  function judge_oneliner(open_line, report,   i, c, n_s, n_d, op, inner) {
    n_s = 0; n_d = 0; op = 0
    for (i = 1; i <= length(open_line); i++) {
      c = substr(open_line, i, 1)
      if (c == "\\") { i++; continue }
      if (c == "\"" && n_s % 2 == 0) { n_d++; continue }
      if (c == "'"'"'" && n_d % 2 == 0) { n_s++; continue }
      if (c == "{" && n_s % 2 == 0 && n_d % 2 == 0) { op = i; break }
    }
    if (op == 0) return
    inner = substr(open_line, op + 1, length(open_line) - op - 1)
    judge_code(inner, report)
  }

  # Limit 2 (#1068): the text after the LAST top-level (non-quoted)
  # `fi`/`done` closer on the line, or "" when there is none. The closer may
  # be followed by `;`, `&&` or `||` — all three end the construct and start a
  # new command, and `fi && [[ -f a ]]` is the same swallowed assertion as
  # `fi; [[ -f a ]]`. A plain compound condition (`if [[ a ]] && [[ b ]]; then`)
  # contains no closer at all, so it is untouched and rule 5'"'"'s exemption still
  # covers it in full. Note a closer CAN appear inside a still-open condition
  # list (`while if true; then :; fi; [[ -f x ]]; do`) — there the remainder is
  # still condition, not an assertion, which is why rule 5 checks for a
  # still-open condition BEFORE consulting this. The boundary class (`^` or a
  # blank/`;`/`&`/`|`) is a coarse but portable word-boundary substitute: this
  # awk has no `\<`/`\>`.
  function closed_construct_tail(ccode,   p, abs, mlen, last) {
    last = 0
    p = 1
    while (p <= length(ccode) &&
           match(substr(ccode, p), /(^|[[:blank:];&|])(fi|done)[[:blank:]]*(;|&&|\|\|)/)) {
      abs = p + RSTART - 1
      mlen = RLENGTH
      if (!in_quotes(substr(ccode, 1, abs - 1))) last = abs + mlen
      p = abs + mlen
    }
    if (last == 0) return ""
    return substr(ccode, last)
  }

  # True when `prefix` ends inside an unclosed `$(( … ))`. The `|`/`&&` opener
  # alternatives accept `<<` + identifier + operator, which an arithmetic shift
  # whose RHS is followed by a bitwise/logical operator also spells
  # (`echo $((a<<b|c))`) — that would open a phantom heredoc named `b`. The
  # redirection-only alternative could not match inside `$(( ))` because the
  # trailing `))` fails its end anchor, so this is a surface the widened
  # alternatives introduced. Both spellings are screened — `$(( … ))` and the
  # bare `(( … ))` arithmetic command (which `if (( … )); then` also reaches,
  # via rule 5). A subscript like `${a[i<<j|k]}` is not, and still fails LOUD
  # as an unterminated-heredoc desync rather than as a false clean. Only the
  # LAST occurrence matters — precisely, the last UNQUOTED one: nested
  # arithmetic whose inner
  # `$(( ))` closes before the `<<` can still slip past, which fails loud as an
  # unterminated-heredoc desync rather than as a false clean.
  function in_arith(prefix,   p, abs, last, mlen) {
    last = 0
    p = 1
    # Only an UNQUOTED `$((` opens an arithmetic context. Screening on quoted
    # ones too would refuse a real opener on a line that merely mentions the
    # shape (`lacks "$o" '"'"'echo $((a'"'"'; cat <<EOF`), reading its payload as code
    # — a false clean this screen would itself have created. The match length
    # is snapshotted before the in_quotes call like every other loop here, so
    # the file states that rule once rather than stating it and excepting it.
    while (p <= length(prefix) && match(substr(prefix, p), /\$?\(\(/)) {
      abs = p + RSTART - 1
      mlen = RLENGTH
      if (!in_quotes(substr(prefix, 1, abs - 1))) last = abs + mlen
      p = abs + mlen
    }
    if (last == 0) return 0
    return (substr(prefix, last) !~ /\)\)/)
  }

  # Limit 5 (#1068): the heredoc-opener recognizer, factored out of rule 7 so
  # it can ALSO run on a condition-exempt line (rule 5) before that line is
  # abandoned — previously the condition exemption `next`ed before rule 7 ever
  # saw it, so `if grep -q y <<EOF; then` was never tracked. Three tails are
  # now accepted beyond the original redirection-only one: a `|` pipe, an `&&`,
  # and the `; then`/`; do` that a condition-line heredoc opener always ends
  # in. Whichever alternative matches, `tok` is stripped down to the bare
  # delimiter the same way regardless of which tail matched.
  # `rs`/`rl` snapshot RSTART/RLENGTH the moment the alternation matches. They
  # are NOT a convenience: in_arith below runs match() itself, which clobbers
  # the globals, and the delimiter is extracted from them afterwards — reading
  # RSTART directly there silently extracted the wrong span and un-tracked
  # every heredoc whose opener line reached the screen. in_quotes is safe (it
  # is a character loop) but relying on that distinction is exactly the trap.
  function try_open_heredoc(hcode,   lt, tok, ok, rs, rl) {
    ok = match(hcode, /(^|[^<])<<-?[[:blank:]]*["'"'"']?[A-Za-z_][A-Za-z_0-9.-]*["'"'"']?([[:blank:]]+[0-9]*[<>]+[[:blank:]]*[^[:blank:]]+)*[[:blank:]]*$/) \
      || match(hcode, /(^|[^<])<<-?[[:blank:]]*["'"'"']?[A-Za-z_][A-Za-z_0-9.-]*["'"'"']?[[:blank:]]*\|[[:blank:]]*([^[:blank:]].*)?$/) \
      || match(hcode, /(^|[^<])<<-?[[:blank:]]*["'"'"']?[A-Za-z_][A-Za-z_0-9.-]*["'"'"']?[[:blank:]]*&&[[:blank:]]*([^[:blank:]].*)?$/) \
      || match(hcode, /(^|[^<])<<-?[[:blank:]]*["'"'"']?[A-Za-z_][A-Za-z_0-9.-]*["'"'"']?[[:blank:]]*;[[:blank:]]*(then|do)[[:blank:]]*$/)
    if (!ok) return 0
    rs = RSTART; rl = RLENGTH
    # A quoted `<<EOF` that ENDS the matched span satisfies the anchor via its
    # closing quote, so the anchor alone is not enough — an assertion ABOUT a
    # heredoc (`lacks "$output" "cat <<EOF"`) would otherwise open a phantom
    # one and swallow the rest of the file, reporting it clean.
    lt = rs
    if (substr(hcode, lt, 1) != "<") lt++
    if (in_quotes(substr(hcode, 1, lt - 1))) return 0
    if (in_arith(substr(hcode, 1, lt - 1))) return 0
    tok = substr(hcode, rs, rl)
    sub(/^[^<]*/, "", tok)
    dash = (tok ~ /^<<-/)
    sub(/^<<-?[[:blank:]]*/, "", tok)
    sub(/([[:blank:]]+[0-9]*[<>]+[[:blank:]]*[^[:blank:]]+)*[[:blank:]]*$/, "", tok)
    sub(/[[:blank:]]*\|.*$/, "", tok)
    sub(/[[:blank:]]*&&.*$/, "", tok)
    sub(/[[:blank:]]*;[[:blank:]]*(then|do)[[:blank:]]*$/, "", tok)
    gsub(/["'"'"']/, "", tok)
    if (tok == "") return 0
    in_heredoc = 1
    delim = tok
    return 1
  }

  function flush_file() {
    # A nested helper still OPEN here never had its close recognized: the file
    # (or this file, in a multi-file scan) ended inside the body rule 4b
    # suppresses. This is the THIRD of the three sites that fold a stuck helper
    # into the tally — rule 3 (a new block opener arrives first), rule 4 (the
    # enclosing block closes first), and this one (the file ends inside the
    # body). All three are needed for the exit-2 promise to be unconditional,
    # and all three report through the one diagnostic below; do not delete any
    # of them as redundant. The FNR == 1 resets run AFTER this, so the state
    # read here is always the flushed file'"'"'s own.
    if (in_helper) {
      n_stuck_helper++
      stuck_helper_lines = stuck_helper_lines " " helper_open_line
    }
    if (in_heredoc)
      printf "D\t%s\theredoc opened with %s is never terminated — the rest of the file was not scanned\n", prev_file, delim
    # #1068: the cross-line quote carry can stick, and a stuck carry makes rule
    # 1b swallow every remaining line — including the block'"'"'s own close — so the
    # scan would report a confident exit 0 on a file it stopped reading. Same
    # class as the unterminated heredoc above, so it gets the same hard error
    # rather than a silent pass.
    if (carry_sq || carry_dq)
      printf "D\t%s\ta multi-line quoted literal is never closed — the rest of the file was not scanned\n", prev_file
    # #1068: likewise a nested helper whose close was never recognized. Its
    # body is suppressed from judgement, so a stuck in_helper silently unscans
    # the remainder of the enclosing block.
    if (n_stuck_helper > 0)
      printf "D\t%s\t%d nested helper function(s) never closed (line(s):%s) — a nested helper must close on an INDENTED line holding only }, optionally with a ; or a redirection tail (a column-0 } closes the enclosing block instead)\n", prev_file, n_stuck_helper, stuck_helper_lines
    if (n_bad_open > 0)
      printf "D\t%s\t%d block opener(s) not recognized (line(s):%s) — an opener must be written on one line ending in {, at column 0\n", prev_file, n_bad_open, bad_lines
  }

  # The assertion-helper roster, spelled ONCE and used as a dynamic regex by
  # helper_open. Keep it in sync with tests/assertions.bash: a helper missing
  # here is not covered by the `and-tail` rule — but NOT silently. The
  # roster-sync test in tests/no-inert-bracket-assertions.bats derives the
  # roster from the library and reds in BOTH directions when this disagrees
  # with it. See the ADDING A HELPER checklist in the header.
  BEGIN { H = "(contains|lacks|starts_with|ends_with|matches)" }

  FNR == 1 {
    if (prev_file != "") flush_file()
    prev_file = FILENAME
    in_block = 0; in_heredoc = 0; delim = ""; dash = 0
    n_bad_open = 0; bad_lines = ""
    # Limit 3 / limit 4 state (#1068), reset per file exactly like the rest of
    # the block-tracking state above: in_helper tracks a nested function
    # opener inside a scanned block, carry_sq/carry_dq track quote parity
    # across the line boundary within a block, and n_stuck_helper counts
    # nested helpers whose close was never recognized (a desync, see
    # flush_file).
    in_helper = 0; carry_sq = 0; carry_dq = 0
    n_stuck_helper = 0; stuck_helper_lines = ""; helper_open_line = 0
  }

  # 1. Inside a heredoc: consume until the terminator; flag nothing. Only a
  #    `<<-` heredoc accepts an indented terminator, and only tabs — matching
  #    the shell, so the detector never closes one the shell keeps open.
  in_heredoc {
    line = $0
    if (dash) sub(/^\t+/, "", line)
    if (line == delim) { in_heredoc = 0; delim = "" }
    next
  }

  # 1b. Limit 4 (#1068): a line that BEGINS already inside a multi-line quoted
  #     literal carried over from a previous line is pure string data — never
  #     a comment, a block opener/closer, an offender, or a heredoc opener.
  #     Must run before rule 2 (a continuation line starting with `#` is text,
  #     not a real comment) and before the block-close rule (a column-0 `}`
  #     inside the literal must not clear the block). Only this line'"'"'s own
  #     quote characters matter, to learn whether the literal closes here;
  #     if it does not, the carry — and therefore this same swallow — simply
  #     repeats on the next line.
  in_block && (carry_sq || carry_dq) {
    apply_quote_carry($0)
    next
  }

  # 2. Full-line comments are prose: they can neither assert, close a block, nor
  #    open a heredoc (a comment ending in `<<EOF` otherwise swallows the file).
  /^[[:blank:]]*#/ { next }

  # Everything below judges the CODE on the line, with any trailing comment
  # removed — an offender or a heredoc opener quoted inside a comment is text.
  # Reported output still uses `$0`, so the operator sees the source verbatim.
  { code = strip_comment($0) }

  # Carry this line'"'"'s own quote parity forward for whichever line comes
  # NEXT (#1068). Runs before rule 3 so it never fires on the opener line
  # itself (in_block is still 0 there until rule 3 sets it, and rule 3 resets
  # the carry anyway) but does fire for every other in-block line, regardless
  # of which rule below ultimately consumes it.
  #
  # A carry is only ESTABLISHED on a line the flat parity model can actually
  # defend. `$( … )` and backticks restart the shell'"'"'s quoting context, which a
  # left-to-right parity walk does not model, so a perfectly balanced real line
  # such as
  #   set="$(printf '"'"'%s\n'"'"' "$X" | grep -oE "\-path '"'"'[^'"'"']+'"'"'" | sort -u)"
  # (tests/react-topic-marker.bats) counts ODD and would otherwise open a
  # phantom literal that swallows everything after it. A `)` is refused for the
  # mirror case: the line that CLOSES such a substitution
  # (`'"'"' "$CFG")"`, tests/coverage-floor-hook.bats) also counts odd on its own.
  # Refusing to carry on these lines leaves them judged exactly as they were
  # before #1068 — per line, occasionally wrong, but never wrong beyond their
  # own line — while a plain multi-line literal, which carries none of these
  # characters on its opening line, is tracked as limit 4 intends. A carry
  # already OPEN is unaffected: only the establishing line is screened, so a
  # continuation line may close on anything. `was_open` is belt-and-braces:
  # rule 1b already `next`s every line that starts inside a literal, so the
  # carry is provably 0,0 whenever this runs and the test cannot fire today.
  # It is kept so the screen stays correct if that ordering is ever changed —
  # the guard must screen ESTABLISHMENT only, never a close.
  in_block {
    was_open = (carry_sq || carry_dq)
    apply_quote_carry(code)
    if (!was_open && (carry_sq || carry_dq) &&
        (index(code, "$(") || index(code, "`") || index(code, ")"))) {
      carry_sq = 0; carry_dq = 0
    }
  }

  # 3. Block openers, counted per opener so a malformed one is reported even
  #    when its siblings are fine. A self-contained one-liner (`{ … }` on the
  #    same line) HAS a body — limit 1 (#1068) judges it via judge_oneliner —
  #    but still neither opens nor stays open, since there is nothing left to
  #    scan on a later line.
  /^[[:blank:]]*@test[[:blank:]]/ ||
  /^[[:blank:]]*(function[[:blank:]]+)?(setup|teardown|setup_file|teardown_file)[[:blank:]]*(\(\))?[[:blank:]]*\{/ ||
  /^[[:blank:]]*(function[[:blank:]]+)?(setup|teardown|setup_file|teardown_file)[[:blank:]]*\(\)[[:blank:]]*$/ {
    # Judge the shape on the code, not on the raw line: a trailing comment must
    # not turn a perfectly legal opener into a reported desync. strip_comment is
    # quote-aware, so a `#` inside an `@test` title is text — pinned by "a legal
    # opener carrying a trailing comment is NOT a desync".
    open_line = strip_comment($0)
    sub(/[[:blank:]]+$/, "", open_line)
    # The recognizer accepts every spelling the SCAN path admits, so a
    # well-formed opener is never a phantom "not recognized". Anything else the
    # admitting pattern sees — notably a hook whose `{` sits on the NEXT line —
    # is REPORTED rather than skipped: leaving it unmatched would silently
    # unscan the whole hook body and still exit 0.
    if (open_line ~ /^[[:blank:]]*(@test[[:blank:]]|(function[[:blank:]]+)?(setup|teardown|setup_file|teardown_file)[[:blank:]]*(\(\))?[[:blank:]]*\{)/ &&
        open_line ~ /^[^[:blank:]]/ && open_line ~ /\{[[:blank:]]*$/) {
      # The new-block-opener stuck-helper path (#1068). This rule runs before
      # rule 4b, so a
      # column-0 opener reached while a nested helper is still open lands here
      # rather than in the suppression rule — and resetting in_helper without
      # counting would discard the whole suppressed span behind a clean exit.
      # Rule 4 covers "the enclosing block closed first" and flush_file covers
      # "the file ended inside the body"; this covers "a new block started
      # first". All three fold into the same tally, which is what makes the
      # exit-2 promise actually unconditional.
      if (in_block && in_helper) {
        n_stuck_helper++
        stuck_helper_lines = stuck_helper_lines " " helper_open_line
      }
      in_block = 1
      in_helper = 0
      carry_sq = 0; carry_dq = 0
    }
    else if (open_line ~ /\{/ && open_line ~ /\}[[:blank:]]*$/) {
      # Limit 1 (#1068): self-contained one-line block — judge its interior,
      # then fall through to `next` below without ever opening a block.
      text = $0
      sub(/^[[:blank:]]+/, "", text)
      judge_oneliner(open_line, text)
    }
    else if (open_line !~ /\}[[:blank:]]*$/) {
      n_bad_open++
      bad_lines = bad_lines " " FNR
    }
    next
  }

  # 4. Block close: a `}` at column 0. Only reached when rule 1b did NOT
  #    already claim this line as a quote continuation, so a column-0 `}`
  #    inside a multi-line literal (limit 4) never reaches here.
  in_block && /^\}/ {
    # #1068: reaching the block'"'"'s close with a nested helper still open means
    # its own close was never recognized, so everything from its opener to
    # here went unjudged. Count it as a desync rather than resetting quietly —
    # a silently unscanned span is exactly what "exit 0 is a verdict" forbids.
    if (in_helper) {
      n_stuck_helper++
      stuck_helper_lines = stuck_helper_lines " " helper_open_line
    }
    in_block = 0
    in_helper = 0
    carry_sq = 0; carry_dq = 0
    # A block close can carry a heredoc redirection too (`} <<EOF`), for the
    # same reason rule 4b'"'"'s close can. Untracked, the payload would be read as
    # top-level code, where a `@test`-shaped payload line would open a phantom
    # block and get its contents judged. Same one-line remedy, same no-op for
    # every other close.
    try_open_heredoc(code)
    next
  }

  # 4b. Limit 3 (#1068): inside a nested helper function defined WITHIN a
  #     scanned block, suppress the offender rules until its own close — an
  #     INDENTED `}`, alone on the line save for a `;` or a redirection tail.
  #     Column 0 is NOT a nested-helper close: rule 4 claims it first for the
  #     OUTER block, and reaching it with a helper still open is the stuck-
  #     helper desync rather than a close. The tail
  #     spellings matter: a helper closed `} 2>/dev/null` or `};` would
  #     otherwise never clear in_helper, silently suppressing the rest of the
  #     enclosing block. The nested function'"'"'s own `and-tail` exposure stays
  #     the documented, unrelated false negative it always was — this rule
  #     only stops the FALSE POSITIVE of flagging its `bracket` line, exactly
  #     as a top-level (unscanned) helper function is never flagged for the
  #     same shape. A heredoc opened INSIDE the helper body is still tracked,
  #     so its payload is skipped as payload rather than read as code — a
  #     column-0 `}` in an untracked payload would otherwise clear the
  #     enclosing block and unscan the rest of it.
  in_block && in_helper {
    if (code ~ /^[[:blank:]]*\}([[:blank:]]*;)?([[:blank:]]+[0-9]*[<>]+[[:blank:]]*[^[:blank:]]+)*[[:blank:]]*$/) {
      in_helper = 0
      # The accepted redirection tail is `[<>]+`, which also matches `<<` — so
      # the close itself can OPEN a heredoc (`} <<EOF`, a redirection attached
      # to the function body: legal bash). Track it before consuming the line,
      # or the payload is read as code and a column-0 `}` in it clears the
      # enclosing block, silently unscanning the rest of the test. A no-op for
      # every non-heredoc tail, so the plain `};` / `} 2>/dev/null` closes are
      # unaffected.
      try_open_heredoc(code)
      next
    }
    try_open_heredoc(code)
    next
  }

  # 4c. The nested helper opener itself: spread across lines, ending the line
  #     right after `{` with nothing else. A self-contained nested one-liner
  #     falls through instead and is judged WHOLE-LINE by rules 6/6b — NOT via
  #     judge_oneliner, which only rule 3 reaches — so its `[[` is flagged when
  #     a separator precedes it and missed when it follows `{ ` directly (a
  #     documented FALSE POSITIVE above, not a scoped helper). Admits the same
  #     single-line spellings rule 3 admits for hooks (`name() {`, `name () {`,
  #     `function name() {`, `function name {`), so a nested helper written in
  #     any of them is scoped alike — recognizing only one of them
  #     would leave the others flagged with "convert it to a helper" advice on
  #     a line that already IS a helper definition. The four hook names never
  #     reach here: rule 3'"'"'s own patterns already claim and `next` those lines
  #     first, regardless of block state.
  in_block && !in_helper && code ~ /^[[:blank:]]*((function[[:blank:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:blank:]]*\(\)|function[[:blank:]]+[A-Za-z_][A-Za-z0-9_]*)[[:blank:]]*\{[[:blank:]]*$/ {
    in_helper = 1
    helper_open_line = FNR
    next
  }

  # 5. A condition is control flow, never an assertion — exempt so a compound
  #    `if [[ a ]] && [[ b ]]` is not flagged with advice that would break it.
  #    Limit 2 (#1068): the exemption used to cover the WHOLE line
  #    unconditionally, missing an assertion after a closed construct on the
  #    same line (`if …; then …; fi; [[ -f a ]]`) — now the remainder after
  #    the LAST top-level `fi;`/`done;` is re-judged same as any other block
  #    line. A compound condition has no such closer on its own line, so it is
  #    untouched. Limit 5 (#1068): a heredoc opener on this line — previously
  #    invisible, since the old blanket `next` ran before rule 7 ever saw it —
  #    is now tracked too, so its payload is skipped rather than misread as
  #    code.
  in_block && code ~ /^[[:blank:]]*(if|elif|while|until)[[:blank:]]/ {
    # A line ending in `; then` / `; do` has NOT closed its condition — every
    # token on it, including anything after a nested construct'"'"'s own `fi;`, is
    # still part of the condition list whose status the construct consumes.
    # Re-judging there would flag control flow as an assertion and advise the
    # one conversion the CONDITIONS section above says breaks it (a helper in
    # a file lacking `load assertions` makes the branch silently false via 127).
    if (code !~ /;[[:blank:]]*(then|do)[[:blank:]]*$/) {
      rem = closed_construct_tail(code)
      if (rem != "") {
        text = $0
        sub(/^[[:blank:]]+/, "", text)
        judge_code(rem, text)
      }
    }
    try_open_heredoc(code)
    next
  }

  # 6 + 6b. The two offender rules (`bracket`, then `and-tail` — #1067), via
  #         the shared judge_code so limits 1 and 2 above can reuse the exact
  #         same judgement on an interior or a remainder rather than a copy.
  in_block {
    text = $0
    sub(/^[[:blank:]]+/, "", text)
    if (judge_code(code, text)) next
  }

  # 7. Heredoc opener, for a line that carried no offender (a line that DID is
  #    never tracked here — rule order is what keeps a flagged-line heredoc a
  #    documented false positive rather than a silently-swallowed payload).
  try_open_heredoc(code) { next }

  END { if (prev_file != "") flush_file() }
' "${scan[@]}")" || awk_status=$?

if (( awk_status )); then
  print -u2 "find-inert-bracket-assertions.zsh: scan failed (awk exit $awk_status)"
  exit 2
fi

# Split the typed records in zsh rather than piping back through awk: a second
# unchecked command substitution could yield empty output on failure and be read
# as "clean", and re-splitting on tabs would truncate an offender line that
# itself contains one.
local -a rows offenders diagnostics
rows=("${(@f)out}")
offenders=()
diagnostics=()

local r rest rfile rline rrule rtext
for r in "${rows[@]}"; do
  if [[ -z "$r" ]]; then
    continue
  fi
  case "$r" in
    (O$'\t'*)
      rest="${r#O$'\t'}"
      rfile="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      rline="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      # The rule tag is a fixed field; everything after it is the source line
      # verbatim, tabs included.
      rrule="${rest%%$'\t'*}"; rtext="${rest#*$'\t'}"
      offenders+=("$rfile:$rline: $rrule: $rtext")
      ;;
    (D$'\t'*)
      rest="${r#D$'\t'}"
      rfile="${rest%%$'\t'*}"; rtext="${rest#*$'\t'}"
      diagnostics+=("$rfile: $rtext")
      ;;
    (*)
      # Fail closed, per "exit 0 is a verdict, not a shrug": a record type this
      # loop does not know is information being dropped, and a silently dropped
      # offender row is exactly the false clean the typed records exist to avoid.
      print -u2 "find-inert-bracket-assertions.zsh: unrecognized record: $r"
      exit 2
      ;;
  esac
done

if (( ${#diagnostics} )); then
  print -u2 "find-inert-bracket-assertions.zsh: cannot trust this scan —"
  local d
  for d in "${diagnostics[@]}"; do print -u2 "  $d"; done
  exit 2
fi

if (( ${#offenders} )); then
  print -rl -- "${offenders[@]}"
  exit 1
fi
exit 0
