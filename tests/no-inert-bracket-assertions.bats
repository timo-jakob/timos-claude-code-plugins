#!/usr/bin/env bats
#
# Suite lint (#1011, extended #1067). TWO inert shapes, one detector:
#
#   * `bracket`  — a `[[ ... ]]` assertion inside a scanned block (#1011),
#                  described at length below;
#   * `and-tail` — an assertion-helper call swallowed by an `&&` tail (#1067),
#                  described above its own section of tests further down.
#
# They are different defects with the same consequence: an assertion whose
# status errexit never sees, so the test passes while proving nothing. #1011
# closed the first and #829 closed the bare-`!` form; the `&&` tail was left
# documented-but-unguarded, which #1067 closes — the belief that produces the
# line ("calling a helper makes position stop mattering") was in this repo's own
# prose, so prose alone was never going to hold it back.
#
# ---------------------------------------------------------------------------
#
# `bracket`: a `[[ ... ]]` assertion inside an `@test` body — or inside
# setup/teardown — is SILENTLY INERT unless it happens to be the block's last
# statement, because bash 3.2 (macOS `/bin/bash`) exempts a failing `[[ ]]` from
# errexit where it catches `[ ... ]` correctly. bash >= 4 catches both — which
# makes the idiom worse, not safer: the assertion means one thing on the
# `bats (macos-latest)` CI leg and another on `bats (ubuntu-latest)`. The ban is
# what makes the suite say the same thing on every platform.
#
# That macos-latest leg is DEACTIVATED as of #1407 (#1408 tracks restoring it).
# It is named above as the ORIGIN of the divergence, not as its enforcement:
# this ban is repo-wide, runs on ubuntu, and is unaffected. It is also now the
# only automated thing standing between an inert `[[ ]]` and main, since bash
# 3.2 is otherwise exercised only on the maintainer's Mac before a push.
#
# This is the same defect class as the bare-`!` negation guarded by #829 in
# tests/no-inert-negative-assertions.bats — that guard's own comment used to
# wave `[[ ]]` through, which is what let them accumulate: 285 inert `[[ ]]`
# assertion lines across 41 files, as counted by
# tests/find-inert-bracket-assertions.zsh on the tree immediately before the
# #1011 sweep.
#
# The sanctioned fix is a helper from tests/assertions.bash (the roster lives in
# tests/README.md, and is derived — never restated — everywhere in this file).
# They are ordinary functions, so calling one
# is a simple command that errexit catches wherever it appears AS A COMMAND OF
# ITS OWN. That is the whole of the guarantee: position stops mattering, the way
# you JOIN the call to other commands does not — see the `and-tail` section
# below, and the neutralisation list in tests/assertions.bash.
#
# The detection itself lives in tests/find-inert-bracket-assertions.zsh (block
# tracking + heredoc skipping is past what a single grep should carry); this
# file pins the repo-wide invariant and proves the detector is not vacuous.
#
# Deliberately NO positional exemption: a trailing `[[ ]]` is correct only by
# accident of position and goes inert the moment a line is appended below it.
#
# The exit-2 tests matter as much as the exit-1 ones: a detector that silently
# stops parsing would report every remaining file clean.

bats_require_minimum_version 1.5.0

load assertions
load roster

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TESTS_DIR="$REPO_ROOT/tests"
  DETECT="$TESTS_DIR/find-inert-bracket-assertions.zsh"
  FIX="$BATS_TEST_TMPDIR/f.bats"
  HELPER_ROSTER="$(helper_roster_of "$TESTS_DIR/assertions.bash")"
  HELPER_RE="$(printf '%s' "$HELPER_ROSTER" | tr ' ' '|')"
  # Fail EVERY test, loudly and at one legible place, if the derivation came back
  # empty (a renamed library, a regex slip). The pipeline ends in `sed`, so its
  # status is sed's and errexit would not otherwise fire — and an empty roster
  # makes `has_helper` the pattern `()`, which matches anything, so every
  # fixture-sanity check in this file would pass vacuously.
  [ -n "$HELPER_ROSTER" ]
}

# Fixtures are built with printf, never a heredoc: bats' own parser treats a
# column-0 `@test` line as a test definition even inside a heredoc, which
# silently truncates the fixture (and would make these self-tests vacuous). The
# #829 guard uses printf for the same reason.
#
# The `-s` check is what keeps the not-flagged tests honest: an empty fixture
# would satisfy "exit 0, no output" while proving nothing at all.
mkfix() { printf '%b' "$1" > "$FIX"; [ -s "$FIX" ]; }

# For a not-flagged case, prove the fixture really does carry a `[[` line — so
# the test pins a deliberate exemption rather than an absence of input.
has_bracket() { grep -q '\[\[' "$FIX"; }

# The `and-tail` counterparts: prove the fixture really does carry the input the
# exemption is about. Without them an exemption test would pass on a typo'd
# fixture that carries neither, proving nothing at all. Two of them, because the
# `||` exemption is deliberately about a fixture with NO `&&` in it — asserting
# one there would be asserting the fixture is the wrong fixture.
has_helper() { grep -qE "($HELPER_RE)" "$FIX"; }
# The `&&` join here is DELIBERATE and is not the #1067 defect, despite looking
# like it. That defect is about a LEFT operand whose failure is swallowed — but
# `&&` short-circuits: when `has_helper` fails, `grep` never runs and the list
# returns has_helper's own non-zero status, so the canary rejects a fixture
# carrying an `&&` but no helper. Verified on bash 3.2.57 both ways: with
# errexit the two spellings behave identically, and WITHOUT it this one still
# returns 1 while `has_helper` on its own line returns grep's 0 — i.e. the
# obvious "one assertion per line" rewrite is strictly weaker here, because it
# makes the canary depend on errexit being active. Leave it as an AND-list.
has_and_tail() { has_helper && grep -q '&&' "$FIX"; }

