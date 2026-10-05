<!-- Shard of reference/residue.md (#2056), read in its index's order:
     the residue branch: when it runs, ordering it last, a run with no PR. -->

## Residue branch — file the remainder, then ship (#1435)

<!-- moved: residue-branch -->
Runs **only** on `CONVERGED_WITH_RESIDUE` (exit 14). The loop has already
decided; your job is to make the remainder visible.

**Order it LAST — after the suggestion-promotion phase below has resolved, and
immediately before §4.** This branch is the one place in the flow that writes to
GitHub before the PR exists, and a promotion sub-loop can still **escalate**,
which ends the run with no PR at all. Filing first would leave issues on the
board for work that never shipped, and the next run would re-decide the whole
blocking phase around them. Nothing is lost by waiting: the promotion phase is a
separate sub-loop over waived Lows and never changes the blocking phase's
residual set, which is what the plan below reads.

**Ordering last shrinks that window; it does not close it.** Everything after
this branch can still end the run with no PR — §5's commit (pre-commit can
fail), §6's token mint or push, and open-pr's explicitly terminal *stop rather
than open the PR* when a dossier input cannot be restored. By then the
follow-up issues are already on GitHub. If the run ends after this branch
without a PR:

- **Do NOT delete them.** They record real remaining blockers, and the epic walk
  has to see them rather than have them vanish.
- **Comment on each filed issue and on the story** that the PR was never opened,
  naming the branch and what stopped it, so the next reader is not looking for a
  merged change that does not exist.
- **Report it in the conversation** with the same detail.

A re-run does not duplicate what this run filed — the idempotency read matches
on label + exact title across the parent's sub-issues **and** the repo, so even
an issue whose **attach** failed is filtered from the next plan. But that is
exactly why a re-run is not a recovery for it: it stays **orphaned**, linked to
no story, and the next run will not re-file it either. Re-attach it yourself
(step 4's `sub_issues` POST, with the id it already has) and name it in the
comments below. What is *not* safe is
silence — a `review-residue` child parented to an epic will halt that epic's next
walk, and a maintainer with no comment to read cannot tell a deliberate deferral
from an abandoned run.

**If the promotion sub-loop DOES escalate, this branch never runs and no PR
opens.** File nothing — but do not let the remainder vanish with the run: name
the blocking phase's residual blockers (from its `final_changelist.blocking`) in
the escalation comment, so they survive somewhere. The next run re-decides the
blocking phase from scratch and will re-derive them.
<!-- /moved: residue-branch -->

**Read on, in this order, before acting.** The branch continues in other shards.
Before step 1, read `reference/residue/risk-threshold.md` § *Risk threshold —
assess before filing (#1920)*. Then read the steps:
`reference/residue/step-1-plan.md`, `reference/residue/steps-2-3.md` and
`reference/residue/steps-4-5.md`. The read order is listed in
`reference/residue.md`.
