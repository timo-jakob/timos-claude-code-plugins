#!/usr/bin/env bats
#
# --iac-only is an ENUM, not a boolean (#1892).
#
# branch-protection.sh and preflight.sh take `--iac-only false|kubernetes`. The
# old `true` value is retired repo-wide with no alias, because every caller lives
# in this repo and moved in the same PR. #1162 adds a third value, `opentofu`.
#
# Two claims, tested apart:
#
#   * THE VALUE SET. Both scripts accept exactly `false` and `kubernetes`, and
#     every other value (the retired `true` included) dies with one typed
#     message. That message is pinned HERE and nowhere else, so widening the
#     enum means editing one needle in one file. The other suites that exercise
#     a refused value assert the refusal, never its wording.
#   * NO CALLER STILL SPELLS THE RETIRED VALUE. A sweep over `git ls-files`,
#     excluding only the dated records under docs/superpowers/, finds the flag
#     followed by the retired value nowhere: executable callers, prose, the
#     bootstrap SKILL.md placeholder and the golden fixtures, which are
#     regenerated rather than exempted. The roster is DERIVED from the index,
#     never a closed list of paths, so a new file that restates the flag is swept
#     the day it lands. A non-vacuity control proves the sweep fires.
#
#     The sweep is WIDER than the story's one-line pattern in two ways, both
#     learned from a site the one-line pattern missed (ARCHITECTURE.md's #1162
#     specification, which wrapped a code span as "`--iac-only" / "true`"):
#     a backtick may sit between the flag and the value, and the value may sit
#     at the start of the NEXT line. What it still cannot see is a value two or
#     more lines below the flag, or one separated from it by any other word.
#
# The retired value is held in a variable below, never written after the flag.
# Written out, this file's own source would trip the sweep it defines.

bats_require_minimum_version 1.5.0

load assertions

# The one statement of the refusal. #1162 widens it to add `opentofu`.
ENUM_MESSAGE='--iac-only must be one of: false kubernetes'

# The retired value, kept out of this file's own source text (see the header).
RETIRED=true

# The sweep's pattern: the story's (the flag, then spaces or `=`, then any
# opening quote or placeholder bracket, then the retired value), widened to admit
# a backtick in both classes, so a code span closed or opened between the flag
# and the value is still caught. Every line the story's pattern matches, this
# one matches too.
SWEEP_RE="--iac-only[[:space:]=\`]+[\"'<\`]*${RETIRED}"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  PREFLIGHT="$REPO_ROOT/development/skills/bootstrap/scripts/preflight.sh"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  # gh answers the repo lookup; uname answers Linux so preflight stops at its
  # macOS check, the first thing after argument validation, and never runs brew
  printf '#!/bin/sh\ncase "$1 $2" in "repo view") echo acme/gitops ;; esac\nexit 0\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\necho Linux\n' > "$STUB_BIN/uname"
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/uname"
  # an empty repo root: no kubernetes-ci.yml, so the kubernetes path refuses with
  # its own message, after validation and before any rule is written
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cd "$WORK"
}

# ---------------------------------------------------------------------------
# The value set
# ---------------------------------------------------------------------------

@test "branch-protection accepts --iac-only false and kubernetes: each gets past validation to its own path (#1892)" {
  # `false` is the language-app path, which requires the toolchain flags: its
  # refusal names them, proving the value was accepted
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --has-dockerfile false --has-codeql false --iac-only false --default-branch main
  [ "$status" -eq 1 ]
  lacks "$stderr" "$ENUM_MESSAGE"
  contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
  # `kubernetes` is the IaC path, which never reads the toolchain and refuses
  # here only because this repo has no kubernetes-ci.yml — the IaC path's own check
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --has-dockerfile false --has-codeql false --iac-only kubernetes --default-branch main
  [ "$status" -eq 1 ]
  lacks "$stderr" "$ENUM_MESSAGE"
  lacks "$stderr" '--static-analysis must be'
  contains "$stderr" 'kubernetes-ci.yml` is absent'
}

@test "preflight accepts --iac-only false and kubernetes: each gets past validation to its own path (#1892)" {
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only false --assume-yes
  [ "$status" -eq 1 ]
  lacks "$stderr" "$ENUM_MESSAGE"
  contains "$stderr" '--static-analysis must be sonarcloud or sonarqube'
  # the IaC path skips the toolchain check and reaches the macOS precondition
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PREFLIGHT" \
    --languages "" --has-dockerfile false --iac-only kubernetes --assume-yes
  [ "$status" -eq 1 ]
  lacks "$stderr" "$ENUM_MESSAGE"
  lacks "$stderr" '--static-analysis must be'
  contains "$stderr" 'This script supports macOS only. Detected: Linux'
}

