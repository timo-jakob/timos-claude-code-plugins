# Language gate framework (#2508) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Ship `scripts/gate.zsh`, the language-path gate framework. It provides the verdict, skip, exit and
module contract, plus the five shared stages: hygiene, yaml, secrets, sast and vuln-scan.

**Architecture:** One zsh template, `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`. Its
only placeholder is `{{DEFAULT_BRANCH}}`.

- **Shared stages.** They are registered through the same `gate_register` interface that language and
  conditional modules use. Those modules live in `scripts/gate.d/*.zsh` and are sourced in name order. The
  framework runs the registrations in a fixed stage order and stops at the first red.
- **Failure reporting.** As in the IaC gate (`templates/iac/scripts/k8s-gate.zsh.tmpl`), a failing command ends
  the run through `err_exit`, and an EXIT trap prints the owed `FAILED` line.

**Tech Stack:** zsh 5.9, bats 1.10+ (the repo's `tests/assertions.bash`), git, jq. Stubbed in tests: yamllint,
gitleaks 8.30, semgrep 1.163, trivy and curl.

**Spec:** `docs/superpowers/specs/2026-10-13-language-gate-command-design.md` (§3.3, §3.4, §3.6, §3.7). The issue
is #2508, a child of epic #1608. Read its body: its test cases are the acceptance contract this plan implements.

## Global Constraints

- **Shell.** New scripts are zsh (`#!/usr/bin/env zsh`). Lines stay at or under 120 characters.
- **Template mode.** The template has a shebang, so git must record it as **100755**. Run `chmod +x` before
  `git add`, or `tests/bootstrap-template-modes.bats` reds.
- **Placeholders.** `{{DEFAULT_BRANCH}}` is the only placeholder. `render.zsh` substitutes it, defaulting to
  `main`, with no other flags.
- **Verdict lines are exact strings:**
  - `gate: <stage> ok`
  - `gate: <stage> skipped — <reason>`
  - `gate: <stage> FAILED`
  - `gate: <stage> FAILED — <reason>`

  The dash is U+2014. A module stage is named `<stage> (<label>)`.
- **Exit codes:**
  - 0: green.
  - 1: a stage failed, whatever the failing tool returned.
  - 2: could not run, always before any verdict line.
  - 130 / 143: interrupted or terminated.
- **Local-only skip.** The reason is exactly `local-only (macOS), enforced by pre-push`.
- **Stage order:** `hygiene yaml secrets format lint typecheck test coverage sast vuln-scan contracts policy image
  ops webui`. `--commit` runs only `hygiene yaml secrets format lint`.
- **CI detection.** "CI" means `CI` is exactly `true`.
- **Test isolation.** Tests never put `/usr/bin` on the gate's `PATH` (#1605). `PATH` is the stub directory plus a
  base directory of symlinked core utilities.
- **Fake secrets.** Any fake secret or key header in a test is assembled from split strings with `printf`, so the
  repo's own gitleaks and detect-private-key hooks never see a literal (gitleaks CI version drift).
- **Heredocs.** No `@test` text inside a heredoc (the bats 1.10 phantom-test bug).
- **New files.** `git add` new files before any gate run, because the sweeps enumerate `git ls-files`.
- **Gate.** The whole bats suite runs through `run-gate.zsh`, under `LC_ALL=C`. Report counts as passed/total.

## Review Focus

These are inputs the spec implies but none of the issue's listed test cases exercises. Each is pinned by a test in
the task named.

1. **A file name containing `:` or a space with a hygiene finding.** The finding must name the whole path, not a
   prefix cut at the first colon. Pinned in Task 5.
2. **An `origin/<default>` that shares no history with `HEAD`.** `git merge-base` fails, and secrets must fall back
   to the whole-history scan, not red or skip. Pinned in Task 6.
3. **A module file that does not parse.** The gate must refuse with exit 2 and name the module before any stage,
   never run a partial stage set. Pinned in Task 2.
4. **Ignored paths, such as `node_modules/` and `.venv/`, exist locally but never on a CI checkout.** The vuln-scan
   must skip them, so the local and CI verdicts agree. Pinned in Task 7.
5. **A brand-new repository with an unborn `HEAD` and staged files.** The first `git commit` runs the pre-commit
   hook, and `--commit` must go green there. Pinned in Task 8.

---

## File Structure

| File | Responsibility |
|---|---|
| `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl` (create, 100755) | The whole framework and the five shared stages. One file, in banner-delimited sections. |
| `tests/gate-script.bats` (create) | Every behaviour, over scratch git repos with stubbed scanners. |
| `development/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (modify) | Minor version bump: new installable content. |

The script's sections, top to bottom, are listed below. Each task adds or extends the sections it names, at that
position.

1. header
2. options and globals
3. output
4. registry
5. module helpers
6. arguments
7. shared stages
8. modules
9. selection and preconditions
10. work directory and traps
11. run

---

### Task 1: Harness, rendering, CLI and work-tree preconditions

**Files:**

- Create: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`
- Test: `tests/gate-script.bats`

**Interfaces:**

- Produces, for the tests:
  - the helpers `gate`, `verdicts`, `module`, `stub`, `track_file`, `commit_file`;
  - the variables `W` (the repo under test, also the cwd), `STUBS`, `BASE`, `STUB_LOG` and `GATE_ENV` (extra
    `KEY=value` words for the gate's environment).
- Produces, in the script: `default_branch`, `script_path`, `script_dir`, `commit_mode`, `stage_order` and
  `commit_stages`.

- [ ] **Step 1: Write the harness and the failing tests**

Create `tests/gate-script.bats`:

```bash
#!/usr/bin/env bats
#
# The language-path gate framework (epic #1608, child #2508):
# development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl, rendered
# by render.zsh and run against scratch git repositories.
#
# Every external scanner is STUBBED: yamllint, gitleaks, semgrep, trivy and curl
# are scripts in $STUBS that log their argv to $STUB_LOG and exit with
# STUB_<NAME>_RC (default 0). The gate's PATH is ONLY $STUBS and $BASE, a
# directory of symlinks to the core utilities the script needs — never /usr/bin
# (#1605), so a tool the host happens to have can neither stand in for a stub
# nor mask a missing one. Tool VERDICTS are not this file's business; the
# language and conditional modules' real-tool behaviour is E4's.

bats_require_minimum_version 1.5.0

load assertions

setup_file() {
  local repo_root
  repo_root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  zsh "$repo_root/development/skills/bootstrap/scripts/render.zsh" \
    --templates "$repo_root/development/skills/bootstrap/templates" \
    --out "$BATS_FILE_TMPDIR/rendered" common/scripts/gate.zsh.tmpl >/dev/null
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl"
  GATE_SRC="$BATS_FILE_TMPDIR/rendered/common/scripts/gate.zsh"
  [ -f "$GATE_SRC" ]
  ZSH_BIN="$(command -v zsh)"
  STUBS="$BATS_TEST_TMPDIR/stubs"
  BASE="$BATS_TEST_TMPDIR/base"
  STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  HOME_DIR="$BATS_TEST_TMPDIR/home"
  mkdir -p "$STUBS" "$BASE" "$HOME_DIR"
  : > "$STUB_LOG"
  local u p
  for u in git jq awk sed grep tail head sort tr cat mktemp rm mkdir wc cut find dirname sleep; do
    p="$(command -v "$u")" || { echo "host lacks $u" >&2; return 1; }
    ln -s "$p" "$BASE/$u"
  done
  for u in yamllint gitleaks semgrep trivy curl; do stub "$u"; done
  GATE_ENV=()
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
  W="$BATS_TEST_TMPDIR/repo"
  make_repo "$W"
  cd "$W"
}

# stub <name> — a stand-in that appends "<name> <argv>" to $STUB_LOG, prints
# $STUB_<NAME>_OUT when set, and exits $STUB_<NAME>_RC (default 0)
stub() {
  local name="$1" var
  var="$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')"
  printf '%s\n' "#!$ZSH_BIN" \
    "print -r -- \"$name \$*\" >> \"\$STUB_LOG\"" \
    "if [[ -n \"\${STUB_${var}_OUT:-}\" ]]; then print -r -- \"\${STUB_${var}_OUT}\"; fi" \
    "exit \"\${STUB_${var}_RC:-0}\"" > "$STUBS/$name"
  chmod +x "$STUBS/$name"
}

# make_repo <dir> — a repo with README.md and scripts/gate.zsh, committed and
# pushed to a bare origin, so origin/main exists and HEAD is not ahead of it
make_repo() {
  local dir="$1" origin="$BATS_TEST_TMPDIR/origin.git"
  git init -q -b main "$dir"
  mkdir -p "$dir/scripts"
  cp "$GATE_SRC" "$dir/scripts/gate.zsh"
  printf 'hello\n' > "$dir/README.md"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  git init -q --bare -b main "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main
}

# gate [args…] — run the gate from the cwd with the isolated environment
gate() {
  run env -i HOME="$HOME_DIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$STUBS:$BASE" \
    STUB_LOG="$STUB_LOG" GIT_CONFIG_NOSYSTEM=1 ${GATE_ENV[@]+"${GATE_ENV[@]}"} \
    "$ZSH_BIN" scripts/gate.zsh "$@"
}

# verdicts — the gate's verdict lines from the last run, in order
verdicts() { printf '%s\n' "$output" | grep '^gate: ' || true; }

# module <name> <line>… — write scripts/gate.d/<name>.zsh (untracked, as a
# module a test needs only for its own run)
module() {
  mkdir -p "$W/scripts/gate.d"
  local name="$1"; shift
  printf '%s\n' "$@" > "$W/scripts/gate.d/$name.zsh"
}

# track_file <path> <line> — write one line and `git add` it (not committed)
track_file() {
  mkdir -p "$(dirname "$W/$1")"
  printf '%s\n' "$2" > "$W/$1"
  git -C "$W" add -- "$1"
}

# commit_file <path> <line> — track_file, then commit (never pushed)
commit_file() {
  track_file "$1" "$2"
  git -C "$W" commit -qm "add $1"
}

@test "the template renders with the default branch substituted and parses (#2508)" {
  run grep -c "^default_branch='main'\$" "$GATE_SRC"
  [ "$output" = 1 ]
  run grep -E '\{\{[A-Z_]+\}\}' "$GATE_SRC"
  [ "$status" -eq 1 ]
  run zsh -n "$GATE_SRC"
  [ "$status" -eq 0 ]
  run grep -c "{{DEFAULT_BRANCH}}" "$TEMPLATE"
  [ "$output" = 1 ]
}

@test "--help prints the header and exits 0 (#2508)" {
  gate --help
  [ "$status" -eq 0 ]
  contains "$output" "gate.zsh — this repository's validation gate"
  contains "$output" "MODULE INTERFACE"
  lacks "$output" "emulate -L zsh"
}

@test "an unknown argument is a usage error before any stage (#2508)" {
  gate --bogus
  [ "$status" -eq 2 ]
  contains "$output" "gate: unknown argument: --bogus (see --help)"
  [ -z "$(verdicts)" ]
}

@test "outside a git work tree the gate refuses with exit 2 (#2508)" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/scripts"
  cp "$GATE_SRC" "$BATS_TEST_TMPDIR/plain/scripts/gate.zsh"
  cd "$BATS_TEST_TMPDIR/plain"
  gate
  [ "$status" -eq 2 ]
  contains "$output" "gate: not inside a git work tree — run it from the repository root"
  [ -z "$(verdicts)" ]
}

@test "from a subdirectory the gate refuses with exit 2, naming the root (#2508)" {
  cd "$W/scripts"
  run env -i HOME="$HOME_DIR" TMPDIR="$BATS_TEST_TMPDIR" PATH="$STUBS:$BASE" \
    STUB_LOG="$STUB_LOG" GIT_CONFIG_NOSYSTEM=1 "$ZSH_BIN" gate.zsh
  [ "$status" -eq 2 ]
  contains "$output" "gate: run it from the repository root ("
  [ -z "$(verdicts)" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: all five fail. `setup_file` fails because the template does not exist.

- [ ] **Step 3: Write the template's sections 1, 2, 6 and 9 (the git half)**

Create `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`:

```zsh
#!/usr/bin/env zsh
# gate.zsh — this repository's validation gate.
#
# Emitted by /development:bootstrap on the language paths (epic #1608). It is
# the MECHANISM behind the repository's gate command: `make lint` runs it, the
# version-controlled hooks/pre-push runs the gate command, hooks/pre-commit runs
# `scripts/gate.zsh --commit`, and the CI `gate` job runs the gate command. One
# script, one verdict, everywhere: a check that exists only in CI is the thing
# this file exists to make impossible.
#
# ---------------------------------------------------------------------------
# STAGES, IN ORDER, STOPPING AT THE FIRST FAILURE
# ---------------------------------------------------------------------------
#   hygiene     tracked text files: trailing whitespace, missing final newline,
#               conflict markers, private-key headers; tracked files over
#               1024 KB; invalid JSON (tsconfig*.json / jsconfig*.json are
#               JSONC by TypeScript's definition and are not parsed)
#   yaml        yamllint --strict over tracked *.yml / *.yaml
#   secrets     gitleaks over the commits since the merge-base with
#               origin/<default> (the whole history when there is none); with
#               --commit, over the staged changes
#   format, lint, typecheck, test, coverage
#               registered by the language modules in scripts/gate.d/
#   sast        semgrep scan --config=auto --error
#   vuln-scan   trivy fs: vuln, secret, misconfig and license; HIGH/CRITICAL
#   contracts, policy, image, ops, webui
#               registered by the conditional modules in scripts/gate.d/
#
# A stage nothing registers does not run and prints nothing: the script names
# exactly the stages this repository has.
#
# ---------------------------------------------------------------------------
# WHAT IT PRINTS
# ---------------------------------------------------------------------------
#   gate: <stage> ok
#   gate: <stage> skipped — <reason>
#   gate: <stage> FAILED
#   gate: <stage> FAILED — <reason>
#
# A module's stage is named `<stage> (<label>)`, e.g. `format (python)`. The
# failing stage's own output sits above its FAILED line. Diagnostics print as
# `error: …` / `warning: …`, or as workflow commands (`::error::…`) when
# GITHUB_ACTIONS is set. Skips are reported, never silent, in three classes:
#   not applicable  the stage's subject is absent: a skip everywhere
#   unavailable     the stage applies but this machine cannot run it: a skip
#                   locally, FAILED when CI=true
#   local-only      registered --local-only: runs locally; when CI=true it is
#                   `skipped — local-only (macOS), enforced by pre-push`
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0        every stage ok or skipped
#   1        a stage FAILED (its verdict line names which), whatever status
#            the failing tool itself returned
#   2        the gate could not run: a missing tool (every one named, with its
#            install hint), a bad invocation, not the root of a git work tree,
#            or a module that does not load or register cleanly. Always before
#            any stage runs: the gate never degrades to the stages it can run
#   130/143  interrupted / terminated; the running stage still gets its line
#
# ---------------------------------------------------------------------------
# HOW TO RUN IT
# ---------------------------------------------------------------------------
#   zsh scripts/gate.zsh            every stage, from the repository root
#   zsh scripts/gate.zsh --commit   hygiene, yaml, secrets, format, lint only
#
# Environment: CI=true selects the CI behaviour of the skip classes above.
#
# ---------------------------------------------------------------------------
# MODULE INTERFACE (scripts/gate.d/*.zsh, sourced in name order)
# ---------------------------------------------------------------------------
#   gate_register [--local-only] <stage> <label> <function> [tool[=hint]]…
#       run <function> as `<stage> (<label>)`; every tool must be on PATH
#       before any stage runs (the hint defaults to `brew install <tool>`)
#   gate_skip <reason>            not applicable; `return` right after
#   gate_unavailable <what>       unavailable; `return` right after
#   gate_fail <message> [reason]  red, with <message> above the verdict line
#   gate_ci                       true when CI=true
#   gate_merge_base               prints the merge-base of HEAD and
#                                 origin/<default>; non-zero when there is none
#   gate_online <url>             true when <url> answers at all
#   gate_tracked <pathspec>…      sets $reply to the tracked files matching
#   GATE_TMP                      a scratch directory, removed on exit
#
# A stage function is called for its effect, never as a condition: a failing
# command inside it ends the run (err_exit) and the EXIT trap prints the
# FAILED line. Never call a stage body from an `if`, `!`, `&&` or `||`.

emulate -L zsh
setopt err_exit nounset pipefail null_glob

# ---------------------------------------------------------------------------
# options and globals
# ---------------------------------------------------------------------------
default_branch='{{DEFAULT_BRANCH}}'
# captured at top level: inside a function zsh's $0 is the FUNCTION's name
script_path="$0"
script_dir="${0:A:h}"
commit_mode=0
typeset -a stage_order=(hygiene yaml secrets format lint typecheck test coverage sast vuln-scan
  contracts policy image ops webui)
typeset -a commit_stages=(hygiene yaml secrets format lint)

# ---------------------------------------------------------------------------
# arguments
# ---------------------------------------------------------------------------
usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$script_path" }

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --commit) commit_mode=1; shift ;;
    *) print -u2 -- "gate: unknown argument: $1 (see --help)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# selection and preconditions
