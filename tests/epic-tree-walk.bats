#!/usr/bin/env bats
#
# #2857 — resolve-issue's Epic flow walks a sub-issue tree of any depth. The
# reader (`read-sub-issues.zsh --tree`) is behaviour-tested in
# tests/read-sub-issues.bats and the telemetry `tree` member in
# tests/build-epic-telemetry-record.bats; this file pins the PROSE that consumes
# them — the conductor's per-step pointers in SKILL.md and the procedure in
# reference/epic-tree.md — by content, never by line number, plus the #2695
# assumption that refine-issue's split writes no `split-child` record.

load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
  TREE="$REPO_ROOT/development/skills/resolve-issue/reference/epic-tree.md"
  SPLIT="$REPO_ROOT/development/skills/refine-issue/scripts/file-split-children.zsh"
}

# a file flattened to one line, every whitespace run one space
flat() { tr -s '[:space:]' ' ' < "$1"; }

# the text of one `### ` section of SKILL.md, from its heading to the next
section() {
  awk -v h="$1" 'index($0, h) == 1 { f = 1; print; next } f && /^#{2,3} / { exit } f' "$SKILL"
}

# the text of one `## ` section of reference/epic-tree.md
tree_section() {
  awk -v h="$1" 'index($0, h) == 1 { f = 1; next } f && /^## / { exit } f' "$TREE" | tr -s '[:space:]' ' '
}

@test "#2857 E1 reads the tree with --tree, before the E1b gate" {
  local e1 read_line gate_line
  e1="$(section '### E1. ')"
  contains "$e1" '"<skill-base-dir>/scripts/read-sub-issues.zsh" --repo "$REPO" --tree <N>'
  lacks "$e1" '--repo "$REPO" --epic <N>'
  contains "$(printf '%s' "$e1" | tr -s '[:space:]' ' ')" 'its `leaf` nodes below the target, at any depth, are the children every later step works'
  read_line="$(grep -nF -- '--repo "$REPO" --tree <N>' "$SKILL" | head -1 | cut -d: -f1)"
  gate_line="$(grep -n '^### E1b\. ' "$SKILL" | cut -d: -f1)"
  [ -n "$read_line" ] && [ -n "$gate_line" ]
  [ "$read_line" -lt "$gate_line" ]
}

@test "#2857 E1b gates the leaves of the --tree read and never an inner node" {
  local e1b
  e1b="$(section '### E1b. ' | tr -s '[:space:]' ' ')"
  contains "$e1b" 'every open `leaf` of E1'"'"'s `read-sub-issues.zsh --tree` read, at any depth'
  contains "$e1b" 'an inner node is never passed to `story-readiness`'
  contains "$(section '### E1. ' | tr -s '[:space:]' ' ')" 're-read with the same `--tree` read, whose document replaces the first,'
  contains "$(tree_section '## E1b — gate leaves only')" \
    'An inner node is **never** passed to `story-readiness`, and E1b never gives an inner node `needs-refinement`'
  contains "$(tree_section '## E1b — gate leaves only')" \
    'An `undecomposed` node counts not ready.** The halt summary reports it as an undecomposed epic and tells the human to attach its children natively, or to run `/development:resolve-issue` on that node directly'
}

@test "#2857 an inner node counts READY by its open leaves, and with none open" {
  contains "$(tree_section '## E1b — gate leaves only')" \
    '**An inner node counts READY** when every open leaf under it is READY. An inner node with sub-issues but none open counts READY.'
}

@test "#2857 every node is named by its full path" {
  contains "$(flat "$TREE")" '**Name every node by its full path** wherever a summary, a halt comment or a park note names it'
  contains "$(flat "$TREE")" '`#12 → #231 → #251`'
  contains "$(tree_section '## E1b — gate leaves only')" 'the halt summary names it by its full path'
}

@test "#2857 a read_failed node halts E1 and is never gated as a fallback" {
  local e1
  e1="$(tree_section '## E1 — reading the tree')"
  contains "$e1" '**Exit 0 with any `read_failed` node** — halt at E1, before E1b.'
  contains "$e1" 'lists **every** `read_failed` node by its full path as a tooling failure'
  contains "$e1" 'its body is **never** gated as a story as a fallback'
  contains "$e1" '`e1_classification` is `halt_tree_read_error`'
}