@test "both scripts refuse the retired true and every other value with the one typed message (#1892)" {
  # the retired value first; then case, affix and near-miss variants that pin the
  # anchors and the exact spelling of `kubernetes`; then an empty value and a
  # following flag swallowed as the value
  local script v
  for script in "$PROTECT" "$PREFLIGHT"; do
    for v in "$RETIRED" True yes 1 Kubernetes kubernetesx xkubernetes k8s opentofu "" --default-branch; do
      run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$script" \
        --static-analysis sonarcloud --vulnerabilities snyk --iac-only "$v"
      [ "$status" -eq 1 ]
      contains "$stderr" "$ENUM_MESSAGE"
    done
  done
}

@test "a refused --iac-only writes no branch-protection rule (#1892)" {
  local calls="$BATS_TEST_TMPDIR/curl-calls"
  : > "$calls"
  printf '#!/bin/sh\necho "$@" >> "%s"\necho 200\n' "$calls" > "$STUB_BIN/curl"
  chmod +x "$STUB_BIN/curl"
  run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --static-analysis sonarcloud --vulnerabilities snyk \
    --has-dockerfile false --has-codeql false --iac-only "$RETIRED" --default-branch main
  [ "$status" -eq 1 ]
  contains "$stderr" "$ENUM_MESSAGE"
  [ ! -s "$calls" ]
}

@test "both scripts refuse a dangling --iac-only with the typed message, not an unbound-variable crash (#1892)" {
  local script
  for script in "$PROTECT" "$PREFLIGHT"; do
    run --separate-stderr env PATH="$STUB_BIN:$PATH" bash "$script" --iac-only
    [ "$status" -eq 1 ]
    contains "$stderr" "$ENUM_MESSAGE"
    lacks "$stderr" 'unbound variable'
  done
}

# ---------------------------------------------------------------------------
# The sweep
# ---------------------------------------------------------------------------

