#!/usr/bin/env bats
#
# Round subagents (#1935, epic #1933) — the review loop's panel and fix work
# runs in fresh subagents, and the conductor reads only their verdicts.
#
# The rule is prose in `development/skills/resolve-issue/reference/review-loop.md`
# (*Round subagents — the conductor reads only verdicts (#1935)*, with its
# *Panel subagent brief* and *Fix subagent brief*) plus two thin plugin agents.
# Nothing a script runs can see a driving session dispatch a subagent, so a
# needle sweep is what holds it. One test per acceptance criterion of #1935,
# each anchored by heading or quoted phrase, never by line number (#1189).
#
# Every needle is matched against whitespace-squeezed text, so a reflow cannot
# retire a pin. A needle pins WORDING: a correct rephrase reds it, and the red
# means "update the needle in the same change", not "relax it".

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REF="$REPO_ROOT/development/skills/resolve-issue/reference"
  PROTO="$REF/review-loop.md"
  PROMO="$REF/promotion.md"
  AGENTS="$REPO_ROOT/development/agents"
  HEADING='### Round subagents — the conductor reads only verdicts (#1935)'
}

# Print the lines of $1 from the line equal to $2 up to (not including) the next
# line starting with one of the prefixes in $3 (a `|`-separated list), or EOF.
# Fails when the start line is absent, so a renamed heading reds every test.
section_of() {
  awk -v start="$2" -v stops="$3" '
    BEGIN { n = split(stops, s, "|") }
    $0 == start { on = 1; print; next }
    on { for (i = 1; i <= n; i++) if (index($0, s[i]) == 1) exit; print }
  ' "$1" | {
    local out
    out="$(cat)"
    [ -n "$out" ] || { printf 'section not found: %s in %s\n' "$2" "$1" >&2; return 1; }
    printf '%s' "$out"
  }
}

squeeze() { LC_ALL=C tr -s '[:space:]' ' '; }

# The whole Round subagents section (its #### briefs included), squeezed.
load_section() {
  section="$(section_of "$PROTO" "$HEADING" '### |## ' | squeeze)"
  [ -n "$section" ]
}
load_panel_brief() {
  panel="$(section_of "$PROTO" '#### Panel subagent brief' '#### |### |## ' | squeeze)"
  [ -n "$panel" ]
}
load_fix_brief() {
  fix="$(section_of "$PROTO" '#### Fix subagent brief' '#### |### |## ' | squeeze)"
  [ -n "$fix" ]
}

# --- AC 1: the section, its two briefs, outside every frozen span -------------

@test "AC1: review-loop.md has the Round subagents heading and both brief sub-headings, once each" {
  [ "$(grep -cxF "$HEADING" "$PROTO")" -eq 1 ]
  [ "$(grep -cxF '#### Panel subagent brief' "$PROTO")" -eq 1 ]
  [ "$(grep -cxF '#### Fix subagent brief' "$PROTO")" -eq 1 ]
}

@test "AC1: the section sits after the last frozen span closes and opens none" {
  local head_line tail_line
  head_line="$(grep -nxF "$HEADING" "$PROTO" | cut -d: -f1)"
  tail_line="$(grep -n '^<!-- /moved: ' "$PROTO" | tail -1 | cut -d: -f1)"
  [ -n "$head_line" ]
  [ -n "$tail_line" ]
  [ "$head_line" -gt "$tail_line" ]
  # No frozen span opens anywhere after the section's heading.
  [ -z "$(tail -n +"$head_line" "$PROTO" | grep '^<!-- moved: ')" ]
}

@test "AC1: both briefs sit inside the Round subagents section" {
  load_section
  contains "$section" '#### Panel subagent brief'
  contains "$section" '#### Fix subagent brief'
}

# --- AC 2: depth budget -------------------------------------------------------

@test "AC2: the section states the depth budget for both flows and the fix subagent's" {
  load_section
  contains "$section" 'conductor (0) → panel subagent (1) → reviewers (2)'
  contains "$section" 'child conductor (1) → panel (2) → reviewers (3)'
  contains "$section" 'the fix subagent dispatches nothing'
}

