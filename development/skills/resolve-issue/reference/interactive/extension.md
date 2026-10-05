<!-- Shard of reference/interactive.md (#2058), read in its index's order:
     the interactive extension: its heading, its intro and steps 1-4. -->

## Interactive extension (#562-resume)

> **Read the #1576 amendment in `reference/interactive/extension-ceiling.md`
> BEFORE acting on step 5** (`reference/interactive/extension-grant.md`). The
> grant is recorded to the work-dir by `record-grant.zsh` — a step the frozen
> text of step 5 in `reference/interactive/extension-grant.md` does not mention
> — and step 5's "buys only two" on a granted closing sweep is superseded there.
>
> **Read the #1226 amendment there too:** step 5's resume invocation also
> carries the run's `loop_args`, which the frozen template in
> `reference/interactive/extension-grant.md` does not show.

<!-- moved: interactive-extension -->
**Interactive extension (human present, `BUDGET_EXHAUSTED` /
`ESCALATE_NO_CONVERGENCE` only, #562-resume).** When the run is
**interactive** — the same human-present determination §0a's remediation uses —
and the loop exited `BUDGET_EXHAUSTED` or `ESCALATE_NO_CONVERGENCE`, do **not**
jump straight to the comment. The person who can grant "three more rounds" or
supply the missing constraint is right here; offer that in-session first. (Every
other exit — `ESCALATE_CONFLICT`, `ESCALATE_AMBIGUOUS` — and **every autonomous
run** skip this branch entirely and go straight to the typed comment below.)

Run this extension loop, tracking a `grants` counter **per loop** — where a
"loop" is one `--work-dir` and its chain of `--resume` invocations. It starts at
0 the **first** time the extension is entered for that loop; re-entering after an
`AWAITING_FIX` detour or a later escalation **of the same loop** resumes the
existing count — **never reset it**, or the `--grants` figure shown to the human
understates what was consumed and the step-6 soft cap can never fire across
detours. The **promotion sub-loop (#994) is a different loop** — its own
work-dir, its own ceiling — so it starts its own counter at 0; pass the **current
loop's** count to `--grants`, and mention the other phase's total as prose
alongside the summary so the human still sees the story's full cost:

1. **Summarize** the exit in the conversation — never make the human read a
   comment when they are right here:

   ```bash
   "<skill-base-dir>/scripts/build-escalation.zsh" --status <status.json> \
     --format summary --grants <grants>
   ```

   It prints the typed status, the remaining blockers (severity + dimension,
   with any **possible false trip** flagged), the round history, the
   **per-round progress table** (Critical/Warning/Suggestion, a **Promoted**
   column when any round has a promoted blocker (#995), new/carried,
   fixed-since-prior), the **blocker-class histogram for the last two rounds**
   (#1435 — new_defect / incomplete_propagation / under_assertion, where a `–`
   cell means that round was never class-stamped rather than that it scored
   zero), the **convergence assessment** — an explicit, honest
   read of whether another round is likely to help — and the grants consumed
   against the soft cap (#969). The histogram is the one that answers "what
   would another round buy?": a round of `new_defect`s is finding fresh
   problems, a round of the other two is re-reading the last fix pass. Show all of it *before* the `AskUserQuestion`
   in step 2, so the human can decide **and** supply direction from the
   summary alone. It is the same data the comment would carry, so nothing
   drifts — never compose an ad-hoc summary instead.

2. **Offer the choice** with `AskUserQuestion` (one question), tailored to the
   exit type. The built-in **"Other"** option is the free-text channel — the
   human uses it to *ask you a question* ("why is that blocker stuck?", "show me
   the diff for `b.py`") **or** to *type guidance*.
   - `BUDGET_EXHAUSTED`: **Grant +3 rounds** · **Grant +3 with guidance** ·
     **Stop**.
   - `ESCALATE_NO_CONVERGENCE`: **Give guidance & retry (+3)** — the primary
     lever, since more rounds alone will not move a stuck blocker — · **Stop**.
     Since #1498 an all-ambiguous carried set no longer reaches this extension
     the first time **unless the rung refused it** — a Critical among the
     matches, the round already at the ceiling, an unstamped changelist, or a
     failed marker write. So arriving here is not proof a continuation was
     spent. Read the step-1 assessment before framing the blocker as stuck: it
     reports the count only when one was spent, and flags a possibly-new
     carried match only on a stamped round.

3. **If they asked a question** (Other → a question, not guidance): answer it
   from the changelist / dossier, then **re-present step 2**. A question never
   consumes a grant.

4. **If they gave guidance** (with or without an explicit grant — guidance
   always implies a grant; the +3/`grants` bookkeeping happens **once**, in
   step 5): **post it as an issue comment** so it is durable and
   survives a dead session, tagged so the audit trail separates human guidance
   from the automated escalation comment:

   ```bash
   # via a QUOTED heredoc + --body-file, never --body "$GUIDANCE": guidance
   # about code routinely contains backticks/$(...) that a double-quoted
   # --body would hand to the shell as command substitution
   cat > /tmp/review-loop-guidance.md <<'GUIDANCE_EOF'
   <!-- review-loop-guidance -->
   <the guidance text>
   GUIDANCE_EOF
   gh issue comment <N> --body-file /tmp/review-loop-guidance.md
   ```

   Then resume (step 5): re-read the issue's comments during the pre-resume
   in-session fix pass so the guidance becomes fix context (the readiness gate
   and escalation already read comments — reuse that, do not invent an env
   side-channel).
<!-- /moved: interactive-extension -->

**Read on, in this order.** Steps 5–7 continue in
`reference/interactive/extension-grant.md`, and the amendments to step 5 in
`reference/interactive/extension-ceiling.md`.