# The swept roster: every tracked file except the dated records under
# docs/superpowers/, one repo-relative path per line. Files deleted in the
# working tree but still in the index are skipped, since there is nothing to read.
swept_files() {
  local f
  git -C "$REPO_ROOT" ls-files | while IFS= read -r f; do
    case "$f" in docs/superpowers/*) continue ;; esac
    if [ -f "$REPO_ROOT/$f" ]; then printf '%s\n' "$f"; fi
  done
}

# One line at a time, plus each line joined to the next: a hit on its own line
# prints as path:line:text; a hit only the join can see — the value wrapped onto
# the next line — prints at the flag's line as path:line:first / second. Binary
# files never reach it: sweep_scan hands it only what `grep -I` calls text. (Not
# an awk `/\000/` test: BSD awk reads that as an EMPTY regex, which matches every
# line, and the sweep then skips every file and passes having read nothing.)
SWEEP_AWK='
  FNR == 1 { prev = "" }
  $0 ~ ENVIRON["SWEEP_RE"] { print FILENAME ":" FNR ":" $0 }
  $0 !~ ENVIRON["SWEEP_RE"] && FNR > 1 && prev !~ ENVIRON["SWEEP_RE"] && (prev " " $0) ~ ENVIRON["SWEEP_RE"] {
    print FILENAME ":" (FNR - 1) ":" prev " / " $0
  }
  { prev = $0 }
'

# Scan the given repo-relative paths under root $1 for the retired spelling.
# Prints every hit. Exit 0 on at least one hit, 1 on none, and 2 when the root
# or any file could not be read — no verdict, never a clean pass.
#
# Decided on OUTPUT and stderr, not on xargs' status: xargs folds a read error
# and an ordinary batch result into the same non-zero status, so the status
# alone cannot tell a clean sweep from one that read nothing.
sweep_scan() {
  local root="$1" hits err
  shift
  err="$BATS_TEST_TMPDIR/sweep-stderr"
  cd "$root" 2>"$err" || { cat "$err" >&2; return 2; }
  # grep -I lists the text files (an empty pattern matches any file with a line),
  # NUL-separated by --null: BSD grep's -Z means decompress, not that. Both
  # stages share one stderr file, so a read error in either is no verdict
  hits="$(printf '%s\0' "$@" | xargs -0 grep -Il --null '' 2>"$err" |
    LC_ALL=C SWEEP_RE="$SWEEP_RE" xargs -0 awk "$SWEEP_AWK" 2>>"$err")" || true
  if [ -s "$err" ]; then
    cat "$err" >&2
    return 2
  fi
  [ -n "$hits" ] || return 1
  printf '%s\n' "$hits"
}

@test "the swept roster is derived from the index and excludes only docs/superpowers (#1892)" {
  local roster
  roster="$(swept_files)"
  # anchored positively first: an enumeration that silently came back empty
  # would make the sweep below pass for having read nothing
  [ "$(printf '%s\n' "$roster" | awk 'NF' | wc -l | tr -d ' ')" -gt 500 ]
  # every class of site the story names is IN the roster
  contains $'\n'"$roster"$'\n' $'\ndevelopment/skills/bootstrap/SKILL.md\n'
  contains $'\n'"$roster"$'\n' $'\ndevelopment/skills/bootstrap/scripts/branch-protection.sh\n'
  contains $'\n'"$roster"$'\n' $'\ndevelopment/skills/bootstrap/templates/common/SETUP.md.tmpl\n'
  contains $'\n'"$roster"$'\n' $'\nARCHITECTURE.md\n'
  contains $'\n'"$roster"$'\n' $'\ndocs/how-to/keep-app-repos-out-of-the-cluster.md\n'
  contains $'\n'"$roster"$'\n' $'\ntests/fixtures/bootstrap-toolchain-golden/row1/common/SETUP.md\n'
  contains $'\n'"$roster"$'\n' $'\ntests/iac-only-enum.bats\n'
  # and nothing under the one excluded tree
  lacks $'\n'"$roster" $'\ndocs/superpowers/'
}

@test "no tracked file outside docs/superpowers spells the retired --iac-only value (#1892)" {
  local -a files=()
  local f
  while IFS= read -r f; do files+=("$f"); done < <(swept_files)
  [ "${#files[@]}" -gt 500 ]
  run sweep_scan "$REPO_ROOT" "${files[@]}"
  # 1 is a clean sweep; 2 would be a read error, which is no verdict
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "NON-VACUITY: the sweep fires on a retired spelling injected into a copy of a swept file (#1892)" {
  # a real swept file, copied to the same relative path under a scratch root,
  # with each shape the sweep must catch appended: the bare flag, the `=` form,
  # the quoted placeholder the bootstrap SKILL.md used, a code span closed and
  # reopened between flag and value, and — the shape ARCHITECTURE.md actually
  # held — a code span wrapped so the value starts the next line
  local rel="development/skills/bootstrap/templates/common/SETUP.md.tmpl"
  local root="$BATS_TEST_TMPDIR/sweep-root" shape
  local -a shapes=(
    "--iac-only ${RETIRED}"
    "--iac-only=${RETIRED}"
    "--iac-only \"<${RETIRED} on the IaC path>\""
    "\`--iac-only\` \`${RETIRED}\`"
    $'emits one job, `gate`, and `--iac-only\n'"${RETIRED}\` requires that one context"
  )
  for shape in "${shapes[@]}"; do
    rm -rf "$root"
    mkdir -p "$root/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$root/$rel"
    # the copy on its own is clean, so a hit below can only be the injected text
    run sweep_scan "$root" "$rel"
    [ "$status" -eq 1 ]
    printf '  branch-protection.sh %s\n' "$shape" >> "$root/$rel"
    run sweep_scan "$root" "$rel"
    [ "$status" -eq 0 ]
    contains "$output" "$rel:"
    # a wrapped hit is reported at the flag's line, so name its first line
    contains "$output" "${shape%%$'\n'*}"
  done
  # and the accepted value is NOT a hit, on one line or wrapped: the pattern
  # keys on the retired value
  cp "$REPO_ROOT/$rel" "$root/$rel"
  printf '  branch-protection.sh --iac-only kubernetes\n  `--iac-only\nkubernetes` requires it\n' >> "$root/$rel"
  run sweep_scan "$root" "$rel"
  [ "$status" -eq 1 ]
}

@test "NON-VACUITY: an unreadable root or file is no verdict, never a clean sweep (#1892)" {
  run sweep_scan "$BATS_TEST_TMPDIR/no-such-root" README.md
  [ "$status" -eq 2 ]
  run sweep_scan "$REPO_ROOT" no/such/file.md
  [ "$status" -eq 2 ]
}