@test "AC2: a panel without the Agent tool returns failed / no-agent-tool and the conductor stops" {
  load_section
  contains "$section" 'returns `failed` / `no-agent-tool`, and the conductor reports and stops'
}

# --- AC 3: dispatch mechanism, exactly one branch -----------------------------

@test "AC3: exactly one dispatch branch holds, per ARCHITECTURE.md's probe record" {
  load_section
  local arch probe_passed=0
  arch="$(squeeze < "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" '**Subagent dispatch mechanism.**'
  case "$arch" in
    *'The three subagent kinds ship as **plugin agents**'*) probe_passed=1 ;;
  esac
  if [ "$probe_passed" -eq 1 ]; then
    [ -f "$AGENTS/round-panel.md" ]
    [ -f "$AGENTS/round-fix.md" ]
    [ "$(grep -cx 'tools: Agent, Read, Grep, Glob, Bash' "$AGENTS/round-panel.md")" -eq 1 ]
    [ "$(grep -cx 'tools: Read, Edit, Write, Grep, Glob, Bash' "$AGENTS/round-fix.md")" -eq 1 ]
    [ "$(grep -cx 'name: round-panel' "$AGENTS/round-panel.md")" -eq 1 ]
    [ "$(grep -cx 'name: round-fix' "$AGENTS/round-fix.md")" -eq 1 ]
    contains "$section" 'The conductor dispatches `subagent_type: round-panel` and `subagent_type: round-fix`'
    contains "$section" 'one fresh subagent per job — a recovery or a retry is a **new** dispatch, never a resumed one'
    lacks "$section" 'subagent_type: general-purpose'
  else
    [ -z "$(ls "$AGENTS"/round-*.md 2>/dev/null)" ]
    contains "$section" 'subagent_type: general-purpose'
  fi
}

@test "AC3: round-fix's tools line carries no Agent" {
  [ -f "$AGENTS/round-fix.md" ] || skip "general-purpose branch: no round-fix agent ships"
  local tools
  tools="$(grep '^tools:' "$AGENTS/round-fix.md")"
  [ -n "$tools" ]
  lacks "$tools" 'Agent'
}

@test "AC3: each agent body points at its brief" {
  [ -f "$AGENTS/round-panel.md" ] || skip "general-purpose branch: no round agents ship"
  contains "$(squeeze < "$AGENTS/round-panel.md")" '*Panel subagent brief*'
  contains "$(squeeze < "$AGENTS/round-fix.md")" '*Fix subagent brief*'
}

# --- AC 4: contract usage -----------------------------------------------------

@test "AC4: the conductor writes handoffs and reads verdicts through round-handoff.zsh" {
  load_section
  contains "$section" 'The conductor writes every handoff with `round-handoff.zsh write-handoff'
  contains "$section" 'reads every verdict with `round-handoff.zsh read-verdict'
}

@test "AC4: a subagent writes its verdict only through round-handoff.zsh write-verdict" {
  load_section
  contains "$section" 'writes its verdict only with `round-handoff.zsh write-verdict'
}

# --- AC 5: the gate stays with the conductor ----------------------------------

@test "AC5: no subagent touches the gate; the conductor mints, launches, waits and dispatches concurrently" {
  load_section
  contains "$section" 'No subagent launches or waits on the gate.'
  contains "$section" 'It mints `T`, launches the detached gate, waits on it, and dispatches the panel subagent while the gate runs'
  contains "$section" "The panel handoff's \`tree_id\` is \`T\`."
}

# --- AC 6: carry precondition -------------------------------------------------

@test "AC6: the carry precondition is report-and-stop" {
  load_section
  contains "$section" 'An absent, zero-byte or unreadable carry is report-and-stop.'
  contains "$section" 'Before writing a panel handoff for any round ≥ 2, run step 1'"'"'s read-before-plan check — `jq length` on `<work-dir>/verify-<R>.json`'
}

