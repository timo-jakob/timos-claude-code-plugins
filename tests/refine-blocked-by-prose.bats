#!/usr/bin/env bats
#
# Refinement and splitting always declare prerequisites as native blockedBy
# edges (#2947). The two scripts have their own suites (add-blocked-by-edges.bats,
# file-split-children.bats); these needles pin the prose that makes the
# refiner produce the edges and the conductor add them:
#
#   - ARCHITECTURE.md's Issue-dependency model states the rule once;
#   - issue-refiner returns proposed_blocked_by and proposed_split[].blocked_by;
#   - refine-issue shows them with the draft, adds them after Step 3 through the
#     script (pointing at ARCHITECTURE.md rather than restating it), lists them
#     in Step 6's trail, and adds them without a prompt in the follow-up and
#     chained modes;
#   - story-spec/v1 still carries no dependencies.
#
# Each needle is anchored by content, never by line (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  REFINER="$REPO_ROOT/development/agents/issue-refiner.md"
  REFINE="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
}

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# The lines of the section headed exactly $1 in $2, up to the next heading of
# the same or a higher level; fenced lines are never read as headings.
section() {
  awk -v h="$1" '
    /^```/ { fence = !fence }
    !fence && $0 == h { f = 1; match(h, /^#+/); lvl = RLENGTH; next }
    f && !fence && /^#+ / { match($0, /^#+/); if (RLENGTH <= lvl) exit }
    f' "$2"
}

@test "ARCHITECTURE.md's Issue-dependency model states that refinement and splitting declare prerequisites natively" {
  local s
  s="$(section '## Issue-dependency model (#583)' "$ARCH" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" '**Refinement and splitting declare prerequisites natively (#2947).**'
  contains "$s" 'becomes a native edge, never prose alone, so the re-gate passes check 3 with no manual `gh api` call.'
  contains "$s" 'copies each **open** blocker of the original onto every child whose `blocked_by` names no sibling'
  contains "$s" 'no edge is inferred (file overlap stays E2'"'"'s to serialise), and refinement never removes one.'
}

@test "issue-refiner returns proposed_blocked_by, excluding context-only references" {
  local f
  f="$(flat "$REFINER")"
  contains "$f" '- **`proposed_blocked_by`** (#2947) — the issue references (`#N` or `owner/repo#N`) of **every prerequisite the prose names as one**'
  contains "$f" 'Leave out a reference the prose marks as context only'
  contains "$f" 'never infer a prerequisite the prose does not state'
  grep -qF '"proposed_blocked_by": ["#412"],' "$REFINER"
}

@test "issue-refiner's proposed_split children carry blocked_by: a sibling index or a reference" {
  local f
  f="$(flat "$REFINER")"
  contains "$f" '`[{ "title", "body", "files", "blocked_by" }, …]`'
  contains "$f" 'the **0-based index** of a sibling child in this array or an issue reference (`#N` / `owner/repo#N`)'
  contains "$f" 'Never make the sibling order cyclic.'
}

@test "refine-issue shows proposed_blocked_by with the draft and adds the edges after Step 3 through one script" {
  local s f
  f="$(flat "$REFINE")"
  contains "$f" '- **`proposed_blocked_by`** (#2947) — the prerequisites Step 3 will add as native `blockedBy` edges, shown with the draft and approved with it.'
  s="$(section '## Step 3 — write back the approved rewrite (human-authored)' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" '**Then declare the prerequisites natively (#2947).**'
  contains "$s" '(ARCHITECTURE.md, *Issue-dependency model*)'
  contains "$s" '"<skill-base-dir>/scripts/add-blocked-by-edges.zsh" --repo "$REPO" --issue <N> --refs <refs.json>'
  contains "$s" 'Every mode runs this step the same way, without a prompt'
}

@test "refine-issue's Step 6 trail lists the edges added" {
  local s
  s="$(section '## Step 6 — the before/after comment trail' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" 'the `blockedBy` edges Step 3 added'
}

@test "the follow-up and chained modes add the edges without a prompt" {
  local s
  s="$(section '## Unattended follow-up mode (`--follow-up`, #2588)' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" 'Step 3'"'"'s native `blockedBy` edges (#2947) are added as written, with no prompt.'
  s="$(section '## Chained refinement mode (`--chained-from`, #2939)' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" 'the `proposed_blocked_by` edges Step 3 adds (#2947) included.'
}

@test "the split plan carries blocked_by, and the guardrail routes every edge through the scripts" {
  local f
  f="$(flat "$REFINE")"
  contains "$f" '"files": ["…"], "blocked_by": [0, "#52"] }'
  contains "$f" 'Step 3'"'"'s `scripts/add-blocked-by-edges.zsh` and `file-split-children.zsh`, never raw `gh api` calls.'
}

@test "story-spec/v1 still carries no dependencies" {
  grep -qF '**No `dependencies` in the block**' "$REFINE"
  contains "$(flat "$REFINER")" '**No `dependencies` field** — dependencies are GitHub-native `blockedBy` (#583)'
}

@test "refine-issue's Step 3 edge exits: a refused or failed edge is relayed and the re-gate judges the story" {
  local s
  s="$(section '## Step 3 — write back the approved rewrite (human-authored)' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" 'Right after the edit, write the approved turn'"'"'s `proposed_blocked_by` to a temporary file outside the repository (`[]` when the turn has none) and run:'
  contains "$s" 'Exit 4 — an edge was refused (a self-reference, a cycle, or one the cycle check could not prove safe), and exit 5 — an edge could not be resolved or written: relay each such edge'"'"'s `detail` in one line, go on to Step 4, and let the re-gate judge the story (a refused prerequisite stays a check-3 objection, and Step 5'"'"'s loop-back takes it).'
}

@test "refine-issue re-runs a partial split only when every filed child is attached" {
  local s
  s="$(section '### Step 2 — size the draft before approval (#2589)' "$REFINE" | tr '\n' ' ' | tr -s ' ')"
  contains "$s" 'When every `filed` entry is `linked: true` — an edge that could not be added, say — re-run it once with the same plan: it reuses the filed children and adds only the missing edges.'
  contains "$s" 'Never re-run it when a `filed` entry is `linked: false`: that child would be filed a second time.'
  contains "$s" 'Relay which child and its triggers, or the `error`, and run another round to revise the split; the revised split is filed the same way.'
}

@test "issue-refiner's proposed_blocked_by is [] when there is none, and covers the gate's objection and the human's reply" {
  local f
  f="$(flat "$REFINER")"
  contains "$f" 'an issue the story must wait for, whether the current body, a gate objection ("declare #M as a blocked-by relationship") or the human'"'"'s reply names it.'
  contains "$f" '`[]` when there is none.'
}
