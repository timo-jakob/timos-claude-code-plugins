#!/usr/bin/env bats
#
# PROPAGATION INVARIANT — the zero-language IaC selection rule (#1432, epic #1431).
#
# THE RULE, as ARCHITECTURE.md states it: **at most one IaC workflow is rendered
# per repo**. A repo with an application language takes neither IaC path; a
# zero-language repo takes at most one — the path whose MARKER it carries; a
# marker-less repo takes neither; and the dual-marker case must halt (a
# specification #1162 owns, not current behaviour).
#
# WHY THIS SWEEP EXISTS. The rule is restated in at least six artifacts —
# `detect-stack.sh`'s `iac_only` derivation, `bootstrap/SKILL.md` (§3l, Step 4b,
# Step 5's IaC preamble), `branch-protection.sh`'s `--iac-only` header,
# `SETUP.md.tmpl`'s required-context table, the checker's header and the how-to
# — and until this file it was pinned at exactly ONE:
# `tests/opentofu-plugin-skeleton.bats` asserts ARCHITECTURE.md's paragraph
# against the flattened file, which holds the authoritative site and nothing
# else. The nearest thing to a sweep,
# `tests/bootstrap-iac-pipeline.bats`'s *the `--iac-only` qualifier is stated
# identically at every restatement* (#1154), walks a CLOSED hand-written
# three-file list and covers a neighbouring qualifier rather than the selection
# rule. So this is genuinely new coverage, derived rather than transcribed.
#
# WHAT IT PINS, and why that clause. The half a restatement actually gets wrong
# is the QUALIFIER: the condition is the **marker**, not merely the absence of a
# language. Drop it and the rule reads "a zero-language repo takes the IaC
# path", which would put a language-less repo that carries no marker at all onto
# a path whose six required contexts nothing renders. So: wherever a site states
# the selection by the absence of a language, it must name the marker in the
# same statement.
#
# It deliberately does NOT pin a COUNT of zero-language repo types. A count is a
# fact that changes whenever an IaC path is added (#1394 renders the second
# one), so a sweep on it reds for correct work. The selection rule is the
# invariant; the inventory is not.
#
# STATEMENT-SCOPED, not file-scoped. `bootstrap/SKILL.md` is five thousand lines;
# a file-scoped needle for "marker" is satisfied there by some unrelated
# paragraph however stale the selection statement has gone — a vacuous pass. The
# window is +/- 2 lines because the sites wrap mid-clause (`detect-stack.sh`
# breaks "the kubernetes / marker with no application language" across two
# comment lines), which is exactly what defeats a per-line grep.

bats_require_minimum_version 1.5.0

load assertions
load prose-lockstep

# The literals the sweep GATES on: a site stating the selection by the LANGUAGE
# half. THREE spellings are in use and all must be gated — with only the first,
# `bootstrap/SKILL.md`'s §3l and Step 4b restatements went unswept while the
# file appeared covered through its Q4 row, so the drift this sweep exists to
# catch could land in the very sections the header names.
#
# `with` is load-bearing in the first — it picks the selection STATEMENTS and
# leaves out the passing mentions ("This repo has no application language, so
# the language-app gates were not generated"), which describe a consequence of
# taking the path rather than the condition for taking it.
#
# Each must be short enough to survive a reflow: `prose_gate_lines` matches
# PER LINE, so a gate phrase that wraps stops matching and its site leaves the
# sweep silently. That is why SKILL.md's Step 5 preamble was reflowed onto one
# line in #1432 rather than given a fourth gate spelling of its own.
#
# TWO SKILL.md lines mention an empty language set and are deliberately NOT
# gated, because neither states the selection CONDITION: Step 4b's
# "Only when the three-part IaC condition above holds" is a back-reference to
# the condition stated five lines earlier, and §3l branch (2)'s "this branch is
# only reachable with an empty resolved language set" states a consequence of
# having taken the path. Gating either would demand the marker be restated in a
# sentence whose subject is not the selection.
GATES=(
  'with no application language'
  'with an empty RESOLVED language set'
  'the resolved language set is empty'
)

# The ways a site may name the MARKER as the condition. `is_kubernetes` is the
# detector field, and a statement keyed on it ("Applies when `is_kubernetes` is
# `true`") names the marker as surely as the prose spelling does — excluding it
# would report §3l stale for being precise.
MARKERS=(
  'kubernetes topic marker'
  'kubernetes marker'
  'is_kubernetes'
)