# --- AC 7: the panel brief's outputs ------------------------------------------

@test "AC7: the panel writes the round's aggregate, never the dispatch sink" {
  load_panel_brief
  contains "$panel" '`<work-dir>/findings-round-<R>.json`, never to the dispatch sink `findings_path`'
}

@test "AC7: on a carried round the panel persists the carry lines and the accounting and checks every reviewer" {
  load_panel_brief
  contains "$panel" '`<work-dir>/carry-lines-<R>.txt`'
  contains "$panel" '`<work-dir>/carry-round-<R>.json`'
  contains "$panel" 'Check that every reviewer accounted for the carry'
}

@test "AC7: the panel writes a panel verdict" {
  load_panel_brief
  contains "$panel" 'Write a `panel` verdict'
  contains "$panel" 'Return to the conductor only that the verdict was written.'
}

@test "AC7: the panel works in worktree_root and plans against it" {
  load_panel_brief
  contains "$panel" "Work in the handoff's \`worktree_root\`, never your cwd"
  contains "$panel" 'Run `review-dispatch.zsh plan --repo <worktree_root> --base <base> --round <round>`'
}

@test "AC7: the panel dispatches every reviewer in the foreground" {
  load_panel_brief
  contains "$panel" '**Dispatch every reviewer in the foreground** (`run_in_background: false`)'
}

@test "AC7: the panel never authors findings, and re-dispatches a silent carry reviewer once" {
  load_panel_brief
  contains "$panel" "Never author a finding, edit one, or write \`[]\` on a reviewer's behalf."
  contains "$panel" 're-dispatch that reviewer once when it gave no per-entry lines'
  contains "$panel" "write every file in steps 3 and 4 with a quoted heredoc"
  contains "$panel" "\`cat > <file> <<'EOF'\` to create one, \`cat >> <file> <<'EOF'\` only to append each reviewer's lines to \`carry-lines-<R>.txt\`"
  contains "$panel" 'never an unquoted one or an interpolated string'
  contains "$panel" '**On a carried round, settle the carry before writing anything.**'
  contains "$panel" 'and keep only its second reply'
  contains "$panel" 're-dispatch that reviewer once when it gave no per-entry lines, with the prompt step 2 built for it'
  contains "$panel" '**Write the aggregate once** — every panel'"'"'s findings joined unchanged, a re-dispatched reviewer'"'"'s from its second reply'
}

@test "AC7: a stopped round returns a non-ok verdict and writes no findings file" {
  load_panel_brief
  contains "$panel" 'return a non-`ok` verdict instead, and write no findings file'
}

@test "AC7: the panel brief maps every stop situation to its outcome and cause" {
  load_panel_brief
  contains "$panel" '| a reviewer dimension did not run | `failed` / `dimension-not-run` |'
  contains "$panel" '| a reviewer prompt or a review skill could not be rendered or found | `failed` / `render-failed` |'
  contains "$panel" "| round ≥ 2 and the plan's \`fix_verification_path\` is \`null\` | \`failed\` / \`fix-verification-null\` |"
  contains "$panel" '| that path is set but a reviewer could not read it | `failed` / `fix-verification-unreadable` |'
  contains "$panel" '| a carried entry is still unaccounted after the one re-dispatch | `failed` / `carry-unconfirmed` |'
  contains "$panel" '| `plan` exited non-zero, and step 1 does not say to fix and re-run | `failed` / `plan-failed` |'
  contains "$panel" '| `worktree_root` is not the implementation worktree | `failed` / `wrong-worktree-root` |'
  contains "$panel" '| a `[DELETED by this story]` excerpt came back empty | `failed` / `empty-excerpt` |'
  contains "$panel" '| a full round whose story diff is empty | `not_applicable` / `story-diff-empty` |'
  contains "$panel" '| the language panel reported NOT APPLICABLE on a full round | `not_applicable` / `not-applicable` |'
  contains "$panel" '| you have no `Agent` tool | `failed` / `no-agent-tool` |'
}

