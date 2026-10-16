# Residue — retired; the risk threshold stays

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

**The residue terminal is retired (#2580), so nothing reaches this branch.** It
was the branch taken on the residue ending (exit 14), which opened the PR with
non-critical blockers left open. The loop no longer emits that status and no
`next_ref` names a residue shard: `CONVERGED` is the only review-loop ending that
opens a PR. #2600 removed the filing path, and #2601 retired the branch itself
and its condition-2 note.

What stays is one shard, `reference/residue/risk-threshold.md`, because the
loop's risk pass reads it:

1. `reference/residue/risk-threshold.md` — `## Risk threshold`: how to read the
   `corner_case_risk_threshold` environment variable, its three states, and the
   probability and impact definitions the risk pass assesses with.

`reference/residue/` holds no `<!-- moved: … -->` block any more: the last one,
`residue-branch`, was deleted with its shard and its manifest row (#2601). The
shard is ordinary prose, outside any byte check.