# Names every .bats under <dir> (recursively, matching the detector's own scan
# scope) that CALLS an assertion helper without loading the library. Matches a
# call, not the English words: the helper name must be followed by an argument
# (a quote or `$`), and comment / `@test` title lines are dropped first — "round
# 1 lacks the stamp" and "matches as a wildcard" are prose, not code. A `run
# <helper>` call needs no alternative of its own: the space after `run` is
# already matched by `[[:space:]]`.
unloaded_helper_users() {
  local dir="$1" f uses has_load out=""
  while IFS= read -r f; do
    uses="$(grep -vE '^[[:space:]]*#|^[[:space:]]*@test' "$f" \
      | grep -cE "(^|[[:space:];&|(])($HELPER_RE)[[:space:]]+[\"'\$]" || true)"
    if [ "$uses" -eq 0 ]; then
      continue
    fi
    has_load="$(grep -cE '^load ([./]*)assertions$' "$f" || true)"
    if [ "$has_load" -eq 0 ]; then
      out="$out $(basename "$f")"
    fi
  done < <(find "$dir" -name '*.bats')
  printf '%s' "$out"
}

@test "no inert assertion survives in any tests/*.bats (#1011, #1067)" {
  # No arguments: also exercises the detector's default (self-directory,
  # recursive) scan mode, which nothing else covers.
  run zsh "$DETECT"
  if [ "$status" -eq 2 ]; then
    # No offender list exists on this path — telling the reader to "convert
    # assertions" would send them looking for something that is not there.
    printf 'The scan could not be trusted. Fix the reported scan error — a\n'      >&2
    printf 'parse desync (heredoc terminator / block opener / unclosed\n'          >&2
    printf 'multi-line quoted literal / unrecognized nested-helper close) or a\n'  >&2
    printf 'usage error — before this guard can pass:\n%s\n' "$output" >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    # Advice per rule: "convert it to a helper" is nonsense for an `and-tail`
    # line, which already calls one — the whole reason offenders carry a tag.
    printf 'Inert assertion(s) found — these pass even when FALSE.\n'              >&2
    printf 'A `bracket:` offender is a `[[ ]]` assertion: convert it to a helper\n' >&2
    printf 'rostered in tests/README.md and add `load assertions`.\n'              >&2
    printf 'An `and-tail:` offender is a helper call swallowed by an `&&` tail:\n' >&2
    printf 'put each assertion on its own line.\n'                                 >&2
    printf 'If a flagged line is one of the false-positive shapes listed under\n'   >&2
    printf '"Known, accepted limits" in the detector, leave it alone instead:\n%s\n' \
      "$output" >&2
    return 1
  fi
  [ "$status" -eq 0 ]
}

# --- it catches the inert shapes -------------------------------------------

@test "the guard catches a planted MID-BODY assertion (self-test, #1011)" {
  mkfix '@test "planted" {\n  [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "[[ -f /nonexistent ]]"
}

@test "the guard catches a planted FINAL-LINE assertion — no positional exemption (#1011)" {
  mkfix '@test "planted" {\n  run true\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "[[ -f /nonexistent ]]"
}

@test "the guard catches a '[[' opening a command after ';' or '&&' (#1011)" {
  # Equally inert, and invisible to a first-token-only rule.
  mkfix '@test "planted" {\n  run true; [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "run true; [[ -f /nonexistent ]]"

  mkfix '@test "planted" {\n  true && [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "true && [[ -f /nonexistent ]]"

  mkfix '@test "planted" {\n  false || [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "false || [[ -f /nonexistent ]]"
}

@test "an offender line containing a TAB is reported whole (#1011)" {
  # Why the typed records are split in zsh rather than piped back through awk:
  # re-splitting on tabs would truncate the reported source line.
  mkfix '@test "planted" {\n  [[ "$x" == "a\tb" ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  local want
  want="$(printf '[[ "$x" == "a\tb" ]]')"
  contains "$output" "$want"
}

@test "the guard catches an assertion in every fixture hook, not just setup (#1011)" {
  # The header claims all four hooks are scanned; pin all four so an edit to
  # the alternation cannot silently unguard three of them.
  local h
  for h in setup teardown setup_file teardown_file; do
    mkfix "$h"'() {\n  [[ -f /nonexistent ]]\n  true\n}\n@test "x" {\n  true\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "[[ -f /nonexistent ]]"
  done
}

@test "the guard names the offending file and line (#1011)" {
  mkfix '@test "planted" {\n  run true\n  [[ "$output" == *"x"* ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

# --- it exempts the forms that are genuinely fine ---------------------------

@test "a heredoc body is payload, not an assertion — not flagged (#1011)" {
  # The trailing assertion AFTER the terminator is the load-bearing part: it
  # proves the heredoc was exited. Without it, "skipped correctly" and
  # "swallowed the rest of the file" would be indistinguishable.
  mkfix '@test "writes a stub script" {\n  cat > "$STUB/s.zsh" <<'"'"'EOF'"'"'\n[[ -f "$STUB/fail" ]] && exit 1\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:5:"
  lacks "$output" "\$STUB/fail"
}

@test "a heredoc opened with a trailing redirection is still recognized (#1011)" {
  # `cat <<'EOF' > "$f"` is as common as `cat > "$f" <<'EOF'`. Missing it would
  # scan the payload as code — and a column-0 '}' in the payload would clear
  # the block, silently skipping every later assertion in that test.
  mkfix '@test "x" {\n  cat <<'"'"'EOF'"'"' > "$f"\n[[ -f /payload ]]\n}\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6:"
  lacks "$output" "/payload"
}

@test "a here-STRING is not a heredoc opener (#1011)" {
  # Regression: `<<<'null'` matched an earlier opener pattern, so the scan
  # swallowed the rest of tests/switch-fable-to-opus.bats and reported clean.
  mkfix '@test "x" {\n  run jq -e '"'"'. != null'"'"' <<<'"'"'null'"'"'\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

@test "a quoted or commented '<<EOF' does not open a phantom heredoc (#1011)" {
  # The end-of-line anchor alone is not enough: a quoted `<<EOF` that ENDS the
  # line satisfies it via the closing quote. Left unguarded, an assertion ABOUT
  # a heredoc swallows the rest of the file and reports it CLEAN — the same
  # false-clean class as the `<<<` here-string bug.
  mkfix '@test "x" {\n  lacks "$output" "cat <<EOF"\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"

  mkfix '@test "x" {\n  run foo  # the stub is written with <<EOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

@test "an unquoted expansion containing '#' is not a comment (#1011)" {
  # `${#a[@]}` / `${v#p}` / `$#` carry a `#` that does NOT start a comment. If
  # the strip treated them as one it would truncate the judged code and hide the
  # offender that follows on the same line — a false clean.
  mkfix '@test "x" {\n  n=${#lines[@]}; [[ "$n" -eq 3 ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"

  mkfix '@test "x" {\n  v=${p#prefix}; [[ -n "$v" ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"
}

@test "a trailing comment is prose too, not code (#1011)" {
  # Rule 2 drops only FULL-line comments; the rest of the line is judged on its
  # code, so a comment discussing the pattern is not a false accusation.
  mkfix '@test "x" {\n  run foo  # inert too: bar; [[ -f /x ]]\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an indented terminator closes a <<- heredoc but not a plain one (#1011)" {
  # For a plain `<<EOF` an indented delimiter is ordinary payload; ending the
  # heredoc there would resume scanning payload as code.
  mkfix '@test "x" {\n  cat > "$f" <<EOF\n  EOF\n[[ -f /payload ]]\nEOF\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  cat > "$f" <<-EOF\n\tpayload\n\tEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:5:"

  # `<<-` strips TABS only, like the shell: a space-indented terminator does not
  # close it, so the heredoc runs to EOF and that is a desync, not a clean.
  mkfix '@test "x" {\n  cat > "$f" <<-EOF\n\tpayload\n  EOF\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "never terminated"

  # A terminator with trailing whitespace is not a terminator either.
  mkfix '@test "x" {\n  cat > "$f" <<EOF\npayload\nEOF \n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "never terminated"
}

@test "a named helper function is the sanctioned fix — not flagged (#1011)" {
  # errexit DOES catch a call to a function, so `[[ ]]` inside one is correct.
  mkfix 'has_it() {\n  [[ -f "$1" ]]\n}\n@test "x" {\n  has_it /nonexistent\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "control flow is not an assertion — 'if [[ ]]' is not flagged (#1011)" {
  # A condition's status is consumed by the construct, so it is not inert —
  # and converting it to `if contains …` would silently flip the branch.
  mkfix '@test "x" {\n  if [[ -f /nonexistent ]]; then\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  while [[ -f /nonexistent ]]; do\n    break\n  done\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a clean file yields exit 0 and no output (#1011)" {
  mkfix '@test "x" {\n  run true\n  [ "$status" -eq 0 ]\n  contains "$output" "ok"\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- a desynced parse is an error, never a false clean ----------------------

@test "an unterminated heredoc is exit 2, not a silent clean (#1011)" {
  mkfix '@test "x" {\n  cat > "$f" <<EOF\npayload\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "never terminated"
}

@test "an @test opener that does not end with '{' is exit 2, not a silent clean (#1011)" {
  mkfix '@test "x"\n{\n  [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "not recognized"
}

@test "exit 2 suppresses the offender list, on stderr vs stdout (#1011)" {
  # A desynced scan must not hand over a half-harvested offender list that looks
  # actionable. Also pins the documented stream split, which plain `run` (which
  # merges them) cannot see.
  mkfix '@test "real" {\n  [[ -f /nonexistent ]]\n}\n@test "broken" {\n  cat > "$f" <<EOF\npayload\n}\n'
  run --separate-stderr zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$stderr" "never terminated"
  [ -z "$output" ]
}

@test "an offender is reported on stdout, not stderr (#1011)" {
  mkfix '@test "x" {\n  [[ -f /nonexistent ]]\n  true\n}\n'
  run --separate-stderr zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"
  [ -z "$stderr" ]
}

@test "a desync in a NON-final file is still reported (multi-file scan, #1011)" {
  # The diagnostics come from two awk paths: END (which only ever flushes the
  # LAST file) and the per-file flush on FNR==1 (every preceding file). Every
  # other exit-2 test here scans ONE fixture, so only END is exercised — yet CI
  # always scans ~80 files at once. Without this, deleting the per-file flush
  # leaves the suite green while a desync in any non-final file is dropped and
  # its unscanned remainder reported clean.
  local a="$BATS_TEST_TMPDIR/a.bats" b="$BATS_TEST_TMPDIR/b.bats"
  printf '@test "x" {\n  cat > "$f" <<EOF\npayload\n' > "$a"
  printf '@test "y" {\n  true\n}\n' > "$b"
  run zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 2 ]
  contains "$output" "never terminated"
  contains "$output" "$a"

  # The malformed-opener path, same shape — this also pins the per-file reset of
  # the counters, since the diagnostic must name A and not B.
  printf '@test "bad"\n{\n  true\n}\n' > "$a"
  run zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 2 ]
  contains "$output" "1 block opener(s) not recognized"
  contains "$output" "(line(s): 1)"
  contains "$output" "$a"
  lacks "$output" "$b:"
}

@test "the two NEW desyncs are also reported in a non-final file (multi-file scan, #1068)" {
  # Sibling of the test above, for the diagnostics #1068 added. Every other
  # test of these two scans ONE fixture, so only the END path is exercised —
  # yet CI always scans ~80 files at once, where a missing per-file reset or a
  # mis-attributed filename would silently drop them.
  local a="$BATS_TEST_TMPDIR/na.bats" b="$BATS_TEST_TMPDIR/nb.bats"
  printf '@test "x" {\n  printf %%s "never closes\n' > "$a"
  printf '@test "y" {\n  true\n}\n' > "$b"
  run zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 2 ]
  contains "$output" "multi-line quoted literal is never closed"
  contains "$output" "$a"
  lacks "$output" "$b:"

  printf '@test "x" {\n  h() {\n    true\n' > "$a"
  run zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 2 ]
  contains "$output" "1 nested helper function(s) never closed"
  contains "$output" "$a"
  lacks "$output" "$b:"
}

@test "offenders are attributed per file, and a desync suppresses them all (#1011)" {
  local a="$BATS_TEST_TMPDIR/oa.bats" b="$BATS_TEST_TMPDIR/ob.bats"
  printf '@test "x" {\n  [[ -f /nonexistent ]]\n  true\n}\n' > "$a"
  printf '@test "y" {\n  [[ -f /nope ]]\n  true\n}\n' > "$b"
  run zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 1 ]
  contains "$output" "$a:2:"
  contains "$output" "$b:2:"

  # A clean-parsing file's real offenders are suppressed when ANOTHER file
  # desynced: the list cannot be trusted as a whole.
  printf '@test "y" {\n  cat > "$f" <<EOF\npayload\n' > "$b"
  run --separate-stderr zsh "$DETECT" "$a" "$b"
  [ "$status" -eq 2 ]
  contains "$stderr" "never terminated"
  [ -z "$output" ]
}

