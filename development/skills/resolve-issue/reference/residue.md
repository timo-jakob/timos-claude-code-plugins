# Residue — file the remainder, then ship

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

**The residue terminal is retired (#2580), so nothing reaches this branch.** It
was the branch taken on the residue ending (exit 14), which opened the PR with
non-critical blockers left open. The loop no longer emits that status and no
`next_ref` names these shards: `CONVERGED` is the only review-loop ending that
opens a PR. #2600 removed the filing path — the script that built the plan
and the three step shards that filed it. `reference/residue/risk-threshold.md`
stays for good, because the risk pass reads it.

It is split into shards under `reference/residue/`, each at most 20,000 bytes
(#2056). Read order:

1. `reference/residue/branch.md` — `## Residue branch`: when it runs, why it is
   ordered last, and what to do if the run then ends with no PR.
2. `reference/residue/risk-threshold.md` — `## Risk threshold`: how to read the
   `corner_case_risk_threshold` environment variable, its three states, and the
   probability and impact definitions the loop's risk pass assesses with.
3. `reference/residue/condition-2-removed.md` — why the residue terminal's
   condition 2 is gone. Read it when a residue condition is in question.

Every `<!-- moved: … -->` block in those shards is byte-identical to the text it
was carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit. One such block remains: `residue-branch` in
`branch.md`. The three step blocks were deleted with their shards (#2600).

**Everything outside those blocks is outside that proof**: the whole of
`risk-threshold.md` and `condition-2-removed.md`, the shard headers, and the
read-on note after `branch.md`'s block. Edit them knowing the byte check does not
cover them.