# --- AC 8: consolidation stays with the conductor -----------------------------

@test "AC8: the conductor runs the loop itself with the verdict's two paths and opens neither" {
  load_section
  contains "$section" 'the conductor runs step-mode `resolve-story-loop.zsh` itself'
  contains "$section" 'as `--findings-file`'
  contains "$section" 'when it is non-null, its `carry_accounting_file` as `--carry-accounting`'
  contains "$section" 'It opens neither file.'
}

# --- AC 9: fix triggers -------------------------------------------------------

@test "AC9: awaiting-fix runs only on a non-zero blocking count; a zero is the closing-sweep promotion" {
  load_section
  contains "$section" 'read `final_changelist.summary.blocking`'
  contains "$section" '**non-zero** → dispatch the fix subagent with `trigger: awaiting-fix`'
  contains "$section" '**zero** → the closing-sweep promotion (step 3). No fix runs'
}

@test "AC9: gate-red carries the gate log and the conductor restarts the boundary" {
  load_section
  contains "$section" 'dispatch the fix subagent with `trigger: gate-red` and `gate_log`'
  contains "$section" 'the conductor restarts the boundary from its step 1'
}

@test "AC9: the fix brief applies the severity bar, guidance, rule-2 flag and Fix-pass rules" {
  load_fix_brief
  contains "$fix" "apply \`grant.severity_bar\` when a grant is set, the human's \`guidance\`"
  contains "$fix" 'when `rule2_mandatory` is `true`'
  contains "$fix" "the profile's *Fix-pass rules*"
}

@test "AC9: the fix brief's two trigger branches" {
  load_fix_brief
  contains "$fix" 'implement every item of the `blocking` array in the `changelist` file'
  contains "$fix" 'read `gate_log`, find what is red, and fix it'
}

@test "AC9: the fix subagent checks its tree, and never commits, pushes or runs the gate" {
  load_fix_brief
  contains "$fix" 'prints that path, and if it does not, edit nothing and return `failed` / `cannot-fix`'
  contains "$fix" 'never commits, pushes, or runs the gate'
  contains "$fix" 'Return to the conductor only that the verdict was written.'
  contains "$fix" 'sibling-sweep each pattern, and subtract rather than add (*A fix pass subtracts*), parking — and filing — what rule 1 refuses'
  contains "$fix" '`failed` / `cannot-fix` with `fix_applied: false` and `files_changed: 0`'
}

@test "AC9: the handoff key set, its conductor-supplied values, and the Fix-pass rules prompt" {
  load_section
  contains "$section" 'this section governs**'
  contains "$section" "Every key ARCHITECTURE.md's \`round-handoff/v1\` table lists for the kind"
  contains "$section" '`tree_id` is the round'"'"'s `T`'
  contains "$section" '`mode` is `round`, so `carry_entries` is `[]`'
  contains "$section" "\`base\` is the loop's \`--base\`, resolved to a commit"
  contains "$section" '`carried_finding_ids` names the entries of `verify-<R>.json`, and is `[]` when it holds none'
  contains "$section" 'resolved with `:A`'
  contains "$section" '`delta_base` is the tree identity **read from** `<work-dir>/tree-<R-1>.txt` on every round ≥ 2 — its content, never the path — and `null` on round 1'
  load_panel_brief
  contains "$panel" 'From round 2 on, add `--prior-tree <delta_base>`'
  contains "$panel" 'Step 1 above governs when to add `--final`'
  contains "$section" 'A non-zero `round-handoff.zsh write-handoff` exit, or a `read-verdict` exit 1 or 2, is report-and-stop.'
  contains "$section" "the dispatch prompt carries that heading's body, since the subagent cannot load a skill"
}

# --- AC 10: non-ok and no-op fix verdicts -------------------------------------