@test "#2857 the depth limit's two exits: 4 stops with no fallback, 5 halts before any build" {
  local e1
  e1="$(tree_section '## E1 — reading the tree')"
  contains "$e1" '**Exit 4** — `RESOLVE_ISSUE_MAX_EPIC_DEPTH` is set to an invalid value. Stop the run before any work'
  contains "$e1" 'There is no fallback to the default limit'
  contains "$e1" '**Exit 5** — the tree is deeper than the limit in force. **Halt before any build**'
  contains "$e1" '`over_limit.path` (as a full path) and `over_limit.limit`'
  contains "$e1" '`e1_classification` is `halt_depth_exceeded`'
}

@test "#2857 E1's total: 0 machinery runs on the target only" {
  contains "$(flat "$TREE")" '**E1'"'"'s `total: 0` machinery runs on the target only.**'
  contains "$(flat "$TREE")" 'Neither runs below the target'
}

@test "#2857 foreign nodes are kept out of the gate and the build" {
  contains "$(tree_section '## E1b — gate leaves only')" \
    '**A `foreign` node** is left out of the gate and out of an inner node'"'"'s READY test'
  contains "$(tree_section '## E3 — build leaves')" '**Only leaves are built.**'
  contains "$(tree_section '## E4 and E5 — bottom-up')" '**An open `foreign` child keeps its parent open**'
}

@test "#2857 inherited edges: one precheck per open inner ancestor, target excluded" {
  contains "$(tree_section '## E3 — build leaves')" \
    'Before a leaf'"'"'s own step 0a, run `dependency-precheck.zsh` once for each open inner node on the leaf'"'"'s path, excluding the target. Any non-`PROCEED` decision parks the leaf exactly as a §0a dependency rejection does, and its comment names that ancestor and the ancestor'"'"'s open blockers.'
  contains "$(section '### E3. ' | tr -s '[:space:]' ' ')" \
    'run `dependency-precheck.zsh` once per open inner node on its path, target excluded'
  contains "$(tree_section '## E3 — build leaves')" \
    '**Escalation triage spans the tree.** The clean-stop triage'"'"'s `--children` is every open leaf in walk order, and each leaf'"'"'s `--deps` record carries in `blockers[]` its open inner ancestors'"'"' blockers too, so a leaf'"'"'s dependants are parked across the whole tree, including leaves under other inner nodes.'
}

@test "#2857 an inner node is never built and starts no story run" {
  contains "$(tree_section '## E3 — build leaves')" \
    'An inner node gets no branch, no PR and **no story run of its own**'
  contains "$(tree_section '## E3 — build leaves')" \
    'Every leaf'"'"'s story run is parented to the **target** epic'"'"'s run.'
}

@test "#2857 inner nodes close bottom-up on positive evidence, the target last" {
  local e45
  e45="$(tree_section '## E4 and E5 — bottom-up')"
  contains "$e45" '**Whenever every child of an open inner node is closed as completed — at the first read or after any close during the run — run its E4 and E5, and re-check its parent**, with the same positive-evidence rule as the target and before the next leaf branches.'
  contains "$e45" 'Close bottom-up: a node'"'"'s E5 runs before its parent'"'"'s, a dependant of an inner node branches only after that node closes, and **the target epic closes last**.'
  contains "$(section '### E4. ' | tr -s '[:space:]' ' ')" '**In a tree, E4 and E5 run bottom-up (#2857).**'
  contains "$(section '### E4. ' | tr -s '[:space:]' ' ')" 'Each inner node gets its own E4 (this same gate) and E5 inside E3, the target last; an open `foreign` child keeps its parent open, and a regression at any inner node stops the whole run as an E4 regression'
}

@test "#2857 an inner node's E4 regression stops the whole run" {
  local e45
  e45="$(tree_section '## E4 and E5 — bottom-up')"
  contains "$e45" '**An inner node'"'"'s E4 runs the target'"'"'s profile-blessed holistic gate.**'
  contains "$e45" '**stops the whole run** as an E4 regression (`failure_cause: e4_regression`)'
  contains "$e45" '**`detect`'"'"'s exit 1 and exit 3** at an inner node'"'"'s E4 halt the run exactly as they do at the target'"'"'s.'
}

