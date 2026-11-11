<!-- Shard of reference/interactive.md: the root's blockers-first procedure in a
     human-started run (#2941), which replaces remediation.md's offer there. -->

## Blockers first in a human-started run (#2941)

**A human-started run clears its blockers without asking.** In a run whose
origin is `human` (§0a), whatever session mode `scripts/resolve-session.zsh`
reports, a shape (i) rejection of the named issue takes remediation's option 1 — *Resolve the dependency AND the
named issue* — and never puts the choice to the human. A `--resume` run does not
chain, so it keeps §0a's arm for its session mode: attended offers remediation,
unattended posts `comment_md` and applies `blocked`. A pipeline-started run is
unchanged: it posts `comment_md`, applies the `blocked` label and stops, as #583
requires.

**Who runs it.** The root runs this procedure when the named issue's step ends
`blocked` (`reference/chain-steps.md` § The issue step (#2940)). The root puts
`BLOCKERS_FIRST=1` in the brief of the named issue's step and of every blocker
step, and never in an E3 child's. A step whose brief names it posts nothing and
applies no label on a §0a rejection, so every comment and label this procedure
needs is posted once, by the root, in step 6.

The procedure works on a **target**: the named issue at first, and a blocker
whose own step ended `blocked` when step 3 recurses. Every comment goes to the
named issue, whatever the target.

1. **Read the decision.** Run `dependency-precheck.zsh` on the target yourself.
   The step's verdict carries the blockers but not the decision JSON this
   procedure reads. `PROCEED` (a blocker closed meanwhile) goes straight to step
   5. Exit 2 is your own malformed call: fix it and re-run once. Exit 1, or a
   second 2, stops the run (step 6) with the reason `precheck failed`.
2. **Stop before building anything on these.** A `REJECT_CYCLE` and a shape
   (ii) rejection stop the run (step 6) before any blocker is built. The stop
   names the cycle or the cause `comment_md` names.
   **An open foreign blocker is waited on first (#3078).** Take each
   `foreign_blockers` entry with `open: true` in turn, before any local blocker
   is built, because clearing the local ones cannot make the precheck pass.
   Watch it with one bounded `Monitor` call, the same bound as step 4's thirty
   one-a-minute re-reads: its command is
   `"<skill-base-dir>/scripts/bounded-wait.zsh" issue --repo <owner/name> --issue <M>`
   and its `timeout_ms` is `1800000`. The script prints one line when the wait
   ends, and its `result` decides:
   - `closed` or `already-closed` → the blocker is gone: go back to step 1 and
     read the decision again. The run continues on whatever that precheck
     returns.
   - `timeout`, `unreadable`, a script exit 1 or 2, or a `Monitor` call that
     expires with no line → stop the run (step 6) as before the wait existed,
     naming the foreign ref. The state stays resumable: re-running
     `/development:resolve-issue` on the named issue starts at step 1 again.

   Wait on each foreign ref at most once in a run; a ref that is open again
   after its wait stops the run (step 6).

   **The blocker choice is never put to the human.** The root never asks
   whether to build the blocker first, remove the blocked-by link or wait
   longer: no rule licenses that question, in either session mode. It waits,
   and then it continues or stops.
3. **Clear each open local blocker, deepest first.** Take the open entries of
   `blockers`, deepest `depth` first, and clear each one in turn, skipping one
   an earlier recursion already cleared. To clear a blocker:
   - **Classify it** as remediation's moved span classifies a rung. A confirmed
     epic-kind blocker runs the Epic flow, and it is cleared only when the epic
     is closed: an Epic flow that ends with the epic still open stops the run
     (step 6). A blocker whose checkbox refs are only criteria takes the
     single-issue step. A near-miss blocker stops the run (step 6), and the
     reason names the fix it needs: native sub-issues or a `- [ ] #N` rewrite.
   - **An epic-kind blocker you cannot confirm, or a blocker you cannot
     classify, is a gap question.** The root asks the human, in both session
     modes, with AskUserQuestion: two options, *the Epic flow* and *the
     single-issue flow*, naming the blocker and what you could not judge. The
     run waits for the answer and then takes the step picked. Declining both
     stops the run (step 6).
   - **Dispatch the blocker's step**, an issue step with `start_at` `"0a"`, so
     the blocker re-enters at its own §0a. Its handoff's `chained_from` is the
     blocker itself, so it parks and chains as a single-issue entry, never by
     E3's terminal (c). Its verdict decides what follows:
     - `done` → wait for its PR to merge (step 4); the blocker is then cleared.
       The chain queue's step 3, named in step 5, records that PR and marks the
       blocker `done`, as it marks an epic-kind blocker once the Epic flow closes
       its epic.
     - `needs-refinement` → #2940's chained refinement step on the blocker. Its
       `ready` dispatches the blocker's step again with `start_at` `"1"`; its
       `split` makes the blocker a confirmed epic, which runs the Epic flow;
       its `questions-pending` takes the relay; any other verdict stops the run
       (step 6).
     - `blocked` → the blocker has open blockers of its own. Run this procedure
       from step 1 with the blocker as the target. Its step 5 builds the
       blocker, so the blocker is cleared when that run ends: never dispatch
       its step a second time.
     - `stopped` → stop the run (step 6).
4. **Merge each blocker before the next one branches.** A blocker PR advances
   by itself only where it merges without a human. In an Approver repo, armed
   auto-merge merges it on green. In a claude-plugin repo whose
   `plugin-approver-override.zsh` reports `override=on`, the step's §6 approves
   and advances it. In both cases, wait for the PR as §6's approve-and-advance
   arm waits: `await-pr-checks.zsh <pr>`, then at most 30 re-reads of
   `gh pr view <pr> --json state,autoMergeRequest`, one a minute, until it
   reads `MERGED`. A PR still unmerged then with green checks, and a blocker
   PR anywhere else, takes the chain queue's approval wait
   (`reference/checkpoint.md`, the chain queue's step 3), and only the wait: a
   `merged` result clears the blocker. When it ends unmerged, stop the run
   (step 6), never with `--pause`, with the reason that blocker PR #P is ready
   and awaits a human merge.
   Re-running `/development:resolve-issue` on the named issue resumes the
   chain: its precheck no longer lists the merged blockers.
5. **Re-verify, then build the target.** Once every blocker from step 3 is
   cleared, run the precheck on the target again; exit 1 or 2 is handled as in
   step 1. On `PROCEED`, dispatch the target's step with `start_at` `"0a"`: it
   re-runs §0a, clears the stale `blocked` label and builds the target. A
   blocker target's verdict is handled as step 3 handles a blocker's. The named
   issue's `done`, `needs-refinement` and `stopped` take the issue step's own
   arms, never step 4 or step 6: `done` takes the chain queue's step 3
   (`reference/checkpoint.md`), `needs-refinement` dispatches #2940's chained
   refinement step on it, and `stopped` keeps that step's own ending. A
   rejection here, or a `blocked` verdict from that step, stops the run (step
   6). Never clear the chain a second time, because that loop has no bound.
6. **Every stop posts one comment and applies the label.** When this
   procedure stops, in either session mode, it starts no further blocker step
   and does not build the named issue. A stopped blocker keeps whatever its own
   run posted, and its own record keeps its own outcome. Run the precheck on
   the named issue once more for a current `comment_md`, since earlier ones
   still list blockers this run merged. On its exit 1 or 2 the comment carries
   no `comment_md`, and so does it on `PROCEED`, which also applies no label:
   that stop is not a dependency stop. Then post one comment on the named issue
   and apply `blocked`, except after a precheck failure, which applies no label,
   as §0a applies none on those exits. Run the block in one Bash call, and
   single-quote each substituted value (a `'` inside one written `'\''`), so a
   reason's backticks or `$` stay literal:

   ```bash
   gh label create blocked --color b60205 \
     --description "Rejected by the dependency precheck — open blockers in its blocked-by graph" \
     2>/dev/null || true
   BLOCKER='<the stopping blocker, or the foreign ref>' REASON='<the reason>' MERGED='<#PR, #PR …, or none>'
   COMMENT_MD='<the comment_md of that precheck, or nothing on its PROCEED, exit 1 or 2>'
   { printf 'blockers first stopped: %s — %s\nMerged in this run: %s\n' "$BLOCKER" "$REASON" "$MERGED"
     if [ -n "$COMMENT_MD" ]; then printf '\n%s\n' "$COMMENT_MD"; fi; } | gh issue comment <N> --body-file -
   gh issue edit <N> --add-label blocked   # never on PROCEED or a precheck failure
   ```

   The named issue's own record is the one its first step emitted, with
   outcome `precheck-parked` (`reference/telemetry.md` step 4, the row for a
   rung that failed, halted or paused). No new outcome or field is added.
