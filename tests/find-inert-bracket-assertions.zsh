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
# whose first token is `if`, `elif`, `while` or `until` is therefore exempt in
# full — including the second half of a compound condition such as
# `if [[ -f a ]] && [[ -f b ]]; then`, which the separator rule would otherwise
# flag with advice that does not apply. The exemption covers BOTH rules for the
# same reason: `if contains "$x" "a" && contains "$x" "b"; then` is a compound
# condition, not two swallowed assertions.
#
# WHERE it is inert — the scoping rule this detector implements:
#   * `@test` bodies, and `setup` / `teardown` / `setup_file` / `teardown_file`
#     (`setup` verified inert on bash 3.2.57; the other three hooks are scanned
#     on the same reasoning) are SCANNED — when the opener is written on one
#     line ending in `{`, and closed by a `}` at column 0. A self-contained
#     one-line block (`teardown() { rm -rf "$W"; }`) is neither scanned nor
#     reported: it has no body to hide an assertion in.
#   * a named helper function is NOT scanned. For `bracket` that is a sanctioned
#     fix WHEN the `[[ ]]`'s status is what the function returns — its last
#     command, or one carrying an explicit `|| return` — because the call site is
#     then a simple command errexit catches; `contains() { [ … ]; }` and friends
#     are the answer rather than the defect. A `[[ ]]` whose status the function
#     DISCARDS is as inert as one in a test body and, being unscanned, is missed
#     (FALSE NEGATIVES, below). For `and-tail` the unscanned-ness is a plain
#     false negative in every case — wrapping `contains … && true` in a function
#     does not rescue it, it only hides it. tests/assertions.bash is the shared
#     helper library and the reference for the idiom.
#   * heredoc bodies are payload, not assertions — a test that *writes* a script
#     containing `[[ ]]` is fine — so heredocs are skipped;
#   * full-line comments are prose, never code.
#
# No positional exemption: a trailing `[[ ]]` is safe only by accident of
# position and goes inert the moment anyone appends a line below it, so a
# final-line occurrence is flagged like any other (subject to the detection rule
# and blind spots above).
#
# Known, accepted limits — narrow, and none of these shapes exists in this
# suite. They run in BOTH directions, so read the direction before acting on a
# flag.
#
# FALSE POSITIVES (a safe `[[ ]]` or helper call is flagged — do NOT convert it;
# restructure the line so the detector can see it, or leave it alone):
#   * a helper function *defined inside* a scanned block and spread across lines
#     has its `[[` line flagged even though a call to it is caught;
#   * `and-tail` judges the WHOLE line, so a helper call followed later on the
#     same line by an `&&` belonging to a *closed* construct
#     (`contains "$x" a; if …; then …; fi && y`) is flagged even though the
#     helper's own status is caught;
#   * quote tracking is per line, so a continuation line of a multi-line quoted
#     literal that begins with `[[`, or a column-0 `}` inside such a literal, is
#     read as code;
#   * a heredoc opened on a line an offender rule flags and `next`s on
#     (`contains … && cat > "$f" <<EOF`) is not tracked, so its payload is
#     scanned as code and a payload line beginning with `[[` is reported as an
#     offender. Here the verdict is not a false clean — the line that caused it
#     is itself reported (exit 1) — or, if the misread payload happens to carry
#     a block-opener shape or a `<<` of its own, the scan trips a desync
#     (exit 2) and suppresses the list. Non-zero either way. The OTHER two untracked-
#     heredoc shapes are worse and are listed under FALSE NEGATIVES, not here.
#
# FALSE NEGATIVES (an inert assertion is missed):
#   * a self-contained ONE-LINE block with several statements
#     (`@test "x" { [[ -f a ]]; true; }`) is skipped rather than scanned;
#   * the condition exemption skips the WHOLE line, so an assertion that follows
#     a closed construct on that line (`if …; then …; fi; [[ -f a ]]`) is missed;
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
#     model; no such literal exists in this suite;
#   * a `[[ ]]` inside a named helper function whose status the function
#     DISCARDS (not its last command, no `|| return`) is as inert as one in a
#     test body — and function bodies are not scanned, so it is missed. Only the
#     status-returning shape is the sanctioned fix;
#   * a heredoc opened on a CONDITION line (`if grep -q y <<EOF; then`, consumed
#     by the condition exemption) or with a tail the opener rule does not accept
#     (`<<EOF | tee f`, `<<EOF && x`) is never tracked and nothing reports the
#     line. Its payload is then scanned as code, so a column-0 `}` in the payload
#     clears the block and every later assertion in it goes unscanned. Neither
#     exists in this suite; keep heredoc openers off condition lines and out of
#     pipelines;
#   * a column-0 `}` inside a MULTI-LINE quoted literal is read as code (quote
#     tracking is per line — also listed under FALSE POSITIVES, for the
#     continuation line it misreads). It clears the block the same way, so every
#     later assertion in that test goes unscanned.
#
# Those last two are the shapes that can exit 0 on a file the scanner did not
# fully read — the desync guards below catch a heredoc or opener it could not
# parse, but a block cleared EARLY looks exactly like a block that ended.
#
# Both the offender rules and the heredoc-opener rule judge the line with any
# trailing comment removed and skip a `<<`/`[[` that sits inside a string, so an
# assertion or comment ABOUT either idiom is text, not code.
#
# EXIT 0 IS A VERDICT, NOT A SHRUG. A parse desync would otherwise report
# "clean" for a file it stopped reading, so the desync shapes are hard errors
# (exit 2) rather than silent passes: a heredoc still open at end of file, and a
# block opener the scanner could not recognize — counted PER OPENER, so one
# malformed `@test` among well-formed siblings is still caught.
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
# first, then track block boundaries, then flag — and only then open a new
# heredoc, so a line that is itself an assertion can never be mistaken for a
# heredoc opener. Records are tab-separated and typed: O = offender,
# D = diagnostic.
local out awk_status=0
out="$(awk '
  # True when the prefix leaves an unclosed quote — i.e. whatever follows it on
  # the line is inside a string literal rather than being code. A backslash
  # escapes the next character so an escaped quote does not flip parity.
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

  # The EARLIEST position at which an assertion helper opens a command, as the
  # first token of the line or the first token after `;`, `&&` or `||`; 0 when
  # there is none. Returns the position just PAST the token, which is where the
  # `&&` that would swallow it has to be. Earliest is enough: an `&&` after a
  # later opener is also after this one, so no other opener can widen the match.
  function helper_open(line,   p, abs) {
    # Position 1 can never be inside a string (quotes are tracked per line), so
    # the line-start case needs no in_quotes check.
    if (match(line, "^[[:blank:]]*" H "[[:blank:]]")) return RSTART + RLENGTH
    p = 1
    while (match(substr(line, p), "(;|&&|\\|\\|)[[:blank:]]*" H "[[:blank:]]")) {
      abs = p + RSTART - 1
      if (!in_quotes(substr(line, 1, abs - 1))) return abs + RLENGTH
      p = abs + RLENGTH
    }
    return 0
  }

  # An unquoted `&&` at or after `from` — the tail that makes the helper call a
  # non-final member of an AND-list. A quoted one is text: nearly every fixture
  # in this suite is a printf string that quotes exactly this shape.
  function and_after(line, from,   p, abs) {
    p = from
    while (match(substr(line, p), /&&/)) {
      abs = p + RSTART - 1
      if (!in_quotes(substr(line, 1, abs - 1))) return 1
      p = abs + RLENGTH
    }
    return 0
  }

  # A `[[` opening a command after a separator, ignoring any that sit inside a
  # quoted string. Scans EVERY match, not just the leftmost: a quoted one early
  # on the line must not mask a real one later.
  function sep_bracket(line,   p, abs) {
    p = 1
    while (match(substr(line, p), /(;|&&|\|\|)[[:blank:]]*\[\[/)) {
      abs = p + RSTART - 1
      if (!in_quotes(substr(line, 1, abs - 1))) return 1
      p = abs + RLENGTH
    }
    return 0
  }

  # Drop a trailing comment, but only a real one: a `#` inside quotes is text.
  # This repo names the issue in almost every test title (`@test "… (#1011)" {`),
  # so a naive strip would eat the opening brace and report every opener as
  # malformed.
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

  function flush_file() {
    if (in_heredoc)
      printf "D\t%s\theredoc opened with %s is never terminated — the rest of the file was not scanned\n", prev_file, delim
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

  # 2. Full-line comments are prose: they can neither assert, close a block, nor
  #    open a heredoc (a comment ending in `<<EOF` otherwise swallows the file).
  /^[[:blank:]]*#/ { next }

  # Everything below judges the CODE on the line, with any trailing comment
  # removed — an offender or a heredoc opener quoted inside a comment is text.
  # Reported output still uses `$0`, so the operator sees the source verbatim.
  { code = strip_comment($0) }

  # 3. Block openers, counted per opener so a malformed one is reported even
  #    when its siblings are fine. A self-contained one-liner (`{ … }` on the
  #    same line) has no body and is neither scanned nor reported.
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
        open_line ~ /^[^[:blank:]]/ && open_line ~ /\{[[:blank:]]*$/)
      in_block = 1
    else if (open_line !~ /\}[[:blank:]]*$/) {
      n_bad_open++
      bad_lines = bad_lines " " FNR
    }
    next
  }

  # 4. Block close: a `}` at column 0.
  in_block && /^\}/ { in_block = 0; next }

  # 5. A condition is control flow, never an assertion — exempt in full so a
  #    compound `if [[ a ]] && [[ b ]]` is not flagged with advice that would
  #    break it.
  in_block && code ~ /^[[:blank:]]*(if|elif|while|until)[[:blank:]]/ { next }

  # 6. The offender: a `[[` opening a command.
  in_block && code ~ /^[[:blank:]]*\[\[/ {
    text = $0
    sub(/^[[:blank:]]+/, "", text)
    printf "O\t%s\t%d\tbracket\t%s\n", FILENAME, FNR, text
    next
  }
  in_block && sep_bracket(code) {
    text = $0
    sub(/^[[:blank:]]+/, "", text)
    printf "O\t%s\t%d\tbracket\t%s\n", FILENAME, FNR, text
    next
  }

  # 6b. The other offender (#1067): a helper call swallowed by an `&&` tail. It
  #     runs AFTER the bracket rules, so a line carrying both is reported once,
  #     under `bracket` — whose fix (convert the `[[ ]]`) has to happen anyway.
  in_block {
    h = helper_open(code)
    if (h && and_after(code, h)) {
      text = $0
      sub(/^[[:blank:]]+/, "", text)
      printf "O\t%s\t%d\tand-tail\t%s\n", FILENAME, FNR, text
      next
    }
  }

  # 7. Heredoc opener: the delimiter, optionally followed only by redirections,
  #    at end of line. The anchor stops a `<<` inside a string from opening a
  #    phantom heredoc; allowing the redirection tail keeps the common
  #    `cat <<'"'"'EOF'"'"' > "$f"` spelling recognized. The leading `[^<]`
  #    guard rejects a here-STRING (`<<<'"'"'null'"'"'`), which opens nothing —
  #    without it the scan would swallow the rest of the file and report clean.
  match(code, /(^|[^<])<<-?[[:blank:]]*["'"'"']?[A-Za-z_][A-Za-z_0-9.-]*["'"'"']?([[:blank:]]+[0-9]*[<>]+[[:blank:]]*[^[:blank:]]+)*[[:blank:]]*$/) {
    # A quoted `<<EOF` that ENDS the line satisfies the anchor via its closing
    # quote, so the anchor alone is not enough — an assertion ABOUT a heredoc
    # (`lacks "$output" "cat <<EOF"`) would otherwise open a phantom one and
    # swallow the rest of the file, reporting it clean.
    lt = RSTART
    if (substr(code, lt, 1) != "<") lt++
    if (in_quotes(substr(code, 1, lt - 1))) next
    tok = substr(code, RSTART, RLENGTH)
    sub(/^[^<]*/, "", tok)
    dash = (tok ~ /^<<-/)
    sub(/^<<-?[[:blank:]]*/, "", tok)
    sub(/([[:blank:]]+[0-9]*[<>]+[[:blank:]]*[^[:blank:]]+)*[[:blank:]]*$/, "", tok)
    gsub(/["'"'"']/, "", tok)
    if (tok != "") { in_heredoc = 1; delim = tok }
    next
  }

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
