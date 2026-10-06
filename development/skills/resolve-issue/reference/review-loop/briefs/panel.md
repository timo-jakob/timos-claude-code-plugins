<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the panel subagent brief. -->

#### Panel subagent brief

You review one round, in place of the conductor. Read your handoff with
`round-handoff.zsh read-handoff --file <the handoff path your prompt names>`;
the scripts below are under `<skill-base-dir>/scripts/`. Before step 1, read the
shards this brief defers to: `<skill-base-dir>/reference/review-loop/step-1-panel.md`
(round step 1), `<skill-base-dir>/reference/review-loop/scope-block.md`,
`<skill-base-dir>/reference/review-loop/topic-panels.md` and
`<skill-base-dir>/reference/review-loop/carry.md`. Work in the handoff's
`worktree_root`, never your cwd (ARCHITECTURE.md, *Where a subagent works*).
Steps 1–5 are `round` mode. A `carry-repair` handoff takes *Carry modes* below
instead; a `carry-redispatch` handoff runs steps 1–5 with the changes *Carry
modes* names.

1. **Plan.** Run `review-dispatch.zsh plan --repo <worktree_root> --base <base>
   --round <round>`. From round 2 on, add `--prior-tree <delta_base>`,
   `--fix-verification <work_dir>/verify-<round>.json` and `--adjudicated
   <work_dir>/adjudicated.json`. On round 1, add `--self-check
   <worktree_root>/.review/self-check.json` when that file exists. Step
   1's round-1 "no flags beyond the round" predates #2014 and does not override
   that. Round step 1
   governs when to add `--final`, the
   plan's exit codes, and the `worktree_root` check. **On a carried round, split
   the carry by owner (#2010):** run `review-dispatch.zsh split-carry
   --fix-verification <work_dir>/verify-<round>.json` and keep the
   `{dimension: path}` map it prints; never write `verify-<round>.json`, which
   stays the loop's carry. Its exit 2 is your own malformed invocation — fix it
   and re-run once; an exit 1, or a second exit 2, is `failed` /
   `fix-verification-unreadable`.
2. **Dispatch the reviewers** of the plan's `review_skill` and of every
   `topic_review_skills` entry (*Topic panels*), exactly as each skill's own
   Step 1 says. Its `SKILL.md` is in the same plugin cache as `<skill-base-dir>`:
   `<plugin-root>/<plugin>[/<version>]/skills/<skill>/SKILL.md`. Build each
   prompt as step 1 and *Build each reviewer's scope block* say, carry included
   — each reviewer's Fix verification line names only the path the map gives
   its own dimension, and a reviewer whose dimension the map does not hold gets
   no such line (*Carry accounting*).
   **Dispatch every reviewer in the foreground** (`run_in_background: false`),
   all in one message, whatever that skill's Step 1 says: a background dispatch
   returns before the reviewer replies (ARCHITECTURE.md, *Subagent dispatch
   mechanism*).
3. **On a carried round, settle the carry before writing anything.** Check that
   every carried entry was accounted for by its owning dimension's reviewer —
   judged by the per-entry lines, whose checksum is that the reviewers' TOTALs
   sum to the length of the file step 1 split;
   re-dispatch, once, only a reviewer that left any entry of its own
   dimension's file without a per-entry line, with the prompt step 2 built
   for it — inside the panel subagent, that is what *Carry accounting*'s
   "re-dispatch the panel" means — and keep only its second reply. Then append
   every reviewer's per-entry lines to `<work-dir>/carry-lines-<R>.txt` — one
   owner's line per entry. A script reviewer counts as one (#2008): the
   claude-plugin panel's `check-manifests.zsh` writes its per-entry lines and
   triple to its `--carry-out` file, which you append to `carry-lines-<R>.txt`
   unchanged, and its records name `check-manifests.zsh` as the `manifest`
   owner. Then assemble
   `<work-dir>/carry-round-<R>.json` from them, as *Carry accounting* says.
4. **Write the aggregate once** — every panel's findings joined unchanged, a
   re-dispatched reviewer's from its second reply — to
   `<work-dir>/findings-round-<R>.json`, never to the dispatch sink
   `findings_path`, which the loop truncates and refuses.

   You have no `Write` tool: write every file in steps 3 and 4 with a quoted
   heredoc — `cat > <file> <<'EOF'` to create one, `cat >> <file> <<'EOF'` only
   to append each reviewer's lines to `carry-lines-<R>.txt` — never an unquoted
   one or an interpolated string, so reviewer text that holds backticks or `$`
   lands unchanged.
5. **Write a `panel` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: on success, `ok` with the aggregate's path and length and the two
   carry files (both `null` on round 1 or an empty carry). Return to the
   conductor only that the verdict was written.

**Recover inside the dispatch before returning a non-`ok` verdict.** Three
arms are yours, not the conductor's:

- a `plan` **exit 2** is your own malformed invocation: fix it and re-run once,
  as *A non-zero `plan` exit is never a scope* says. Return `plan-failed` only
  on exit 1, exit 3 or a second exit 2;
- a `worktree_root` that is not the implementation worktree: re-plan against
  the implementation worktree, as step 1's check says. Return
  `wrong-worktree-root` only when the re-planned descriptor still names the
  wrong root;
- an empty excerpt: apply *An empty excerpt is not always a stop*, and
  re-confirm `worktree_root`, before returning `empty-excerpt`.

**Carry modes.** Both write a `panel` verdict exactly as step 5 does.

- **`carry-repair`** dispatches no reviewers. Read `<work-dir>/carry-lines-<R>.txt`
  — one owning reviewer's line per entry since #2010 —
  rebuild `<work-dir>/carry-round-<R>.json` from those lines, and leave
  `findings-round-<R>.json` byte-unchanged. On success the verdict is `ok` with
  that untouched aggregate and its length, the rebuilt `carry-round-<R>.json`
  and `carry-lines-<R>.txt`. When the lines cannot produce a valid accounting,
  return `failed` / `carry-unconfirmed`.
- **`carry-redispatch`** runs steps 1–5 with an **empty** scope and a verify
  file naming only `carry_entries`, as *Carry accounting → Recover by ground*
  says. First project the `verify-<R>.json` entries that `carry_entries` names
  into `<work-dir>/verify-<R>-carry.json` with `jq`; never write
  `verify-<R>.json`, which stays the loop's carry. Step 1 then plans with
  `--prior-tree <tree_id>` in place of `<delta_base>`, so the delta is empty,
  and `--fix-verification <work-dir>/verify-<R>-carry.json`, and never adds
  `--final`. Step 1's split runs on `verify-<R>-carry.json` instead, so
  `carry_entries` are grouped by `dimension` and step 2 dispatches **only**
  each group's owning reviewer (#2010) — never the whole panel, and a
  dimension with no group is not dispatched, which is not
  `dimension-not-run`; the handoff's
  `carry_entries` stay the flat `round-handoff/v1` array.
  Steps 3 and 4 keep their re-dispatch and quoted-heredoc rules on
  these paths: write their output to `<work-dir>/findings-round-<R>-carry.json`,
  merge it into `findings-round-<R>.json` (`jq -s 'add'`) once, atomically,
  append their per-entry lines to `carry-lines-<R>.txt`, and re-assemble
  `carry-round-<R>.json` from every line in that file. The verdict is `ok` with
  the merged aggregate and its length, `carry-round-<R>.json` and
  `carry-lines-<R>.txt`. Never retype or reword a finding.

Where step 1 or the sections it defers to would stop the round, return a
non-`ok` verdict instead, and write no findings file:

| Situation | `outcome` / `cause` |
|---|---|
| a planned dimension did not run | `failed` / `dimension-not-run` |
| a reviewer prompt or a review skill could not be rendered or found | `failed` / `render-failed` |
| round ≥ 2 and the plan's `fix_verification_path` is `null` | `failed` / `fix-verification-null` |
| that path is set but a reviewer could not read it | `failed` / `fix-verification-unreadable` |
| a carried entry is still unaccounted after the one re-dispatch | `failed` / `carry-unconfirmed` |
| `plan` exited non-zero, and step 1 does not say to fix and re-run | `failed` / `plan-failed` |
| `worktree_root` is not the implementation worktree | `failed` / `wrong-worktree-root` |
| a `[DELETED by this story]` excerpt came back empty | `failed` / `empty-excerpt` |
| a full round whose story diff is empty | `not_applicable` / `story-diff-empty` |
| the language panel reported NOT APPLICABLE on a full round | `not_applicable` / `not-applicable` |
| you have no `Agent` tool | `failed` / `no-agent-tool` |

**Planned** is the review skill's own Step 1 table, read for this round (#2008).
A dimension that table does not plan this round produces no verdict at all —
it is neither run nor missing, so it never raises `dimension-not-run`. Rounds
are told apart by the plan's `scope_mode` and the split-carry map, never by the
round number alone (round 1 and every closing sweep are both `"full"`); a
dimension skipped on delta rounds comes back by *Carry-driven dispatch
(#2008)*. `round-verdict/v1` and the cause vocabulary above are unchanged.

Never author a finding, edit one, or write `[]` on a reviewer's behalf.
