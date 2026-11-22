# Review loop — the round protocol

On-demand reference for `development/skills/resolve-issue/SKILL.md`. When its
pointer reaches the round protocol, read every shard below in this order before
round 1's step 1. The loop's status JSON names the shard each exit needs in
`next_ref`.

This index carries §3.5's round protocol as shards under `reference/review-loop/`,
each at most 20,000 bytes (#2055). Read order:

1. `reference/review-loop/core.md` — `## The round protocol`: the concurrent
   round boundary, its steps 1–7, and the end-the-turn wait.
2. `reference/review-loop/scope-block.md` — the #1582 reviewer scope block.
3. `reference/review-loop/step-1-panel.md` — round step 1, the review panel.
4. `reference/review-loop/step-2-invocation.md` — round step 2, the loop
   invocation template and its `loop_args`.
5. `reference/review-loop/exit-2-stale-findings.md` — `STALE_FINDINGS` (exit 2):
   recover by cause.
6. `reference/review-loop/exit-20-awaiting-fix.md` — `AWAITING_FIX` (exit 20):
   the fix pass, and round step 4's terminal statuses.
7. `reference/review-loop/delta-rounds.md` — selected gates and the test bar
   for delta rounds.
8. `reference/review-loop/topic-panels.md` — topic panels.
9. `reference/review-loop/decided-pass.md` — the decided pass.
10. `reference/review-loop/risk-pass.md` — the risk pass.
11. `reference/review-loop/carry.md` — carry accounting and carry-driven
    dispatch.
12. `reference/review-loop/subagents.md` — round subagents.
13. `reference/review-loop/recovery-arms.md` — the verdict recovery arms.
14. `reference/review-loop/estimates.md` — narrating long waits with a sourced
    estimate or none.
15. `reference/review-loop/briefs/` — `panel.md`, `fix.md`, `decide.md` and
    `risk.md`, one brief per round subagent.

Every `<!-- moved: … -->` block in those shards is byte-identical to the text it
was carved out of: `scripts/verify-reference-move.zsh` proves it, and its
`MANIFEST` names the frozen blocks. Text outside those blocks is outside that
proof.
