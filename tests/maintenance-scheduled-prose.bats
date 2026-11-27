#!/usr/bin/env bats
#
# #3214: under --scheduled a /development:maintenance run never asks. Every
# prompt of the skill has a documented path in reference/scheduled.md, and this
# suite pins those rules, the flag's wiring in SKILL.md (Phase 0, the resume
# entry, Phase 3, Phase 8, Phase 9), the bugs concern's clause and the
# ARCHITECTURE.md entry. The sweep asserts that every prompt in the skill sits
# next to an "under `--scheduled`" clause, so a prompt added later without one
# fails here.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/maintenance"
  SKILL="$SKILL_DIR/SKILL.md"
  SCHEDULED="$SKILL_DIR/reference/scheduled.md"
  BUGS="$SKILL_DIR/reference/bugs.md"
  PR_CYCLE="$SKILL_DIR/reference/pr-cycle.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  [ -f "$SCHEDULED" ]
}

# File $1 whitespace-collapsed, so a needle may span a line break.
flat() {
  tr -s '[:space:]' ' ' < "$1"
}

# The prompt lines of file $1 that have no "under `--scheduled`" clause within
# 15 lines either side, one "<file>:<line>" per line. A prompt is a mention of
# AskUserQuestion or "ask the user".
unclaused_prompts() {
  awk -v f="$1" '
    { line[NR] = $0 }
    tolower($0) ~ /askuserquestion|ask the user/ { prompt[NR] = 1 }
    tolower($0) ~ /under `--scheduled`/ { clause[NR] = 1 }
    END {
      for (n = 1; n <= NR; n++) {
        if (!(n in prompt)) continue
        ok = 0
        for (d = -15; d <= 15; d++) if ((n + d) in clause) { ok = 1; break }
        if (!ok) print f ":" n
      }
    }
  ' "$1"
}

# ---- reference/scheduled.md: the rule for each prompt -----------------------

@test "scheduled.md: a missing tool or runtime skips the work that needed it, is reported, and nothing is installed" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "**A missing tool or runtime → skip the work that needed it and report.**"
  contains "$text" "nothing is installed"
  contains "$text" "never installs a tool or a runtime"
}

@test "scheduled.md: an earlier run's checkpoint is discarded when stale, the run starts fresh, and it is reported" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "**An earlier run's checkpoint → discard it past the age its row below gives, start fresh and report; a younger one ends the run untouched, reported.**"
  contains "$text" "never resumes"
  contains "$text" '`checkpoint.zsh clear`, then Phase 1; report the discarded checkpoint'
}

@test "scheduled.md: any other prompt takes the choice that changes nothing, reported" {
  contains "$(flat "$SCHEDULED")" "**Any other prompt → the choice that changes nothing, reported.**"
  contains "$(flat "$SCHEDULED")" "Each is reported: the Phase 9 summary gets one line per prompt that took its scheduled path, naming the prompt and what the run did instead."
}

@test "scheduled.md: every prompt site has its row" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "| Resume entry, a checkpoint and neither \`--resume\` nor \`--fresh\` |"
  contains "$text" "| Phase 3 state pre-flight, exit 1 (a tool is not installed) |"
  contains "$text" "| Phase 3 state pre-flight, exit 2 (R.4) |"
  contains "$text" "| Phase 8 step 8, the post-merge pre-flight exits 1 or 2 (R.4) |"
  contains "$text" "| Phase 8 pre-dispatch hook, the runtime is missing |"
  contains "$text" "never \`install\`"
  contains "$text" "| asks: resume or start fresh | \`age=\` beyond 6h, since a live run saves at every stage transition:"
  contains "$text" "Younger: a run may still be going, so end this run with the checkpoint untouched and report its last phase and age."
  contains "$text" "Under \`--dry-run\`, the checkpoint is left as it is"
}

@test "scheduled.md: approval stays whatever the repo declares" {
  contains "$(flat "$SCHEDULED")" "never approves its own work — approval stays whatever the repo declares"
}

@test "scheduled.md: the budget's caps, its overrides and its failure arms" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "security 5, dependencies 5, bugs 5, codequality 10, topic 10"
  contains "$text" "Without \`--scheduled\` only the bugs cap applies"
  contains "$text" "The open-queue cap is 5"
  contains "$text" "yq -o=json '.budget' .maintenance.yml > <scratch>/budget.json"
  contains "$text" "\`--batch=N\` then applies to \`run\` alone"
  contains "$text" "pass \`--queue <the queue cap>\`, so no new PR opens while the queue cannot be read"
  contains "$text" "a window that cannot be read has to count as closed"
  contains "$text" "report its stderr and call it again without the refused part — the defaults for a refused block"
  contains "$text" "Any other exit 2 is your own malformed call: fix it and re-run once."
  contains "$text" "[[ -n \"\$caps\" ]] || caps='{}'"
  contains "$text" "caps=\"\$(jq -c 'if . == null then {} elif type == \"object\" then (if .caps == null then {} else .caps end) else . end' <scratch>/budget.json)\" || caps=''"
  contains "$text" "A \`budget:\` block that is not a mapping — \`budget: off\`, say — reaches the script as it is, so the script refuses it"
  contains "$text" "Pass \`--scheduled\` and \`--queue\` only under \`--scheduled\`, and \`--cutoff-epoch\` only when \`MAINTENANCE_CUTOFF_EPOCH\` is set"
}

