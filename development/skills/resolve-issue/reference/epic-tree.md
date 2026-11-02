# resolve-issue — the sub-issue tree

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it
when the Epic flow points here, never up front. The reader it relies on is
`scripts/read-sub-issues.zsh --tree`, whose header states the document, the five
kinds and the exit codes; this file is only the procedure that consumes them.

## The tree (#2857)

An epic's native sub-issues form a **tree of any depth**, up to the limit in
force. The rules below are written once, for any depth, never as a fixed number
of levels. The **target** is the epic the run was invoked on, at depth 0;
*below the target* means depth 1 and deeper. Each node of the first
`--tree` read has exactly one `kind`:

- a **leaf** is a story: the only kind that is ever gated, built or counted;
- an **inner** node is an epic below (or at) the target: never gated, never
  built, closed only bottom-up;
- an **undecomposed** node is an epic below the target with nothing native
  under it: it counts not ready;
- a **read_failed** node is a tooling failure: it halts E1;
- a **foreign** node lives in another repository: it is listed, never read.

**Name every node by its full path** wherever a summary, a halt comment or a
park note names it: the `path` of the `--tree` document, written
`#12 → #231 → #251`. A bare number hides which epic a leaf sits under.

**E1's `total: 0` machinery runs on the target only.** The backfill with its
dry-run vets, and the inline-slice classification, apply to the target exactly
as E1 states them. Neither runs below the target: a nested `total == 0` node is
either `undecomposed` or a leaf story, and the reader has already said which.

## E1 — reading the tree

The first read is `read-sub-issues.zsh --repo "$REPO" --tree <N>`; after a
live backfill, the re-read is this same `--tree` read, and its document replaces
the first for E1b to E5. The root node's `total` and `completed` are the
`summary` E1's table branches on, and the open `leaf` nodes below the target,
at any depth, are the children every later step works. Branch on the reader's
exit first:

- **Exit 4** — `RESOLVE_ISSUE_MAX_EPIC_DEPTH` is set to an invalid value. Stop
  the run before any work, relaying the script's stderr. There is no fallback
  to the default limit, and no epic record: nothing was read.
- **Exit 5** — the tree is deeper than the limit in force. **Halt before any
  build**: post the halt comment on the target naming `over_limit.path` (as a
  full path) and `over_limit.limit`, build nothing, leave the epic open.
  `e1_classification` is `halt_depth_exceeded`.
- **Exit 1** — the root itself could not be read: a classification failure,
  reported and stopped exactly as step 0 handles one.
- **Exit 2** — your own malformed call: fix it and re-run.
- **Exit 0 with any `read_failed` node** — halt at E1, before E1b. The halt
  comment lists **every** `read_failed` node by its full path as a tooling
  failure. Such a node counts not ready, and its body is **never** gated as a
  story as a fallback: a failed read is not evidence of a leaf.
  `e1_classification` is `halt_tree_read_error`.

Every `foreign` node is noted on the reader's stderr. It never halts the run,
and E1 carries it to the run summary (E3), which lists every open one by its
full path.

## E1b — gate leaves only

`story-readiness` runs on **every open `leaf` of the whole tree**, in one
parallel batch. An inner node is **never** passed to `story-readiness`, and E1b
never gives an inner node `needs-refinement`: its body describes work its
sub-issues already carry, so gating it would re-ask questions a split settled.
Only the leaves whose readiness stamp misses are gated, and every fresh
verdict is stamped; a hit answers here exactly as a fresh verdict does (#2955):
see `reference/readiness-cache.md` § E1b — gate only the stamp misses

- **An inner node counts READY** when every open leaf under it is READY. An
  inner node with sub-issues but none open counts READY.
- **An `undecomposed` node counts not ready.** The halt summary reports it as an
  undecomposed epic and tells the human to attach its children natively, or to
  run `/development:resolve-issue` on that node directly, where E1's backfill
  and vets apply as they do to any target.
- **An unready leaf** gets `needs-refinement` and its questions exactly as an
  unready child does, and the halt summary names it by its full path.
- **A `foreign` node** is left out of the gate and out of an inner node's READY
  test, as a cross-repo child always was.

One unready leaf or one `undecomposed` node anywhere in the tree means the
epic is not ready: build nothing.

## E2 — order across the tree

Order the **leaves of the whole tree** by their native `blockedBy` edges, with
E2's conflict-aware rules applied unchanged to that flattened leaf set. An edge
on an inner node applies to **every leaf under it**: a leaf of `#231` waits for
`#231`'s blockers. An edge that points **at** an inner node is satisfied when
that node closes. Ordering is never the only guard: E3 enforces both.

## E3 — build leaves

**Only leaves are built.** An inner node gets no branch, no PR and **no story
run of its own** — no per-inner-node `resolve-issue` invocation and no
telemetry run. Every leaf's story run is parented to the **target** epic's run.

- **Inherited edges are enforced, not only ordered.** Before a leaf's own step
  0a, run `dependency-precheck.zsh` once for each open inner node on the leaf's
  path, excluding the target. Any non-`PROCEED` decision parks the leaf exactly
  as a §0a dependency rejection does, and its comment names that ancestor and the
  ancestor's open blockers. An exit 1 or 2 on an ancestor's precheck is the
  leaf's precheck tooling failure, handled as E3 handles a child's. An edge
  pointing **at** an inner node needs nothing extra: the precheck reads the
  blocker's state, so it is satisfied only once that node closes.
- **Escalation triage spans the tree.** The clean-stop triage's `--children`
  is every open leaf in walk order, and each leaf's `--deps` record carries in
  `blockers[]` its open inner ancestors' blockers too, so a leaf's dependants
  are parked across the whole tree, including leaves under other inner nodes.
- **The run summary** names every leaf, escalated, parked and `foreign` node by
  its full path.

## E4 and E5 — bottom-up

**Whenever every child of an open inner node is closed as completed — at the
first read or after any close during the run — run its E4 and E5, and re-check
its parent**, with the same positive-evidence rule as the target and before the
next leaf branches. Close bottom-up: a node's E5 runs before its parent's, a
dependant of an inner node branches only after that node closes, and **the
target epic closes last**.

- **An open `foreign` child keeps its parent open**, exactly as an open
  cross-repo child keeps an epic open. The run summary names it as the reason.
- **An inner node's E4 runs the target's profile-blessed holistic gate.** The
  gate is repo-wide, so "scoped to its subtree" means only that its report and
  its closing summary list that subtree's leaves and their merged PRs — never a
  narrower command.
- **A regression at an inner node's E4** is filed exactly as at the target's,
  leaves the inner node open, and **stops the whole run** as an E4 regression
  (`failure_cause: e4_regression`). No further leaf branches off a main known
  to be regressed; a re-run resumes once the regression is handled.
- **`detect`'s exit 1 and exit 3** at an inner node's E4 halt the run exactly as
  they do at the target's.

A re-run reads the tree again: closed leaves and closed subtrees are listed and
never descended into, so it continues from where the last run stopped.

## The #2695 assumption

refine-issue's split (`development/skills/refine-issue/scripts/file-split-children.zsh`)
writes no `split-child` record. So a node with native sub-issues and no trusted
record is an inner node whose children refine-issue or a human filed: E3 walks
its sub-issues as this file describes, and never applies #2695's size route to
it. `tests/epic-tree-walk.bats` pins that the script writes no such record.