# ---------------------------------------------------------------------------
local toplevel
if ! toplevel="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  print -u2 -- "gate: not inside a git work tree — run it from the repository root"
  exit 2
fi
if [[ "${PWD:A}" != "${toplevel:A}" ]]; then
  print -u2 -- "gate: run it from the repository root (${toplevel})"
  exit 2
fi
```

Then make it executable: `chmod +x development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`.

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `5/5 passed`. If the subdirectory test fails because `git` misbehaves under the restricted `PATH` (on
macOS, `/usr/bin/git` is an xcrun shim), point `$BASE/git` at the real binary
(`$(xcrun --find git 2>/dev/null || command -v git)`) in `setup`, and say so in a comment there.

- [ ] **Step 5: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh skeleton — CLI and work-tree preconditions (#2508)"
```

---

### Task 2: Registry, run loop, verdicts and the EXIT trap

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`. This adds sections 3, 4, 8, 10
  and 11, and the selection half of section 9.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Consumes: from Task 1, `stage_order`, `commit_stages`, `commit_mode` and `script_dir`.
- Produces: the shared helpers below. Later tasks and child modules rely on these exact names.
  - `annotate <level> <msg…>`
  - `stage_begin <name>`
  - `stage_ok`
  - `gate_skip <reason>`
  - `gate_fail <message> [reason]`
  - `gate_register [--local-only] <stage> <label> <fn> [tool[=hint]]…`
  - `GATE_TMP`
  - the parallel arrays `reg_stage`, `reg_label`, `reg_fn`, `reg_local` and `reg_tools`
  - `selected`: the registry indexes to run, in run order

- [ ] **Step 1: Write the failing tests** (append to `tests/gate-script.bats`)

```bash
# demo_verdicts — only the verdict lines of the test modules' `(demo…)` stages
demo_verdicts() { verdicts | grep '(demo' || true; }