@test "scheduled.md: opens_pr is derived from isolation and advisory" {
  contains "$(flat "$SCHEDULED")" "\`true\` unless the group's \`isolation\` is \`false\` (a vendor-PR stage that only triages or merges standing PRs) or it is \`advisory\`"
}

@test "scheduled.md: the cutoff is checked before each group and a group in progress finishes" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "the budget is checked again before each group of \`run\` starts"
  contains "$text" "A group in progress — its agent spawned — always finishes"
  contains "$text" "the cutoff is only ever checked between groups"
  contains "$text" "and so is each conflicting bot PR before the standing-PR slot rebases it, with the group \`{\"tool\": \"conflicting_bot_pr\", \"concern\": \"codequality\", \"opens_pr\": false}\`"
  contains "$text" "Count the queue afresh, as section 2 does, and pipe the one group through the same script."
  contains "$text" "The same failure arms as section 2 apply."
  contains "$text" "add to \`<q>\` each stage of \`phase8-stages\` whose \`pr\` is set and whose \`status\` is not \`merged\`"
  contains "$text" "and each PR the \`Bugs\` block records and does not record as merged"
  contains "$text" "the queue cap holds within one run only; the Phase 9 summary says so"
  contains "$text" "for a refused cutoff, under \`--scheduled\`, start nothing new and record every group \`deferred\` by \`cutoff\`"
}

@test "scheduled.md: under --scheduled a full queue stops a bug fix but not an analysis" {
  contains "$(flat "$SCHEDULED")" "with the queue full no fix starts, while analyses, which open no PR, go on"
}

@test "scheduled.md: where the budget's figures come from, and what is read when" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "Every run applies the budget, attended or not, once Phase 8 holds the concern-ordered queue and before the \`--batch=N\` cap."
  contains "$text" "A repo overrides any of them in the optional \`budget:\` block of \`.maintenance.yml\`"
  contains "$text" "Read it once per run, before the first budget check — Stage 0's when one runs, else Phase 8's — and only when \`.maintenance.yml\` exists at the repo root"
  contains "$text" "With no \`.maintenance.yml\`, or no \`budget:\` block, every default holds."
  contains "$text" "When \`yq\` is missing or fails on the file, every default holds too, and the summary reports why."
  contains "$text" "\`--caps\` is the block's \`caps\` object, \`{}\` when it has none; \`--queue-cap\` is its \`queue_cap\`, left out when it has none."
  contains "$text" "The bugs cap \`reference/bugs.md\` counts against is the same figure: \`caps.bugs\`, else 5."
  contains "$text" "\`--fresh\` is accepted, and clears a checkpoint of any age."
}

@test "scheduled.md: a budget that cannot be applied never lets a scheduled run go uncapped" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "Exit 1 (jq) decided nothing, so report its stderr."
  contains "$text" "So did an exit 2 that survives that re-run, and so does the queue SKILL.md Phase 8's \`order-groups.zsh\` fallback (its exit 2 or 1) leaves"
  contains "$text" "its groups carry no \`concern\`, so never call the script on them; report the \`order-groups.zsh\` stderr instead."
  contains "$text" "Without \`--scheduled\`, work the queue as it is"
  contains "$text" "Under \`--scheduled\`, start no group: record each \`deferred\` with no \`deferred_by\`"
}

@test "scheduled.md: a deferred group or bug is not started, and a deferral never counts against a cap" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "A group it defers is not started: record it \`deferred\` with that \`deferred_by\`, and go on to the next, which is checked the same way."
  contains "$text" "Once the cutoff has passed every later group is deferred by \`cutoff\` too."
  contains "$text" "The bugs concern has no planner groups, so \`reference/bugs.md\` keeps its own count against the bugs cap."
  contains "$text" "A bug it defers is listed in the \`Bugs\` block with its \`deferred_by\` and does not count against the cap."
}

# ---- SKILL.md wiring ---------------------------------------------------------