@test "a record the splitter cannot type is exit 2, not a dropped offender (#1067)" {
  # The fail-closed default arm is the only exit-2 path with no other coverage,
  # and it is reachable: a scanned path containing a NEWLINE splits one `O\t…`
  # record across two rows, and the second row is untypeable. A regression that
  # replaced `exit 2` with `continue` would silently drop offender rows and
  # report a clean — the exact false clean the typed records exist to prevent.
  local dir="$BATS_TEST_TMPDIR/nl"
  mkdir -p "$dir"
  local weird="$dir/a
b.bats"
  printf '@test "x" {\n  [[ -f /nonexistent ]]\n  true\n}\n' > "$weird"
  run --separate-stderr zsh "$DETECT" "$weird"
  [ "$status" -eq 2 ]
  contains "$stderr" "unrecognized record"
  [ -z "$output" ]
}

@test "the detector's roster matches the library's, name for name (#1067)" {
  # A sixth helper added to assertions.bash but not to the detector's `H` would
  # ship with its `&&`-swallowed call sites unflagged, and the suite would stay
  # green. This is the only remaining CODE copy of the roster — everything in
  # this file derives from the library — so one set equality closes the drift in
  # both directions: a name added to the library and missing from `H`, and a
  # name left in `H` after the library dropped it.
  [ -n "$HELPER_ROSTER" ]
  local detector_roster
  detector_roster="$(grep -oE 'H = "\([A-Za-z0-9_|]+\)"' "$DETECT" \
    | sed -E 's/.*\(([A-Za-z0-9_|]+)\).*/\1/' | tr '|' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [ "$detector_roster" = "$HELPER_ROSTER" ]
}

@test "the roster derivation is not vacuous and skips internals (self-test, #1067)" {
  # `helper_roster_of` is what makes every other roster check meaningful; if it
  # ever returned empty, or the same value regardless of input, the sync test
  # above would compare two empty strings and pass forever.
  # All four spellings bash admits, a digit-bearing name, a CAPITALISED name, and
  # an internal. Each of the unusual shapes is one an earlier version of this
  # derivation silently dropped: a name it cannot see is absent from BOTH sides
  # of the sync test below, so the two agree vacuously and the helper ships
  # unguarded — which is why breadth here is load-bearing, not tidiness.
  local lib="$BATS_TEST_TMPDIR/lib.bash"
  printf 'alpha() { :; }\nbeta () { :; }\nfunction gamma() { :; }\nfunction delta {\n:\n}\neps2() { :; }\ncontainsJSON() { :; }\n_private() { :; }\n' \
    > "$lib"
  run helper_roster_of "$lib"
  [ "$status" -eq 0 ]
  [ "$output" = "alpha beta containsJSON delta eps2 gamma" ]

  # And it really does see the live library's five, in the spellings it uses.
  contains "$HELPER_ROSTER" "contains"
  contains "$HELPER_ROSTER" "matches"
}

@test "tests/README.md's contributor-facing roster names every helper (#1067)" {
  # ARCHITECTURE.md designates README the source of truth for the roster, and it
  # is prose — no derivation can reach it, so a sixth helper would silently leave
  # it naming five. This is the one roster copy a human has to keep, so it gets
  # the one check that can be written for it.
  local h tick='`'
  for h in $HELPER_ROSTER; do
    grep -qF -- "$tick$h$tick" "$TESTS_DIR/README.md"
  done
}

@test "an unreadable path is a usage error (exit 2), not a false clean (#1011)" {
  run zsh "$DETECT" "$BATS_TEST_TMPDIR/does-not-exist.bats"
  [ "$status" -eq 2 ]
  contains "$output" "cannot read"
}

@test "the default scan mode reports exit 2 when there is nothing to scan (#1011)" {
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  cp "$DETECT" "$empty/"
  run zsh "$empty/find-inert-bracket-assertions.zsh"
  [ "$status" -eq 2 ]
  contains "$output" "no .bats files to scan"
}

@test "the default scan mode finds a planted offender, including in a subdirectory (#1011)" {
  local root="$BATS_TEST_TMPDIR/scanroot"
  mkdir -p "$root/nested"
  cp "$DETECT" "$root/"
  printf '@test "x" {\n  [[ -f /nonexistent ]]\n  true\n}\n' > "$root/nested/deep.bats"
  run zsh "$root/find-inert-bracket-assertions.zsh"
  [ "$status" -eq 1 ]
  contains "$output" "nested/deep.bats:2:"
}