@test "a module stage runs at its stage's position, named <stage> (<label>) (#2508)" {
  module demo \
    'gate_register test demo demo_test' \
    'gate_register format demo demo_format' \
    'demo_test() { : }' \
    'demo_format() { : }'
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = "$(printf '%s\n' 'gate: format (demo) ok' 'gate: test (demo) ok')" ]
}

@test "two modules registering one stage run in module file-name order (#2508)" {
  module b-second 'gate_register lint demo-b demo_b' 'demo_b() { : }'
  module a-first 'gate_register lint demo-a demo_a' 'demo_a() { : }'
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = "$(printf '%s\n' 'gate: lint (demo-a) ok' 'gate: lint (demo-b) ok')" ]
}

@test "the first red stops the run with exit 1, and it is the last verdict line (#2508)" {
  module demo \
    'gate_register format demo demo_format' \
    'gate_register lint demo demo_lint' \
    'demo_format() { false }' \
    'demo_lint() { : }'
  gate
  [ "$status" -eq 1 ]
  [ "$(verdicts | tail -n 1)" = 'gate: format (demo) FAILED' ]
  lacks "$output" 'lint (demo)'
}

@test "a failing tool's own status is normalised to exit 1 (#2508)" {
  local rc
  for rc in 'return 7' 'exit 2' 'exit 127'; do
    module demo 'gate_register format demo demo_format' "demo_format() { $rc }"
    gate
    [ "$status" -eq 1 ]
    [ "$(verdicts | tail -n 1)" = 'gate: format (demo) FAILED' ]
  done
}

@test "gate_fail prints its message above a FAILED line carrying the reason (#2508)" {
  module demo 'gate_register format demo demo_format' "demo_format() { gate_fail 'boom happened' 'boom' }"
  gate
  [ "$status" -eq 1 ]
  [ "$(verdicts | tail -n 1)" = 'gate: format (demo) FAILED — boom' ]
  [ "$(printf '%s\n' "$output" | grep -n '^error: boom happened$' | cut -d: -f1)" -lt \
    "$(printf '%s\n' "$output" | grep -n 'FAILED — boom' | cut -d: -f1)" ]
  GATE_ENV=(GITHUB_ACTIONS=true)
  gate
  contains "$output" '::error::boom happened'
}

@test "gate_skip reports a not-applicable skip and the run stays green (#2508)" {
  module demo 'gate_register typecheck demo demo_tc' "demo_tc() { gate_skip 'compiler-checked'; return 0 }"
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = 'gate: typecheck (demo) skipped — compiler-checked' ]
}

@test "registration errors and an unloadable module refuse with exit 2 before any stage (#2508)" {
  module demo 'gate_register bogus demo demo_fn' 'demo_fn() { : }'
  gate
  [ "$status" -eq 2 ]
  contains "$output" "gate: gate_register: unknown stage 'bogus'"
  [ -z "$(verdicts)" ]

  module demo 'gate_register format demo'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'gate: gate_register needs <stage> <label> <function>'
  [ -z "$(verdicts)" ]

  module demo 'gate_register format demo demo_missing_fn'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'gate: format (demo) registers demo_missing_fn, which is not defined'
  [ -z "$(verdicts)" ]

  module demo 'demo_fn() {' 'gate_register format demo demo_fn'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'gate: could not load module scripts/gate.d/demo.zsh'
  [ -z "$(verdicts)" ]
}

