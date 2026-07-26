#!/usr/bin/env bats
#
# Suite lint (#1011): a `[[ ... ]]` assertion inside an `@test` body — or inside
# setup/teardown — is SILENTLY INERT unless it happens to be the block's last
# statement. `[[ ]]` is a shell keyword, not a simple command, so bats' failure
# detection does not trip on a false one the way it does for `[ ... ]`.
#
# This is the same defect class as the bare-`!` negation guarded by #829 in
# tests/no-inert-negative-assertions.bats — that guard's own comment used to
# wave `[[ ]]` through, which is what let them accumulate: 285 inert `[[ ]]`
# assertion lines across 41 files, as counted by
# tests/find-inert-bracket-assertions.zsh on the tree immediately before the
# #1011 sweep.
#
# The sanctioned fix is tests/assertions.bash: `contains`, `lacks`,
# `starts_with`, `ends_with`, `matches` are ordinary functions, so calling one
# is a simple command that errexit catches wherever it appears.
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

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TESTS_DIR="$REPO_ROOT/tests"
  DETECT="$TESTS_DIR/find-inert-bracket-assertions.zsh"
  FIX="$BATS_TEST_TMPDIR/f.bats"
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

# Names every .bats under <dir> (recursively, matching the detector's own scan
# scope) that CALLS an assertion helper without loading the library. Matches a
# call, not the English words: the helper name must be followed by an argument
# (a quote or `$`), and comment / `@test` title lines are dropped first — "round
# 1 lacks the stamp" and "matches as a wildcard" are prose, not code.
unloaded_helper_users() {
  local dir="$1" f uses has_load out=""
  while IFS= read -r f; do
    uses="$(grep -vE '^[[:space:]]*#|^[[:space:]]*@test' "$f" \
      | grep -cE '(^|[[:space:];&|(]|\brun )(contains|lacks|starts_with|ends_with|matches)[[:space:]]+["'"'"'$]' || true)"
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

@test "no inert '[[ ]]' assertion survives in any tests/*.bats (#1011)" {
  # No arguments: also exercises the detector's default (self-directory,
  # recursive) scan mode, which nothing else covers.
  run zsh "$DETECT"
  if [ "$status" -eq 2 ]; then
    # No offender list exists on this path — telling the reader to "convert
    # assertions" would send them looking for something that is not there.
    printf 'The scan could not be trusted. Fix the reported parse desync\n'        >&2
    printf '(heredoc terminator / block opener) before this guard can pass:\n%s\n' \
      "$output" >&2
    return 1
  fi
  if [ "$status" -ne 0 ]; then
    printf 'Inert `[[ ]]` assertion(s) found — these pass even when FALSE.\n'      >&2
    printf 'Convert each to a helper from tests/assertions.bash (contains /\n'     >&2
    printf 'lacks / starts_with / ends_with / matches) and `load assertions`.\n' >&2
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
