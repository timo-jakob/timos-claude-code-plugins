# Residue — file the remainder, then ship

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries the branch taken on a `CONVERGED_WITH_RESIDUE` (exit 14) ending,
which only the loop's closing full sweep can declare. It is split into
shards under `reference/residue/`, each at most 20,000 bytes (#2056). The loop's
exit-14 status JSON names the first shard in `next_ref`. Read order:

1. `reference/residue/branch.md` — `## Residue branch`: when it runs, why it is
   ordered last, and what to do if the run then ends with no PR.
2. `reference/residue/risk-threshold.md` — `## Risk threshold`: read it before
   step 1. It tells you how to read the `corner_case_risk_threshold` environment
   variable. Set to a usable value, it adds an assessment before step 1 and
   amends steps 1, 2, 3 and 5, which cannot carry the change themselves. Set to a
   value it cannot use, it adds only one line to the PR Summary. Unset, empty or
   zero, the branch runs exactly as written.
3. `reference/residue/step-1-plan.md` — step 1, build the plan, with the
   remainder rule.
4. `reference/residue/steps-2-3.md` — steps 2–3: the `--dry-run` diff and the
   empty plan.
5. `reference/residue/steps-4-5.md` — steps 4–5: create and attach the issues,
   name them in the PR body, and the known consequence by linkage shape.
6. `reference/residue/condition-2-removed.md` — why the residue terminal's
   condition 2 is gone. Read it when a residue condition is in question.

Every `<!-- moved: … -->` block in those shards is byte-identical to the text it
was carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit. The frozen branch is cut into four such blocks:
`residue-branch` in `branch.md`, then `residue-branch-step-1`,
`residue-branch-steps-2-3` and `residue-branch-steps-4-5` across the step shards.

**Everything outside those blocks is outside that proof**: the whole of
`risk-threshold.md` and `condition-2-removed.md`, the shard headers, and the
read-on note after `branch.md`'s block. Edit them knowing the byte check does not
cover them.