@test "an interrupt keeps its status and still names the running stage (#2508)" {
  module demo 'gate_register format demo demo_format' 'demo_format() { kill -INT $$; sleep 5 }'
  gate
  [ "$status" -eq 130 ]
  [ "$(verdicts | tail -n 1)" = 'gate: format (demo) FAILED' ]
  module demo 'gate_register format demo demo_format' 'demo_format() { kill -TERM $$; sleep 5 }'
  gate
  [ "$status" -eq 143 ]
  [ "$(verdicts | tail -n 1)" = 'gate: format (demo) FAILED' ]
}

@test "GATE_TMP exists during a stage and is removed after a green and a red run (#2508)" {
  module demo 'gate_register format demo demo_format' \
    "demo_format() { [[ -d \"\$GATE_TMP\" ]]; print -r -- \"\$GATE_TMP\" > '$BATS_TEST_TMPDIR/tmp-path' }"
  gate
  [ "$status" -eq 0 ]
  [ ! -e "$(cat "$BATS_TEST_TMPDIR/tmp-path")" ]
  module demo 'gate_register format demo demo_format' \
    "demo_format() { print -r -- \"\$GATE_TMP\" > '$BATS_TEST_TMPDIR/tmp-path'; false }"
  gate
  [ "$status" -eq 1 ]
  [ ! -e "$(cat "$BATS_TEST_TMPDIR/tmp-path")" ]
}
```

- [ ] **Step 2: Run the tests and confirm the new ones fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: the 9 new tests fail, because `gate_register` is not defined yet. The 5 from Task 1 still pass.

- [ ] **Step 3: Add sections 3 and 4 after section 2 ("options and globals")**

```zsh
# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------
# The stage whose verdict line is still owed. Set at each stage's start and
# cleared by its verdict; the EXIT trap turns any non-zero exit while it is set
# into that stage's FAILED line, so failures need no per-command bookkeeping.
current_stage=""
fail_reason=""
verdict_done=0

annotate() {
  # `annotate <level> <message…>` — level is error, warning or notice
  local level="$1"; shift
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    print -r -- "::${level}::$*"
  else
    print -r -- "${level}: $*"
  fi
}
stage_begin() { current_stage="$1"; fail_reason=""; verdict_done=0 }
stage_ok()    { print -r -- "gate: ${current_stage} ok"; current_stage=""; verdict_done=1 }
gate_skip()   { print -r -- "gate: ${current_stage} skipped — $1"; current_stage=""; verdict_done=1 }
# the message on its own line, then the verdict via the trap — so the message
# always sits above the FAILED line
gate_fail()   { fail_reason="${2:-}"; annotate error "$1"; exit 1 }

# ---------------------------------------------------------------------------
# registry
# ---------------------------------------------------------------------------
# Parallel arrays, one entry per registration, in registration order. Tools are
# newline-joined `name` or `name=install hint` words.
typeset -a reg_stage=() reg_label=() reg_fn=() reg_local=() reg_tools=()