@test "AC10: a non-ok fix verdict and a fix that changed nothing are both report-and-stop" {
  load_section
  contains "$section" 'A fix verdict that is not `ok` is report-and-stop'
  contains "$section" "report-and-stop**, on either trigger; on \`gate-red\` it is §3's *abandon and report*"
  contains "$section" 'A fix that changed nothing is report-and-stop'
  contains "$section" '`fix_applied: false` or `files_changed: 0`'
  contains "$section" 'an `awaiting-fix` pass that parked every blocker under step 3'"'"'s rule 1'
  contains "$section" 'Take the next boundary there, so the parked items are re-raised as step 3 says.'
  contains "$section" 'the `- parked:` notes in `<work-dir>/progress.md` name each of the round'"'"'s blocking items'
}

# --- AC 11: interim panel recovery --------------------------------------------

@test "AC11: any non-ok panel verdict is report-and-stop until #1937" {
  load_section
  contains "$section" 'any non-`ok` panel verdict is report-and-stop until #1937'
}

# --- AC 12: stall retry -------------------------------------------------------

@test "AC12: a stall is exactly a read-verdict exit 3, with one re-dispatch and no recovery charge" {
  load_section
  contains "$section" 'read-verdict` exit 3, a missing file included'
  contains "$section" 'exactly one re-dispatch, then report-and-stop'
  contains "$section" 'a fresh subagent with a freshly written handoff'
  contains "$section" 'A verdict that validates but is not `ok` is not a stall'
  contains "$section" "recovery dispatches (#1937's) don't count against the retry"
}

@test "AC12: every dispatch first clears the same round and kind's earlier verdict and panel files" {
  load_section
  contains "$section" '**Before every dispatch, clear what an earlier dispatch of the same round and kind left behind**: delete `<work-dir>/verdict-<R>-<kind>.json` and, for a panel, `findings-round-<R>.json`, `carry-lines-<R>.txt` and `carry-round-<R>.json`. A delete that fails is report-and-stop.'
}

# --- AC 13: everything else unchanged -----------------------------------------

@test "AC13: the other exit codes keep their paths; promotion, residue and escalation stay in the conductor" {
  load_section
  contains "$section" 'Exit codes 0, 14, 10, 11, 12, 13, 2 and 1 take their existing paths, from the status JSON alone'
  contains "$section" 'a mid-run exit 2 on the CARRY-UNACCOUNTED arm, which is report-and-stop until #1937'
  contains "$section" 'Promotion, residue and escalation stay in the conductor'
}

# --- AC 14: promotion.md pointer ----------------------------------------------

@test "AC14: promotion.md, after its frozen span, points sub-loop rounds at the same subagents" {
  local close_line after
  close_line="$(grep -n '^<!-- /moved: suggestion-promotion -->$' "$PROMO" | cut -d: -f1)"
  [ -n "$close_line" ]
  after="$(tail -n +"$((close_line + 1))" "$PROMO" | squeeze)"
  contains "$after" "The sub-loop's rounds dispatch the same panel and fix subagents (#1935)."
  contains "$after" '§ *Round subagents — the conductor reads only verdicts (#1935)*'
  contains "$after" "the seeded file — not the verdict's path — is what that round passes as \`--findings-file\`"
}

# --- AC 15: the structural criterion ------------------------------------------

@test "AC15: the conductor reads only verdicts, status JSON and work-dir state, with two named exceptions" {
  load_section
  contains "$section" 'The conductor reads only verdicts, status JSON and its work-dir state'
  contains "$section" "never reviewer output, a findings file's contents or a diff"
  contains "$section" 'There are two named exceptions'
  contains "$section" 'NOT APPLICABLE option (2)'
  contains "$section" 'the promotion seed procedure with its step-7 verification'
}

@test "AC15: the decided pass is named as a temporary third exception until #1936" {
  load_section
  contains "$section" 'The decided pass is a temporary third exception until #1936'
  contains "$section" 'The risk pass (#1921) reads the same aggregate in the same slot, so it sits inside that exception too'
}
