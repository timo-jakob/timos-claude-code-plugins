#!/usr/bin/env bats
#
# Round subagents (#1935, #1936, epic #1933) — the review loop's panel, decide
# and fix work runs in fresh subagents, and the conductor reads only their
# verdicts.
#
# The rule is prose in `development/skills/resolve-issue/reference/review-loop.md`
# (*Round subagents — the conductor reads only verdicts (#1935)*, with its
# *Panel subagent brief*, *Fix subagent brief* and *Decide subagent brief*) plus
# three thin plugin agents. Nothing a script runs can see a driving session
# dispatch a subagent, so a needle sweep is what holds it. One test per
# acceptance criterion of #1935 and of #1936, each anchored by heading or quoted
# phrase, never by line number (#1189).
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
    *'The four subagent kinds ship as **plugin agents**'*) probe_passed=1 ;;
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
    # #2022: the conductor's own round dispatches run in the foreground, since
    # on an E3 child they are nested and would default to a background launch.
    contains "$section" 'Make every `round-panel`, `round-fix`, `round-decide` and `round-risk` dispatch in the foreground (`run_in_background: false`), as ARCHITECTURE.md'"'"'s *Subagent dispatch mechanism* records: in the epic E3 child flow the conductor is itself a subagent, so its own dispatch is nested and defaults to a background launch, which returns before the verdict is written.'
    # …and it carves the foreground dispatch out of #1513's wait rule by
    # POINTING at it; tests/round-boundary-wait.bats counts it as a pointer site.
    contains "$section" 'A foreground dispatch returns its verdict in the same turn, so the conductor carries straight on: **How to wait** governs only the gate and a dispatch that did launch in the background — it is not restated here.'
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
  contains "$panel" 'Check that every carried entry was accounted for by its owning dimension'"'"'s reviewer'
  # #2010: one owner per entry — the TOTALs are the checksum across owners
  contains "$panel" 'judged by the per-entry lines, whose checksum is that the reviewers'"'"' TOTALs sum to the length of the file step 1 split;'
  lacks "$panel" 'Check that every reviewer accounted for the carry'
}

