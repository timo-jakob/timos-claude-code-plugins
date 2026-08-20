#!/usr/bin/env bats
#
# Suite lint (#1360): two ways a bats test silently stops being the test it says
# it is. Both are swept repo-wide here, over `git ls-files 'tests/*.bats'`, for
# the same reason the family's other sweeps are: a closed file list rots, and the
# next offender lands in the file nobody remembered to add.
#
# RULE 1 — an UNGUARDED permission-barrier `chmod`.
#   tests/Dockerfile runs the suite as **uid 0**, where `chmod` is not a barrier
#   at all: root reads a `chmod 000` file and writes into a `chmod 555`
#   directory. So the denial path such a test exists to exercise never executes,
#   and the test either reds (it asserted the denial) or passes while proving
#   nothing. It passes on the macOS host lane and on both CI legs — and reds only
#   in Docker, the one lane nobody watches. That asymmetry is the whole reason
#   for a sweep rather than a one-line fix: #1360 found exactly ONE unguarded
#   instance — measured on this tree, 49 barrier sites across 15 files, all
#   guarded after the fix — and nothing stopped the next one from landing.
#
#   TWO GUARD SPELLINGS ARE RECOGNISED, AND ONLY TWO. The ban is on an
#   *unguarded* barrier rather than on a spelling, but the detector is textual,
#   so a semantically equivalent guard written another way — `[ "$EUID" -ne 0 ]`,
#   a `require_nonroot` helper, `(( EUID == 0 )) && skip` — WILL be reported
#   UNGUARDED. Write the guard inline as one of:
#     * a line whose `id -u` PRECEDES its `skip`, or that opens an `if` whose
#       body carries `skip` before `fi` (an `id -u` inside the skip's own message
#       is not a guard — that is how a dependency skip gets mistaken for one);
#     * an `if` whose condition is a `[ -r … ]` / `[ -w … ]` test and whose body
#       carries `skip`, on a LINE below its `chmod` — the ordering check runs
#       before the line's own barriers are counted, so a compressed
#       `chmod 000 "$F"; if [ -r "$F" ]; then skip; fi` is reported unguarded.
#   The effect idiom is restricted to `if`-form and to `-r`/`-w` deliberately:
#   `[ -x "$BIN/tool" ] || skip "not installed"` is how a DEPENDENCY guard is
#   written, and accepting it would let one launder every barrier beside it.
#
#   Both idioms in the tree are accepted:
#     * the UID test    — `[ "$(id -u)" -ne 0 ] || skip …`, or the multi-line
#                         `if [ "$(id -u)" -eq 0 ]; then skip …; fi`;
#     * the EFFECT test — `if [ -r "$F" ]; then skip …; fi`, which asks whether
#                         the barrier actually bites and so also covers
#                         CAP_DAC_OVERRIDE and root-squashed mounts. It must come
#                         AFTER the chmod and test the permission the barrier
#                         removed on the same path — a guard that can fire before
#                         the barrier is set skips the test everywhere.
#   A detector that knew only `id -u` would flag
#   tests/build-refine-telemetry-record.bats's effect-guarded test — a correct
#   test — and be a false alarm before it ever caught anything. Its self-tests
#   below therefore cover the positive AND both negatives.
#
# RULE 2 — a BACKTICKED `@test` description.
#   bats *evaluates* every test description to resolve variable references
#   (`eval "printf -v test_description '%s' \"$2\""`), so backticks in one run as
#   command substitution. tests/detect-stack.bats had a backticked `kubernetes`,
#   which emitted `kubernetes: command not found` to stderr once per test in that
#   file — and silently STRIPPED the word from the test's own name. Since bats
#   evaluates every description, nothing but a sweep keeps the next one out.
#
# SCOPE. Rule 1 looks only INSIDE `@test` blocks: a barrier planted in a helper
# or in `setup()` is out of scope, deliberately, because the guard that matters
# is the one that skips the *test*. It skips heredoc bodies as data. On a line
# carrying a `skip` token it masks every quoted span WHEN COUNTING BARRIERS —
# guard recognition still reads the raw line, or `"$(id -u)"` would itself be
# masked — which in this tree means
# skip messages, four of which spell out `chmod a-w` in prose — so the residual
# is: a real barrier quoted on the SAME LINE as a `skip`
# (`bash -c "chmod 000 $F" || skip "…"`) is invisible to the sweep. Put the two
# on separate lines. On every other line quoted spans are searched normally, so
# `run bash -c "chmod 000 $F"` and a `printf`-planted fixture both report a site;
# for the fixture case the remedy is to move it into a heredoc, never to add a
# root-bypass `skip` to a test that is not about permissions.
#
# RULE 2 DOES NOT TRACK HEREDOCS — the asymmetry is deliberate but worth knowing:
# it scans every `@test`-shaped line, so a bats fixture planted in a heredoc body
# would be read as a real description. Plant fixture `@test` lines with `printf`,
# as this file does. Both rules skip this file, which names the offending shapes
# in prose and plants them as fixtures.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SELF="$(basename "$BATS_TEST_FILENAME")"
  DETECTOR="$BATS_TEST_TMPDIR/detect.awk"
  BACKTICK_DETECTOR="$BATS_TEST_TMPDIR/backtick.awk"
  write_detector
  write_backtick_detector
}

# EXTRACTS THE DESCRIPTION, rather than trying to express it as one regex.
# bats evaluates exactly the text between `@test ` and the final `{`, so that
# substring — and nothing else on the line — is what may not contain a backtick.
# The regex this replaces banned a `#` between the backtick and the brace, which
# made it blind to the house style that ends descriptions with `(#1360)`: the
# majority of this suite's `@test` lines, and so the shape most likely to carry
# the next offender.
write_backtick_detector() {
  cat > "$BACKTICK_DETECTOR" <<'AWK'
# Masks quoted spans with same-length filler so the brace search below sees only
# unquoted text while offsets still line up with the original.
function blank_quoted(s,   out, i, ch, inq, qc, n) {
  out = ""; inq = 0; qc = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    # A backslash escapes the next character INSIDE a double-quoted span only
    # (single quotes have no escapes). Without this, `"a \"#\" b"` desyncs the
    # tracker, the `#` after it reads as unquoted, and the rest of the line —
    # including a real barrier — is truncated away silently.
    if (inq && qc == "\"" && ch == "\\") { out = out "XX"; i++; continue }
    if (inq) { if (ch == qc) inq = 0; out = out "X" }
    else if (ch == "'" || ch == "\"") { inq = 1; qc = ch; out = out "X" }
    else out = out ch
  }
  return out
}

/^[[:space:]]*@test[[:space:]]/ {
  # Cut at the FIRST UNQUOTED `{`, rather than requiring the line to END in one.
  # bats' one-line form `@test "desc" { body; }` is a real shape — 18 of them in
  # tests/no-cluster-deploy.bats — and end-anchoring skipped every one, so a
  # backticked description there would never have been looked at. Unquoted,
  # because a description may legitimately contain a brace (`jq '{a:1}'`).
  masked = blank_quoted($0)
  brace = index(masked, "{")
  if (brace == 0) next
  scanned++
  desc = substr($0, 1, brace - 1)
  sub(/^[[:space:]]*@test[[:space:]]+/, "", desc)
  if (index(desc, "`") > 0) printf "%s:%d: %s\n", FILE, NR, $0
}
# The count of descriptions this detector actually EXTRACTED — not a parallel
# grep's idea of how many there are. Rule 1 floors figures the detector itself
# produces, which is what makes a coverage collapse loud; without this, a
# regression that made `brace == 0` for some shape present in the tree would
# yield zero offenders against an unchanged grep-derived anchor count, i.e. a
# green sweep over a detector that read almost nothing.
END { printf "SCANNED\t%d\n", scanned }
AWK
}