@test "SKILL.md: each prompt site carries its scheduled path" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "It also turns on the whole run budget (\`reference/scheduled.md\` § 2): the per-concern caps, the open-queue cap and the cutoff."
  contains "$text" "Under \`--scheduled\` there is no question: its \`age=\` picks the path \`reference/scheduled.md\` § 1 gives, the \`--fresh\` path or ending this run with the checkpoint untouched, and either is reported."
  contains "$text" "Under \`--dry-run\` neither applies: the dry run leaves the checkpoint as it is."
  contains "$text" "Under \`--scheduled\`, skip that language instead — drop it from \`supported\` and record it in \`unsupported\`, noted \`skipped under --scheduled\` — and move every \`supported_topics\` entry that requires it to \`unsupported_topics\`, noted \`marker present but required language <lang> was skipped under --scheduled\`; report the stderr, and go on with the others."
  contains "$text" "Under \`--scheduled\`, no question: skip that language as for exit 1 and report the blockers."
  contains "$text" "Under \`--scheduled\` none of this runs: the language is skipped, with every topic that requires it, and its blockers reported"
  contains "$text" "the group is not started, and neither is any later group of its concern for the same target. Record each \`deferred\` and report the hook's \`label\` as missing"
  contains "$text" "Under \`--scheduled\` there is no question and no halt: on exit 1 or 2 the language's remaining stages, and those of every topic that requires the language, are not started, each is recorded \`deferred\`, and the stderr or blockers are reported"
}

@test "SKILL.md: Phase 0 documents --scheduled and refuses it with --resume" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "- \`--scheduled\` — the run nobody watches (#3214). It **never asks**"
  contains "$text" "an earlier run's checkpoint past the age § 1 gives is discarded and reported, a younger one ends the run untouched (a run may still be going)"
  contains "$text" "Restore the **recorded flags**, \`--scheduled\` included: a resumed run keeps its original scope"
  contains "$text" "When \`--scheduled\` and \`--resume\` are both passed, halt with: \"--scheduled never resumes an interrupted run; drop --resume.\""
}

@test "SKILL.md: Phase 8 applies the run budget before the batch cap, on every run" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "**Run budget — every run (#3214).** Before the batch cap"
  contains "$text" "scripts/apply-run-budget.zsh"
  contains "$text" "scripts/count-open-queue.zsh"
  contains "$text" "check the budget again **before each group starts**"
  contains "$text" "On a resume, *Resuming into Phase 8* reconciles the recorded stages first, and only groups with no recorded stage go through the budget: a recorded stage is never re-split."
  contains "$text" "\`status: deferred\` (with or without \`deferred_by\`) → keep it deferred; a resumed run keeps its original scope, so the group is not decided again."
  contains "$text" "Record each deferred group as a \`deferred\` stage in \`phase8-stages\`, with its \`deferred_by\`"
  contains "$text" "the rest of this phase works \`run\` alone"
  contains "$text" "and so is a group the run budget defers, with its \`\"deferred_by\"\` beside the status"
  contains "$text" "When it defers Stage 0, nothing is pushed or opened and the plugin is not re-invoked"
}

@test "SKILL.md: Stage 0 is checked as a codequality group that opens a PR, and the batch cap works on run" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "Under \`--scheduled\`, check the budget first, as \`reference/scheduled.md\` § 3 checks a group, with the group \`{\"tool\": \"coverage\", \"concern\": \"codequality\", \"opens_pr\": true}\`."
  contains "$text" "When \`--batch\` is absent the batch is all of \`run\`, so this step is a no-op."
  contains "$text" "Sort the budget's \`run\` list by \`priority_score\` (descending) and keep the **top N**"
  contains "$text" "Without \`--scheduled\` only the bugs cap applies, so an attended run keeps every other group."
  contains "$text" "the open-queue cap and the cutoff. Without it only the bugs cap applies."
  contains "$text" "Record each \`deferred\` and report the hook's \`label\` as missing (\`reference/scheduled.md\` § 1)."
}

@test "scheduled.md: the queue is counted on its own call, and a group reaches the script through a file" {
  local text
  text="$(flat "$SCHEDULED")"
  contains "$text" "Under \`--scheduled\` the run **never asks**: each place the skill would otherwise ask has its path below."
  contains "$text" "Under \`--scheduled\`, count the open queue first, as its own call:"
  contains "$text" "The caps object reaches the script through \`\$caps\`, read from \`<scratch>/budget.json\` in the same command, and is never pasted into the command line"
  contains "$text" "Write the group, as JSON, to \`<scratch>/group.json\` with the Write tool first, never inline in the command"
  contains "$text" "A group deferred with no \`deferred_by\` — here, or by § 1's missing runtime or failed pre-flight, never by \`--batch=N\` — is listed in the Phase 9 summary with its reason instead."
}