# +/- 2 lines: enough to survive the widest wrap the sites actually use, narrow
# enough that an unrelated paragraph cannot satisfy the needle.
SPAN=2

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Exactly ONE artifact is authoritative in-repo. Every other restating file
  # must agree with it; when they disagree, this is the one that is right.
  AUTHORITATIVE="$REPO_ROOT/ARCHITECTURE.md"
}

# Every site that restates the rule, EXCLUDING the authoritative one.
#
# DERIVED, never transcribed — the criterion MAINTAINING.md's propagation-
# invariant pattern sets. `grep -rlE` over named directories is the mechanism
# that fits THIS rule: its sites share no filename token and span two trees, but
# every one of them names the flag or the derivation the rule is realised by.
#
# WHAT THIS ROSTER COVERS, stated so the boundary is a decision and not an
# accident of the grep: sites that NAME THE FLAG (`--iac-only` / `iac_only`)
# inside the `development` plugin, `docs/` and ARCHITECTURE.md. Membership is
# decided by the flag; the clause is judged on how the site states the rule. So
# a site that states the selection and never names the flag is out of roster BY
# CONSTRUCTION, and three classes of those exist today:
#
#   * `development-kubernetes/` and `development-opentofu/` — sibling topic
#     plugins, outside the grep roots entirely (`grep -r development` matches
#     the directory named exactly `development`);
#   * plugin manifests, `.claude-plugin/marketplace.json`, `README.md` and
#     `docs/reference/commands.md` — these describe primary-ELIGIBILITY (which
#     plugin may declare `primary:` for a language-less repo) rather than which
#     CI workflow is rendered, which is a different rule;
#   * `development/skills/maintenance/SKILL.md` — in-tree, and the closest
#     near-miss: it carries gate spelling #1 verbatim and is out of roster only
#     because it never names the flag.
#
# Widening the roster to the gate spellings themselves would pull all three in;
# that is a deliberate follow-up rather than this story's work, because the
# marker qualifier does not obviously belong in a plugin `description:`.
#
# Two exclusion classes are encoded in the `case` below, both deliberate:
#   * ARCHITECTURE.md — the authoritative site, held to the full rule by its own
#     test below rather than to the restatement clause;
#   * docs/superpowers/ — plans and specs are a HISTORICAL record of what was
#     decided at a point in time. Sweeping them would make a correct rule change
#     red until someone rewrote a design document to say something it never
#     said, which is the opposite of a propagation invariant's job.
selection_sites() {
  local rel
  while IFS= read -r rel; do
    case "$rel" in
      ARCHITECTURE.md) continue ;;
      docs/superpowers/*) continue ;;
    esac
    printf '%s\n' "$REPO_ROOT/$rel"
  # LC_ALL=C so the roster's order is reproducible across CI legs: the default
  # collation orders `templates/common/scripts/…` and `templates/common/SETUP…`
  # differently, and an order-dependent sweep is a bug waiting for a locale.
  done < <(cd "$REPO_ROOT" && grep -rlE 'iac[-_]only' development docs ARCHITECTURE.md | LC_ALL=C sort)
}

# Every selection STATEMENT in one site: the gate-line numbers across all three
# spellings, de-duplicated and numerically sorted, so a line carrying two
# spellings counts once.
selection_gate_lines() {
  local g
  [ "$#" -eq 1 ] || { printf 'selection_gate_lines: needs exactly one file\n' >&2; return 2; }
  [ -f "$1" ] && [ -r "$1" ] || { printf 'selection_gate_lines: unreadable site %s\n' "$1" >&2; return 2; }
  for g in "${GATES[@]}"; do
    prose_gate_lines "$1" "$g"
  done | sort -n -u
  return 0
}

# The sites the sweep GATES on — those holding at least one selection statement.
selection_gated() {
  local f
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { printf 'selection_gated: unreadable site %s\n' "$f" >&2; return 2; }
    # `grep -q` inside an `if` is errexit-exempt. The plain assignment this
    # replaces took its status from `grep -c`, which exits 1 on a zero count;
    # harmless at today's call sites (a command in a pipeline but the last is
    # exempt too, which is why the suite was green either way) but a trap for
    # the next caller who does not pipe, and one that would truncate silently.
    if selection_gate_lines "$f" | grep -q .; then
      printf '%s\n' "$f"
    fi
  done
  return 0
}

# Of the gated sites, the statements that FAIL the marker qualifier — one
# `<file>:<line>` per gap, empty output when the invariant holds.
#
# Factored out of the test bodies on purpose: the non-vacuity controls below run
# this same code over a deliberately staled copy of a real site, which is only
# honest if it is literally the same code.
selection_gaps() {
  local f ln win m hit
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] || { printf 'selection_gaps: unreadable site %s\n' "$f" >&2; return 2; }
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      win="$(prose_window "$f" "$ln" "$SPAN")"
      # The marker must be named AS THE CONDITION, in one of the spellings the
      # sites use. Deliberately not a bare "marker": `detect-stack.sh` carries
      # an `is-opentofu-marker:end` section fence two lines above its own
      # selection statement, so a bare needle passes there no matter how stale
      # the statement goes — the exact vacuity this sweep is written to avoid.
      hit=0
      for m in "${MARKERS[@]}"; do
        case "$win" in *"$m"*) hit=1 ;; esac
      done
      if [ "$hit" -eq 1 ]; then continue; fi
      printf '%s:%s\n' "$f" "$ln"
    done < <(selection_gate_lines "$f")
  done
  return 0
}

@test "ARCHITECTURE.md is the one authoritative statement of the IaC selection rule (#1432)" {
  # The site every other one must agree with, held to the rule in FULL — all
  # four clauses. A restatement sweep is only meaningful if the thing being
  # propagated is itself pinned somewhere.
  # STATEMENT-scoped, like the restatement half of this file and for the same
  # reason: ARCHITECTURE.md is thousands of lines, so four clauses asserted
  # against the flattened file are satisfied by four occurrences anywhere in it.
  # The whole point of the authoritative test is that this is the ONE statement
  # every other site is held to, so it must be one statement.
  local body ln
  [ -f "$AUTHORITATIVE" ]
  ln="$(prose_gate_lines "$AUTHORITATIVE" 'at most one IaC workflow is rendered' | awk 'END{print NR}')"
  [ "$ln" -eq 1 ]
  ln="$(prose_gate_lines "$AUTHORITATIVE" 'at most one IaC workflow is rendered')"
  # The gate stops at "rendered" because the sentence WRAPS after it
  # ("…is rendered per / repo"), and prose_gate_lines matches per line — the
  # constraint its own header states. The full clause is asserted below, inside
  # the window, where the whitespace collapse rejoins the wrap.
  #
  # span 12 covers the paragraph; the clauses run from the at-most-one sentence
  # to the marker qualifier about six lines later
  body="$(prose_window "$AUTHORITATIVE" "$ln" 12)"
  contains "$body" 'at most one IaC workflow is rendered per repo'
  contains "$body" 'a repo with an application language takes neither IaC path'
  contains "$body" 'the condition is the marker, not merely the absence of a language'
  # The dual-marker halt — specification, owned by #1162; seed 2 pins how the
  # rule is STATED, never that the halt is implemented. Needled on the FULL
  # clause, not a bare "must halt": that phrase occurs again two paragraphs
  # later ("must halt at bootstrap"), so the short needle would survive the
  # rule statement losing this clause entirely.
  contains "$body" 'the dual-marker case must halt'
}

@test "the derived IaC-selection site list is not empty or shrunken (#1432)" {
  # The canary the derivation itself needs: a broken grep, a renamed directory
  # or a moved artifact would turn the sweep below into a silent no-op that
  # reports green having swept nothing.
  local sites n
  sites="$(selection_sites)"
  n="$(printf '%s\n' "$sites" | awk 'NF{c++} END{print c+0}')"
  [ "$n" -ge 6 ]
  contains "$sites" 'detect-stack.sh'
  contains "$sites" 'branch-protection.sh'
  contains "$sites" 'SETUP.md.tmpl'
  contains "$sites" 'bootstrap/SKILL.md'
}

@test "every IaC selection statement names the MARKER, not just the absent language (#1432)" {
  local f gated
  local -a sites=()
  while IFS= read -r f; do
    sites+=("$f")
  done < <(selection_sites)
  [ "${#sites[@]}" -ge 6 ]
  run selection_gaps "${sites[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # NON-VACUITY: at least one site must have taken the gated arm, or a gate
  # phrase that stopped matching would make the whole sweep a no-op. Counted
  # through awk, which always exits 0 — `grep -c` returns 1 on an empty list
  # and would abort the test before this assertion could report it.
  gated="$(selection_gated "${sites[@]}" | awk 'END{print NR}')"
  [ "$gated" -ge 1 ]
}

@test "the IaC-selection sweep skips a site that only MENTIONS the flag (#1432)" {
  # Two roster members reference `--iac-only` without stating the selection
  # condition: the checker's header (quoting §3l on what its JSON does not
  # carry) and the how-to (naming the flag that requires the six contexts).
  # They are correctly outside the gate, and pinned as their own case so a gate
  # that widened to every roster member reds here rather than forcing a
  # restatement into a site whose job is not to carry one.
  local a="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-no-cluster-deploy.zsh"
  local b="$REPO_ROOT/docs/how-to/keep-app-repos-out-of-the-cluster.md"
  local sites
  [ -f "$a" ]
  [ -f "$b" ]
  # They must actually BE on the derived roster, or this case asserts nothing
  # about the sweep: a rename or a changed grep would drop them silently and
  # leave "correctly outside the gate" true of files the sweep never sees.
  sites="$(selection_sites)"
  contains "$sites" "$a"
  contains "$sites" "$b"
  run selection_gated "$a" "$b"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "FAIL CLOSED: an unreadable site is a typed failure, never a clean sweep (#1432)" {
  # The rosters are derived by `grep -rl` and re-open their paths later, so a
  # renamed or worktree-absent site is a real path to a green sweep of nothing.
  # Without these guards the sweeps report the site as clean rather than
  # unreadable: `win="$(prose_window …)"` and `< <(selection_gate_lines …)` both discard the helper's exit 2, so the
  # site simply reads as "not gated" and is skipped in silence. Every one of the
  # three entry points is pinned, each needling its OWN prefix so a case cannot
  # pass on a sibling's arm.
  local gone="$BATS_TEST_TMPDIR/renamed-away.md"
  [ ! -e "$gone" ]
  run selection_gate_lines "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'selection_gate_lines: unreadable site'
  run selection_gated "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'selection_gated: unreadable site'
  run selection_gaps "$gone"
  [ "$status" -eq 2 ]
  contains "$output" 'selection_gaps: unreadable site'
}

@test "ROSTER TRIPWIRE: MAINTAINING.md records this invariant's derived site count (#1432)" {
  # A derived sweep answers *do the sites I found agree?* but never *did a site
  # appear or vanish?* — a seventh restatement could land tomorrow, carry the
  # clause, and pass in silence, with nobody told the rule now moves seven
  # files. So the count is written down in the pattern's own table, and this
  # ties the written figure to the derivation. Adding or removing a restatement
  # reds here until MAINTAINING.md is updated in the same PR.
  local table row f n gated statements
  local -a sites=()
  table="$(sed -n '/^| Invariant | Authoritative site |/,/^$/p' "$REPO_ROOT/MAINTAINING.md")"
  [ -n "$table" ]
  # Read the ROW, not the whole table: both invariants in force today happen to
  # sweep six files, so a table-wide needle would be satisfied by the sibling
  # row and this tripwire would pass with its own figure deleted. `awk` rather
  # than `grep`, which exits 1 on no match and would abort before `[ -n "$row" ]`
  # could report the deleted row.
  row="$(awk '/IaC selection rule/' <<< "$table")"
  [ -n "$row" ]
  while IFS= read -r f; do
    sites+=("$f")
  done < <(selection_sites)
  n="${#sites[@]}"
  gated="$(selection_gated "${sites[@]}" | awk 'END{print NR}')"
  # The STATEMENT count, which the two file counts cannot see: a seventh
  # selection statement added inside a file already on the roster moves neither
  # `n` nor `gated`. The pattern's own rule is to record every figure that
  # moves independently, and this is the third.
  statements=0
  for f in "${sites[@]}"; do
    statements=$(( statements + $(selection_gate_lines "$f" | awk 'END{print NR}') ))
  done
  # THREE figures, because all three move independently: a new file naming the
  # flag grows the roster, a new file that also states the selection grows the
  # gated set, and a new statement in an existing file grows only the last.
  [ "$n" -eq 6 ]
  [ "$gated" -eq 4 ]
  [ "$statements" -eq 8 ]
  matches "$row" '(^|[^0-9])6 roster files'
  matches "$row" '(^|[^0-9])4 stating the selection'
  matches "$row" '(^|[^0-9])8 selection statements'
  # …and the sweep that enforces it is named IN THE ROW, so a reader of the
  # table can find the code rather than trusting the row. Asserted on the row
  # and not the document: the mechanism table above names this file too, so a
  # document-wide needle survives the row's Sweep column being emptied.
  contains "$row" 'tests/iac-selection-rule.bats'
}

@test "NON-VACUITY: the IaC-selection sweep reds on a stale PROSE site (#1432)" {
  # MUTATION (recorded here so this control cannot rot into a tautology): in
  # development/skills/bootstrap/SKILL.md — a prose site — §3l's own opening
  # sentence loses its marker qualifier: `Applies when is_kubernetes is true,
  # the resolved language set is empty` -> `Applies when the resolved language
  # set is empty`. That is the drift itself, not a synthetic edit: it turns
  # "the marker selects the path" into "the absent language selects the path",
  # in the section that defines the path.
  #
  # §3l rather than the Q4 row, deliberately: Q4's window names `is_kubernetes`
  # several times over, so mutating one mention there proves nothing about the
  # sweep — a control has to remove EVERY accepted marker spelling from the
  # window it targets, or it is testing its own sed rather than the invariant.
  local src="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local mut="$BATS_TEST_TMPDIR/stale-prose.md"
  [ -f "$src" ]
  sed 's/^Applies when `is_kubernetes` is `true`, \*\*the resolved language set is empty\*\*,/Applies when **the resolved language set is empty**,/' \
    "$src" > "$mut"
  # the mutation must have bitten, or the control proves nothing
  run cmp -s "$src" "$mut"
  # exactly 1 = "files differ". `cmp` exits 2 when it cannot READ one of them,
  # which a `-ne 0` test would accept as "the mutation bit" on a sed whose
  # redirect went nowhere.
  [ "$status" -eq 1 ]
  # the staled copy must still be GATED, or it would be skipped rather than caught
  run selection_gated "$mut"
  # status 0 = the sweep RAN. Without this, the [ -f ] guard's own diagnostic
  # ("selection_gated: unreadable site <path>") contains $mut and would satisfy the
  # needle below on the very path where the sweep never executed.
  [ "$status" -eq 0 ]
  [ "$output" = "$mut" ]
  run selection_gaps "$mut"
  # status 0 = the sweep RAN, matching the guarded-creator controls. Without it
  # the readability guard's own diagnostic — which embeds $mut — could satisfy
  # the needle on a path where the sweep never executed; today only the needle's
  # trailing colon prevents that, which is punctuation rather than an assertion.
  [ "$status" -eq 0 ]
  contains "$output" "$mut:"
}

@test "NON-VACUITY: the IaC-selection sweep reds on a stale CODE site (#1432)" {
  # MUTATION (recorded, as above): in
  # development/skills/bootstrap/scripts/detect-stack.sh — a code site — the
  # `iac_only` block's own comment drops the marker from the condition,
  # `# marker with no application language.` -> `# tree is selected with no
  # application language.`. Two distinct sites and two distinct file kinds, so
  # a normalisation that silently stopped working on comments (the one this
  # sweep depends on most) cannot leave the control green.
  local src="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  local mut="$BATS_TEST_TMPDIR/stale-code.sh"
  [ -f "$src" ]
  sed 's/^# marker with no application language\./# tree is selected with no application language./' \
    "$src" > "$mut"
  run cmp -s "$src" "$mut"
  # exactly 1 = "files differ". `cmp` exits 2 when it cannot READ one of them,
  # which a `-ne 0` test would accept as "the mutation bit" on a sed whose
  # redirect went nowhere.
  [ "$status" -eq 1 ]
  run selection_gated "$mut"
  # status 0 = the sweep RAN. Without this, the [ -f ] guard's own diagnostic
  # ("selection_gated: unreadable site <path>") contains $mut and would satisfy the
  # needle below on the very path where the sweep never executed.
  [ "$status" -eq 0 ]
  [ "$output" = "$mut" ]
  run selection_gaps "$mut"
  # status 0 = the sweep RAN, matching the guarded-creator controls. Without it
  # the readability guard's own diagnostic — which embeds $mut — could satisfy
  # the needle on a path where the sweep never executed; today only the needle's
  # trailing colon prevents that, which is punctuation rather than an assertion.
  [ "$status" -eq 0 ]
  contains "$output" "$mut:"
}