# The detector, as awk over one file at a time. It prints one line per barrier
# site it finds — `OK<TAB>file:line: text` or `UNGUARDED<TAB>file:line: text` —
# so the sweep can assert BOTH that nothing is unguarded and that it actually
# saw barriers (an empty offender list from a detector that scanned nothing is
# the failure mode every sweep in this repo is written against).
write_detector() {
  cat > "$DETECTOR" <<'AWK'
# Every judgment below is made on the line's CODE — the line with any comment
# removed — never on its raw text. Both directions matter: a commented-out
# `chmod 000` must not be reported as a site (several files carry a prose line
# naming one — grep `chmod 000 is still readable`), and — the silent direction —
# a comment merely DISCUSSING `id -u` must not clear a real barrier.
#
# The strip is QUOTE-AWARE rather than a `[^"']*$` tail, because that tail failed
# on an apostrophe — and failed silently in the worst direction: a trailing
# comment like `# we don't skip here` survived the strip, `has_skip()` then saw
# the word `skip`, and the barrier on that line VANISHED from the report
# altogether (no OK line, no UNGUARDED line, and the site floor absorbs a few
# such losses without reddening). Apostrophes in trailing comments are common —
# tests/resolve-story-loop-step.bats has one on the very line this story fixed.
# Masks quoted spans with same-length filler, so the `#` search below sees only
# unquoted text while every offset still lines up with the original.
function blank_quoted(s,   out, i, ch, inq, qc, n) {
  out = ""; inq = 0; qc = ""; n = length(s)
  for (i = 1; i <= n; i++) {
    ch = substr(s, i, 1)
    # A backslash escapes the next character INSIDE a double-quoted span only
    # (single quotes have no escapes). Without this, `"a \"#\" b"` desyncs the
    # tracker, the `#` after it reads as unquoted, and the rest of the line —
    # including a real barrier — is truncated away silently.
    if (inq && qc == "\"" && ch == "\\") { out = out "XX"; i++; continue }
    if (inq) { if (ch == qc) inq = 0; out = out "X" }
    else if (ch == "'" || ch == "\"") { inq = 1; qc = ch; out = out "X" }
    else out = out ch
  }
  return out
}
function code(s,   masked, p) {
  if (s ~ /^[[:space:]]*#/) return ""
  if (index(s, "#") == 0) return s          # the common case, and the fast one
  masked = blank_quoted(s)
  p = index(masked, "#")
  if (p > 0) return substr(s, 1, p - 1)
  return s
}

# One mode CLAUSE: is it a barrier — i.e. does it deny the OWNER read or write,
# which is exactly what root then bypasses?

#   octal    owner digit 0-5 (6 = rw-, 7 = rwx are not barriers): 000, 555, 444,
#            111, 500, and 4-digit setuid/sticky forms such as 1555, 2000;
#   symbolic a `-` operator removing r or w FROM THE OWNER: a-w, -w, u-r, a-rwx;
#   `=`      an assignment affecting the owner that omits r OR w: a=rx, u=r,
#            ug=r (no write) and a=w, u=wx (no read).
# The SUBJECT test applies to both symbolic branches: `go-w` and `o-r` remove
# nothing from the owner, so root bypasses nothing and demanding a guard for them
# would be a false alarm on a correct test.
function clause_is_barrier(c,   subj, perms) {
  if (c ~ /^[0-7]?[0-5][0-7][0-7]$/) return 1
  if (c ~ /^[augo]*-[rwx]*[rw][rwx]*$/) {
    subj = c; sub(/-.*$/, "", subj)
    # an empty subject means `a`; otherwise the clause must touch owner or all
    return (subj == "" || subj ~ /[au]/)
  }
  if (c ~ /=/) {
    subj = c; sub(/=.*$/, "", subj)
    perms = c; sub(/^[^=]*=/, "", perms)
    # denies READ or WRITE, matching the stated contract — `a=w` denies read just
    # as `a=rx` denies write. An x-only removal (`a=rw`) is not a barrier.
    if ((subj == "" || subj ~ /[au]/) && (perms !~ /w/ || perms !~ /r/)) return 1
  }
  return 0
}

# EVERY `chmod` on the line, not just the first: a one-line barrier-and-restore
# (`chmod 000 "$f"; run foo; chmod 644 "$f"`) would otherwise be read as its
# restore and pass. Comma-separated clauses are split, so `chmod a-w,u+x` is
# still seen as a barrier. Each barrier occurrence is recorded separately.
function count_barriers(s,   rest, tok, n) {
  # Quoted spans are masked ONLY on a `skip` line. Four skip MESSAGES in
  # tests/resolve-story-loop.bats spell out `chmod a-w` in prose ("runs as root:
  # chmod a-w cannot make the sink unwritable"), and counting those would make the
  # reported site count disagree with the number of barriers actually executed —
  # which is what the anti-vacuity floor is calibrated against.
  #
  # NARROW ON PURPOSE. Masking every line's quoted spans also hid a `chmod` inside
  # a quoted command string (`run bash -c "chmod 000 $F"`) — a barrier that really
  # does execute — and hid the `printf`-planted fixture text SCOPE says is
  # reported. Both would have been silent under-reports. Masking beats discarding
  # the whole line on `has_skip`, which additionally swallowed a genuine barrier
  # whose trailing comment merely contained the word.
  n = 0
  # The masking TRIGGER here reads the raw line on purpose, unlike the two guard
  # gates: switching it to the masked line would make an ordinary prose line such
  # as `echo "chmod 000 means locked, skip it"` report a false site. The price is
  # that the documented same-line residual is slightly wider than "carries a skip
  # token" — any line containing that token SHAPE, quoted or not, has its quoted
  # spans masked. It fails toward under-reporting, i.e. toward the residual
  # already documented in SCOPE, never toward a false alarm.
  # A SENTINEL space, so the `chmod` match needs no `^` alternative. A leading or
  # trailing anchor INSIDE an alternation is the one regex construct whose
  # behaviour is least settled across awks, and this detector must agree exactly
  # between macOS awk and the container's mawk — divergence there would be a
  # lane-dependent verdict, which is the very thing this file exists to end. The
  # sentinel also matters for the one-line `@test "x" {chmod 000 "$F"; }` form,
  # where `chmod` sits at offset 1.
  rest = " " (has_skip(s) ? blank_quoted(s) : s)
  while (match(rest, /[^[:alnum:]_.-]chmod[[:space:]]+/)) {
    rest = substr(rest, RSTART + RLENGTH)
    tok = rest
    # REAL chmod options only. `-[A-Za-z]+` also swallowed a bare symbolic MODE:
    # `chmod -w "$f"` had its `-w` eaten as a flag, the masked path became the
    # mode token, and the barrier vanished — while clause_is_barrier() documents
    # and codes for exactly that spelling.
    sub(/^((-[RfvchHLPN]+|--[a-z][a-z-]*)[[:space:]]+)+/, "", tok)
    sub(/[[:space:]].*$/, "", tok)               # the mode token
    if (any_clause_is_barrier(tok)) n++
  }
  return n
}
function any_clause_is_barrier(t,   parts, i, n) {
  n = split(t, parts, ",")
  for (i = 1; i <= n; i++) if (clause_is_barrier(parts[i])) return 1
  return 0
}

# Either accepted idiom, recognised as a MARKER — the test that decides whether
# the barrier bites. It is deliberately never enough on its own: see the
# association rule below.
#
# The EFFECT idiom is recognised ONLY as an `if` condition, and only for `-r`/`-w`.
# Both restrictions close the same laundering hole: `[ -x "$BIN/tool" ] || skip
# "tool not installed"` is the ordinary spelling of a DEPENDENCY guard, and a
# marker+skip on one line sets the guard for the whole test — so without them an
# unrelated dependency skip clears every barrier beside it. A barrier denies read
# or write, never execute, so `-x` is never the right effect test anyway.
# TOKEN-ANCHORED: an unanchored `id -u` also fires on `uuid -u` or `--build-id -u`,
# which paired with a same-line dependency `skip` would clear every barrier beside
# it — the same laundering the effect idiom's restrictions close.
# Sentinel-prefixed and split so no anchor sits inside an alternation — see the
# note in count_barriers() on why that construct is avoided here.
function uid_marker(s,   t) {
  t = " " s
  # the follower class carries a backtick too, so the POSIX `\`id -u\`` spelling
  # is recognised alongside `$(id -u)` — otherwise a correctly guarded test reds
  return (t ~ /[^[:alnum:]_-]id[[:space:]]+-u[[:space:])"`]/ \
       || t ~ /[^[:alnum:]_-]id[[:space:]]+-u$/)
}
function effect_marker(s) {
  return (s ~ /^[[:space:]]*if[[:space:]].*\[[[:space:]]+-[rw][[:space:]]/)
}
# The uid test is position-free — it is correct above or below the barrier. The
# EFFECT test is not: it asks whether the barrier bites, so placed BEFORE the
# `chmod` it reads the still-open file, fires unconditionally, and skips the test
# on EVERY lane — silently deleting the coverage everywhere instead of only in
# Docker. Requiring a barrier to have been seen first is what enforces that.
function guard_marker(s) {
  if (uid_marker(s)) return 1
  return (effect_marker(s) && nbar > 0)
}
# `skip;` and `skip)` are legal message-less spellings; requiring whitespace
# after the word would report a correctly guarded test as an offender.
function has_skip(s,   t) {
  t = " " s
  # `-` excluded from the preceding class, exactly as uid_marker does: without it
  # `run tool --skip cache` reads as a bats skip, which inside an open guard block
  # sets the guard and on any line masks its quoted spans.
  return (t ~ /[^[:alnum:]_-]skip[[:space:];&|)]/ || t ~ /[^[:alnum:]_-]skip$/)
}
# The marker must sit BEFORE the `skip` token on the line. Both accepted
# spellings do (`[ "$(id -u)" -ne 0 ] || skip …`, `if [ -r "$F" ]; then skip …`),
# while a marker inside the skip's MESSAGE does not — without this,
# `command -v tool >/dev/null || skip "not root? check id -u"` clears every
# barrier in the test. Masking quotes instead would be wrong: it would also mask
# `"$(id -u)"` itself and report every correctly guarded test as an offender.
# The TOKEN is located on the masked copy — blank_quoted preserves length, so the
# offset still indexes the original — while the marker prefix is taken from the
# RAW line, because `"$(id -u)"` is itself quoted and masking it would hide every
# real guard. A genuine `skip` is never inside quotes.
function marker_before_skip(s,   p) {
  p = index(blank_quoted(s), "skip")
  if (p == 0) return 0
  return guard_marker(substr(s, 1, p - 1))
}
function opens_if(s) { return (s ~ /[;[:space:]]then[[:space:]]*$/) }
function closes_if(s) {
  return (s ~ /^[[:space:]]*fi[[:space:];]/ || s ~ /^[[:space:]]*fi$/)
}

# The heredoc delimiter this line opens, or "" for none. Getting this wrong in
# EITHER direction is expensive: a missed opener lets a fixture's column-0 `}`
# end the @test block early (everything after goes unscanned), and a PHANTOM
# opener swallows the rest of the file outright. Round 2 of #1360 hit three
# phantoms — a herestring, a commented `<<EOF`, and `RetryBaseDelay << shift;`
# inside a quoted Go snippet — so each screen below names the shape it exists for.
function heredoc_delim(s,   p, t, m) {
  p = s
  gsub(/<<</, "@@@", p)                    # a herestring is not a heredoc
  # Normalise `<<'EOF'` / `<<"EOF"` to `<<EOF` BEFORE blanking quoted spans, or
  # the blanking would eat a legitimate quoted delimiter.
  while (match(p, /<<-?['"][A-Za-z_][A-Za-z0-9_]*['"]/)) {
    t = substr(p, RSTART, RLENGTH)
    gsub(/['"]/, "", t)
    p = substr(p, 1, RSTART - 1) t substr(p, RSTART + RLENGTH)
  }
  # A `<<` inside a string is data: an assertion needle, a planted fixture, or an
  # arithmetic shift in a quoted code sample.
  gsub(/'[^']*'/, "", p)
  gsub(/"[^"]*"/, "", p)
  # TAIL-ANCHORED: a real opener ends the line or is followed by a
  # redirection/pipe/`;` — including a numbered one (`cat <<EOF 2>/dev/null`).
  # The residual: an arithmetic `$((a<<b))` in UNQUOTED code would still read as
  # an opener. Nothing in the tree does that, and the DESYNC guard now turns any
  # such phantom into a named failure rather than a silent truncation.
  # SPLIT, not one alternation with `$` inside it — this file forbids that
  # construct twice over (see count_barriers and uid_marker), and this is the
  # function whose mis-read is the most expensive: a phantom opener swallows the
  # rest of the file, and this is also what decides whether DESYNC fires.
  if (!match(p, /<<-?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[0-9]*[|&;)<>]/) \
   && !match(p, /<<-?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/)) return ""
  m = substr(p, RSTART, RLENGTH)
  hd_dash = (m ~ /^<<-/)
  sub(/^<<-?/, "", m)
  sub(/[[:space:]]*[0-9]*[|&;)<>]?[[:space:]]*$/, "", m)
  return m
}

function flush(   i) {
  for (i = 1; i <= nbar; i++)
    print (guard ? "OK\t" : "UNGUARDED\t") FILE ":" bars[i]
  nbar = 0; guard = 0; gblock = 0
}

BEGIN { intest = 0; nbar = 0; guard = 0; gblock = 0; hd = ""; hd_dash = 0 }

# HEREDOC BODIES ARE DATA, NOT CODE — and skipping them is load-bearing twice
# over. This suite writes pretty-printed JSON fixtures whose closing `}` sits at
# COLUMN 0 inside a `@test` (tests/telemetry-emit.bats does), which the `^}`
# block-end rule below would read as the end of the test: everything after it
# would go unscanned, so a barrier planted below such a fixture would never be
# reported at all. It also keeps a `chmod` that is merely fixture TEXT from
# being reported as a real barrier. The sibling detector
# tests/find-inert-bracket-assertions.zsh tracks heredocs for the same reason.
hd != "" {
  line = $0
  if (hd_dash) sub(/^\t+/, "", line)
  if (line == hd) hd = ""
  next
}
{
  # The OPENER line is still code (it can carry a chmod), so record the pending
  # delimiter and fall through rather than skipping it.
  hd = heredoc_delim(code($0))
}

# A `@test` opener. The ONE-LINE form `@test "x" { …; }` needs its body scanned
# on this same line and the block closed again: `next` alone both skipped the
# body (an inline barrier was a guaranteed false negative) and left `intest`
# stuck open, so every following top-level line — helper bodies included, which
# SCOPE declares out of scope — was scanned as if inside a test.
/^[[:space:]]*@test[[:space:]]/ {
  if (intest) flush()
  intest = 1
  cl = code($0)
  brace = index(blank_quoted(cl), "{")
  if (brace > 0 && substr(cl, brace) ~ /\}[[:space:]]*$/) {
    scan_body(substr(cl, brace + 1))
    flush()
    intest = 0
  }
  next
}
intest && /^}/ { flush(); intest = 0; next }
intest {
  # every judgment on CODE, never raw text
  cl = code($0)
  scan_body(cl)
  next
}
function scan_body(cl,   n, i) {
  # ASSOCIATION, not two independent whole-test flags. A marker and a `skip`
  # merely co-occurring in the same test is NOT a guard: an ordinary
  # `[ -x "$STUB/docker" ]` assertion plus an unrelated `command -v tool || skip`
  # would otherwise launder a completely unguarded barrier — the exact hole this
  # sweep exists to close. Two shapes count, and they are the two the tree uses:
  #   * marker and `skip` on the SAME line
  #     (`[ "$(id -u)" -ne 0 ] || skip …`, `if [ -r "$F" ]; then skip …; fi`);
  #   * a marker line that OPENS an `if`, with the `skip` inside it before `fi`.
  # Granularity stays per-@test on purpose: `skip` aborts the whole test, so a
  # real guard moots every barrier in it.
  # `has_skip` FIRST: marker_before_skip() locates the token with a bare index(),
  # which is a SUBSTRING match, so on its own it fires on a line like
  # `[ "$(id -u)" -eq 0 ] && echo "chmod barriers skipped" >&2` — a warn-and-
  # continue line that skips nothing — and would clear every barrier in the test.
  # Gated, the index() stays safe: landing on an earlier `skipXX` only shortens
  # the prefix, which fails closed.
  # BOTH skip gates read the MASKED line: a real `skip` is never quoted, so a
  # warn-and-continue line whose message merely contains the word — `echo "warn:
  # we skip barrier checks as root"` — must not count as one. Same fail-open
  # class as the `skipped` substring, one spelling over, and it reaches here
  # through the same-line gate and the open-if-block gate alike.
  if (has_skip(blank_quoted(cl)) && marker_before_skip(cl)) guard = 1
  else if (guard_marker(cl) && opens_if(cl)) gblock = 1
  else if (gblock && has_skip(blank_quoted(cl))) guard = 1
  if (gblock && closes_if(cl)) gblock = 0
  n = count_barriers(cl)
  for (i = 0; i < n; i++) { nbar++; bars[nbar] = NR ": " $0 }
}
# DESYNC GUARD. An opener whose delimiter never arrives means everything after it
# went unscanned — and without this the sweep reports that file clean, which is
# indistinguishable from a genuinely clean file. Round 2 of #1360 found exactly
# that failure twice (a herestring, then a commented `<<EOF`), each time by
# noticing a missing count rather than by any signal from the detector. A hard,
# named exit is the signal.
END {
  if (hd != "") {
    printf "DESYNC\t%s: heredoc %s never terminated — the rest of the file was NOT scanned. Either that file really has an unterminated heredoc, or heredoc_delim() mis-read a `<<` shape in it (a herestring, a commented opener, a quoted arithmetic shift). If the file really is unterminated, fix the heredoc in that test — the rest of it has never been scanned. If the file is valid shell, fix heredoc_delim() and add the shape to the self-tests; never edit a working test to appease the detector.\n", FILE, hd > "/dev/stderr"
    exit 2
  }
  if (intest) flush()
}
AWK
}

# The tracked tests/*.bats roster, with git's own failure TYPED rather than left
# to surface as grep's status. Both sweeps use it, so the diagnostic exists once.
# The failure it names is the likeliest one in the Docker lane — a git that
# cannot see its object store — and a bare pipeline would report it as an empty
# list, i.e. as a clean tree.
bats_file_list() {
  local out="$1" raw="$1.raw"
  if ! git -C "$REPO_ROOT" ls-files 'tests/*.bats' > "$raw"; then
    printf 'git ls-files failed — is the git store readable? In the Docker lane it is bind-mounted by tests/run-script-tests.zsh (#1360).\n' >&2
    return 1
  fi
  # This file names the banned shapes in prose and plants them as fixtures, so it
  # is excluded from its own sweeps. TYPED like the git branch above, and `-F` so
  # the filename's dots are literal: `grep -v` exits 1 when it selects nothing, so
  # left bare it would return that status as the function's own — aborting with a
  # failing-line trace rather than the named diagnostic this function exists for.
  if ! grep -vF -- "/$SELF" "$raw" > "$out"; then
    printf 'the tests/*.bats roster is empty after self-exclusion (%s tracked) — the sweep would cover nothing.\n' \
      "$(wc -l < "$raw" | tr -d ' ')" >&2
    return 1
  fi
}

# Runs the detector over a newline-delimited list of repo-relative paths.
#
# PROPAGATES the last non-zero awk status. A `while read` loop returns only its LAST
# command's status, so without this the DESYNC guard — and an awk that simply
# could not open a file — would be thrown away for every file but the last, and
# the sweep would report the tree clean. That is the failure the guard exists to
# make loud, one indirection further out.
scan() {
  local list="$1" f rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -v FILE="$f" -f "$DETECTOR" "$REPO_ROOT/$f" || rc=$?
  done < "$list"
  return "$rc"
}

scan_backticks() {
  local list="$1" f rc=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -v FILE="$f" -f "$BACKTICK_DETECTOR" "$REPO_ROOT/$f" || rc=$?
  done < "$list"
  return "$rc"
}

@test "no @test in any tracked tests/*.bats plants an UNGUARDED permission-barrier chmod (#1360)" {
  local list="$BATS_TEST_TMPDIR/files.txt" report="$BATS_TEST_TMPDIR/report.txt"
  # `git ls-files`, per the story's contract — and it works inside the Docker
  # lane only because tests/run-script-tests.zsh now bind-mounts the git dir and
  # the git common dir (#1360). Before that, in a worktree checkout, git fataled
  # and a sweep like this one would have inspected nothing.
  bats_file_list "$list"
  # ANTI-VACUITY, part 1: git actually spoke. 121 files are tracked, 120 scanned
  # (this file is excluded); the floor sits far enough below to survive normal
  # churn and far enough above zero to catch a roster that collapsed. The
  # figures are a snapshot for the reader — only the floor is enforced, so they
  # drift with every added suite rather than redding; re-measure when you notice.
  local nfiles
  nfiles="$(wc -l < "$list" | tr -d ' ')"
  if [ "$nfiles" -lt 90 ]; then
    printf 'git ls-files returned only %s tests/*.bats (~120 expected) — the sweep scanned almost nothing.\n' "$nfiles" >&2
    return 1
  fi

  scan "$list" > "$report" \
    || { printf 'the barrier detector ABORTED (DESYNC, or a file it could not read) — see stderr above; the sweep did NOT cover the whole tree.\n' >&2; return 1; }

  # ANTI-VACUITY, part 2: the detector actually FOUND barriers. An empty offender
  # list means nothing if the scan matched no `chmod` at all — a broken regex, an
  # unreadable file, an awk that never ran, or a block tracker that closed early.
  # MEASURED on this tree: 49 barrier sites across 15 files, identically under
  # macOS awk and the container's mawk 1.3.4 (an earlier draft disagreed across
  # the two — 53 vs 28 — which is why the figure is quoted for both). The floor
  # sits just below, so a coverage collapse reds instead of passing on whatever
  # survived: three separate truncation bugs during #1360 each showed up first as
  # a missing count and nothing else.
  local found
  found="$(grep -c ':' "$report" || true)"
  if [ "$found" -lt 45 ]; then
    printf 'the detector matched only %s barrier sites (49 expected) — either its regex/@test-block tracking is broken, or barrier-bearing tests were legitimately removed. Confirm which before lowering this floor, and record the new measured count here.\n' \
      "$found" >&2
    return 1
  fi
  # ...and it accepted the effect-guarded test specifically, which is the one a
  # uid-only detector would wrongly flag. A named positive control beats a count:
  # if that test is ever renamed away, this reds instead of rotting.
  contains "$(grep '^OK' "$report")" 'tests/build-refine-telemetry-record.bats'
  # ...and a file whose barrier sits AFTER a herestring, which is the shape that
  # silently truncated the scan before the opener probe learned to skip `<<<`.
  contains "$(grep '^OK' "$report")" 'tests/switch-fable-to-opus.bats'
  # ...and the only file whose barriers are SYMBOLIC (`chmod a-w`), so a
  # regression in that branch reds by name instead of hiding inside the floor's
  # margin — the four sites it contributes take 49 to exactly 45.
  contains "$(grep '^OK' "$report")" 'tests/resolve-story-loop.bats'
  # ...and the FILE dimension, not just the site count: a truncation that loses
  # one mid-sized file drops only a few sites and would clear the floor above,
  # which is exactly how the herestring bug hid. 15 files measured.
  local files_with_sites
  files_with_sites="$(sed 's/^[A-Z]*	//; s/:.*//' "$report" | sort -u | wc -l | tr -d ' ')"
  if [ "$files_with_sites" -lt 13 ]; then
    printf 'barrier sites were found in only %s files (15 expected) — a whole file is probably going unscanned. Confirm before lowering this floor, and record the new measured count here.\n' \
      "$files_with_sites" >&2
    return 1
  fi

  local offenders
  offenders="$(grep '^UNGUARDED' "$report" || true)"
  if [ -n "$offenders" ]; then
    printf 'Unguarded permission-barrier chmod(s) — root bypasses these, so the denial path never runs.\nGuard each with `[ "$(id -u)" -ne 0 ] || skip …` or `if [ -r "$F" ]; then skip …; fi`:\n%s\n' \
      "$offenders" >&2
    return 1
  fi
}

@test "the barrier detector catches a planted UNGUARDED barrier (self-test, #1360)" {
  # Written under BATS_TEST_TMPDIR and scanned by absolute path: the fixture
  # must never land in the repo, where the sweep above would find it. The
  # reported path comes from -v FILE, so the message still reads like a real one.
  printf '@test "x" {\n  mkdir -p locked\n  chmod 000 locked\n  [ ! -r locked ]\n}\n' \
    > "$BATS_TEST_TMPDIR/unguarded.bats"
  run awk -v FILE=planted.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/unguarded.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
  contains "$output" 'planted.bats:3'
  contains "$output" 'chmod 000 locked'
}

@test "the barrier detector ACCEPTS a uid-guarded barrier (negative self-test, #1360)" {
  # Both uid spellings in the tree, in one fixture: the one-line `|| skip` and
  # the multi-line `if … then skip … fi`.
  {
    printf '@test "one-liner" {\n  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "multi-line" {\n  if [ "$(id -u)" -eq 0 ]; then\n    skip "root reads every directory"\n  fi\n'
    printf '  chmod 555 "$D"\n  [ ! -w "$D" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/uid-guarded.bats"
  run awk -v FILE=uid.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/uid-guarded.bats"
  [ "$status" -eq 0 ]
  # BOTH barriers seen — otherwise "no UNGUARDED line" would be true because the
  # detector found nothing, not because it accepted them.
  [ "$(grep -c '^OK' <<<"$output")" -eq 2 ]
  lacks "$output" 'UNGUARDED'
}

@test "the barrier detector ACCEPTS an effect-guarded barrier (negative self-test, #1360)" {
  # The tests/build-refine-telemetry-record.bats idiom, verbatim in shape: the
  # guard follows the chmod and asks whether the barrier actually bites.
  {
    printf '@test "effect-guarded file" {\n  chmod 000 "$ST"\n'
    printf '  if [ -r "$ST" ]; then skip "running as a user that bypasses file permissions"; fi\n'
    printf '  [ ! -r "$ST" ]\n}\n'
    printf '@test "effect-guarded dir" {\n  chmod 555 "$R"\n'
    printf '  if [ -w "$R" ]; then skip "running as a user that bypasses directory permissions"; fi\n'
    printf '  [ ! -w "$R" ]\n}\n'
    # ...and the MULTI-LINE spelling, which traverses a different combination
    # (marker + opens_if, then a `skip` on a later line before `fi`).
    printf '@test "effect-guarded, multi-line" {\n  chmod 000 "$M"\n'
    printf '  if [ -r "$M" ]; then\n    skip "bypasses file permissions"\n  fi\n'
    printf '  [ ! -r "$M" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/effect-guarded.bats"
  run awk -v FILE=effect.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/effect-guarded.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^OK' <<<"$output")" -eq 3 ]
  lacks "$output" 'UNGUARDED'
}

@test "an effect guard placed BEFORE the chmod is not a guard (self-test, #1360)" {
  # The precondition tests/README.md states and this detector now enforces: an
  # effect test above the barrier reads the still-open file, fires every time,
  # and skips the test on EVERY lane — a worse outcome than the inert barrier it
  # was meant to prevent, because the coverage is lost everywhere rather than
  # only under uid 0. The uid idiom stays position-free, since it is correct
  # either way; the second fixture pins that.
  {
    printf '@test "effect guard too early" {\n'
    printf '  if [ -r "$F" ]; then skip "bypasses file permissions"; fi\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "uid guard early is fine" {\n'
    printf '  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"\n'
    printf '  chmod 000 "$G"\n  [ ! -r "$G" ]\n}\n'
    # ...and BOTH directions of position-free, so a later "harmonise the two
    # idioms" edit that gated uid on nbar > 0 too would red here rather than
    # start falsely reporting a correct guard.
    printf '@test "uid guard after the barrier is fine" {\n'
    printf '  chmod 000 "$H"\n'
    printf '  [ "$(id -u)" -ne 0 ] || skip "chmod proves nothing as root"\n'
    printf '  [ ! -r "$H" ]\n}\n'
    # BOTH same-line shapes, which the docs describe as reported unguarded: the
    # guard checks run before the line's own barriers are counted. The second is
    # genuinely broken (the guard fires before the barrier exists); the first is
    # the conservative residual. A "count first, then decide" refactor would flip
    # both silently, so pin them.
    printf '@test "compressed, guard after" {\n'
    printf '  chmod 000 "$I"; if [ -r "$I" ]; then skip "bypasses file permissions"; fi\n'
    printf '  [ ! -r "$I" ]\n}\n'
    printf '@test "compressed, guard before" {\n'
    printf '  if [ -r "$J" ]; then skip "bypasses file permissions"; fi; chmod 000 "$J"\n'
    printf '  [ ! -r "$J" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/ordering.bats"
  run awk -v FILE=ord.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/ordering.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 3 ]
  [ "$(grep -c '^OK' <<<"$output")" -eq 2 ]
}

@test "a trailing comment neither hides a barrier nor supplies a guard (self-test, #1360)" {
  # The silent one. With a naive `[^\"']*$` strip, an apostrophe in a trailing
  # comment left the word `skip` visible, `count_barriers` bailed, and the site
  # disappeared from the report entirely — not reported OK, not reported
  # UNGUARDED, just gone.
  {
    printf '@test "apostrophe in a trailing comment" {\n'
    printf '  chmod 000 "$F"  # the round%ss own note, we don%st skip here\n' "'" "'"
    printf '  [ ! -r "$F" ]\n}\n'
    printf '@test "a comment cannot supply the guard" {\n'
    printf '  chmod 000 "$G"  # the usual id -u skip dance belongs here, doesn%st it\n' "'"
    printf '  [ ! -r "$G" ]\n}\n'
    # SAME LINE on purpose: with the quoted hash on its own line, a naive
    # truncate-at-first-`#` strip yields a line with no chmod either way, so the
    # count is identical and the direction proves nothing.
    printf '@test "a hash inside a string is not a comment" {\n'
    printf '  run foo "a#b"; chmod 000 "$H"\n  [ ! -r "$H" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/trailing.bats"
  run awk -v FILE=tc.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/trailing.bats"
  [ "$status" -eq 0 ]
  # all three sites present, none laundered by its comment
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 3 ]
  lacks "$output" 'OK'
}

@test "the ONE-LINE @test form is scanned, and does not leave the block open (self-test, #1360)" {
  # bats' `@test "x" { …; }` is a real shape — 18 of them in
  # tests/no-cluster-deploy.bats. Skipping the line wholesale made an inline
  # barrier a guaranteed false negative AND left the block tracker open, so every
  # following top-level line (helper bodies, which SCOPE excludes) was scanned as
  # if inside a test.
  {
    printf '@test "inline barrier" { chmod 000 "$F"; [ ! -r "$F" ]; }\n'
    printf 'helper_after() {\n  chmod 000 "$OUTSIDE"\n}\n'
  } > "$BATS_TEST_TMPDIR/oneline-test.bats"
  run awk -v FILE=ol.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/oneline-test.bats"
  [ "$status" -eq 0 ]
  # the inline barrier IS a site...
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
  contains "$output" 'ol.bats:1'
  # ...and the helper below it is NOT, because the block closed on the same line
  lacks "$output" 'ol.bats:3'
}

@test "the sweep FAILS when the detector aborts on any file, not just the last (self-test, #1360)" {
  # The status-propagation contract. A `while read` loop returns only its last
  # command's status, so a DESYNC in the middle of the roster used to vanish and
  # the sweep reported the tree clean — the exact silence the DESYNC guard exists
  # to break.
  local dir="$BATS_TEST_TMPDIR/multi"
  mkdir -p "$dir"
  printf '@test "unterminated" {\n  cat > "$f" <<NOPE\n  never closed\n' > "$dir/a.bats"
  printf '@test "fine" {\n  true\n}\n' > "$dir/b.bats"
  printf 'a.bats\nb.bats\n' > "$dir/list.txt"
  # scan() resolves paths under $REPO_ROOT, so point it at the fixture dir
  REPO_ROOT="$dir"
  run scan "$dir/list.txt"
  [ "$status" -eq 2 ]
  contains "$output" 'DESYNC'
}

@test "a barrier outside a @test block is out of scope, by decision (self-test, #1360)" {
  # Pins the documented boundary rather than leaving it as prose: rule 1 inspects
  # `@test` bodies only, so a barrier in setup() or a shared helper yields no
  # site and must be guarded by hand. A green sweep therefore proves a guard is
  # present, never that one was not needed elsewhere.
  {
    printf 'setup() {\n  chmod 000 "$F"\n}\n'
    printf 'mk_locked() {\n  mkdir -p "$1"\n  chmod 000 "$1"\n}\n'
    printf '@test "uses the helper" {\n  mk_locked "$D"\n  [ ! -r "$D" ]\n}\n'
    # POSITIVE CONTROL, so "nothing reported" is an observation rather than a
    # construction: an in-@test barrier the detector MUST see. Without it this
    # fixture is equally satisfied by a detector that read nothing at all.
    printf '@test "control" {\n  chmod 000 "$CTRL"\n  [ ! -r "$CTRL" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/outside.bats"
  run awk -v FILE=out.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/outside.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
  contains "$output" 'chmod 000 "$CTRL"'
}

@test "an UNRELATED skip plus an unrelated file test does NOT clear a barrier (self-test, #1360)" {
  # The hole a whole-block marker/skip pair would leave wide open, and the reason
  # the detector associates the two: a dependency skip and an ordinary `[ -x … ]`
  # assertion are both commonplace in this suite, so accepting their mere
  # co-occurrence would launder exactly the offender the sweep exists to catch.
  {
    printf '@test "unrelated skip and unrelated file test" {\n'
    printf '  command -v somedep >/dev/null || skip "somedep not installed"\n'
    printf '  [ -x "$STUB/docker" ]\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/unassociated.bats"
  run awk -v FILE=unassoc.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/unassociated.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
  lacks "$output" 'OK'
}

@test "a COMMENTED-OUT barrier is not a site, and a comment about id -u clears nothing (self-test, #1360)" {
  # Both directions of commented(), because both are load-bearing and they fail
  # in opposite ways: the first would invent sites out of prose (several files in
  # the tree literally write `# … chmod 000 is still readable`), the second would let
  # a comment *discussing* the root problem stand in for an actual guard.
  {
    printf '@test "commented barrier only" {\n  # chmod 000 locked is what root ignores\n  true\n}\n'
    printf '@test "comment mentions the guard but does not apply it" {\n'
    printf '  # the usual [ "$(id -u)" -ne 0 ] || skip idiom belongs here\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/commented.bats"
  run awk -v FILE=commented.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/commented.bats"
  [ "$status" -eq 0 ]
  # exactly ONE site — the live one in the second test, reported UNGUARDED
  [ "$(grep -c ':' <<<"$output")" -eq 1 ]
  contains "$output" 'UNGUARDED'
  lacks "$output" 'commented.bats:2'
}

@test "a heredoc fixture and a herestring do not truncate the scan (self-test, #1360)" {
  # Two shapes that each silently ended the @test block early during
  # development, so everything after them went unscanned and a real barrier was
  # never reported: a pretty-printed JSON heredoc whose closing brace sits at
  # COLUMN 0 (tests/telemetry-emit.bats has one), and `<<<'null'` — a herestring
  # that reads exactly like a heredoc opener (the `<<<'null'` in
  # tests/switch-fable-to-opus.bats's model-enum assertion).
  {
    printf '@test "heredoc then barrier" {\n  cat > "$f" <<EOF\n{\n  "a": 1\n}\nEOF\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "herestring then barrier" {\n  run jq -e . <<<%s\n' "'null'"
    printf '  chmod 555 "$D"\n  [ ! -w "$D" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/heredoc.bats"
  run awk -v FILE=heredoc.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/heredoc.bats"
  [ "$status" -eq 0 ]
  # BOTH barriers found — a truncating scan reports one or none — and the JSON
  # fixture's own braces contribute no site of their own.
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 2 ]
  contains "$output" 'chmod 000 "$F"'
  contains "$output" 'chmod 555 "$D"'
}

@test "a same-line DEPENDENCY skip does not clear a barrier (self-test, #1360)" {
  # The widest remaining laundering shape, and the reason the effect idiom is
  # recognised only as an `if` condition and only for -r/-w: `[ -x … ] || skip`
  # is how a dependency guard is normally written, and a marker+skip on one line
  # sets the guard for the whole test.
  {
    printf '@test "dependency skip, unguarded barrier" {\n'
    printf '  [ -x "$BIN/tool" ] || skip "tool not installed"\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "dependency skip in if-form, unguarded barrier" {\n'
    printf '  if [ -x "$BIN/tool" ]; then skip "tool not installed"; fi\n'
    printf '  chmod 000 "$G"\n  [ ! -r "$G" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/depskip.bats"
  run awk -v FILE=dep.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/depskip.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 2 ]
  lacks "$output" 'OK'
}

@test "a barrier inside a quoted command string is still a site (self-test, #1360)" {
  # The under-report that masking every line's quoted spans would have caused:
  # `run bash -c "chmod 000 $F"` executes a real barrier, and a `printf`-planted
  # fixture is the shape SCOPE says is reported. Masking is therefore narrowed to
  # `skip` lines, where a quoted `chmod` is prose rather than an invocation.
  {
    printf '@test "barrier via a quoted command string" {\n'
    printf '  run bash -c "chmod 000 $F; cat $F"\n  [ "$status" -ne 0 ]\n}\n'
    printf '@test "printf-planted fixture text" {\n'
    printf '  printf %s > "$f"\n  true\n}\n' "'chmod 000 locked\\n'"
  } > "$BATS_TEST_TMPDIR/quoted.bats"
  run awk -v FILE=q.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/quoted.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 2 ]
}

@test "a chmod quoted inside a skip MESSAGE is not a site (negative self-test, #1360)" {
  # The other side of the same narrowing, and the reason it exists: four skip
  # messages in tests/resolve-story-loop.bats spell out `chmod a-w` in prose.
  printf '@test "guarded, message names the mode" {\n  [ "$(id -u)" -ne 0 ] || skip "runs as root: chmod a-w cannot make the sink unwritable"\n  chmod a-w "$BAD"\n  [ ! -w "$BAD" ]\n}\n' \
    > "$BATS_TEST_TMPDIR/skipmsg.bats"
  run awk -v FILE=sm.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/skipmsg.bats"
  [ "$status" -eq 0 ]
  # exactly ONE site — the real `chmod a-w`, not the one named in the message
  [ "$(grep -c ':' <<<"$output")" -eq 1 ]
  contains "$output" 'OK'
  lacks "$output" 'sm.bats:2'
}

@test "every documented barrier MODE spelling is detected (self-test, #1360)" {
  # Only the octal branch was exercised by the other fixtures, yet
  # clause_is_barrier() also claims symbolic `-`, `=`, comma-separated clauses,
  # 4-digit setuid/sticky forms and a leading flag. The real tree contributes
  # exactly four symbolic sites, so a regression in that branch drops 49 -> 45 —
  # which the site floor does not catch, since 45 is not < 45.
  {
    printf '@test "symbolic minus" {\n  chmod a-w "$A"\n  [ ! -w "$A" ]\n}\n'
    printf '@test "symbolic minus, owner" {\n  chmod u-r "$B"\n  [ ! -r "$B" ]\n}\n'
    printf '@test "symbolic assign" {\n  chmod a=rx "$C"\n  [ ! -w "$C" ]\n}\n'
    printf '@test "comma clauses" {\n  chmod a-w,u+x "$D"\n  [ ! -w "$D" ]\n}\n'
    printf '@test "leading flag" {\n  chmod -R 000 "$E"\n  [ ! -r "$E" ]\n}\n'
    printf '@test "four digit" {\n  chmod 2000 "$F"\n  [ ! -r "$F" ]\n}\n'
    # BARE symbolic modes: `-w`/`-r` are modes, not flags, and a flag strip of
    # `-[A-Za-z]+` ate them — the barrier then vanished entirely.
    printf '@test "bare minus w" {\n  chmod -w "$G"\n  [ ! -w "$G" ]\n}\n'
    printf '@test "bare minus r" {\n  chmod -r "$H"\n  [ ! -r "$H" ]\n}\n'
    printf '@test "real flag then bare mode" {\n  chmod -R -w "$I"\n  [ ! -w "$I" ]\n}\n'
    # an assignment that denies READ is a barrier just as one denying write is
    printf '@test "assign denying read" {\n  chmod a=w "$J"\n  [ ! -r "$J" ]\n}\n'
    printf '@test "assign denying read, owner" {\n  chmod u=wx "$K"\n  [ ! -r "$K" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/modes.bats"
  run awk -v FILE=modes.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/modes.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 11 ]
  lacks "$output" 'OK'
}

@test "a word merely CONTAINING skip is not a guard (self-test, #1360)" {
  # The fail-open shape: a warn-and-continue line that skips nothing. A bare
  # substring search for `skip` finds it inside `skipped`, and with a uid marker
  # earlier on the line that would clear every barrier in the test.
  {
    printf '@test "warn but continue" {\n'
    printf '  [ "$(id -u)" -eq 0 ] && echo "WARN: chmod barriers skipped" >&2\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "a tool flag named --skip" {\n'
    printf '  [ "$(id -u)" -eq 0 ] && run tool --skip cache\n'
    printf '  chmod 000 "$G"\n  [ ! -r "$G" ]\n}\n'
    # ...and the bare word inside a quoted MESSAGE, which the token class alone
    # cannot reject: a real `skip` is never quoted.
    printf '@test "the word skip inside a warning message" {\n'
    printf '  [ "$(id -u)" -eq 0 ] && echo "warn: we skip barrier checks as root" >&2\n'
    printf '  chmod 000 "$H"\n  [ ! -r "$H" ]\n}\n'
    # ...and its multi-line analogue, which reaches the open-if-block gate instead
    printf '@test "quoted skip inside a uid if-block" {\n'
    printf '  if [ "$(id -u)" -eq 0 ]; then\n'
    printf '    echo "cannot enforce barriers; skip checks manually" >&2\n  fi\n'
    printf '  chmod 000 "$I"\n  [ ! -r "$I" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/substr.bats"
  run awk -v FILE=ss.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/substr.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 4 ]
  lacks "$output" 'OK'
}

@test "an escaped quote does not desync the quote tracker (self-test, #1360)" {
  # `"a \"#\" b"` toggles the tracker twice at the escapes; without backslash
  # handling the `#` then reads as unquoted, code() truncates there, and the
  # barrier after it vanishes — neither OK nor UNGUARDED, just gone.
  {
    printf '@test "escaped quote then barrier" {\n'
    printf '  run grep "a \\"#\\" b"; chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/escq.bats"
  run awk -v FILE=eq.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/escq.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
}

@test "the backtick spelling of the uid guard is recognised (self-test, #1360)" {
  # POSIX command substitution: the character after `-u` is a backtick, not one of
  # the shapes the follower class originally allowed, so a correct guard red.
  printf '@test "backtick uid guard" {\n  [ %sid -u%s -ne 0 ] || skip "chmod proves nothing as root"\n  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n' \
    '`' '`' > "$BATS_TEST_TMPDIR/btuid.bats"
  run awk -v FILE=bu.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/btuid.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'OK'
  lacks "$output" 'UNGUARDED'
}

@test "message-less skip and a bare fi are recognised (self-test, #1360)" {
  # Both spellings rely on a regex whose anchor the detector deliberately keeps
  # terminal rather than inside an alternation, and neither occurs in the tree —
  # so without this fixture the two branches are unexercised on BOTH lanes, and a
  # cross-awk divergence there would show up only as a Docker-only red.
  {
    printf '@test "message-less skip, one line" {\n'
    printf '  [ "$(id -u)" -ne 0 ] || skip\n  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
    printf '@test "bare fi closes the guard block" {\n  chmod 000 "$G"\n'
    printf '  if [ -r "$G" ]; then\n    skip\n  fi\n  [ ! -r "$G" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/bare.bats"
  run awk -v FILE=bare.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/bare.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^OK' <<<"$output")" -eq 2 ]
  lacks "$output" 'UNGUARDED'
}

@test "a skip MESSAGE naming id -u does not clear a barrier (self-test, #1360)" {
  # The string sibling of the comment-direction test: `command -v tool || skip
  # "not root? check id -u"` is an ordinary dependency skip whose MESSAGE happens
  # to name the marker. Requiring the marker to precede the `skip` token is what
  # separates it from the real guard, whose marker is the condition.
  {
    printf '@test "dependency skip whose message names the marker" {\n'
    printf '  command -v tool >/dev/null || skip "not root? check id -u"\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/msgmarker.bats"
  run awk -v FILE=mm.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/msgmarker.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
  lacks "$output" 'OK'
}

@test "a WRONG-SENSE effect guard is accepted — the documented residual (self-test, #1360)" {
  # PINNED, not endorsed. `chmod 555` denies WRITE, so an `-r` guard is true for
  # everyone and fires on every lane — worse than the inert barrier the sweep
  # exists to prevent. The detector checks ordering but not path or permission
  # sense, exactly as tests/README.md and ARCHITECTURE.md say. This test records
  # the boundary so a later tightening flips it deliberately.
  {
    printf '@test "wrong sense" {\n  chmod 555 "$D"\n'
    printf '  if [ -r "$D" ]; then skip "bypasses permissions"; fi\n'
    printf '  [ ! -w "$D" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/wrongsense.bats"
  run awk -v FILE=ws.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/wrongsense.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'OK'
}

@test "a group/other-only chmod is not a barrier (negative self-test, #1360)" {
  # `go-w` and `o-r` remove nothing from the OWNER, so root bypasses nothing and
  # demanding a guard would be a false alarm on a correct test.
  {
    printf '@test "group only" {\n  chmod go-w "$f"\n  true\n}\n'
    printf '@test "other only" {\n  chmod o-r "$f"\n  true\n}\n'
    printf '@test "control" {\n  chmod 000 "$CTRL"\n  [ ! -r "$CTRL" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/groupother.bats"
  run awk -v FILE=go.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/groupother.bats"
  [ "$status" -eq 0 ]
  # only the control — the group/other clauses contribute nothing
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
  contains "$output" 'chmod 000 "$CTRL"'
}

@test "a commented <<EOF does not open a phantom heredoc, and a stray one is a DESYNC (self-test, #1360)" {
  # The second truncation shape round 2 found: the opener probe ran on raw text,
  # so a `<<EOF` inside a COMMENT swallowed the rest of the file. Both halves are
  # pinned — the comment must not open one, and an opener that never terminates
  # must fail loudly rather than silently report a clean file.
  {
    printf '@test "commented opener then barrier" {\n  # cat <<EOF is what this looked like\n'
    printf '  chmod 000 "$F"\n  [ ! -r "$F" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/commented-heredoc.bats"
  run awk -v FILE=ch.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/commented-heredoc.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
  contains "$output" 'chmod 000 "$F"'

  printf '@test "unterminated" {\n  cat > "$f" <<NOPE\n  never closed\n' \
    > "$BATS_TEST_TMPDIR/desync.bats"
  run awk -v FILE=desync.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/desync.bats"
  [ "$status" -eq 2 ]
  contains "$output" 'DESYNC'
  contains "$output" 'NOPE'
}

@test "a one-line barrier-and-restore is still a barrier (self-test, #1360)" {
  # The greedy-match trap: reading only the LAST chmod on the line yields the
  # RESTORE mode (644), which is not a barrier, so the site would vanish.
  printf '@test "compressed" {\n  chmod 000 "$f"; run thing; chmod 644 "$f"\n  [ "$status" -ne 0 ]\n}\n' \
    > "$BATS_TEST_TMPDIR/oneline.bats"
  run awk -v FILE=oneline.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/oneline.bats"
  [ "$status" -eq 0 ]
  contains "$output" 'UNGUARDED'
  contains "$output" 'oneline.bats:2'
  # EXACTLY ONE: the restore on the same line must not contribute a second site.
  # A widened octal branch would roughly double the tree's reported count, and the
  # anti-vacuity checks are floors rather than ranges, so the inflation could hide
  # a genuinely lost file underneath it.
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
}

@test "a RESTORE mode is not a barrier (negative self-test, #1360)" {
  # Every barrier test in the tree pairs its chmod with a restore, so accepting
  # restores would inflate the site count and make the floors meaningless.
  {
    printf '@test "restore file" {\n  chmod 644 "$f"\n  true\n}\n'
    printf '@test "restore dir" {\n  chmod 755 "$d"\n  true\n}\n'
    printf '@test "restore rw" {\n  chmod 666 "$f"\n  true\n}\n'
    printf '@test "control" {\n  chmod 000 "$CTRL"\n  [ ! -r "$CTRL" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/restore.bats"
  run awk -v FILE=rs.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/restore.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
  contains "$output" 'chmod 000 "$CTRL"'
}

@test "a barrier sharing a line with a skip token is dropped — the documented residual (self-test, #1360)" {
  # PINNED, not endorsed. Masking every quoted span on a `skip` line is what keeps
  # the four prose `chmod a-w` skip MESSAGES out of the count; the price is that a
  # real barrier quoted on that same line vanishes. SCOPE says so, and this test
  # makes a later narrowing flip deliberately rather than by surprise.
  {
    printf '@test "barrier and skip share a line" {\n'
    printf '  run bash -c "chmod 000 $F" || skip "sandbox is read-only"\n'
    printf '  [ ! -r "$F" ]\n}\n'
    printf '@test "control" {\n  chmod 000 "$CTRL"\n  [ ! -r "$CTRL" ]\n}\n'
  } > "$BATS_TEST_TMPDIR/sharedline.bats"
  run awk -v FILE=sl.bats -f "$DETECTOR" "$BATS_TEST_TMPDIR/sharedline.bats"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^UNGUARDED' <<<"$output")" -eq 1 ]
  contains "$output" 'chmod 000 "$CTRL"'
}

@test "no @test description in any tracked tests/*.bats contains a backtick (#1360)" {
  local list="$BATS_TEST_TMPDIR/files2.txt" offenders anchors
  bats_file_list "$list"
  # ANTI-VACUITY, the same doctrine rule 1 follows: prove the grep actually read
  # the tree before claiming the tree is clean. Without it, an xargs/grep that
  # opened nothing is indistinguishable from a clean sweep — and this rule's whole
  # job is to keep an eval-ing description out. 3709 `@test` lines over the
  # self-excluded list today.
  local raw
  raw="$(scan_backticks "$list")" \
    || { printf 'the backtick detector ABORTED on some file — the sweep did NOT cover the whole tree.\n' >&2; return 1; }
  # Measured on what the DETECTOR extracted, not on a parallel grep — rule 1's
  # doctrine. 3709 descriptions over the self-excluded list today.
  anchors="$(awk -F'\t' '$1 == "SCANNED" {s += $2} END {print s+0}' <<<"$raw")"
  if [ "$anchors" -lt 3000 ]; then
    printf 'the backtick detector extracted only %s @test descriptions (3709 expected over the self-excluded list) — either it read nothing, or tests were legitimately removed. Confirm which before lowering this floor, and record the new measured count here.\n' \
      "$anchors" >&2
    return 1
  fi
  offenders="$(grep -v '^SCANNED	' <<<"$raw" || true)"
  if [ -n "$offenders" ]; then
    printf 'Backticked @test description(s) — bats EVALUATES descriptions, so these run as command substitution and mangle the test name:\n%s\n' \
      "$offenders" >&2
    return 1
  fi
}

@test "the backtick rule catches a planted backticked description (self-test, #1360)" {
  local fixture="$BATS_TEST_TMPDIR/backticked.bats"
  # Assembled from pieces so this source line itself is not a backticked @test.
  # BOTH orderings of the house style, because the regex this replaced was blind
  # to the second: a `#` anywhere after the backtick defeated it, and this suite's
  # dominant description shape ends `(#NNNN)`.
  {
    printf '@test "a quoted, CRLF-authored %skubernetes%s still reaches its arm" {\n  true\n}\n' '`' '`'
    printf '@test "a %skubernetes%s marker (#1153)" {\n  true\n}\n' '`' '`'
    printf '@test "x #1360: a %sfoo%s thing" {\n  true\n}\n' '`' '`'
    # the ONE-LINE form — 18 of them in tests/no-cluster-deploy.bats, and an
    # end-anchored `{` skipped every one
    printf '@test "a %sfoo%s thing" { true; }\n' '`' '`'
    # ...and a description that legitimately contains a brace, which is why the
    # brace search masks quoted spans first
    printf '@test "the {{PRIMARY}} %skubernetes%s table (#1154)" {\n  true\n}\n' '`' '`'
  } > "$fixture"
  run awk -v FILE=bt.bats -f "$BACKTICK_DETECTOR" "$fixture"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^bt.bats:' <<<"$output")" -eq 5 ]
  contains "$output" 'SCANNED	5'
  contains "$output" 'kubernetes'
  contains "$output" '#1153'
  contains "$output" '{{PRIMARY}}'
}

@test "rule 2 reads a heredoc-planted @test as a real one — the documented residual (self-test, #1360)" {
  # PINNED, not endorsed. Rule 1 skips heredoc bodies; rule 2 does not, so a bats
  # fixture planted in a heredoc is scanned as if it were this file's own test.
  # That is why fixture `@test` lines are planted with `printf` throughout.
  local fixture="$BATS_TEST_TMPDIR/heredoc-desc.bats"
  {
    printf '@test "plants a fixture" {\n  cat > "$f" <<EOF\n'
    printf '@test "a %sfoo%s thing" {\n  true\n}\n' '`' '`'
    printf 'EOF\n  true\n}\n'
  } > "$fixture"
  run awk -v FILE=hd.bats -f "$BACKTICK_DETECTOR" "$fixture"
  [ "$status" -eq 0 ]
  # the planted line inside the heredoc IS reported, and IS counted as scanned
  [ "$(grep -c '^hd.bats:' <<<"$output")" -eq 1 ]
  contains "$output" 'SCANNED	2'
}

@test "the backtick rule ignores a backtick in a trailing comment (negative self-test, #1360)" {
  # bats evaluates the description only; a backtick after the opening brace never
  # reaches the eval, so flagging it would be a false alarm on an innocent line.
  local fixture="$BATS_TEST_TMPDIR/comment-backtick.bats"
  {
    printf '@test "plain description" {  # see %sfoo%s\n  true\n}\n' '`' '`'
    # ...and the one-line form whose BODY, not description, carries the backtick:
    # the first-unquoted-brace cut must land before it.
    printf '@test "plain one-liner" { run echo %sfoo%s; }\n' '`' '`'
  } > "$fixture"
  run awk -v FILE=cb.bats -f "$BACKTICK_DETECTOR" "$fixture"
  [ "$status" -eq 0 ]
  # no offenders — and the SCANNED line proves both descriptions were extracted,
  # so "no offenders" is a verdict rather than a detector that read nothing
  [ "$(grep -v '^SCANNED	' <<<"$output")" = "" ]
  contains "$output" 'SCANNED	2'
}
