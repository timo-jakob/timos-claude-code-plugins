<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the decide subagent brief. -->

#### Decide subagent brief

The decide subagent runs one round's decided pass in place of the conductor.
This brief states what it does and what the conductor does around it; the
per-finding procedure — which commands run, how each verdict is settled, the
malformed shapes and the retirement rule — is *The decided pass*
(`<skill-base-dir>/reference/review-loop/decided-pass.md`), and is not restated
here. The conductor dispatches `subagent_type: round-decide`; the
decide subagent dispatches nothing.

**The conductor, before the dispatch.**

- **When.** Dispatch it after the boundary's step 5 has judged the gate green,
  or straight after the panel on a round that runs with no gate — the
  closing-sweep promotion and the findings-file recovery re-invokes — and
  straight after the panel a CADENCE recovery re-runs, over its new aggregate.
  Never on a red gate, and never on a green gate that reported a tree other than
  `T`.
- **The handoff.** Write `handoff-<R>-decide.json` with `round-handoff.zsh
  write-handoff`: `aggregate_findings_file` from the panel verdict,
  `worktree_root` as *What the conductor puts in a handoff* says for every
  kind — the same value as the panel handoff's — and `retired_file` =
  `<work-dir>/decides-retired.txt`.
- **The file lifecycle.** Create `decides-retired.txt` empty before round 1's
  panel dispatch, which clears any earlier run's file. Truncate
  `decided-<R>.log` and `<work-dir>/decides-ran-<R>.txt` before the round's
  first decide dispatch; every decide subagent only appends to them, re-entries
  included. An absent retired file reads as empty. None of these writes is a
  read.

**The decide subagent.** Read your handoff with `round-handoff.zsh read-handoff
--file <the handoff path your prompt names>`; the scripts are under
`<skill-base-dir>/scripts/`. Then:

1. **Confirm `worktree_root`**: `git -C <worktree_root> rev-parse
   --show-toplevel` must print that path. If it does not, run nothing, edit
   nothing, and return `failed` / `wrong-worktree-root`.
2. **Settle every retired command as retired, without running it**, before
   anything runs: each command listed in `retired_file` is settled like an
   unrunnable one — step 5, `"decided": "green"`, logged as a writing command —
   including a finding a decide pass already decided.
3. **Run the decided pass** over `aggregate_findings_file`, as *The decided
   pass* specifies, in `worktree_root`. Step 2's findings are already settled:
   never run a command `retired_file` lists. Run every command in the foreground
   and wait for it; a `decides:` command that names the gate script is a
   decided-pass command, not the round's gate, which has already returned.
4. **Append** each finding's entry to `<work-dir>/decided-<R>.log`, and each
   distinct command you ran to `<work-dir>/decides-ran-<R>.txt`, one per line.
5. **Write the aggregate once, atomically**, after every verdict is in: write
   the whole edited aggregate to a temporary file in the work-dir and `mv` it
   over `aggregate_findings_file`, so a re-dispatch never meets a partly edited
   aggregate.
6. **Write a `decide` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: `ok` with `cause: null` and only `decided_red`, `decided_green`
   and `malformed` (the counts of findings this pass stamped `red`, stamped
   `green`, and named malformed) and `ran_commands_file` =
   `<work-dir>/decides-ran-<R>.txt`; or, from step 1, `failed` /
   `wrong-worktree-root` with `decided_red`, `decided_green`, `malformed` and
   `ran_commands_file` all `null`. Return to the conductor only that the
   verdict was written.

**Any other failure writes no verdict.** If reading the handoff, reading
`retired_file` or the aggregate, an append, or the aggregate write or `mv` of
this brief's step 5 fails, write no verdict and return that you failed: the
conductor's stall retry takes it from there. Never write `ok` unless that `mv`
succeeded.

**The conductor, after the verdict.**

- **Risk pass, then consolidation.** Run the risk pass only after reading an
  `ok` decide verdict. Once the decide verdict is `ok`, pass the panel verdict's
  `aggregate_findings_file` as `--findings-file`. On a promotion sub-loop's
  round 1, pass instead the seeded file built from that decided aggregate
  (`reference/promotion.md`). Open neither the aggregate,
  `decides-ran-<R>.txt` nor `decides-retired.txt`.
- **Narration.** Report the verdict's `decided_red`, `decided_green` and
  `malformed` counts and the `decided-<R>.log` path. Findings are named in
  `decided-<R>.log` only.
- **Non-ok and stall.** A decide verdict that is not `ok` is report-and-stop,
  with no consolidation. The stall retry above applies unchanged: one fresh
  re-dispatch on a `read-verdict` exit 3, then report-and-stop.
- **A CADENCE refusal right after a decide pass**, in this order:
  1. append `decides-ran-<R>.txt` to `decides-retired.txt` without reading it;
  2. dispatch a fresh decide subagent over the same aggregate, which re-settles
     the retired commands' findings and runs none of them — a recovery dispatch,
     not a stall re-dispatch;
  3. only then take either of that arm's recoveries. Re-running the panel
     needs a decide pass over its new aggregate, as *When* says.
- **A CARRY-UNACCOUNTED refusal on the *neither confirmed nor re-raised* ground
  naming a tool-verdict carry** (*The decided pass*'s KNOWN LIMITATION;
  *Verdict recovery arms*). To report the entry and its `decides:` command, the
  conductor may look up only the `decided-<R'>.log` entries matching a
  `carry_unconfirmed[]` identity's `file` and `dimension`, reading only their
  `decides:` command and exit status. That lookup happens only on that
  report-and-stop path, and it counts as work-dir state.