@test "Phase 6: a full queue stops only the dispatch of a language that can start the improver" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "A \`queue\` deferral does not stop the dispatch of a topic, or of a language whose kept payload carries \`dispatch_mode: \"auxiliary\"\`"
  contains "$text" "On a \`queue\` deferral no language dispatch that can start an improver is made: a language dispatched as \`\"primary\"\` is not dispatched"
  contains "$text" "The payload does not record whether its dispatcher's coverage pre-flight will start the improver"
  contains "$(flat "$SCHEDULED")" "it stops the dispatch of a language dispatched as \`\"primary\"\`, which can start the improver"
  contains "$(flat "$PR_CYCLE")" "a full queue stops its Phase 6 dispatch"
  contains "$(flat "$ARCH")" "not planned at all for a language a full queue keeps from its Phase 6 dispatch"
  run ! grep -qF "which only a \`cutoff\` deferral stops" "$SCHEDULED"
  run ! grep -qF "A \`queue\` deferral does not stop a dispatch," "$SKILL"
}

@test "SKILL.md: a conflicting bot PR the cutoff stops is deferred, never escalated or dropped" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "with the group \`{\"tool\": \"conflicting_bot_pr\", \"concern\": \"codequality\", \"opens_pr\": false}\`: a rebase opens no PR, so only the cutoff can defer it."
  contains "$text" "A PR not started because of the cutoff is left untouched and is no stage of \`phase8-stages\`, only a line of Phase 9's *Conflicting bot PRs remediated* block"
  contains "$text" "it is either merged/armed, \`escalated\` with a concrete reason, or, under \`--scheduled\`, \`deferred\` by \`cutoff\`."
  contains "$text" "not rebased: the window closed at <time>; the next run picks it up"
}

@test "SKILL.md: a topic whose required language a scheduled run skipped is never dispatched" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "| required language skipped under \`--scheduled\` (Phase 3 pre-flight) | \`marker present but required language <lang> was skipped under --scheduled\` |"
  contains "$(flat "$SCHEDULED")" "skip that language and the topics that require it as for exit 1"
  contains "$(flat "$SCHEDULED")" "the remaining stages of the language and of every topic that requires it are not started"
}

@test "SKILL.md: Phase 9 lists what the budget deferred and every prompt's scheduled path" {
  local text
  text="$(flat "$SKILL")"
  contains "$text" "⏸ Deferred by the budget — not processed (K):"
  contains "$text" "🌙 Scheduled run — no questions asked (K):"
  contains "$text" "⏸ Deferred under --scheduled — not processed (K):"
  contains "$text" "runtime <label> missing | pre-flight failed: <stderr or blockers>"
}

@test "bugs.md: the bugs cap follows the budget and the scheduled checks" {
  local text
  text="$(flat "$BUGS")"
  contains "$text" "\`budget.caps.bugs\` (\`reference/scheduled.md\` § 2)"
  contains "$text" "Under \`--scheduled\` the cutoff and the open queue are also checked before each bug starts"
}

@test "pr-cycle.md and ARCHITECTURE.md state the budget" {
  contains "$(flat "$PR_CYCLE")" "## Why a scheduled run has a budget, and what the open queue counts"
  contains "$(flat "$PR_CYCLE")" "It is checked between groups, never inside one: a group whose agent has started finishes"
  local text
  text="$(flat "$ARCH")"
  contains "$text" "### The run budget and \`--scheduled\` (#3214)"
  contains "$text" "Vendor PRs never count"
}

# ---- the sweep ---------------------------------------------------------------

@test "sweep: every prompt in the maintenance skill sits next to an under --scheduled clause" {
  local f out="" n=0
  for f in "$SKILL" "$SKILL_DIR"/reference/*.md; do
    [ "$f" = "$SCHEDULED" ] && continue
    out+="$(unclaused_prompts "$f")"
    n=$((n + $(grep -ciE 'askuserquestion|ask the user' "$f" || true)))
  done
  [ -z "$out" ] || { printf 'prompts without a scheduled clause:\n%s\n' "$out"; return 1; }
  # the sweep has something to sweep: the skill's known prompts are found
  [ "$n" -ge 6 ]
}

@test "sweep: a prompt with no clause nearby is reported, and one with a clause is not" {
  local doc="$BATS_TEST_TMPDIR/doc.md" i
  { printf 'Ask the user via `AskUserQuestion` which way.\n'
    for i in $(seq 1 20); do printf 'filler %s\n' "$i"; done
    printf 'Then ask the user again.\n'
    printf 'Under `--scheduled` there is no question.\n'
  } > "$doc"
  [ "$(unclaused_prompts "$doc")" = "$doc:1" ]
}