gate_register() {
  local local_only=0
  if [[ "${1:-}" == --local-only ]]; then local_only=1; shift; fi
  if (( $# < 3 )); then
    print -u2 -- "gate: gate_register needs <stage> <label> <function> [tool[=hint]]…"
    exit 2
  fi
  if (( ! ${stage_order[(Ie)$1]} )); then
    print -u2 -- "gate: gate_register: unknown stage '$1' (one of: ${stage_order[*]})"
    exit 2
  fi
  local -a tools=("${@[4,-1]}")
  reg_stage+=("$1"); reg_label+=("$2"); reg_fn+=("$3"); reg_local+=("$local_only")
  reg_tools+=("${(pj:\n:)tools}")
}
```

- [ ] **Step 4: Add section 8 between section 6 ("arguments") and section 9**

```zsh
# ---------------------------------------------------------------------------
# modules
# ---------------------------------------------------------------------------
# Name order, so a module's stages run in a stable order. A module that does not
# load is refused before any stage: running the stages that did load would be a
# green over a gate that validated less than it claims.
local module
for module in "$script_dir"/gate.d/*.zsh; do
  if ! source "$module"; then
    print -u2 -- "gate: could not load module scripts/gate.d/${module:t}"
    exit 2
  fi
done
```

- [ ] **Step 5: At the top of section 9, before the git checks, add the selection and the function check**

```zsh
# the registry indexes to run, in stage order, then registration order
typeset -a selected=()
local s i
for s in "${stage_order[@]}"; do
  if (( commit_mode )) && (( ! ${commit_stages[(Ie)$s]} )); then continue; fi
  for (( i = 1; i <= ${#reg_stage}; i++ )); do
    if [[ "${reg_stage[i]}" == "$s" ]]; then selected+=("$i"); fi
  done
done

for i in "${selected[@]}"; do
  if (( ! ${+functions[${reg_fn[i]}]} )); then
    print -u2 -- "gate: ${reg_stage[i]} (${reg_label[i]}) registers ${reg_fn[i]}, which is not defined"
    exit 2
  fi
done
```

- [ ] **Step 6: Append sections 10 and 11 at the end of the file**

```zsh
# ---------------------------------------------------------------------------
# work directory and traps
# ---------------------------------------------------------------------------
GATE_TMP="${$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX"):A}"
cleanup() {
  local rc=$?
  rm -rf "$GATE_TMP"
  if (( rc != 0 )) && [[ -n "$current_stage" ]]; then
    if [[ -n "$fail_reason" ]]; then
      print -r -- "gate: ${current_stage} FAILED — ${fail_reason}"
    else
      print -r -- "gate: ${current_stage} FAILED"
    fi
    # NORMALISE to the documented 1: err_exit ends the run with the failing
    # tool's own status, and a tool exiting 2 would read as "the gate could not
    # run". A signal keeps its status, per the two traps below.
    if (( rc != 130 && rc != 143 )); then exit 1; fi
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
run_entry() {
  local i="$1" name="${reg_stage[$1]}"
  if [[ -n "${reg_label[i]}" ]]; then name+=" (${reg_label[i]})"; fi
  stage_begin "$name"
  "${reg_fn[i]}"
  if (( ! verdict_done )); then stage_ok; fi
}
for i in "${selected[@]}"; do run_entry "$i"; done
```

- [ ] **Step 7: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `14/14 passed`. If the unloadable-module case exits 1 rather than 2, zsh has aborted on the parse error
before the `if` could catch it. In that case, parse-check the module first, inside the loop:
`if ! zsh -n "$module" 2>/dev/null || ! source "$module"; then`. Keep the same message.

- [ ] **Step 8: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh registry, run loop and verdict trap (#2508)"
```

---

### Task 3: The unavailable and local-only skip classes

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`, sections 3 and 11.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Consumes: from Task 2, `gate_skip`, `gate_fail` and `run_entry`.
- Produces: `gate_ci` and `gate_unavailable <what>`. The local-only branch in `run_entry` reads `reg_local`.

- [ ] **Step 1: Write the failing tests**

```bash
@test "unavailable: a skip locally, a FAILED naming the cause when CI=true (#2508)" {
  module demo 'gate_register image demo demo_image' 'demo_image() { gate_unavailable docker; return 0 }'
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = 'gate: image (demo) skipped — docker unavailable' ]
  GATE_ENV=(CI=true)
  gate
  [ "$status" -eq 1 ]
  [ "$(verdicts | tail -n 1)" = 'gate: image (demo) FAILED — docker unavailable in CI' ]
  contains "$output" 'error: docker is unavailable on this CI runner'
}

@test "only CI=true is CI: CI=false and CI=1 take the local branch (#2508)" {
  module demo 'gate_register image demo demo_image' 'demo_image() { gate_unavailable docker; return 0 }'
  local v
  for v in false 1; do
    GATE_ENV=("CI=$v")
    gate
    [ "$status" -eq 0 ]
    [ "$(demo_verdicts)" = 'gate: image (demo) skipped — docker unavailable' ]
  done
}

@test "local-only: runs locally, skipped with the pre-push reason when CI=true (#2508)" {
  module demo 'gate_register --local-only test demo demo_test' \
    "demo_test() { print ran > '$BATS_TEST_TMPDIR/ran' }"
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = 'gate: test (demo) ok' ]
  [ -f "$BATS_TEST_TMPDIR/ran" ]
  rm "$BATS_TEST_TMPDIR/ran"
  GATE_ENV=(CI=true)
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = 'gate: test (demo) skipped — local-only (macOS), enforced by pre-push' ]
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: 3 new failures: `gate_unavailable` is undefined, and the local-only stage runs in CI.

- [ ] **Step 3: Add to section 3, after `gate_fail`**

```zsh
gate_ci()     { [[ "${CI:-}" == true ]] }
# A CI run never skips an applicable stage: a misconfigured runner would
# otherwise skip the check and still report a green gate.
gate_unavailable() {
  if gate_ci; then
    gate_fail "$1 is unavailable on this CI runner — a CI run never skips an applicable stage" \
      "$1 unavailable in CI"
  fi
  gate_skip "$1 unavailable"
}
```

- [ ] **Step 4: In `run_entry` (section 11), add the local-only branch between `stage_begin` and the call**

```zsh
  if (( reg_local[i] )) && gate_ci; then
    gate_skip 'local-only (macOS), enforced by pre-push'
    return 0
  fi
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `17/17 passed`.

- [ ] **Step 6: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh unavailable and local-only skip classes (#2508)"
```

---

### Task 4: The missing-tool refusal

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`, section 9.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Consumes: `selected`, `reg_tools` and `reg_local` from Task 2, and `gate_ci` from Task 3.
- Produces: the refusal line format `gate: required tool not on PATH: <tool> — install it with: <hint>`. The
  conditional-modules and preflight children quote this line.

- [ ] **Step 1: Write the failing tests**

```bash
@test "a missing module tool exits 2 before any stage, naming it and its default hint (#2508)" {
  module demo 'gate_register format demo demo_format demo-fmt' 'demo_format() { : }'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'gate: required tool not on PATH: demo-fmt — install it with: brew install demo-fmt'
  [ -z "$(verdicts)" ]
}

@test "a tool=hint registration prints its own hint (#2508)" {
  module demo 'gate_register format demo demo_format "demo-fmt=pipx install demo-fmt==1.2.3"' 'demo_format() { : }'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'demo-fmt — install it with: pipx install demo-fmt==1.2.3'
}

@test "every missing tool is named in one run, each once (#2508)" {
  module demo \
    'gate_register format demo demo_format t-one t-two' \
    'gate_register lint demo demo_lint t-one' \
    'demo_format() { : }' 'demo_lint() { : }'
  gate
  [ "$status" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c 'not on PATH: t-one ')" = 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'not on PATH: t-two ')" = 1 ]
}

@test "a present tool is not reported, and the run proceeds (#2508)" {
  stub demo-fmt
  module demo 'gate_register format demo demo_format demo-fmt' 'demo_format() { demo-fmt --check }'
  gate
  [ "$status" -eq 0 ]
  contains "$(cat "$STUB_LOG")" 'demo-fmt --check'
}

@test "CI=true does not demand a local-only stage's tools; a local run does (#2508)" {
  module demo 'gate_register --local-only test demo demo_test swiftlint' 'demo_test() { swiftlint }'
  GATE_ENV=(CI=true)
  gate
  [ "$status" -eq 0 ]
  [ "$(demo_verdicts)" = 'gate: test (demo) skipped — local-only (macOS), enforced by pre-push' ]
  GATE_ENV=()
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'required tool not on PATH: swiftlint'
}

@test "--commit does not demand the tools of stages it does not run (#2508)" {
  module demo 'gate_register image demo demo_image docker-x' 'demo_image() { docker-x }'
  gate --commit
  [ "$status" -eq 0 ]
  lacks "$output" 'docker-x'
  gate
  [ "$status" -eq 2 ]
  contains "$output" 'required tool not on PATH: docker-x'
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: the four exit-2 assertions fail, with the run reaching the stage and dying with 127.

- [ ] **Step 3: In section 9, insert between the function check and the git checks**

```zsh
# Every tool, BEFORE any stage runs: never degrade to the stages that can run.
# A local-only stage's tools are not demanded on CI, which never runs it.
local -a missing=()
local t tool hint
for i in "${selected[@]}"; do
  if (( reg_local[i] )) && gate_ci; then continue; fi
  for t in ${(f)reg_tools[i]}; do
    tool="${t%%=*}"
    if [[ "$t" == *=* ]]; then hint="${t#*=}"; else hint="brew install $tool"; fi
    if ! command -v "$tool" >/dev/null 2>&1 && (( ! ${missing[(I)${tool}=*]} )); then
      missing+=("${tool}=${hint}")
    fi
  done
done
if (( ${#missing} > 0 )); then
  local m
  for m in "${missing[@]}"; do
    print -u2 -- "gate: required tool not on PATH: ${m%%=*} — install it with: ${m#*=}"
  done
  exit 2
fi
```

- [ ] **Step 4: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `23/23 passed`.

- [ ] **Step 5: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh refuses missing tools before any stage (#2508)"
```

---

### Task 5: The hygiene stage

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`. This adds sections 5 and 7.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Produces:
  - `gate_tracked <pathspec>…`, which sets `$reply` (tracked paths, NUL-safe).
  - `stage_hygiene`, registered as `gate_register hygiene "" stage_hygiene git jq`.
  - A stage with an empty label prints as its bare name (`gate: hygiene ok`).

- [ ] **Step 1: Write the failing tests**

```bash
# last_verdict — the final verdict line of the last run
last_verdict() { verdicts | tail -n 1; }

@test "hygiene: a clean repo passes, and hygiene is the first stage (#2508)" {
  gate
  [ "$status" -eq 0 ]
  [ "$(verdicts | head -n 1)" = 'gate: hygiene ok' ]
}

@test "hygiene: each finding class reds the stage, naming file and line, and stops the run (#2508)" {
  printf 'a \n' > ws.txt
  printf 'x' > nofinal.txt
  printf 'ok\n<<<<<<< HEAD\n' > conflict.txt
  printf '%s%s\n' '-----BEGIN OPENSSH PRIV' 'ATE KEY-----' > id.txt
  printf '{\n' > bad.json
  head -c 1048577 /dev/zero > big.bin
  git add ws.txt nofinal.txt conflict.txt id.txt bad.json big.bin
  gate
  [ "$status" -eq 1 ]
  contains "$output" 'error: ws.txt:1: trailing whitespace'
  contains "$output" 'error: nofinal.txt: no newline at end of file'
  contains "$output" 'error: conflict.txt:2: conflict marker'
  contains "$output" 'error: id.txt:1: private key'
  contains "$output" 'error: bad.json: invalid JSON'
  contains "$output" 'error: big.bin: larger than 1024 KB (1048577 bytes)'
  [ "$(last_verdict)" = 'gate: hygiene FAILED' ]
  [ "$(verdicts | wc -l | tr -d ' ')" = 1 ]
}

@test "hygiene: each class alone is enough to red it (#2508)" {
  local f
  for f in ws nofinal conflict key json big; do
    git -C "$W" reset -q --hard && git -C "$W" clean -qfd
    case "$f" in
      ws)       printf 'a\t\n' > f.txt ;;
      nofinal)  printf 'x' > f.txt ;;
      conflict) printf '>>>>>>> branch\n' > f.txt ;;
      key)      printf '%s%s\n' '-----BEGIN PRIV' 'ATE KEY-----' > f.txt ;;
      json)     printf '{"a":}\n' > f.json ;;
      big)      head -c 1048577 /dev/zero > f.txt ;;
    esac
    git add -A
    gate
    [ "$status" -eq 1 ]
    [ "$(last_verdict)" = 'gate: hygiene FAILED' ]
  done
}

@test "hygiene: the near misses are not findings (#2508)" {
  printf 'Title\n=======\n' > setext.md
  printf '%s\n' '// TypeScript allows comments' '{}' > tsconfig.json
  mkdir -p web && printf '%s\n' '// so does this' '{}' > web/tsconfig.app.json
  printf '{"a": 1}\n' > good.json
  head -c 1048576 /dev/zero > exactly-1mb.bin
  : > empty.txt
  git add -A
  gate
  [ "$status" -eq 0 ]
  [ "$(verdicts | head -n 1)" = 'gate: hygiene ok' ]
}

@test "hygiene: only TRACKED files are checked (#2508)" {
  printf 'untracked \n' > loose.txt
  gate
  [ "$status" -eq 0 ]
}

@test "hygiene: a path with a colon and a space is named whole (#2508)" {
  printf 'x \n' > 'a:b notes.txt'
  git add -A
  gate
  [ "$status" -eq 1 ]
  contains "$output" 'error: a:b notes.txt:1: trailing whitespace'
}

@test "hygiene: findings are workflow commands under GitHub Actions (#2508)" {
  printf 'a \n' > ws.txt
  git add ws.txt
  GATE_ENV=(GITHUB_ACTIONS=true)
  gate
  [ "$status" -eq 1 ]
  contains "$output" '::error::ws.txt:1: trailing whitespace'
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: the 7 new tests fail, because no hygiene stage is registered.

- [ ] **Step 3: Add section 5 after section 4 ("registry")**

```zsh
# ---------------------------------------------------------------------------
# module helpers
# ---------------------------------------------------------------------------
# tracked paths only: a CI checkout holds nothing else, so checking an untracked
# file locally would make the two verdicts disagree
gate_tracked() { reply=( ${(0)"$(git ls-files -z -- "$@")"} ) }
```

- [ ] **Step 4: Add section 7 after section 6 ("arguments")**

```zsh
# ---------------------------------------------------------------------------
# shared stages
# ---------------------------------------------------------------------------
# `hygiene_grep <finding> <git grep args…>` — appends "<file>:<line>: <finding>"
# to the caller's `findings` per match. -z ends the FILE NAME with a NUL, so a
# path holding `:` is still named whole.
hygiene_grep() {
  local what="$1" out rc=0 line file rest
  shift
  out="$(git grep -I -n -z "$@")" || rc=$?
  # 1 is "no match"; anything above is git failing, which is no verdict
  if (( rc > 1 )); then gate_fail "git grep failed (exit ${rc}) while checking for ${what}"; fi
  for line in ${(f)out}; do
    file="${line%%$'\0'*}"
    rest="${line#*$'\0'}"
    findings+=("${file}:${rest%%:*}: ${what}")
  done
}

stage_hygiene() {
  local -a findings=() size
  local f out rc=0
  hygiene_grep 'trailing whitespace' -E -e '[[:blank:]]+$'
  # `=======` alone is a Markdown setext underline, so only the two
  # unambiguous markers count
  hygiene_grep 'conflict marker' -E -e '^(<<<<<<<|>>>>>>>)( |$)'
  hygiene_grep 'private key' -E -e 'BEGIN ([A-Z0-9]+ )*PRIVATE KEY'
  # every non-empty tracked text file ends in a newline
  out="$(git grep -I -l -z -e '')" || rc=$?
  if (( rc > 1 )); then gate_fail "git grep failed (exit ${rc}) while listing text files"; fi
  for f in ${(0)out}; do
    if [[ -n "$(tail -c 1 "./$f")" ]]; then findings+=("${f}: no newline at end of file"); fi
  done
  zmodload -F zsh/stat b:zstat
  gate_tracked .
  for f in "${reply[@]}"; do
    if [[ ! -f "$f" || -L "$f" ]]; then continue; fi
    # "./" so a path beginning with "-" is never read as an option
    zstat -A size +size "./$f"
    if (( size[1] > 1048576 )); then findings+=("${f}: larger than 1024 KB (${size[1]} bytes)"); fi
  done
  # tsconfig/jsconfig are JSONC by TypeScript's definition: comments are legal
  gate_tracked '*.json' ':(exclude,glob)**/tsconfig*.json' ':(exclude,glob)**/jsconfig*.json'
  for f in "${reply[@]}"; do
    if [[ -f "$f" ]] && ! jq empty "./$f" >/dev/null 2>&1; then findings+=("${f}: invalid JSON"); fi
  done
  if (( ${#findings} > 0 )); then
    for f in "${findings[@]}"; do annotate error "$f"; done
    gate_fail "hygiene: ${#findings} finding(s) above"
  fi
}

gate_register hygiene "" stage_hygiene git jq
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `30/30 passed`.

If the colon test fails, `git grep -z -n` may also be ending the LINE NUMBER with a NUL rather than `:`, which
some git versions do. Check `git grep -z -n x | od -c | head`, then take `rest%%$'\0'*` in place of `rest%%:*`.

The Task 2 tests still pass, because the demo modules' stages are filtered by `demo_verdicts`.

- [ ] **Step 6: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh hygiene stage (#2508)"
```

---

### Task 6: The yaml and secrets stages

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`, sections 5 and 7.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Produces:
  - `gate_merge_base`. It prints a sha, and returns non-zero when `refs/remotes/origin/<default>` is absent or
    shares no history. Call it only as a condition: `if base="$(gate_merge_base)"; then`.
  - `stage_yaml` and `stage_secrets`, registered with the tools `yamllint` and `gitleaks git`.

- [ ] **Step 1: Write the failing tests**

```bash
@test "yaml: no tracked YAML is a not-applicable skip, and yamllint is not run (#2508)" {
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: yaml skipped — no YAML files'
  lacks "$(cat "$STUB_LOG")" 'yamllint'
}

@test "yaml: yamllint --strict runs on exactly the tracked YAML files (#2508)" {
  track_file a.yml 'a: 1'
  track_file sub/b.yaml 'b: 2'
  printf 'c: 3\n' > loose.yml
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: yaml ok'
  contains "$(cat "$STUB_LOG")" 'yamllint --strict -- a.yml sub/b.yaml'
  lacks "$(cat "$STUB_LOG")" 'loose.yml'
}

@test "yaml: a yamllint failure reds the stage and stops the run (#2508)" {
  track_file a.yml 'a: 1'
  GATE_ENV=(STUB_YAMLLINT_RC=1)
  gate
  [ "$status" -eq 1 ]
  [ "$(last_verdict)" = 'gate: yaml FAILED' ]
}

@test "secrets: no commits ahead of origin/main is a skip, and gitleaks is not run (#2508)" {
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: secrets skipped — no commits ahead of origin/main'
  lacks "$(cat "$STUB_LOG")" 'gitleaks'
}

@test "secrets: commits ahead are scanned from the merge-base (#2508)" {
  local base
  base="$(git -C "$W" rev-parse origin/main)"
  commit_file feature.txt 'new'
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: secrets ok'
  contains "$(cat "$STUB_LOG")" "gitleaks git --no-banner --redact --log-opts=${base}..HEAD ."
}

@test "secrets: without origin/<default>, or with no shared history, the whole history is scanned (#2508)" {
  git -C "$W" remote remove origin
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: secrets ok'
  contains "$(cat "$STUB_LOG")" 'gitleaks git --no-banner --redact .'
  : > "$STUB_LOG"
  # an origin/main sharing no history with HEAD: merge-base fails
  git -C "$W" checkout -q --orphan other
  git -C "$W" commit -qm unrelated
  git -C "$W" update-ref refs/remotes/origin/main other
  git -C "$W" checkout -q main
  gate
  [ "$status" -eq 0 ]
  contains "$(cat "$STUB_LOG")" 'gitleaks git --no-banner --redact .'
}

@test "secrets: a gitleaks finding reds the stage (#2508)" {
  commit_file feature.txt 'new'
  GATE_ENV=(STUB_GITLEAKS_RC=1)
  gate
  [ "$status" -eq 1 ]
  [ "$(last_verdict)" = 'gate: secrets FAILED' ]
}

@test "secrets: --commit scans the staged changes (#2508)" {
  track_file staged.txt 'x'
  gate --commit
  [ "$status" -eq 0 ]
  contains "$(cat "$STUB_LOG")" 'gitleaks git --pre-commit --staged --no-banner --redact .'
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: 8 new failures, because no yaml or secrets stage is registered.

- [ ] **Step 3: Add to section 5**

```zsh
# the merge-base of HEAD and origin/<default>; non-zero when that ref is absent
# or shares no history with HEAD. Call it only as a condition.
gate_merge_base() {
  if ! git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}" >/dev/null; then
    return 1
  fi
  git merge-base HEAD "refs/remotes/origin/${default_branch}" 2>/dev/null
}
```

- [ ] **Step 4: Add to section 7, after the hygiene registration**

```zsh
stage_yaml() {
  gate_tracked '*.yml' '*.yaml'
  local -a files=("${reply[@]}")
  if (( ${#files} == 0 )); then gate_skip 'no YAML files'; return 0; fi
  yamllint --strict -- "${files[@]}"
}
gate_register yaml "" stage_yaml yamllint

# The commits this push or PR adds — exactly what reaches the remote. With no
# usable merge-base (a first push, an unrelated origin) every commit is new, so
# the whole history is scanned rather than nothing.
stage_secrets() {
  if (( commit_mode )); then
    gitleaks git --pre-commit --staged --no-banner --redact .
    return 0
  fi
  local base count
  if base="$(gate_merge_base)"; then
    count="$(git rev-list --count "${base}..HEAD")"
    if (( count == 0 )); then
      gate_skip "no commits ahead of origin/${default_branch}"
      return 0
    fi
    gitleaks git --no-banner --redact "--log-opts=${base}..HEAD" .
  else
    gitleaks git --no-banner --redact .
  fi
}
gate_register secrets "" stage_secrets gitleaks git
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `38/38 passed`.

- [ ] **Step 6: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh yaml and secrets stages (#2508)"
```

---

### Task 7: The sast and vuln-scan stages, and the shared toolchain

**Files:**

- Modify: `development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl`, sections 5 and 7.
- Test: `tests/gate-script.bats`

**Interfaces:**

- Produces: `gate_online <url>`, which is true when the URL answers with any HTTP status. It also produces
  `stage_sast` and `stage_vuln_scan`.
- After this task the shared tool set is git, jq, yamllint, gitleaks, semgrep, trivy and curl. The preflight child
  installs exactly these.

- [ ] **Step 1: Write the failing tests**

```bash
@test "a clean repo runs the five shared stages in order, green (#2508)" {
  gate
  [ "$status" -eq 0 ]
  [ "$(verdicts)" = "$(printf '%s\n' 'gate: hygiene ok' 'gate: yaml skipped — no YAML files' \
    'gate: secrets skipped — no commits ahead of origin/main' 'gate: sast ok' 'gate: vuln-scan ok')" ]
}

@test "sast: semgrep runs with the auto config and --error, after an online probe (#2508)" {
  gate
  contains "$(cat "$STUB_LOG")" 'curl -sS --max-time 5 -o /dev/null https://semgrep.dev'
  contains "$(cat "$STUB_LOG")" 'semgrep scan --config=auto --error --quiet'
  GATE_ENV=(STUB_SEMGREP_RC=1)
  gate
  [ "$status" -eq 1 ]
  [ "$(last_verdict)" = 'gate: sast FAILED' ]
  lacks "$output" 'vuln-scan'
}

@test "offline: sast and vuln-scan skip locally, without running their tools (#2508)" {
  GATE_ENV=(STUB_CURL_RC=6)
  gate
  [ "$status" -eq 0 ]
  contains "$(verdicts)" 'gate: sast skipped — network unavailable'
  contains "$(verdicts)" 'gate: vuln-scan skipped — network unavailable'
  lacks "$(cat "$STUB_LOG")" 'semgrep'
  lacks "$(cat "$STUB_LOG")" 'trivy'
}

@test "offline under CI=true: sast FAILED naming the cause, and the run stops (#2508)" {
  GATE_ENV=(STUB_CURL_RC=6 CI=true)
  gate
  [ "$status" -eq 1 ]
  [ "$(last_verdict)" = 'gate: sast FAILED — network unavailable in CI' ]
  lacks "$output" 'vuln-scan'
}

@test "vuln-scan: trivy fs scans vuln, secret, misconfig and license at HIGH and CRITICAL (#2508)" {
  gate
  contains "$(cat "$STUB_LOG")" \
    'trivy fs --scanners vuln,secret,misconfig,license --severity HIGH,CRITICAL --exit-code 1 .'
  GATE_ENV=(STUB_TRIVY_RC=1)
  gate
  [ "$status" -eq 1 ]
  [ "$(last_verdict)" = 'gate: vuln-scan FAILED' ]
}

@test "vuln-scan: ignored paths are skipped, so a local scan sees what CI sees (#2508)" {
  printf 'node_modules/\n*.log\n' > .gitignore
  git add .gitignore
  mkdir -p node_modules/pkg && printf '{}\n' > node_modules/pkg/package.json
  printf 'x\n' > debug.log
  gate
  [ "$status" -eq 0 ]
  contains "$(cat "$STUB_LOG")" '--skip-dirs node_modules'
  contains "$(cat "$STUB_LOG")" '--skip-files debug.log'
}

@test "every shared tool is demanded before any stage (#2508)" {
  local tool
  for tool in yamllint gitleaks semgrep trivy curl jq git; do
    rm -f "$STUBS/$tool" "$BASE/$tool"
    gate
    [ "$status" -eq 2 ]
    contains "$output" "gate: required tool not on PATH: $tool — install it with: brew install $tool"
    [ -z "$(verdicts)" ]
    if [ "$tool" = jq ] || [ "$tool" = git ]; then ln -s "$(command -v "$tool")" "$BASE/$tool"; else stub "$tool"; fi
  done
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: 7 new failures. The shared-tools test fails on `semgrep`, `trivy` and `curl`, which nothing demands yet.

- [ ] **Step 3: Add to section 5**

```zsh
# any HTTP answer at all means online; only a connection failure is offline
gate_online() { curl -sS --max-time 5 -o /dev/null "$1" >/dev/null 2>&1 }
```

- [ ] **Step 4: Add to section 7, after the secrets registration**

```zsh
stage_sast() {
  if ! gate_online https://semgrep.dev; then gate_unavailable network; return 0; fi
  semgrep scan --config=auto --error --quiet
}
gate_register sast "" stage_sast semgrep curl

# Ignored paths (node_modules/, .venv/, build output) never exist on a CI
# checkout; scanning them locally would make the two verdicts disagree.
stage_vuln_scan() {
  if ! gate_online https://mirror.gcr.io/v2/; then gate_unavailable network; return 0; fi
  local -a skip=() ignored=()
  local p
  ignored=( ${(0)"$(git ls-files -z --others --ignored --exclude-standard --directory)"} )
  for p in "${ignored[@]}"; do
    if [[ "$p" == */ ]]; then skip+=(--skip-dirs "${p%/}"); else skip+=(--skip-files "$p"); fi
  done
  trivy fs --scanners vuln,secret,misconfig,license --severity HIGH,CRITICAL --exit-code 1 "${skip[@]}" .
}
gate_register vuln-scan "" stage_vuln_scan trivy curl
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `45/45 passed`.

The vuln-scan assertion for a clean repo expects `--exit-code 1 .` with nothing in between. If a host git config
makes `git ls-files --others --ignored` list something, the isolated `HOME` and `GIT_CONFIG_NOSYSTEM=1` should
already prevent it. If it still appears, find out why before changing the assertion.

- [ ] **Step 6: Commit**

```bash
git add tests/gate-script.bats development/skills/bootstrap/templates/common/scripts/gate.zsh.tmpl
git commit -m "feat(bootstrap): gate.zsh sast and vuln-scan stages (#2508)"
```

---

### Task 8: `--commit` end to end, module placement among the shared stages, and the whole-suite gate

**Files:**

- Test: `tests/gate-script.bats`
- Modify: `development/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, for the version.

**Interfaces:**

- Consumes: everything above. This task adds no new script code unless a test exposes a gap.

- [ ] **Step 1: Write the tests**

```bash
@test "a module's format stage runs between secrets and sast (#2508)" {
  module demo 'gate_register format demo demo_format' 'demo_format() { : }'
  gate
  [ "$status" -eq 0 ]
  [ "$(verdicts)" = "$(printf '%s\n' 'gate: hygiene ok' 'gate: yaml skipped — no YAML files' \
    'gate: secrets skipped — no commits ahead of origin/main' 'gate: format (demo) ok' \
    'gate: sast ok' 'gate: vuln-scan ok')" ]
}

@test "--commit runs exactly hygiene, yaml, secrets, format and lint (#2508)" {
  module demo \
    'gate_register format demo demo_ok' 'gate_register lint demo demo_ok' \
    'gate_register test demo demo_ok' 'gate_register image demo demo_ok' \
    'demo_ok() { : }'
  track_file staged.txt 'x'
  gate --commit
  [ "$status" -eq 0 ]
  [ "$(verdicts)" = "$(printf '%s\n' 'gate: hygiene ok' 'gate: yaml skipped — no YAML files' \
    'gate: secrets ok' 'gate: format (demo) ok' 'gate: lint (demo) ok')" ]
  lacks "$(cat "$STUB_LOG")" 'semgrep'
  lacks "$(cat "$STUB_LOG")" 'trivy'
}

@test "--commit is green in a brand-new repository with an unborn HEAD (#2508)" {
  local fresh="$BATS_TEST_TMPDIR/fresh"
  git init -q -b main "$fresh"
  mkdir -p "$fresh/scripts"
  cp "$GATE_SRC" "$fresh/scripts/gate.zsh"
  printf 'hello\n' > "$fresh/README.md"
  git -C "$fresh" add -A
  cd "$fresh"
  gate --commit
  [ "$status" -eq 0 ]
  [ "$(verdicts | head -n 1)" = 'gate: hygiene ok' ]
  contains "$(verdicts)" 'gate: secrets ok'
}

@test "the header documents every module-interface name (#2508)" {
  local name
  for name in gate_register gate_skip gate_unavailable gate_fail gate_ci gate_merge_base gate_online \
    gate_tracked GATE_TMP --local-only; do
    contains "$(awk 'NR==1{next} /^#/{print; next} {exit}' "$TEMPLATE")" "$name"
  done
}
```

- [ ] **Step 2: Run the tests and confirm they pass**

Run: `development/skills/resolve-issue/scripts/bats-quiet.zsh tests/gate-script.bats`

Expected: `49/49 passed`. If the unborn-HEAD case fails in `hygiene`, it is because `git grep` with no commits
still searches the index and the working tree, but a pathspec or `ls-files` call may assume `HEAD`. Fix the
script, not the test. That repository state is what the first commit's hook meets.

- [ ] **Step 3: Mutation-check every guard (#1587)**

For each mutation below:

1. Apply it to the template.
2. Run `bats-quiet.zsh tests/gate-script.bats`.
3. Confirm at least one case reds.
4. Revert it with `git checkout -- <template>`.

Record each mutation and the case it redded in the PR's test plan.

- the `exit 1` normalisation in `cleanup`, replaced by nothing
- the `rc != 130 && rc != 143` guard, deleted, so 130 is normalised too
- `gate_ci`'s `== true`, changed to `-n "${CI:-}"`
- the local-only branch in `run_entry`, deleted
- the `reg_local[i] && gate_ci` skip in the tool check, deleted
- `(( ! ${missing[(I)…]} ))`, deleted, so tools are no longer deduplicated
- the `commit_mode` filter in the selection, deleted
- the `-z` in `hygiene_grep`, deleted, together with its NUL parsing
- each of the six hygiene checks, deleted one at a time
- the `tsconfig*/jsconfig*` excludes, deleted
- the `count == 0` skip in `stage_secrets`, deleted
- the `else` whole-history branch in `stage_secrets`, replaced by `gate_skip`
- the `--skip-dirs` loop in `stage_vuln_scan`, deleted
- the module-load `if ! source`, made unconditional

- [ ] **Step 4: Bump the plugin version, re-reading main first**

Run `git fetch origin main`. Read `development/.claude-plugin/plugin.json`'s `version` on `origin/main`, then bump
the **minor** digit, since this adds installable content. Set the same value on the `development` entry in
`.claude-plugin/marketplace.json`.

- [ ] **Step 5: Run the whole suite through the blessed gate**

Run it detached, per the resolve profile: `LC_ALL=C <resolve-issue skill-base-dir>/scripts/run-gate.zsh --tests-dir
tests`.

Expected: exit 0, with a passed/total equal to the suite total. Pay particular attention to
`tests/bootstrap-template-modes.bats` (the 100755 mode), `tests/render.bats` and any template-sweep suite. If one
of them reds because of the new template, fix it in this PR.

- [ ] **Step 6: Commit**

```bash
git add tests/gate-script.bats development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "test(bootstrap): gate.zsh --commit and module placement end to end (#2508)"
```

The PR, review and merge go through `/development:resolve-issue 2508`'s normal flow. It closes #2508.