@test "#2010: the panel splits the carry by owner and hands each reviewer only its own dimension's path" {
  load_panel_brief
  contains "$panel" '**On a carried round, split the carry by owner (#2010):** run `review-dispatch.zsh split-carry --fix-verification <work_dir>/verify-<round>.json`'
  contains "$panel" 'never write `verify-<round>.json`, which stays the loop'"'"'s carry'
  # a split failure takes an EXISTING cause — the verdict vocabulary is unchanged
  contains "$panel" 'an exit 1, or a second exit 2, is `failed` / `fix-verification-unreadable`'
  contains "$panel" 'each reviewer'"'"'s Fix verification line names only the path the map gives its own dimension, and a reviewer whose dimension the map does not hold gets no such line'
  # carry-redispatch: grouped by dimension, owners only, flat v1 handoff kept
  contains "$panel" 'Step 1'"'"'s split runs on `verify-<R>-carry.json` instead, so `carry_entries` are grouped by `dimension` and step 2 dispatches **only** each group'"'"'s owning reviewer (#2010) — never the whole panel'
  contains "$panel" 'a dimension with no group is not dispatched, which is not `dimension-not-run`'
  contains "$panel" 'the handoff'"'"'s `carry_entries` stay the flat `round-handoff/v1` array'
  # carry-repair still rebuilds from the lines, now one owner's line per entry
  contains "$panel" 'Read `<work-dir>/carry-lines-<R>.txt` — one owning reviewer'"'"'s line per entry since #2010 — rebuild `<work-dir>/carry-round-<R>.json` from those lines'
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

@test "AC7: the panel dispatches the reviewers of the review_skill and of every topic panel" {
  # #2023: dropping the topic-panel half of this sentence would silently drop
  # every topic panel from a round, and nothing else pins it.
  load_panel_brief
  contains "$panel" "**Dispatch the reviewers** of the plan's \`review_skill\` and of every \`topic_review_skills\` entry (*Topic panels*)"
}

@test "AC7: the panel dispatches every reviewer in the foreground" {
  load_panel_brief
  contains "$panel" '**Dispatch every reviewer in the foreground** (`run_in_background: false`)'
}

@test "AC7: the panel never authors findings, and re-dispatches a silent carry reviewer once" {
  load_panel_brief
  contains "$panel" "Never author a finding, edit one, or write \`[]\` on a reviewer's behalf."
  contains "$panel" 're-dispatch, once, only a reviewer that left any entry of its own dimension'"'"'s file without a per-entry line'
  contains "$panel" "write every file in steps 3 and 4 with a quoted heredoc"
  contains "$panel" "\`cat > <file> <<'EOF'\` to create one, \`cat >> <file> <<'EOF'\` only to append each reviewer's lines to \`carry-lines-<R>.txt\`"
  contains "$panel" 'never an unquoted one or an interpolated string'
  contains "$panel" '**On a carried round, settle the carry before writing anything.**'
  contains "$panel" 'and keep only its second reply'
  contains "$panel" 're-dispatch, once, only a reviewer that left any entry of its own dimension'"'"'s file without a per-entry line, with the prompt step 2 built for it'
  contains "$panel" '**Write the aggregate once** — every panel'"'"'s findings joined unchanged, a re-dispatched reviewer'"'"'s from its second reply'
}

@test "AC7: a stopped round returns a non-ok verdict and writes no findings file" {
  load_panel_brief
  contains "$panel" 'return a non-`ok` verdict instead, and write no findings file'
}

@test "AC7: the panel brief maps every stop situation to its outcome and cause" {
  load_panel_brief
  contains "$panel" '| a planned dimension did not run | `failed` / `dimension-not-run` |'
  lacks "$panel" 'a reviewer dimension did not run'
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

# --- AC 11: interim panel recovery, retired by #1937 --------------------------

@test "AC11: the interim report-and-stop rule is gone; a non-ok panel verdict takes the recovery arms" {
  load_section
  lacks "$section" 'any non-`ok` panel verdict is report-and-stop until #1937'
  contains "$section" 'A non-`ok` panel verdict takes *Verdict recovery arms (#1937)* below.'
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
  contains "$section" '**Before every dispatch, clear what an earlier dispatch of the same round and kind left behind**: delete `<work-dir>/verdict-<R>-<kind>.json` and, for a panel, what its mode replaces:'
  contains "$section" '- a **`round`**-mode panel also deletes `findings-round-<R>.json`, `carry-lines-<R>.txt` and `carry-round-<R>.json`;'
  contains "$section" 'A delete that fails is report-and-stop.'
}

# --- AC 13: everything else unchanged -----------------------------------------

@test "AC13: the other exit codes keep their paths; promotion, residue and escalation stay in the conductor" {
  load_section
  contains "$section" 'Exit codes 0, 14, 10, 11, 12, 13, 2 and 1 take their existing paths, from the status JSON alone'
  contains "$section" 'a mid-run exit 2 on the CARRY-UNACCOUNTED, CADENCE or never-ran arm, which takes `#### Verdict recovery arms (#1937)`.'
  lacks "$section" 'reads per-entry lines the conductor no longer holds'
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

@test "AC15: neither the decided pass nor the risk pass is an exception (#1936, #2025)" {
  load_section
  contains "$section" 'There are two named exceptions, both human-driven'
  contains "$section" 'The risk pass (#1921) is not an exception: while `corner_case_risk_threshold` is on, the risk subagent assesses the aggregate and the conductor passes its verdict'"'"'s `risk_file` as `--risk` unopened; when the threshold is off or ignored, no risk subagent is dispatched.'
  lacks "$section" 'The risk pass (#1921) is the one exception that is not human-driven'
  lacks "$section" '#2025 moves it into a subagent.'
  lacks "$section" 'The decided pass is a temporary third exception'
  lacks "$section" 'so it sits inside that exception too'
}

# --- #1936: the decide subagent -----------------------------------------------
#
# One test per acceptance criterion of #1936, anchored like the rest.

load_decide_brief() {
  decide="$(section_of "$PROTO" '#### Decide subagent brief' '#### |### |## ' | squeeze)"
  [ -n "$decide" ]
}
load_decided_pass() {
  decided="$(section_of "$PROTO" \
    '### The decided pass — run every `decides:` command before consolidating (#1584)' '### |## ' | squeeze)"
  [ -n "$decided" ]
}

@test "#1936 AC1: the Decide subagent brief sits once inside the Round subagents section and points at the decided pass" {
  [ "$(grep -cxF '#### Decide subagent brief' "$PROTO")" -eq 1 ]
  load_section
  contains "$section" '#### Decide subagent brief'
  load_decide_brief
  contains "$decide" 'the per-finding procedure — which commands run, how each verdict is settled, the malformed shapes and the retirement rule — is *The decided pass* above, and is not restated here'
  # The brief restates none of the per-finding arms.
  lacks "$decide" 'Red means the command RAN'
  lacks "$decide" 'Three malformed shapes promote nothing'
}

@test "#1936 AC2: exactly one dispatch branch holds for the decide subagent" {
  load_decide_brief
  local arch
  arch="$(squeeze < "$REPO_ROOT/ARCHITECTURE.md")"
  case "$arch" in
    *'The four subagent kinds ship as **plugin agents**'*)
      [ -f "$AGENTS/round-decide.md" ]
      [ "$(grep -cx 'name: round-decide' "$AGENTS/round-decide.md")" -eq 1 ]
      [ "$(grep -cx 'tools: Read, Edit, Write, Grep, Glob, Bash' "$AGENTS/round-decide.md")" -eq 1 ]
      lacks "$(grep '^tools:' "$AGENTS/round-decide.md")" 'Agent'
      contains "$(squeeze < "$AGENTS/round-decide.md")" '*Decide subagent brief*'
      contains "$decide" 'The conductor dispatches `subagent_type: round-decide`'
      lacks "$decide" 'subagent_type: general-purpose'
      load_section
      contains "$section" '`subagent_type: round-decide` for the decided pass, one fresh subagent per job'
      ;;
    *)
      [ ! -e "$AGENTS/round-decide.md" ]
      contains "$decide" 'subagent_type: general-purpose'
      ;;
  esac
  contains "$decide" 'the decide subagent dispatches nothing'
  # The depth budget's own bullet, pinned with its list neighbour: the brief
  # repeats the sentence, so a bare needle could not see the bullet go.
  load_section
  contains "$section" '- the fix subagent dispatches nothing; - the decide subagent dispatches nothing;'
}

@test "#1936 AC3: the dispatch point and the decide handoff" {
  load_decide_brief
  contains "$decide" 'Dispatch it after the boundary'"'"'s step 5 has judged the gate green, or straight after the panel on a round that runs with no gate'
  contains "$decide" 'the closing-sweep promotion and the findings-file recovery re-invokes'
  contains "$decide" 'Never on a red gate, and never on a green gate that reported a tree other than `T`.'
  contains "$decide" 'the findings-file recovery re-invokes — and straight after the panel a CADENCE recovery re-runs, over its new aggregate.'
  contains "$decide" 'Write `handoff-<R>-decide.json` with `round-handoff.zsh write-handoff`'
  contains "$decide" '`aggregate_findings_file` from the panel verdict'
  contains "$decide" '`worktree_root` as *What the conductor puts in a handoff* says for every kind — the same value as the panel handoff'"'"'s'
  lacks "$decide" 'from the dispatch descriptor'
  contains "$decide" '`retired_file` = `<work-dir>/decides-retired.txt`'
}

@test "#1936 AC4: the decide subagent's duties" {
  load_decide_brief
  contains "$decide" 'If it does not, run nothing, edit nothing, and return `failed` / `wrong-worktree-root`.'
  contains "$decide" '**Run the decided pass** over `aggregate_findings_file`, as *The decided pass* specifies, in `worktree_root`.'
  contains "$decide" '**Settle every retired command as retired, without running it**, before anything runs'
  # Retired commands are settled before the decided pass runs, so a retired
  # writing command never runs again.
  local after_settle="${decide#*'**Settle every retired command as retired, without running it**'}"
  [ "$after_settle" != "$decide" ]
  contains "$after_settle" '**Run the decided pass** over `aggregate_findings_file`'
  contains "$decide" 'Step 2'"'"'s findings are already settled: never run a command `retired_file` lists.'
  contains "$decide" 'step 5, `"decided": "green"`, logged as a writing command — including a finding a decide pass already decided'
  contains "$decide" 'to `<work-dir>/decided-<R>.log`, and each distinct command you ran to `<work-dir>/decides-ran-<R>.txt`, one per line'
  contains "$decide" '**Write the aggregate once, atomically**, after every verdict is in'
  contains "$decide" '`mv` it over `aggregate_findings_file`'
  contains "$decide" '**Write a `decide` verdict** with `round-handoff.zsh write-verdict'
  contains "$decide" '`ok` with `cause: null` and only `decided_red`, `decided_green` and `malformed` (the counts of findings this pass stamped `red`, stamped `green`, and named malformed)'
  contains "$decide" 'or, from step 1, `failed` / `wrong-worktree-root` with `decided_red`, `decided_green`, `malformed` and `ran_commands_file` all `null`.'
  contains "$decide" '**Any other failure writes no verdict.** If reading the handoff, reading `retired_file` or the aggregate, an append, or the aggregate write or `mv` of this brief'"'"'s step 5 fails, write no verdict and return that you failed: the conductor'"'"'s stall retry takes it from there.'
  contains "$decide" 'Never write `ok` unless that `mv` succeeded.'
  contains "$decide" '`ran_commands_file` = `<work-dir>/decides-ran-<R>.txt`'
  contains "$decide" 'Return to the conductor only that the verdict was written.'
}

@test "#1936 AC5: the file lifecycle" {
  load_decide_brief
  contains "$decide" 'Create `decides-retired.txt` empty before round 1'"'"'s panel dispatch, which clears any earlier run'"'"'s file.'
  contains "$decide" 'Truncate `decided-<R>.log` and `<work-dir>/decides-ran-<R>.txt` before the round'"'"'s first decide dispatch; every decide subagent only appends to them, re-entries included.'
  contains "$decide" 'An absent retired file reads as empty.'
  contains "$decide" 'None of these writes is a read.'
}

@test "#1936 AC6: the risk pass runs only after an ok decide verdict, and the conductor opens nothing else" {
  load_decide_brief
  contains "$decide" 'Run the risk pass only after reading an `ok` decide verdict.'
  contains "$decide" 'Once the decide verdict is `ok`, pass the panel verdict'"'"'s `aggregate_findings_file` as `--findings-file`.'
  contains "$decide" 'On a promotion sub-loop'"'"'s round 1, pass instead the seeded file built from that decided aggregate (`reference/promotion.md`).'
  contains "$decide" 'Open neither the aggregate, `decides-ran-<R>.txt` nor `decides-retired.txt`.'
  lacks "$decide" 'except through the risk pass, as the structural criterion says'
  load_section
  contains "$section" 'and then an `ok` decide verdict where the round'"'"'s decided pass runs'
}

@test "#1936 AC7: the CADENCE sequence, in order" {
  load_decide_brief
  local seq
  seq="${decide#*'**A CADENCE refusal right after a decide pass**, in this order:'}"
  [ "$seq" != "$decide" ]
  contains "$seq" '1. append `decides-ran-<R>.txt` to `decides-retired.txt` without reading it; 2. dispatch a fresh decide subagent over the same aggregate, which re-settles the retired commands'"'"' findings and runs none of them — a recovery dispatch, not a stall re-dispatch; 3. only then take either of that arm'"'"'s recoveries.'
  contains "$seq" '3. only then take either of that arm'"'"'s recoveries. Re-running the panel needs a decide pass over its new aggregate, as *When* says.'
}

@test "#1936 AC8: a non-ok decide verdict is report-and-stop, and the stall retry applies unchanged" {
  load_decide_brief
  contains "$decide" 'A decide verdict that is not `ok` is report-and-stop, with no consolidation.'
  contains "$decide" 'The stall retry above applies unchanged: one fresh re-dispatch on a `read-verdict` exit 3, then report-and-stop.'
}

@test "#1936 AC9: narration reports only the counts and the log path" {
  load_decide_brief
  contains "$decide" 'Report the verdict'"'"'s `decided_red`, `decided_green` and `malformed` counts and the `decided-<R>.log` path.'
  contains "$decide" 'Findings are named in `decided-<R>.log` only.'
}

@test "#1936 AC10: the decided-pass section is edited in place at the five phrases" {
  load_decided_pass
  contains "$decided" '**The decide subagent is the one who settles them** (*Decide subagent brief* below)'
  lacks "$decided" 'You are the one who settles them'
  contains "$decided" '**The conductor truncates it before the round'"'"'s first decide dispatch** (*Decide subagent brief* below), and every decide pass only appends'
  lacks "$decided" 'Truncate it on this round'"'"'s first entry'
  lacks "$decided" 'unless the refusal isolates one, and then that one'
  contains "$decided" 'and say so in the log only: a tool you could not run decides nothing'
  lacks "$decided" 'in your round narration'
  contains "$decided" 'name the malformed finding in the log only.'
  lacks "$decided" 'in the log and the round narration'
}

@test "#1936 AC11: the KNOWN LIMITATION lookup is a narrow work-dir-state read" {
  load_decide_brief
  contains "$decide" 'the conductor may look up only the `decided-<R'"'"'>.log` entries matching a `carry_unconfirmed[]` identity'"'"'s `file` and `dimension`, reading only their `decides:` command and exit status.'
  contains "$decide" 'That lookup happens only on that report-and-stop path, and it counts as work-dir state.'
}

@test "#1936 AC12: the risk-pass section keeps its own heading and its slot after the decided pass" {
  # The section is out of scope for #1936; its heading and its opening rule are
  # the two things a misplaced edit would most likely move.
  [ "$(grep -cxF '### The risk pass — assess every blocking finding before consolidating (#1921)' "$PROTO")" -eq 1 ]
  local risk
  risk="$(section_of "$PROTO" '### The risk pass — assess every blocking finding before consolidating (#1921)' '### |## ' | squeeze)"
  contains "$risk" '**Assess the round'"'"'s blockers against `corner_case_risk_threshold` after the decided pass and before the step-2 invocation.**'
}

@test "#1936 AC13: promotion.md names the decide subagent alongside the panel and fix subagents" {
  local close_line after
  close_line="$(grep -n '^<!-- /moved: suggestion-promotion -->$' "$PROMO" | cut -d: -f1)"
  [ -n "$close_line" ]
  after="$(tail -n +"$((close_line + 1))" "$PROMO" | squeeze)"
  contains "$after" 'they are now dispatched as the **panel**, **decide**, **risk** and **fix** subagents'
  contains "$after" 'On sub-loop round 1, `<pre-seed-round-1.json>` is the panel verdict'"'"'s `aggregate_findings_file`, `<promotion-work-dir>/findings-round-1.json` — inside the work-dir, not at a path of its own, so the decide handoff can name it'
  contains "$after" 'The decide subagent runs over `<pre-seed-round-1.json>` first: build the seeded file (step 3) only after an `ok` decide verdict, from the decided file.'
  contains "$after" 'The decide pass'"'"'s atomic rewrite is the one overwrite step 1 permits — it changes stamps and severities only, never a finding'"'"'s `file`, `dimension` or line, so step 2 classifies against a baseline that is still valid.'
  load_section
  contains "$section" 'A promotion sub-loop'"'"'s rounds dispatch the same panel, decide, risk and fix subagents'
}

# --- #1937: verdict recovery arms ---------------------------------------------
#
# One test per acceptance criterion of #1937, anchored like the rest.

load_arms() {
  arms="$(section_of "$PROTO" '#### Verdict recovery arms (#1937)' '#### |### |## ' | squeeze)"
  [ -n "$arms" ]
}
load_carry_section() {
  carry="$(section_of "$PROTO" '### Carry accounting — confirmed, re-raised, unconfirmed (#1583)' '### |## ' | squeeze)"
  [ -n "$carry" ]
}

@test "#1937 AC1: the Verdict recovery arms sub-heading sits once inside the Round subagents section, outside every frozen span" {
  [ "$(grep -cxF '#### Verdict recovery arms (#1937)' "$PROTO")" -eq 1 ]
  load_section
  contains "$section" '#### Verdict recovery arms (#1937)'
  local arms_line tail_line
  arms_line="$(grep -nxF '#### Verdict recovery arms (#1937)' "$PROTO" | cut -d: -f1)"
  tail_line="$(grep -n '^<!-- /moved: ' "$PROTO" | tail -1 | cut -d: -f1)"
  [ "$arms_line" -gt "$tail_line" ]
  load_arms
  contains "$arms" 'This is the one statement of what the conductor does with a non-`ok` panel verdict, and with the loop'"'"'s CARRY-UNACCOUNTED, CADENCE and never-ran refusals.'
  contains "$arms" 'for its reasoning read that arm, which is not restated here'
}

@test "#1937 AC2: review-loop.md says 'until #1937' nowhere" {
  [ -z "$(grep -F 'until #1937' "$PROTO")" ]
}

@test "#1937 AC3: a non-ok verdict stops the gate first, and the outcome/cause pairing is closed" {
  load_arms
  contains "$arms" '**A non-`ok` panel verdict is boundary step 3 refusing or aborting the round.** Stop the gate with the handle step 2 recorded, then take the arm below.'
  contains "$arms" 'An arm that resumes the round resumes at step 1, except on a no-fix round, exactly as step 3 says.'
  contains "$arms" '**A non-`ok` verdict from a `carry-repair` or `carry-redispatch` panel takes no row:** its gate has already finished, so nothing is stopped or resumed, and it is that ground'"'"'s cap — report-and-stop.'
  contains "$arms" '`not-applicable` and `story-diff-empty` pair with `not_applicable`; the other nine causes pair with `failed`. A verdict whose outcome/cause pair is off this table is report-and-stop.'
}

@test "#1937 AC4: every one of the eleven panel causes maps onto its arm" {
  load_arms
  contains "$arms" '| `dimension-not-run`, `render-failed` | `failed` | step 2'"'"'s **FAILED** arm: one fresh round-mode panel; the same cause again is report-and-stop |'
  contains "$arms" '| `fix-verification-null` | `failed` | the FAILED arm'"'"'s null carry: re-run the carry precondition on `verify-<R>.json`, then one fresh round-mode panel, whose brief plans with `--fix-verification`; the same cause again is report-and-stop |'
  contains "$arms" '| `fix-verification-unreadable` | `failed` | the FAILED arm'"'"'s unreadable carry: re-run the carry precondition — an unreadable `verify-<R>.json` is report-and-stop — then one fresh round-mode panel; the same cause again is report-and-stop |'
  contains "$arms" '| `carry-unconfirmed` | `failed` | the **missing-confirmation** arm: one fresh round-mode panel, and "if the re-run again reports no confirmation count, report it in the conversation and stop" |'
  contains "$arms" '| `plan-failed` | `failed` | report-and-stop'
  contains "$arms" '| `wrong-worktree-root` | `failed` | report-and-stop'
  contains "$arms" '| `empty-excerpt` | `failed` | report-and-stop'
  contains "$arms" 'and a fresh panel "fails the same way" |'
  contains "$arms" '| `no-agent-tool` | `failed` | report-and-stop |'
  contains "$arms" '| `not-applicable` | `not_applicable` | the **NOT APPLICABLE on a full round** arm: autonomous, stop with no commit and no PR; interactive, its three options, none taken without an explicit choice. Never coerced to `[]`, and the panel is not re-run |'
  contains "$arms" '| `story-diff-empty` | `not_applicable` | the **empty story diff** shape: go back to **§2 (Implement)**'
  contains "$arms" 'The three NOT APPLICABLE options are never offered, and, per the #1485 note, neither the re-invoke arm nor the panel re-run arm is taken |'
  # the quoted arms really exist where the table says they do
  contains "$(squeeze < "$PROTO")" 'if the re-run again reports no confirmation count, report it in the conversation and stop'
  contains "$(squeeze < "$PROTO")" 'fails the same way.'
}

@test "#1937 AC5: the never-ran arm is a shown absence of dispatch, and a dispatched-but-silent panel is a stall" {
  load_arms
  contains "$arms" '**The never-ran arm is not a verdict.** It applies only when the conductor can show that no panel subagent was dispatched this round'
  contains "$arms" 'Dispatch one round-mode panel, then a decide subagent over its aggregate, then re-invoke.'
  contains "$arms" 'A panel that was dispatched and returned no valid verdict is a stall, not never-ran.'
}

@test "#1937 AC6: CARRY-UNACCOUNTED reads its ground from loop output and scopes the tool-verdict exception (#2032)" {
  load_arms
  contains "$arms" 'Read the ground from the loop'"'"'s refusal stderr and the status JSON'"'"'s `carry_unconfirmed[]` — loop output, never reviewer output.'
  contains "$arms" 'an entry stamped `"decided": "red"` in `verify-<R>.json`, or one the *Decide subagent brief*'"'"'s narrow `decided-<R'"'"'>.log` lookup finds a red for, is a tool-verdict carry — report it and its `decides:` command and stop, dispatching nothing.'
  # #2032: the exception is scoped to the refused entries on the
  # neither-confirmed ground, exactly as *Recover by ground* states it.
  contains "$arms" 'The #1647 tool-verdict exception applies only on the *neither confirmed nor re-raised* ground, and only to an entry the refusal names in `carry_unconfirmed[]`: such an entry stamped'
  contains "$arms" 'It reaches no other entry and no other ground: the three `carry-repair` grounds and an unevidenced re-raise never take it, whatever else `verify-<R>.json` holds.'
  lacks "$arms" 'First apply the #1647 tool-verdict exception'
  # #2032: the decided pass's KNOWN LIMITATION and the decide brief's lookup
  # licence state the same scope, so no second copy keeps the unscoped stop.
  load_decided_pass
  contains "$decided" 'on a CARRY-UNACCOUNTED refusal on the *neither confirmed nor re-raised* ground that names such an entry in `carry_unconfirmed[]`, do **not** take the carry recovery'"'"'s re-dispatch'
  contains "$decided" 'it cannot succeed until #1647 lands'
  contains "$decided" 'taking it from the log of the round that **decided** it, `<work-dir>/decided-<R>.log`, **not** this round'"'"'s, since the command was not run this round — and stop.'
  contains "$decided" 'Every other ground, an unevidenced re-raise of such an entry included, takes its own recovery (*Verdict recovery arms*).'
  lacks "$decided" 'on a CARRY-UNACCOUNTED refusal naming such an entry'
  load_decide_brief
  contains "$decide" '**A CARRY-UNACCOUNTED refusal on the *neither confirmed nor re-raised* ground naming a tool-verdict carry** (*The decided pass*'"'"'s KNOWN LIMITATION; *Verdict recovery arms*).'
  lacks "$decide" '**A CARRY-UNACCOUNTED refusal naming a tool-verdict carry**'
}

@test "#1937 AC7: each ground takes its carry mode, with its own cap" {
  load_arms
  contains "$arms" 'one panel in **`carry-repair`** mode, `carry_entries` every carried identity projected from `verify-<R>.json`. On `ok`, re-invoke with the same `--findings-file` and the rebuilt `--carry-accounting`; no decide dispatch follows;'
  contains "$arms" 'one panel in **`carry-redispatch`** mode, `carry_entries` the refused identities only. On `ok`, dispatch a decide subagent over the merged aggregate, then re-invoke.'
  contains "$arms" 'The cap is that arm'"'"'s own, per ground: "If the re-run again leaves an entry unaccounted, report it in the conversation and stop". A different ground takes its own arm once.'
}

@test "#1937 AC8: a stalled carry-redispatch is restored from its pre-carry snapshots" {
  load_arms
  contains "$arms" 'copy `findings-round-<R>.json` and `carry-lines-<R>.txt` to `<work-dir>/findings-round-<R>.pre-carry.json` and `<work-dir>/carry-lines-<R>.pre-carry.txt` without opening them'
  contains "$arms" 'before its stall re-dispatch restore both over the originals, so the retry merges and appends exactly once. A failed copy or restore is report-and-stop.'
  contains "$arms" '`carry-repair` takes no snapshot'
}

@test "#1937 AC9: every recovery is a fresh round-mode subagent with a rewritten handoff and a mode-aware clear" {
  load_arms
  contains "$arms" 'The FAILED re-run, the missing-confirmation arm, the never-ran arm and the CADENCE re-run dispatch in `round` mode, reusing the original `delta_base` and `carried_finding_ids` with `carry_entries` `[]`.'
  contains "$arms" 'Before every recovery dispatch, rewrite `handoff-<R>-panel.json` with `round-handoff.zsh write-handoff`'
  contains "$arms" 'which always deletes the previous `verdict-<R>-panel.json`, so a stalled recovery reads as a stall and never as the superseded verdict'
  load_section
  contains "$section" '`mode` is `round`, so `carry_entries` is `[]`, except on the two carry recoveries (*Verdict recovery arms (#1937)*)'
}

@test "#1937 AC10: the dispatch clear depends on the panel's mode" {
  load_section
  contains "$section" '- a **`carry-repair`** panel deletes nothing more;'
  contains "$section" '- a **`carry-redispatch`** panel also deletes `<work-dir>/findings-round-<R>-carry.json` and `<work-dir>/verify-<R>-carry.json`, and keeps `findings-round-<R>.json`, `carry-lines-<R>.txt` and `carry-round-<R>.json`.'
}

@test "#1937 AC11: the CADENCE refusal in full — decide sequence first, held attest, never the fresh mint" {
  load_arms
  contains "$arms" '**The CADENCE refusal, in full.** First the *Decide subagent brief*'"'"'s sequence, unchanged.'
  contains "$arms" 'mint a fresh `--findings-tree`, dispatch a new round-mode panel, dispatch a decide subagent over its aggregate, and consolidate with the fresh `--findings-tree` and the **held** `--gate-attest`, or with it omitted — never the fresh mint.'
  contains "$arms" 'The other recovery, discarding the fix and re-consolidating, dispatches no panel.'
}

@test "#1937 AC12: arm caps and the stall retry are separate" {
  load_arms
  contains "$arms" 'Each arm'"'"'s cap is its own, and never the stall retry.'
  contains "$arms" 'for a `carry-redispatch`, after the snapshot restore — and a recovery dispatch neither consumes nor resets it.'
  contains "$arms" 'A verdict that validates but is not `ok` is never a stall.'
}

@test "#1937 AC13: the panel brief recovers plan exit 2, a wrong worktree and an empty excerpt inside its own dispatch" {
  load_panel_brief
  contains "$panel" '**Recover inside the dispatch before returning a non-`ok` verdict.**'
  contains "$panel" 'a `plan` **exit 2** is your own malformed invocation: fix it and re-run once, as *A non-zero `plan` exit is never a scope* says. Return `plan-failed` only on exit 1, exit 3 or a second exit 2;'
  contains "$panel" 'Return `wrong-worktree-root` only when the re-planned descriptor still names the wrong root;'
  contains "$panel" 'apply *An empty excerpt is not always a stop*, and re-confirm `worktree_root`, before returning `empty-excerpt`.'
  contains "$panel" 'Steps 1–5 are `round` mode. A `carry-repair` handoff takes *Carry modes* below instead; a `carry-redispatch` handoff runs steps 1–5 with the changes *Carry modes* names.'
}

@test "#1937 AC14: carry-repair rebuilds the accounting from the lines and leaves the aggregate untouched" {
  load_panel_brief
  contains "$panel" '**`carry-repair`** dispatches no reviewers.'
  contains "$panel" 'rebuild `<work-dir>/carry-round-<R>.json` from those lines, and leave `findings-round-<R>.json` byte-unchanged.'
  contains "$panel" 'When the lines cannot produce a valid accounting, return `failed` / `carry-unconfirmed`.'
}

@test "#1937 AC15: carry-redispatch writes its own file, merges once, and re-assembles the accounting from every line" {
  load_panel_brief
  contains "$panel" '**`carry-redispatch`** runs steps 1–5 with an **empty** scope and a verify file naming only `carry_entries`'
  contains "$panel" 'First project the `verify-<R>.json` entries that `carry_entries` names into `<work-dir>/verify-<R>-carry.json` with `jq`; never write `verify-<R>.json`, which stays the loop'"'"'s carry.'
  contains "$panel" 'Step 1 then plans with `--prior-tree <tree_id>` in place of `<delta_base>`, so the delta is empty, and `--fix-verification <work-dir>/verify-<R>-carry.json`, and never adds `--final`.'
  contains "$panel" 'Steps 3 and 4 keep their re-dispatch and quoted-heredoc rules on these paths:'
  contains "$panel" 'write their output to `<work-dir>/findings-round-<R>-carry.json`, merge it into `findings-round-<R>.json` (`jq -s '"'"'add'"'"'`) once, atomically'
  contains "$panel" 're-assemble `carry-round-<R>.json` from every line in that file'
  contains "$panel" 'Never retype or reword a finding.'
}

@test "#1937 AC16: Recover by ground points at the carry modes and no longer assumes the lines are in context" {
  load_carry_section
  lacks "$carry" 'its per-entry lines are in your context'
  lacks "$carry" 'you then merge the two arrays into'
  contains "$carry" 'rebuild `carry-round-R.json` from them with the panel brief'"'"'s `carry-repair` mode'
  contains "$carry" 'the panel brief'"'"'s `carry-redispatch` mode merges the two arrays into `findings-round-R.json`'
}

# --- #2025: the risk subagent -------------------------------------------------
#
# One test per acceptance criterion of #2025 that lives in prose, anchored like
# the rest. The contract and validator half is tests/round-handoff.bats.

load_risk_brief() {
  riskb="$(section_of "$PROTO" '#### Risk subagent brief' '#### |### |## ' | squeeze)"
  [ -n "$riskb" ]
}
load_risk_pass() {
  riskp="$(section_of "$PROTO" '### The risk pass — assess every blocking finding before consolidating (#1921)' '### |## ' | squeeze)"
  [ -n "$riskp" ]
}

@test "#2025 AC1: the Risk subagent brief sits once inside the Round subagents section, outside every frozen span" {
  [ "$(grep -cxF '#### Risk subagent brief' "$PROTO")" -eq 1 ]
  load_section
  contains "$section" '#### Risk subagent brief'
  local brief_line tail_line
  brief_line="$(grep -nxF '#### Risk subagent brief' "$PROTO" | cut -d: -f1)"
  tail_line="$(grep -n '^<!-- /moved: ' "$PROTO" | tail -1 | cut -d: -f1)"
  [ "$brief_line" -gt "$tail_line" ]
  load_risk_brief
  contains "$riskb" 'is *The risk pass* above and `reference/residue.md` § *1. Assess every residual blocker*, and is restated by neither'
  lacks "$riskb" 'is exactly one of the four anchors'
}

@test "#2025 AC2: round-risk ships as a plugin agent with no Agent tool, dispatched in the foreground" {
  [ -f "$AGENTS/round-risk.md" ]
  [ "$(grep -cx 'name: round-risk' "$AGENTS/round-risk.md")" -eq 1 ]
  [ "$(grep -cx 'tools: Read, Write, Grep, Glob, Bash' "$AGENTS/round-risk.md")" -eq 1 ]
  lacks "$(grep '^tools:' "$AGENTS/round-risk.md")" 'Agent'
  contains "$(squeeze < "$AGENTS/round-risk.md")" '*Risk subagent brief*'
  load_risk_brief
  contains "$riskb" 'The conductor dispatches `subagent_type: round-risk`, in the foreground (`run_in_background: false`), one fresh subagent per job; the risk subagent dispatches nothing.'
  load_section
  contains "$section" '- the decide subagent dispatches nothing; - the risk subagent dispatches nothing.'
  contains "$section" 'so the four kinds ship as plugin agents:'
  contains "$section" '`development/agents/round-risk.md`'
  contains "$(squeeze < "$REPO_ROOT/ARCHITECTURE.md")" 'The four subagent kinds ship as **plugin agents**'
}

@test "#2025 AC3: the threshold decides whether a risk subagent runs at all" {
  load_risk_brief
  contains "$riskb" '**Off** or **ignored**, or **hook mode**: dispatch no risk subagent and pass no `--risk`; ignored keeps its narration line and PR Summary note.'
  contains "$riskb" '**On**, in step mode: dispatch it every round, the promotion sub-loop'"'"'s rounds and the closing sweep included.'
}

@test "#2025 AC4: the three-part sequencing rule" {
  load_risk_brief
  contains "$riskb" '1. Dispatch the risk subagent only after reading an `ok` decide verdict for the round'"'"'s latest decide dispatch.'
  contains "$riskb" '2. Pass `--risk` only with the `risk_file` of an `ok` risk verdict whose dispatch came after that decide verdict.'
  contains "$riskb" '3. Whenever the aggregate changes after a risk dispatch — a fresh decide dispatch (the CADENCE sequence) or a carry recovery'"'"'s merge — re-dispatch the risk subagent before the next invocation that passes `--risk`.'
}

@test "#2025 AC5: the risk handoff and the clear before every risk dispatch" {
  load_risk_brief
  contains "$riskb" 'Write `handoff-<R>-risk.json` with `round-handoff.zsh write-handoff`: `aggregate_findings_file` the file the round passes as `--findings-file` (*Risk pass, then consolidation* above; on a promotion sub-loop'"'"'s round 1, the seeded file, built in the work-dir),'
  contains "$riskb" 'and `tree_id` the round'"'"'s `T`.'
  contains "$riskb" 'Delete `<work-dir>/verdict-<R>-risk.json` and `<work-dir>/risk-<R>.json`. A delete that fails is report-and-stop.'
}

@test "#2025 AC6: the risk subagent checks its tree, assesses afresh and writes the risk file once, atomically" {
  load_risk_brief
  contains "$riskb" '`git -C <worktree_root> rev-parse --show-toplevel` must print that path. If it does not, write no risk file, and write a `failed` / `wrong-worktree-root` verdict with `round-handoff.zsh write-verdict`, carrying `risk_file` and `assessed_count` both `null`.'
  # #2033: writing the verdict is itself a write, so step 1 must never forbid
  # it — a wrong-root subagent that writes nothing reads as a stall.
  lacks "$riskb" 'write nothing and return'
  contains "$riskb" 'afresh, never copied from an earlier round, with `p`, `impact` and both rationales'
  contains "$riskb" '**Write `<work-dir>/risk-<R>.json` once, atomically**, in the #1920 shape — the identity verbatim, a digit-string `line` as the number it spells, `[]` when nothing is eligible — to a temporary file in the work-dir, then `mv` it into place.'
  contains "$riskb" 'When you cannot read or parse the aggregate, or cannot assess an eligible finding, write no risk file and return `failed` / `assessment-failed`.'
  contains "$riskb" 'The risk subagent edits no repository file, and never commits, pushes or runs the gate.'
}

@test "#2025 AC7: the risk verdict holds only the risk file and its count" {
  load_risk_brief
  contains "$riskb" '`ok` with `cause: null`, `risk_file` = `<work-dir>/risk-<R>.json` and `assessed_count` the number of entries in it.'
  contains "$riskb" 'A `failed` verdict carries `risk_file` and `assessed_count` both `null`.'
}

@test "#2025 AC8: the conductor passes the risk file on unopened and narrates from the verdict" {
  load_risk_brief
  contains "$riskb" 'pass the verdict'"'"'s `risk_file` as `--risk` unopened, and the handoff'"'"'s `aggregate_findings_file` as `--findings-file`. Open neither file.'
  contains "$riskb" 'Narrate from `assessed_count`, the `risk-<R>.json` path, the status JSON and the progress block'
}

@test "#2025 AC9: a not-ok risk verdict is report-and-stop, the stall retry is unchanged, and there is no fallback to off" {
  load_risk_brief
  contains "$riskb" 'A risk verdict that validates but is not `ok` is report-and-stop.'
  contains "$riskb" 'The stall retry above applies unchanged: one fresh re-dispatch on a `read-verdict` exit 3, then report-and-stop.'
  contains "$riskb" 'Never fall back to threshold off, and never invoke the loop without `--risk` while the threshold is on.'
}

@test "#2025 AC10: a loop exit 2 naming --risk gets one fresh risk dispatch carrying the stderr line" {
  load_risk_brief
  contains "$riskb" 'make one fresh risk dispatch whose prompt carries that stderr line verbatim, then re-invoke the same round with the same flags. A second such exit 2 in the same round is report-and-stop.'
}

@test "#2025 AC11: the risk-pass section is edited at exactly its three named places" {
  load_risk_pass
  contains "$riskp" 'While the threshold is on, the risk subagent (*Risk subagent brief* below) makes the assessment this section describes, and the conductor dispatches it and passes `--risk`.'
  contains "$riskp" 're-dispatch the risk subagent over the merged aggregate before you re-invoke.'
  lacks "$riskp" 'assess the merged findings too and rewrite'
  contains "$riskp" 'make one fresh risk dispatch whose prompt carries that stderr line verbatim, then re-invoke the same round with the same flags; a second such exit 2 in the same round is report-and-stop.'
  lacks "$riskp" 'fix it and re-invoke the same round with the same flags'
  # untouched: the section's opening rule
  contains "$riskp" '**Assess the round'"'"'s blockers against `corner_case_risk_threshold` after the decided pass and before the step-2 invocation.**'
}

@test "#2025 AC12: the decide brief no longer reserves a risk-pass read" {
  load_decide_brief
  lacks "$decide" 'except through the risk pass'
}

@test "#2025 AC13: promotion.md and the Round subagents section name the risk subagent for the sub-loop" {
  local close_line after
  close_line="$(grep -n '^<!-- /moved: suggestion-promotion -->$' "$PROMO" | cut -d: -f1)"
  [ -n "$close_line" ]
  after="$(tail -n +"$((close_line + 1))" "$PROMO" | squeeze)"
  contains "$after" '**panel**, **decide**, **risk** and **fix** subagents'
  load_section
  contains "$section" 'rounds dispatch the same panel, decide, risk and fix subagents'
}