@test "a compound condition is control flow, not an assertion (#1011)" {
  # The separator rule would otherwise flag the SECOND `[[` and advise a
  # conversion the header explicitly forbids for conditions.
  mkfix '@test "x" {\n  if [[ -f /a ]] && [[ -f /b ]]; then\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  while [[ -f /a ]] || [[ -f /b ]]; do\n    break\n  done\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The condition set is (if|elif|while|until) in BOTH the rule-5 guard and the
  # shared judge_code exemption, but only `if`/`while` were ever exercised.
  # These pin the END-TO-END verdict, not either alternation individually: the
  # two are redundant here, so dropping the keyword from just one still leaves
  # the other exempting the line. The isolating pins are elsewhere — the
  # post-closer test drives rule 5's set (judge_code would otherwise exempt the
  # whole line), and the one-liner-interior test drives judge_code's set (a
  # path rule 5 never claims).
  mkfix '@test "x" {\n  if false; then\n    :\n  elif [[ -f /a ]] && [[ -f /b ]]; then\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  until [[ -f /a ]] || [[ -f /b ]]; do\n    break\n  done\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a full-line comment is prose, not code (#1011)" {
  # Both halves matter: a comment mentioning the pattern must not be flagged,
  # and a comment ending in a heredoc token must not open a phantom heredoc
  # (which would swallow the file and fail the whole suite).
  mkfix '@test "x" {\n  # run true; [[ -f /nope ]] is inert too\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  # the stub is written with <<EOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

@test "a quoted '[[' inside a string literal is not an offender (#1011)" {
  # in_quotes: the separator rule must not fire on text ABOUT the pattern...
  mkfix '@test "x" {\n  printf %s '"'"'run true; [[ -f /x ]]'"'"'\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # ...but a quoted one early on the line must not mask a real one later.
  mkfix '@test "x" {\n  run zsh -c '"'"'set -e; [[ -f x ]]'"'"'; [[ -n "$output" ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"
}

@test "a backslash-escaped quote does not flip quote parity (#1011)" {
  # in_quotes skips the character after a backslash. Without that, the escaped
  # quote reads as an open string and the real trailing offender is MASKED —
  # a false clean, the worst direction.
  mkfix '@test "x" {\n  run cmd "a\\"b"; [[ -n "$output" ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"
}

@test "a self-contained one-line hook neither opens a block nor desyncs (#1011)" {
  # `teardown() { rm -rf "$W"; }` has no body to hide an assertion in; treating
  # it as an opener would leak the block over the rest of the file.
  mkfix 'teardown() { rm -rf "$W"; }\n@test "x" {\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

@test "ONE malformed opener among well-formed siblings is still exit 2 (#1011)" {
  # The desync guard is per-opener, not per-file: a file whose other tests parse
  # fine would otherwise hide the unscanned one behind a clean verdict.
  mkfix '@test "good" {\n  true\n}\n@test "bad"\n{\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  # Assert the distinctive fragments, not a bare digit: BATS_TEST_TMPDIR is a
  # random path full of digits, so `contains "$output" "4"` would pass no
  # matter what line the diagnostic actually named.
  contains "$output" "1 block opener(s) not recognized"
  contains "$output" "(line(s): 4)"

  # Two malformed openers: pins the per-opener accumulation, not just that the
  # count is non-zero.
  mkfix '@test "good" {\n  true\n}\n@test "bad1"\n{\n  true\n}\n@test "bad2"\n{\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "2 block opener(s) not recognized"
  contains "$output" "(line(s): 4 8)"
}

@test "a legal opener carrying a trailing comment is NOT a desync (#1011)" {
  # Regression: a naive comment strip ate the `{` of every `@test "… (#1011)" {`
  # title in this repo and reported the whole suite as malformed.
  mkfix '@test "x" {  # note\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"

  mkfix '@test "title with (#1011) ref" {\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2:"

  mkfix 'teardown() { rm -rf "$W"; }  # cleanup\n@test "x" {\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3:"
}

@test "the alternative hook spellings the pattern admits are scanned (#1011)" {
  # `function setup() {` and `setup () {` are legal bash; the recognizer must
  # mirror what the opener pattern lets in, or they hard-fail as bogus desyncs.
  local spelling
  for spelling in 'function setup() {' 'function setup {' 'setup () {'; do
    mkfix "$spelling"'\n  [[ -f /nonexistent ]]\n  true\n}\n@test "x" {\n  true\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "[[ -f /nonexistent ]]"
  done
}

@test "a hook opener whose brace is on the NEXT line is exit 2 (#1011)" {
  # Sibling of the @test case. Narrowing the admitting pattern once turned this
  # from a loud desync into a silent clean — the whole hook body went unscanned
  # while the file still reported exit 0.
  mkfix 'setup()\n{\n  [[ -f /nonexistent ]]\n  true\n}\n@test "x" {\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "not recognized"
  contains "$output" "(line(s): 1)"
}

@test "an indented @test opener is exit 2, not a silent skip (#1011)" {
  mkfix '  @test "indented" {\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "not recognized"
}

@test "a path containing '=' is scanned, not read as an awk assignment (#1011)" {
  # Without the ./ normalization awk would treat it as a variable assignment,
  # scan nothing, and report a false clean.
  local dir="$BATS_TEST_TMPDIR/eq"
  mkdir -p "$dir"
  printf '@test "x" {\n  [[ -f /nonexistent ]]\n  true\n}\n' > "$dir/a=b.bats"
  cd "$dir"
  run zsh "$DETECT" "a=b.bats"
  [ "$status" -eq 1 ]
  contains "$output" "a=b.bats:2:"
}

# --- the `and-tail` rule: a helper call swallowed by an `&&` (#1067) --------
#
# The AND-list errexit exemption applies to a function call exactly as it does to
# `[[ ]]`, so `contains "$output" "a" && contains "$output" "b"` silently drops
# the FIRST assertion. Unlike the `bracket` inertness this holds on EVERY bash
# (verified 3.2.57 and 5.2, pinned in tests/assertions.bats), so no platform or
# positional reasoning rescues it.
#
# Only the LEFT operand is inert. A helper that ENDS the list is the status
# errexit catches, so `true && contains …` is deliberately not flagged — and the
# exemption tests below are what stop a future widening of the rule from
# reddening every legitimate line in the suite.

@test "the guard catches a helper call swallowed by an '&&' tail (self-test, #1067)" {
  # The shape from the issue: the FIRST call is the one that vanishes.
  mkfix '@test "planted" {\n  contains "$output" "a" && contains "$output" "b"\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" 'contains "$output" "a" && contains "$output" "b"'
  contains "$output" "and-tail"

  # `<helper> && <anything>` is the same defect — the tail need not be a helper.
  mkfix '@test "planted" {\n  lacks "$output" "a" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" 'lacks "$output" "a" && true'

  # A helper in the MIDDLE of a three-member list is swallowed exactly as a
  # leading one is. This is where "earliest opener" and "a helper that ends the
  # list is exempt" meet: narrowing helper_open to line-start-only would leave
  # this inert shape unflagged while both extremes stayed green.
  mkfix '@test "planted" {\n  true && contains "$o" "a" && lacks "$o" "b"\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "and-tail"
}

@test "the '&&' rule sees a helper opening a command after ';' too (#1067)" {
  # Same opener rule as `bracket`: first token of the line, or first after a
  # separator. A first-token-only rule would miss this.
  mkfix '@test "planted" {\n  run foo; starts_with "$output" "a" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" 'run foo; starts_with "$output" "a" && true'

  mkfix '@test "planted" {\n  false || ends_with "$output" "a" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" 'ends_with "$output" "a" && true'

  # helper_open must keep SCANNING past a quoted separator+helper, not stop at
  # it. A regression that returned 0 on the first quoted match would silently
  # unflag the real offender later on the line — a false clean, the worst
  # direction. This is the `and-tail` counterpart of the `bracket` rule's
  # "a quoted one early on the line must not mask a real one later".
  mkfix '@test "planted" {\n  printf %s '"'"'x; contains "a" "b"'"'"'; lacks "$o" "z" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "and-tail"
}

@test "the '&&' rule covers every helper in the roster (#1067)" {
  # The roster is one awk variable. Pin every name in it, so dropping one
  # cannot silently unguard that helper while the suite stays green.
  local h
  for h in $HELPER_ROSTER; do
    mkfix '@test "planted" {\n  '"$h"' "$output" "a" && true\n  true\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$h"
    contains "$output" "and-tail"
  done
}

@test "the '&&' rule fires in a fixture hook, not just a test body (#1067)" {
  local h
  for h in setup teardown setup_file teardown_file; do
    mkfix "$h"'() {\n  contains "$x" "a" && true\n  true\n}\n@test "x" {\n  true\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "and-tail"
  done
}

@test "a helper that ENDS the AND-list is caught by errexit — not flagged (#1067)" {
  # `true && contains …` returns the helper's own status as the list's status,
  # which is exactly what errexit sees. Flagging it would red legitimate lines.
  mkfix '@test "x" {\n  true && contains "$output" "a"\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  false || contains "$output" "a"\n  true\n}\n'
  has_helper
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a plain helper call on its own line is the sanctioned form (#1067)" {
  mkfix '@test "x" {\n  contains "$output" "a"\n  lacks "$output" "b"\n  true\n}\n'
  has_helper
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an '&&' inside the needle is text, not a tail (#1067)" {
  # Quote tracking is what keeps this rule usable at all: this suite builds
  # almost every fixture as a printf string that quotes the offending shape
  # verbatim, so a quote-blind rule would flag its own test files.
  mkfix '@test "x" {\n  contains "$output" "a && b"\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  printf %s '"'"'contains "a" "b" && true'"'"'\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # ...but a quoted `&&` must not MASK a real one later: and_after keeps
  # scanning past it. Every case above ends at the quoted `&&`, so without this
  # a regression to "return 0 on the first quoted hit" would report a genuinely
  # inert line as clean and no test would see it.
  mkfix '@test "x" {\n  contains "$output" "a && b" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "and-tail"
}

@test "an '&&' in a TRAILING comment is prose, not a tail (#1067)" {
  # The `and-tail` counterpart of the `bracket` rule's trailing-comment test:
  # the rule judges the line with the comment stripped. If it ever stopped
  # stripping, this perfectly legitimate line would be flagged with advice
  # ("one assertion per line") that does not apply.
  mkfix '@test "x" {\n  contains "$output" "a"  # a note about x && y\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the documented '|| true' FALSE NEGATIVE is recorded, not silently missed (#1067)" {
  # `contains … || true` discards the assertion exactly as an `&&` tail does,
  # and the header lists it as a FALSE NEGATIVE — "a blind spot, not a
  # blessing". Pin the current verdict so widening `and_after` to cover a
  # non-failing `||` tail is a deliberate, visible change rather than an
  # accidental one, exactly as the unscanned-named-function false negative is
  # pinned below.
  mkfix '@test "x" {\n  contains "$output" "a" || true\n  true\n}\n'
  has_helper
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Each documented limit gets its OWN test, per tests/README.md's one-planted-
# issue rule: bundled, a regression names none of them and errexit stops at the
# first, leaving the rest unevaluated. Same rationale as the `|| true` pin above
# — a limit the prose ADVERTISES must be pinned, so widening or narrowing the
# rule is a deliberate change with a red test rather than a quiet divergence
# between the docs and the code.

@test "a PIPED helper call is a documented blind spot (#1067)" {
  # A pipeline's status is its last command's and bats runs no `pipefail`, so
  # the assertion is discarded — but `and_after` keys on `&&`, so nothing flags
  # it.
  mkfix '@test "x" {\n  contains "$output" "a" | cat\n  true\n}\n'
  has_helper
  grep -q '|' "$FIX"
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an AND-list continued with a trailing backslash is a documented blind spot (#1067)" {
  # The rule is per line, so the left operand is hidden on the line above.
  mkfix '@test "x" {\n  contains "$o" "a" \\\n    && contains "$o" "b"\n  true\n}\n'
  has_helper
  # The canary that matters here: the fixture must really END a line with ONE
  # backslash. An escaping slip yields `\\` — an escaped literal backslash, a
  # complete command — which is a different (and syntactically invalid) shape,
  # and the test would go on passing while pinning nothing.
  grep -qE '[^\\]\\$' "$FIX"
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "'[ … ] && [ … ]' is matched by NEITHER rule (#1067)" {
  # Inert on every bash — the AND-list exemption is not about helpers — but
  # `bracket` keys on `[[` and `and-tail` on the helper roster, so it is missed.
  # Its own canary: this fixture carries neither a `[[` nor a helper, so neither
  # of the standard ones applies.
  mkfix '@test "x" {\n  [ -n "$a" ] && [ -f "$b" ]\n  true\n}\n'
  grep -qF -- '[ -n "$a" ] && [ -f "$b" ]' "$FIX"
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an '&&' belonging to a CLOSED construct still flags the helper — documented false positive (#1067)" {
  # Pinned in the other direction: the rule judges the whole line, so a helper
  # whose own status IS caught is flagged anyway when an `&&` appears later.
  mkfix '@test "x" {\n  contains "$x" "a"; if true; then true; fi && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "and-tail"
}

@test "a heredoc opened on a FLAGGED line still reports that line (#1067)" {
  # The header's safety claim for this false positive rests entirely on rule
  # order: the offender rules run BEFORE the heredoc-opener rule. Hoist the
  # heredoc rule and this line would open a tracked heredoc, `next` without
  # reporting, and swallow its payload — the offender vanishes and the file
  # reports CLEAN. Nothing else pins that ordering.
  mkfix '@test "x" {\n  contains "$o" "a" && cat > "$f" <<EOF\npayload\nEOF\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: and-tail:"
}

@test "a helper as the LEFT operand of '||' is deliberately not flagged (#1067)" {
  # The documented asymmetry: a `[[ ]]` carrying an `|| return 1` tail is
  # flagged for uniformity with the ban on the idiom, but a helper call has no
  # idiom to ban, so `contains … || return 1` is a legitimate assertion. Pinning
  # it is what stops a future widening of and_after to `(&&|\|\|)` from
  # reddening real call sites with advice that does not apply.
  mkfix '@test "x" {\n  contains "$output" "a" || return 1\n  true\n}\n'
  has_helper
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an '&&' helper CONDITION is control flow, not an assertion (#1067)" {
  # Same carve-out as `bracket`: the construct consumes the status, so nothing
  # is swallowed — and there is no one-assertion-per-line fix to advise.
  mkfix '@test "x" {\n  if contains "$o" "a" && contains "$o" "b"; then\n    true\n  fi\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  while contains "$o" "a" && contains "$o" "b"; do\n    break\n  done\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "'run <helper> && …' is not the flagged shape (#1067)" {
  # `run` is the command; the helper is its argument, and `run` succeeds
  # regardless, so nothing is swallowed that was not already the caller's to
  # check via `$status`.
  mkfix '@test "x" {\n  run contains "$output" "a" && true\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a helper name is matched as a whole token, not a substring (#1067)" {
  # `foo_matches` / `matches_all` are different commands. Matching loosely would
  # flag them and send the reader looking for an assertion that is not there.
  mkfix '@test "x" {\n  foo_matches "$o" "a" && true\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  matches_all "$o" "a" && true\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the '&&' rule is scoped to blocks and skips heredocs and comments (#1067)" {
  # A named helper function is not scanned. For `and-tail` that is a documented
  # FALSE NEGATIVE, not a carve-out: `h() { contains … && true; }` is just as
  # inert as the same line in a test body — the wrapper hides it, it does not
  # rescue it. Pinned so the scoping is a deliberate limit rather than an
  # accident, and so widening the scan later is a visible decision.
  mkfix 'h() {\n  contains "$1" "a" && true\n}\n@test "x" {\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  cat > "$f" <<EOF\ncontains "a" "b" && true\nEOF\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  # contains "a" "b" && true is inert\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- offenders carry the rule that found them -------------------------------

@test "each offender is tagged with its rule, and a mixed file reports both (#1067)" {
  # The tag is what lets the guard give advice that fits: "convert it to a
  # helper" is wrong for a line that already calls one. Assert the whole
  # `<file>:<line>: <rule>: ` prefix, so a tag emitted in the wrong field (where
  # it would read as part of the source line) still fails this.
  mkfix '@test "x" {\n  [[ -f /nonexistent ]]\n  contains "$output" "a" && true\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket: [[ -f /nonexistent ]]"
  contains "$output" "$FIX:3: and-tail: contains"
}

@test "a line that is BOTH shapes is reported once, as 'bracket' (#1067)" {
  # `[[ … ]] && contains …` is a `[[ ]]` assertion first; converting it is the
  # fix either way, so two reports for one line would just be noise.
  mkfix '@test "x" {\n  [[ -f /nonexistent ]] && contains "$output" "a"\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "bracket"
  lacks "$output" "and-tail"
  [ "${#lines[@]}" -eq 1 ]
}

# --- five closed parser blind spots (#1068) ---------------------------------
#
# Each was a documented, accepted limit of the line-oriented awk state
# machine; #1068 closes all five within that same machine (no rewrite). Every
# limit gets its own planted-offender test that fails when its fix is
# reverted, plus a not-flagged counterpart — the same one-planted-issue
# discipline the rest of this file follows.

@test "a self-contained ONE-LINE block with several statements is scanned (#1068)" {
  # Limit 1 (false negative): rule 3 used to treat every one-liner as having
  # no body to hide an assertion in. A multi-statement one DOES have a body.
  mkfix '@test "x" { [[ -f /nonexistent ]]; true; }\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:1: bracket: @test \"x\" { [[ -f /nonexistent ]]; true; }"

  # A single-statement one-liner carries nothing to flag either way.
  mkfix 'teardown() { rm -rf "$W"; }\n'
  grep -qF -- 'teardown() { rm -rf "$W"; }' "$FIX"
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # judge_oneliner is reached from rule 3 by BOTH the @test and the hook
  # alternations; the hook one-liner is the shape that motivated the limit, so
  # it gets its own planted offender rather than only an offender-free case.
  mkfix 'teardown() { rm -f x; [[ -f /nonexistent ]]; }\n@test "x" {\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:1: bracket: teardown() { rm -f x; [[ -f /nonexistent ]]; }"
}

@test "a BRACE inside the @test title does not shield a one-liner offender (#1068)" {
  # judge_oneliner finds the opening `{` with a quote-aware walk rather than
  # the first `{` on the line. With a plain index() the interior would start
  # mid-title, inherit the title's unmatched closing quote, and the real
  # `; [[` would then read as quoted — exit 0, offender hidden. Every other
  # one-liner fixture uses a brace-free title, so nothing else reaches this.
  mkfix '@test "expands {a}" { rm -f y; [[ -f /nonexistent ]]; }\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:1: bracket:"
  contains "$output" "[[ -f /nonexistent ]]"
}

@test "a one-liner interior is judged, not merely skipped — exemptions apply inside it (#1068)" {
  # The counterpart above cannot tell "judge_oneliner found nothing" from
  # "judge_oneliner never ran": its interior has nothing flaggable at all.
  # These two DO carry the input the exemption is about, so they pin the
  # judgement rather than an absence of input.
  #
  # A quoted `[[` in the interior is text, via in_quotes on the substring.
  mkfix '@test "x" { printf %s "a; [[ -f /x ]]"; true; }\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # A condition in the interior is control flow, via judge_code's exemption.
  # This is also the isolating pin for judge_code's OWN keyword set: rule 5
  # never claims a one-liner interior, so an `elif` missing from judge_code
  # alone reds here via sep_bracket.
  mkfix '@test "x" { elif [[ -f /a ]] && [[ -f /b ]]; then :; fi; }\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # COMPOUND, deliberately: a simple `if [[ … ]]; then` interior would be
  # unflaggable anyway (its `[[` follows `if `, which is neither line-start nor
  # a separator), so the assertion would hold with the exemption deleted and
  # pin nothing. With `&& [[` present, sep_bracket reports it the moment the
  # exemption is dropped — the same shape the whole-line sibling pins.
  mkfix '@test "x" { if [[ -f /a ]] && [[ -f /b ]]; then true; fi; }\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a one-liner interior reaches the and-tail rule too, not just bracket (#1068)" {
  # judge_oneliner routes through the shared judge_code, so BOTH offender
  # rules apply to an interior. Without this, a regression that dropped the
  # and-tail half on the one-liner path would stay green.
  mkfix '@test "x" { contains "$o" "a" && true; }\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:1: and-tail:"
}

@test "an assertion AFTER a closed construct on the same line is caught (#1068)" {
  # Limit 2 (false negative): the condition exemption used to skip the WHOLE
  # line; the remainder after a top-level fi;/done; is now re-judged. Assert
  # the full `<file>:<line>: <rule>: ` prefix, not a bare needle — the bare
  # text also appears in the output produced by dropping the condition
  # exemption altogether, which would pass a broken rule.
  mkfix '@test "x" {\n  if true; then :; fi; [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket: if true; then :; fi; [[ -f /nonexistent ]]"

  mkfix '@test "x" {\n  while true; do break; done; [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket: while true; do break; done; [[ -f /nonexistent ]]"

  # An `&&`/`||` closer tail ends the construct exactly as `;` does, so the
  # assertion after it is swallowed the same way and must be caught. Both
  # alternatives are pinned: dropping either from the closer pattern is a
  # false clean the other half would not catch.
  mkfix '@test "x" {\n  if true; then :; fi && [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  mkfix '@test "x" {\n  if true; then :; fi || [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # Isolates rule 5's keyword set: with `until` missing from rule 5 the line is
  # never re-judged (judge_code exempts it whole) and the offender vanishes.
  mkfix '@test "x" {\n  until true; do :; done; [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # The LAST top-level closer wins: with two closed constructs on one line,
  # taking the FIRST match would hand back a remainder still containing the
  # second construct, whose own `if` would then exempt the whole thing.
  mkfix '@test "x" {\n  if true; then :; fi; if true; then :; fi; [[ -f /nonexistent ]]\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # A compound condition entirely on ONE line has no closer on that line, so
  # it stays fully exempt — the fix must not widen into this shape.
  mkfix '@test "x" {\n  if [[ -f /a ]] && [[ -f /b ]]; then\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a QUOTED 'fi;' on a condition line yields no re-judged remainder (#1068)" {
  # The in_quotes guard in closed_construct_tail. Without it the remainder
  # would start inside the needle, `judge_code` would flag the quoted `[[`,
  # and the guard would advise converting a CONDITION to a helper — the one
  # rewrite the header explicitly forbids (127 makes the branch silently
  # false in a file lacking `load assertions`).
  mkfix '@test "x" {\n  if grep -q "x fi; [[ -f /y ]]" f; then :; fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a WORD ending in fi/done is not a closer — the boundary class (#1068)" {
  # closed_construct_tail's boundary class is a coarse but portable
  # word-boundary substitute. Drop it and `wifi;` matches as a closer, so the
  # remainder ` then :; [[ -f /a ]]; fi` gets judged and its `; [[` reported —
  # flagging genuine control flow with the one conversion the header forbids
  # for conditions.
  mkfix '@test "x" {\n  if grep -q wifi; then :; [[ -f /a ]]; fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkfix '@test "x" {\n  while grep -q undone; do :; [[ -f /a ]]; done\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the carry is fed comment-stripped code, so a trailing comment cannot open a literal (#1068)" {
  # apply_quote_carry takes `code`, not `$0`. Feeding it the raw line would let
  # an apostrophe in a trailing comment open a phantom multi-line literal that
  # swallows the rest of the block — the offender below would vanish and the
  # scan would end exit 2 on "never closed" instead. Held only by accident
  # elsewhere in the suite, which is exactly the reasoning used for the
  # phantom-heredoc pins.
  mkfix '@test "x" {\n  run foo  # the marker'"'"'s absence\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3: bracket:"
}

@test "a still-OPEN condition list is exempt in full, closers and all (#1068)" {
  # A line ending in `; then`/`; do` has not closed its condition: every token
  # on it, including anything after a NESTED construct's own `fi;`, is still a
  # condition-list member whose status the construct consumes. Re-judging here
  # would flag control flow with the forbidden conversion advice.
  mkfix '@test "x" {\n  while if true; then :; fi; [[ -f /a ]]; do\n    break\n  done\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The guard alternation is (then|do); the `do` branch is above, this is
  # `then`. Narrowing it to one keyword would re-judge the other's remainder.
  mkfix '@test "x" {\n  if if true; then :; fi; [[ -f /a ]]; then\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a post-closer remainder reaches the and-tail rule too (#1068)" {
  # The remainder routes through the shared judge_code, so both offender rules
  # apply to it — not just `bracket`.
  mkfix '@test "x" {\n  if true; then :; fi; contains "$o" "a" && true\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: and-tail:"
}

@test "a helper function defined INSIDE a scanned block is not flagged (#1068)" {
  # Limit 3 (false positive): its own `[[` line used to be flagged even though
  # a call to it, in the SAME block, is caught normally.
  mkfix '@test "x" {\n  has_it() {\n    [[ -f "$1" ]]\n  }\n  has_it /nonexistent\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # An assertion OUTSIDE the nested helper, in the same outer block, is still
  # caught — the suppression is scoped to the nested function's own body.
  mkfix '@test "x" {\n  has_it() {\n    [[ -f "$1" ]]\n  }\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:5:"
}

@test "every legal nested-helper SPELLING is scoped alike (#1068)" {
  # Recognizing only `name() {` would leave the other legal spellings flagged
  # — and the guard would advise "convert it to a helper" on a line that
  # already IS a helper definition. These are the same spellings the hook
  # recognizer admits (pinned for hooks at "the alternative hook spellings").
  local spelling
  for spelling in 'has_it() {' 'has_it () {' 'function has_it() {' 'function has_it {'; do
    mkfix '@test "x" {\n  '"$spelling"'\n    [[ -f "$1" ]]\n  }\n  true\n}\n'
    has_bracket
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "a nested helper's close may carry a ';' or redirection tail (#1068)" {
  # in_helper clears only on a recognized close. A helper closed `};` or
  # `} 2>/dev/null` would otherwise leave it set forever, silently suppressing
  # every later line of the enclosing block — so the planted offender AFTER
  # the helper is what proves the state was released.
  local closer
  for closer in '  }' '  };' '  } 2>/dev/null'; do
    mkfix '@test "x" {\n  has_it() {\n    [[ -f "$1" ]]\n'"$closer"'\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:5: bracket: [[ -f /nonexistent ]]"
  done
}

@test "a nested helper whose close is never recognized is exit 2, not a silent skip (#1068)" {
  # The stuck-state desync. Suppressing a helper body is only safe if the
  # scanner can prove where that body ENDS; a close it cannot recognize would
  # otherwise swallow the rest of the block behind a confident exit 0.
  mkfix '@test "x" {\n  has_it() {\n    [[ -f "$1" ]]\n  } | cat\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "1 nested helper function(s) never closed"
  contains "$output" "(line(s): 2)"
}

@test "a nested helper still open at END OF FILE is exit 2, not a silent skip (#1068)" {
  # The sibling of the block-close case: rule 4 catches a helper still open
  # when the enclosing block closes, but a TRUNCATED file never reaches that
  # `}`. Without the flush_file check, rule 4b suppresses every line from the
  # opener to EOF and the scan exits 0 — and before #1068 this same file
  # reported the `[[` line, so it would be a regression, not just a gap.
  mkfix '@test "x" {\n  has_it() {\n    [[ -f /nonexistent ]]\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "1 nested helper function(s) never closed"
  contains "$output" "(line(s): 2)"
}

@test "stuck nested helpers are counted PER HELPER, not per file (#1068)" {
  # Mirrors the two-malformed-opener test: a count that saturated at one would
  # hide every stuck helper after the first, and the header claims per-helper.
  mkfix '@test "a" {\n  h1() {\n    true\n  } | cat\n}\n@test "b" {\n  h2() {\n    true\n  } | cat\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "2 nested helper function(s) never closed"
  contains "$output" "(line(s): 2 7)"
}

@test "a nested helper still open when a NEW block opener arrives is exit 2 (#1068)" {
  # The third way a helper close can go unfound. Rule 3 runs BEFORE the
  # suppression rule, so a column-0 opener reached while the helper is open
  # lands there — and without folding it into the tally it would discard the
  # whole suppressed span behind a clean exit. Reverting the fold makes this
  # file exit 0 while origin/main reports the `[[` line, so it is a regression
  # guard, not just a gap.
  mkfix '@test "a" {\n  h() {\n    [[ -f /payload ]]\n@test "b" {\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "1 nested helper function(s) never closed"
  contains "$output" "(line(s): 2)"
}

@test "an and-tail swallowed helper call inside a nested helper is a documented blind spot (#1068)" {
  # The nested-helper suppression covers the whole body, so it inherits the
  # top-level helper's `and-tail` false negative too — the header says so, and
  # the top-level analogue is already pinned, so this one gets the same pin.
  mkfix '@test "x" {\n  h() {\n    contains "$1" "a" && true\n  }\n  true\n}\n'
  has_and_tail
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a function nested inside a helper body closes the outer one early — documented limit (#1068)" {
  # The nested-helper model is one level deep: the inner function's own
  # indented `}` clears the suppression, so the rest of the OUTER helper body
  # is judged as block code and its assertion is flagged.
  mkfix '@test "x" {\n  outer() {\n    inner() {\n      true\n    }\n    [[ -f /nonexistent ]]\n  }\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6: bracket:"
}

@test "a close line that itself opens a heredoc still tracks it (#1068)" {
  # The accepted close tail is a redirection, and `[<>]+` also matches `<<` —
  # so `} <<EOF` is a legal close that OPENS a heredoc. Consuming it without
  # tracking leaves the payload read as code, its column-0 `}` clears the
  # enclosing block, and the assertion after the terminator is never judged:
  # exit 0 on a file origin/main reports. Both close paths carry the tail, so
  # both are pinned.
  mkfix '@test "x" {\n  h() {\n    cat\n  } <<EOF\n}\npayload\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "payload"

  # The outer block's own close, same shape: an untracked payload here would be
  # read at top level, where a `@test`-shaped payload line opens a phantom
  # block and gets its contents judged.
  mkfix '@test "x" {\n  true\n} <<EOF\n@test "phantom" {\n  [[ -f /payload ]]\n}\nEOF\n@test "real" {\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:9: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"
}

@test "a heredoc inside a nested helper body is tracked as payload (#1068)" {
  # Rule 4b `next`s the helper body, so without tracking, a heredoc opened in
  # it would have its payload read as code — and a column-0 '}' in that
  # payload would clear the OUTER block, unscanning the rest of the test.
  mkfix '@test "x" {\n  has_it() {\n    cat <<EOF\n}\n[[ -f /payload ]]\nEOF\n  }\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"
}

@test "a continuation line of a multi-line quoted literal is judged as string (#1068)" {
  # Limit 4 (false positive): quote parity now persists across lines, so a
  # continuation line is text, not code. The `[[` sits in a FLAGGABLE position
  # (first token of the line) — a `[[` mid-line would be unflaggable anyway,
  # so the test would pass with the whole carry reverted and pin nothing.
  mkfix '@test "x" {\n  printf %s "line one\n[[ -f /x ]] still text"\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The paired POSITIVE: the very same text outside a literal IS flagged, so
  # the carry — not the text — is what makes the difference.
  mkfix '@test "x" {\n  [[ -f /x ]] still text\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # The sep_bracket path is a separate branch of judge_code, so it needs its
  # own continuation-line shape.
  mkfix '@test "x" {\n  printf %s "line one\n; [[ -f /x ]] still text"\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a multi-line literal left OPEN at end of file is exit 2, not a silent clean (#1068)" {
  # The carry can only be trusted if a carry that never closes is loud. Left
  # silent, rule 1b swallows every remaining line — including the block's own
  # close and any later @test opener — behind a confident exit 0.
  mkfix '@test "x" {\n  printf %s "never closes\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 2 ]
  contains "$output" "multi-line quoted literal is never closed"
}

@test "a line the parity model cannot read never OPENS a carry (#1068)" {
  # `$( … )` and backticks restart the shell's quoting context, which the flat
  # parity walk does not model, so a balanced real line can count odd. Such a
  # line must not open a phantom literal — these two shapes are adapted from
  # tests/react-topic-marker.bats and tests/coverage-floor-hook.bats (quote
  # parity, the load-bearing property, is preserved verbatim), both of which
  # the detector must still scan clean.
  mkfix '@test "x" {\n  s="$(printf '"'"'%s'"'"' "$M" | grep -oE "\\-path '"'"'[^'"'"']+'"'"'" | sort -u)"\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3: bracket: [[ -f /nonexistent ]]"

  # The backtick clause of the same screen, which no other fixture reaches: a
  # backtick substitution whose inner quotes leave the flat model counting odd.
  # Without that clause the carry opens here and swallows the offender below.
  mkfix '@test "x" {\n  v="`grep -oE "a'"'"'b" f`"\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:3: bracket: [[ -f /nonexistent ]]"

  # Neither boundary line of a multi-line $(...) opens a carry (the first
  # carries `$(`, the last a `)`), so no phantom literal forms and the
  # remainder of the block is scanned — the payload lines in between are
  # judged per line as code.
  mkfix '@test "x" {\n  E="$(awk '"'"'\n    /^x/ { n=1 }\n  '"'"' "$CFG")"\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:5: bracket: [[ -f /nonexistent ]]"
}

@test "rule 1b claims a continuation line before the establishment screen runs (#1068)" {
  # The screen must gate ESTABLISHMENT only, never a close. Rule 1b consumes
  # every line that BEGINS inside a literal before the screen rule is reached,
  # which is what guarantees that — so a `)` on a continuation line cannot
  # close the carry early and start judging the literal's tail as code. (The
  # `!was_open` conjunct in the screen is belt-and-braces for that ordering;
  # rule 1b makes it unreachable today, so it is not independently testable.)
  mkfix '@test "x" {\n  printf %s "one\nmid ) text\n[[ -f /x ]] two"\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an offender BEFORE a literal-opening quote on the same line is still caught (#1068)" {
  # The round-1 regression this file exists to prevent a repeat of: seeding
  # in_quotes from the carry (which the carry-advance rule has already moved to
  # the line's END parity) inverts every quoted/unquoted verdict on a line with
  # odd parity, so an offender sitting before the literal-opening quote reads
  # as string and vanishes. Nothing else in the suite puts a judged offender on
  # an odd-parity line, so without this the regression could return unnoticed.
  # It must reach a path that consults in_quotes — the leading-`[[` branch
  # never does — hence the separator form.
  mkfix '@test "x" {\n  run true; [[ -f /nonexistent ]]; printf %s "opens\ncloses"\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # The and-tail sibling, covering helper_open/and_after rather than
  # sep_bracket.
  mkfix '@test "x" {\n  run true; contains "$o" "a" && true; printf %s "opens\ncloses"\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: and-tail:"
}

@test "a FLAGGED condition line still tracks its heredoc — the rule-5 exception (#1068)" {
  # The header carves rule 5 out of the flagged-line-heredoc false positive:
  # unlike rules 6/6b, it judges its post-closer remainder AND still tracks the
  # opener. Mirroring rules 6/6b here (nexting after a positive judgement)
  # would leave the payload scanned as code, its column-0 `}` would clear the
  # block, and everything after would go unscanned. The TRAILING offender is
  # the load-bearing assertion: it proves the block survived the payload.
  mkfix '@test "x" {\n  if true; then :; fi; [[ -f /nonexistent ]]; cat <<EOF\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /trailing ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"
  contains "$output" "$FIX:6: bracket:"
  lacks "$output" "/payload"
}

@test "a column-0 '}' inside a multi-line literal does not clear the block — false clean pinned (#1068)" {
  # Limit 4's OTHER direction: per-line quote tracking used to read a
  # column-0 '}' inside the still-open literal as the block's close, so every
  # later assertion in that test went unscanned. The planted offender AFTER
  # it must still be caught.
  mkfix '@test "x" {\n  printf %s "line one\n}\nline two"\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:5: bracket: [[ -f /nonexistent ]]"
}

@test "a heredoc opened on a CONDITION line is tracked, payload skipped (#1068)" {
  # Limit 5a (false negative): the condition exemption used to `next` before
  # the heredoc-opener rule ever ran, so this shape was never tracked.
  mkfix '@test "x" {\n  if grep -q y <<EOF; then\n  [[ -f /payload ]]\n}\nEOF\n    true\n  fi\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"

  mkfix '@test "x" {\n  if grep -q y <<EOF; then\n  [[ -f /payload ]]\n}\nEOF\n    true\n  fi\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # False-clean direction pinned: a column-0 '}' INSIDE the payload must not
  # clear the block either, once the opener is recognized.
  mkfix '@test "x" {\n  if grep -q y <<EOF; then\n}\n[[ -f /payload ]]\nEOF\n    true\n  fi\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"
}

@test "a heredoc opened on a '; do' condition line is tracked too (#1068)" {
  # The condition set is if/elif/while/until, so the opener rule accepts a
  # `; do` tail as well as `; then`. Testing only `; then` would let an edit
  # narrowing the alternation pass while `while … <<EOF; do` silently reverts
  # to an untracked payload whose column-0 '}' clears the block.
  mkfix '@test "x" {\n  while grep -q y <<EOF; do\n}\n[[ -f /payload ]]\nEOF\n    break\n  done\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"

  # `until` is the fourth condition keyword and reaches the opener rule the
  # same way; nothing else in the suite drives it there.
  mkfix '@test "x" {\n  until grep -q y <<EOF; do\n}\n[[ -f /payload ]]\nEOF\n    break\n  done\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"
}

@test "a heredoc opener with a PIPE tail is tracked, payload skipped (#1068)" {
  # Limit 5b (false negative): '<<EOF | tee f' was a tail the opener rule did
  # not accept. The payload carries a column-0 '}' so this pins the FALSE-CLEAN
  # direction the acceptance criteria name: with the fix reverted the '}'
  # clears the block and the trailing offender goes unscanned (exit 0), rather
  # than merely being misreported.
  mkfix '@test "x" {\n  cat <<EOF | tee "$f"\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"

  mkfix '@test "x" {\n  cat <<EOF | tee "$f"\n[[ -f /payload ]]\nEOF\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a heredoc opener with an AND tail is tracked, payload skipped (#1068)" {
  # Limit 5b (false negative), the other tail: '<<EOF && x'. Same column-0 '}'
  # in the payload, for the same false-clean reason as the pipe tail above.
  mkfix '@test "x" {\n  cat <<EOF && true\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"

  mkfix '@test "x" {\n  cat <<EOF && true\n[[ -f /payload ]]\nEOF\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the CONDITION-line opener alternative accepts '<<-' too (#1068)" {
  # The `<<-` pin matrix: the redirection tail has one, and the `|`/`&&` tails
  # share one — the condition-line alternative is its own independently
  # editable branch, so it needs its own. Narrow its `<<-?` to `<<` and the
  # opener stops being tracked, the payload is read as code, its column-0 `}`
  # clears the block, and the trailing assertion goes unscanned at exit 0.
  # Both condition spellings, each with a column-0 `}` in the payload: the
  # tracked opener keeps the block alive, so the trailing offender is still
  # judged. The terminator is tab-indented, which only a `<<-` opener accepts,
  # so this pins `dash` on this branch as well as the branch itself.
  local head tail
  for head in 'if grep -q y <<-EOF; then' 'while grep -q y <<-EOF; do'; do
    case "$head" in (if*) tail='    true\n  fi' ;; (*) tail='    break\n  done' ;; esac
    mkfix '@test "x" {\n  '"$head"'\n}\n[[ -f /payload ]]\n\tEOF\n'"$tail"'\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:8: bracket: [[ -f /nonexistent ]]"
    lacks "$output" "/payload"
  done
}

@test "an arithmetic shift is not a heredoc opener (#1068)" {
  # The `|`/`&&` alternatives accept `<<` + identifier + operator, which an
  # arithmetic shift whose RHS is followed by a bitwise or logical operator
  # also spells. Unscreened, `$((a<<b|c))` opens a phantom heredoc named `b`
  # and the scan ends exit 2 "never terminated" on a perfectly valid file —
  # a regression the widened alternatives introduced and the `$((` screen
  # removes. The trailing offender is what proves the scan kept going.
  local expr
  for expr in 'a<<b|c' 'a<<b||c' 'a<<b&&c'; do
    mkfix '@test "x" {\n  echo $(('"$expr"'))\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:3: bracket: [[ -f /nonexistent ]]"
  done

  # The bare arithmetic COMMAND form has no `$` and reaches the same widened
  # alternatives; `if (( … )); then` gets there via rule 5. Both are screened.
  local cmd
  for cmd in '(( f = a<<b | c ))' 'if (( a<<b|c )); then :; fi'; do
    mkfix '@test "x" {\n  '"$cmd"'\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:3: bracket: [[ -f /nonexistent ]]"
  done

  # A QUOTED unclosed `$((` must NOT refuse a real opener — the screen walks
  # unquoted occurrences only. Blind to quoting, this reads the payload as
  # code, its column-0 `}` clears the block, and the offender below vanishes.
  mkfix '@test "x" {\n  lacks "$output" '"'"'echo $((a'"'"'; cat <<EOF\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"

  # ...and a REAL opener later on a line whose arithmetic already closed is
  # still tracked, so the screen is scoped to the unclosed case.
  mkfix '@test "x" {\n  echo $((a<<2)); cat <<EOF |\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
  lacks "$output" "/payload"
}

@test "a heredoc opener whose '|' or '&&' ENDS the line is tracked too (#1068)" {
  # The idiomatic line-continuation spelling: the downstream command sits on
  # the next line. Requiring a command after the operator left these untracked,
  # so the payload was read as code and its column-0 `}` cleared the block —
  # exit 0 with the trailing assertion unscanned, on a shape the header claimed
  # was accepted.
  local op
  for op in '|' '||' '&&'; do
    mkfix '@test "x" {\n  cat <<EOF '"$op"'\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
    lacks "$output" "/payload"
  done
}

@test "only ONE heredoc per line is tracked; which one follows the alternation order — documented limit (#1068)" {
  # This fixture pins the `<<A <<B` spelling specifically: the end-anchored
  # redirection alternative matches leftmost at `<<A`, absorbing ` <<B` into
  # its redirection group, so `A` is tracked and body B is read as code, where
  # its column-0 `}` clears the block. Do NOT generalize that to "the first
  # opener wins" — for `cat <<A | cat <<B` the same alternative's leftmost
  # match is `<<B`, so the SECOND is tracked and both bodies are skipped; see
  # the detector header's three-spelling enumeration. Distinct from the other
  # heredoc limits either way: the recognizer ACCEPTED an opener and saw its
  # heredoc terminate, so no desync guard fires — hence exit 0, pinned here as
  # the deliberate limit it is.
  # A's payload carries a planted offender, so this also reds if NEITHER
  # opener is tracked (then it would be judged and reported) — without it the
  # test cannot tell "first tracked" from "none tracked".
  mkfix '@test "x" {\n  cat <<A <<B\n[[ -f /payload-a ]]\nA\n}\n[[ -f /payload ]]\nB\n  [[ -f /nonexistent ]]\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a heredoc delimiter outside the accepted charset is untracked — documented limit (#1068)" {
  # The recognizer requires [A-Za-z_][A-Za-z_0-9.-]*, so a digit-leading or
  # punctuation delimiter is untracked on every tail: payload read as code, its
  # column-0 `}` clears the block, trailing assertion unscanned. Exotic, and
  # pinned as the deliberate limit it is.
  mkfix '@test "x" {\n  cat <<'"'"'1EOF'"'"'\n}\n[[ -f /payload ]]\n1EOF\n  [[ -f /nonexistent ]]\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the new opener tails accept '<<-' too, with tab-stripping (#1068)" {
  # All four alternatives spell `<<-?`, but only the ORIGINAL redirection tail
  # has a `<<-` pin. Narrowing `<<-?` to `<<` in one of the new alternatives —
  # or setting `dash` on the wrong path — would leave `cat <<-EOF | tee f`
  # untracked, its payload read as code, and the column-0 `}` in that payload
  # clearing the block: a silent exit-0 false clean of exactly the class
  # limit 5 closed. The terminator is tab-indented, which only a `<<-` opener
  # accepts, so this also pins that `dash` is set on these paths.
  local tail
  for tail in ' | tee "$f"' ' && true'; do
    mkfix '@test "x" {\n  cat <<-EOF'"$tail"'\n}\n[[ -f /payload ]]\n\tEOF\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:6: bracket: [[ -f /nonexistent ]]"
    lacks "$output" "/payload"
  done
}

@test "a QUOTED mention of each new opener tail does not open a phantom heredoc (#1068)" {
  # The in_quotes guard in try_open_heredoc. Each widened tail reaches it, and
  # an assertion ABOUT such a heredoc must stay text — otherwise it swallows
  # the rest of the file and reports it CLEAN, the same false-clean class as
  # the '<<<' here-string bug. Today the guard is covered only by accident
  # (fixtures in this very file happen to be such strings), which evaporates
  # the moment they are rewritten.
  local needle
  for needle in 'cat <<EOF | tee f' 'cat <<EOF && true'; do
    mkfix '@test "x" {\n  lacks "$output" "'"$needle"'"\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:3: bracket: [[ -f /nonexistent ]]"
  done
}

@test "a quoted heredoc mention on a CONDITION line does not open a phantom heredoc (#1068)" {
  # The condition-line opener path (rule 5) is a phantom surface that did NOT
  # exist before #1068, and only in_quotes closes it. The needle's closing
  # quote must land immediately AFTER the delimiter — that is the shape the
  # opener regex accepts (its optional quote class absorbs the closing quote),
  # so this genuinely reaches the guard. A needle whose quote falls after the
  # `; then` matches no alternative at all and would pin nothing.
  local stanza
  for stanza in 'if grep -q "y <<EOF"; then\n    true\n  fi' 'while grep -q "y <<EOF"; do\n    break\n  done'; do
    mkfix '@test "x" {\n  '"$stanza"'\n  [[ -f /nonexistent ]]\n}\n'
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 1 ]
    contains "$output" "$FIX:5: bracket: [[ -f /nonexistent ]]"
  done
}

# Each limit #1068 ADDS to the header gets its own pin too, by the same rule
# that governs the #1067 ones above: a limit the prose advertises must red when
# someone widens or narrows it, or the docs and the code diverge quietly.

@test "a nested in-block helper written as a ONE-LINER is judged whole-line — documented limit (#1068)" {
  # Not recognized by rule 4c (which wants the line to END at `{`) and not
  # routed through judge_oneliner (only rule 3 reaches that), so it is judged
  # as an ordinary block line. A separator makes the `[[` visible...
  mkfix '@test "x" {\n  h() { rm -f y; [[ -f "$1" ]]; }\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:2: bracket:"

  # ...while the same helper with the `[[` FIRST is silently accepted, because
  # `{ ` is not a command separator. Both halves are documented; pinning them
  # is what makes a future change to either a deliberate one.
  mkfix '@test "x" {\n  h() { [[ -f "$1" ]]; }\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a nested helper whose brace is on the NEXT line is not scoped — documented limit (#1068)" {
  # Rule 4c admits only single-line openers, so this body is judged as
  # ordinary block code and its assertion is flagged.
  mkfix '@test "x" {\n  has_it()\n  {\n    [[ -f "$1" ]]\n  }\n  true\n}\n'
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 1 ]
  contains "$output" "$FIX:4: bracket:"
}

@test "a one-liner interior starting with a condition is exempt in full — documented limit (#1068)" {
  # The limit-1 x limit-2 intersection: the post-closer re-judging lives in
  # rule 5, which sees whole condition LINES, not extracted interiors.
  mkfix '@test "x" { if true; then :; fi; [[ -f /nonexistent ]]; }\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a heredoc opener with a generic ';' or '&' tail is untracked — documented limit (#1068)" {
  # #1068 narrowed this limit from "every non-redirection tail" to the residual
  # shapes below: a generic `;` tail, a backgrounding `&`, a redirection
  # composed with another accepted tail, and a condition whose construct
  # continues on the same line.
  # Both newly ACCEPTED tails (| and &&) have planted-offender pins; the
  # residual pair gets the same treatment in the other direction, so widening
  # the opener rule later is a visible change rather than a quiet one. The
  # column-0 `}` in the payload is what makes the current verdict exit 0: the
  # payload is read as code and clears the block.
  local tail
  for tail in '; echo after' ' &' ' > "$f" | tee x' '; then :; fi'; do
    mkfix '@test "x" {\n  cat <<EOF'"$tail"'\n}\n[[ -f /payload ]]\nEOF\n  [[ -f /nonexistent ]]\n}\n'
    has_bracket
    run zsh "$DETECT" "$FIX"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "a carry refused by the establishment screen leaves the block clearable — a documented residual gap (#1068)" {
  # ONE of the residual exit-0 gaps the detector enumerates (see its FOUR-gap
  # section) — not a desync: the opening line carries a `$(`, so no carry is
  # established, the literal's body is judged as code, and its column-0 `}`
  # clears the block — so the later planted offender goes unscanned. Pinned as
  # a deliberate limit; if a future change closes it, this test reds and the
  # header entry must move.
  mkfix '@test "x" {\n  printf %s "opens $( and stays open\n}\n[[ -f /payload ]]\nstill"\n  [[ -f /nonexistent ]]\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a phantom carry closed MID-FILE swallows the span between — a documented residual gap (#1068)" {
  # The second of the four residual exit-0 gaps. A parity misread opens a
  # carry the shell would not (the documented backslash-inside-single-quotes
  # shape: the model treats the backslash as an escape, so the closing quote is
  # swallowed). Rule 1b then eats every line until some later line flips the
  # parity back — a full-line comment holding one apostrophe does it, because
  # rule 1b consumes continuation lines BEFORE the comment rule. The offender
  # in between is skipped and the scan ends exit 0. Pinned as the deliberate
  # limit it is: origin/main reports that line, so if a future change bounds
  # this, the test reds and the header entry must move.
  mkfix '@test "x" {\n  contains "$o" '"'"'x\\'"'"' && true\n  [[ -f /nonexistent ]]\n  # don'"'"'t\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "code after a literal's mid-line close on a continuation line is not judged — documented limit (#1068)" {
  # Rule 1b treats the whole continuation line as text once the literal is
  # established, so real code after the closing quote is never judged. The
  # pre-#1068 per-line model missed the same remainder, so this is carried
  # over rather than new — but it is advertised, so it is pinned.
  mkfix '@test "x" {\n  printf %s "one\ntwo"; [[ -f /nonexistent ]]\n  true\n}\n'
  has_bracket
  run zsh "$DETECT" "$FIX"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the companion convention ----------------------------------------------

@test "every file using a helper loads assertions.bash (#1011)" {
  # A converted file that forgets `load assertions` fails with "command not
  # found" only on the paths that reach the helper — and inside an `if`
  # condition that 127 makes the branch silently false, so match a helper call
  # in ANY position, not just at line start.
  local missing
  missing="$(unloaded_helper_users "$TESTS_DIR")"
  if [ -n "$missing" ]; then
    printf 'These files use an assertion helper without loading it:%s\n' "$missing" >&2
    return 1
  fi
}

@test "the load-assertions check is not vacuous (self-test, #1011)" {
  # Without this, a regex slip would make `uses` zero everywhere and the guard
  # above would report green forever while enforcing nothing.
  local dir="$BATS_TEST_TMPDIR/loadcheck"
  mkdir -p "$dir"
  printf '@test "x" {\n  contains "$output" "y"\n  true\n}\n' > "$dir/bad.bats"
  run unloaded_helper_users "$dir"
  [ "$status" -eq 0 ]
  contains "$output" "bad.bats"

  printf 'load assertions\n@test "x" {\n  contains "$output" "y"\n  true\n}\n' > "$dir/bad.bats"
  run unloaded_helper_users "$dir"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