@test "#2857 every SKILL.md step points at its epic-tree.md section" {
  local h
  for h in '§ E1 — reading the tree' '§ E1b — gate leaves only' '§ E2 — order across the tree' \
           '§ E3 — build leaves' '§ E4 and E5 — bottom-up'; do
    contains "$(flat "$SKILL")" "\`reference/epic-tree.md\` $h"
    grep -qxF "## ${h#§ }" "$TREE" || { echo "no heading for $h"; false; }
  done
}

@test "#2857 E1 branches on the root node's summary, and carries foreign nodes to the summary" {
  local e1
  e1="$(tree_section '## E1 — reading the tree')"
  contains "$e1" 'The root node'"'"'s `total` and `completed` are the `summary` E1'"'"'s table branches on, and the open `leaf` nodes below the target, at any depth, are the children every later step works.'
  contains "$e1" 'after a live backfill, the re-read is this same `--tree` read, and its document replaces the first for E1b to E5.'
  contains "$e1" 'It never halts the run, and E1 carries it to the run summary (E3), which lists every open one by its full path.'
}

@test "#2857 E1b gates every open leaf in one batch; one unready node builds nothing" {
  local e1b
  e1b="$(tree_section '## E1b — gate leaves only')"
  contains "$e1b" '`story-readiness` runs on **every open `leaf` of the whole tree**, in one parallel batch.'
  contains "$e1b" 'One unready leaf or one `undecomposed` node anywhere in the tree means the epic is not ready: build nothing.'
}

@test "#2857 E2 orders the flattened leaf set, an inner node's edge holding every leaf under it" {
  local e2
  e2="$(tree_section '## E2 — order across the tree')"
  contains "$e2" 'Order the **leaves of the whole tree** by their native `blockedBy` edges'
  contains "$e2" 'An edge on an inner node applies to **every leaf under it**'
  contains "$e2" 'An edge that points **at** an inner node is satisfied when that node closes.'
}

@test "#2857 the run summary names nodes by full path, and an inner E4 is never narrower" {
  contains "$(tree_section '## E3 — build leaves')" \
    '**The run summary** names every leaf, escalated, parked and `foreign` node by its full path.'
  contains "$(tree_section '## E4 and E5 — bottom-up')" 'never a narrower command'
}

@test "#2857 a re-run skips closed leaves and closed subtrees" {
  contains "$(tree_section '## E4 and E5 — bottom-up')" \
    'A re-run reads the tree again: closed leaves and closed subtrees are listed and never descended into, so it continues from where the last run stopped.'
}

@test "#2857 the epic record counts leaves only, in both statements of the contract" {
  local f
  for f in development/skills/resolve-issue/reference/epic-telemetry.md ARCHITECTURE.md; do
    contains "$(flat "$REPO_ROOT/$f")" 'Inner, `undecomposed`, `read_failed` and `foreign` nodes count nowhere'
    contains "$(flat "$REPO_ROOT/$f")" '"child" below means such a leaf'
  done
  contains "$(flat "$REPO_ROOT/development/skills/resolve-issue/reference/epic-telemetry.md")" 'the closed ones among them — after a live backfill'"'"'s re-read when one ran and succeeded. Inner, `undecomposed`, `read_failed` and `foreign` nodes count nowhere, and neither does a leaf under a closed subtree, which that read never lists'
}

@test "#2857 #2695's assumption: file-split-children.zsh writes no split-child record" {
  # a split child carrying a trusted split-child record would route #2695's
  # size path instead of this walk; the day the splitter starts writing one,
  # this reds and the walk's inner-node rule must be revisited
  # A record is follow-up-origin.zsh's `kind: "split-child"`, so the script
  # would have to name that helper or that kind. `split-children`, the script's
  # own name, is not the kind and must not trip the check.
  [ -f "$SPLIT" ]
  grep -q 'split-children' "$SPLIT"
  if grep -nE 'split-child([^r]|$)' "$SPLIT"; then echo "the splitter names the split-child kind"; return 1; fi
  if grep -n 'follow-up-origin' "$SPLIT"; then echo "the splitter calls follow-up-origin"; return 1; fi
}
