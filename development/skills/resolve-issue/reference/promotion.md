# Suggestion promotion

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

It carries the phase offered on a convergence of an interactive run that
waived at least one suggestion, unless the `enable_suggestions` setting is off.
It is split into shards under `reference/promotion/`, each at most 20,000 bytes
(#2057). Read order:

1. `reference/promotion/gate.md` — `## Suggestion promotion on convergence`:
   the gate, the `enable_suggestions` condition, the telemetry id, and steps
   1–2, derive and render the waived set.
2. `reference/promotion/step-3-select.md` — step 3, the multi-select, and the
   offered-vs-promoted telemetry record.
3. `reference/promotion/step-4-sub-loop.md` — steps 4–6: the promote file and
   the sub-loop, the budget, one-shot.
4. `reference/promotion/step-7-terminal.md` — step 7, the terminal and every
   exit the sub-loop can produce.
5. `reference/promotion/step-8-status-files.md` — step 8, keep both status
   files, plus the #1226 sinks and the #1935 round-subagents notes.

Every `<!-- moved: … -->` block in those shards is byte-identical to the text it
was carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit. The frozen phase is cut into five such blocks:
`suggestion-promotion` in `gate.md`, then `suggestion-promotion-step-3`,
`suggestion-promotion-step-4`, `suggestion-promotion-step-7` and
`suggestion-promotion-step-8` across the step shards.

**Everything outside those blocks is outside that proof**: the shard headers,
`gate.md`'s opening note and `enable_suggestions` condition, its read-on note,
and the #1226 and #1935 notes after `step-8-status-files.md`'s block. Edit them
knowing the byte check does not cover them.
