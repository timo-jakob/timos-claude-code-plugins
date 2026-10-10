# Interactive procedures — a human is present

On-demand reference for `development/skills/resolve-issue/SKILL.md` — read it when the
step that points here is reached, never up front.

Both procedures it carries run only when a human invoked the skill and is
present; an autonomous run takes neither. It is split into shards under
`reference/interactive/`, each at most 20,000 bytes (#2058). Read order:

1. `reference/interactive/remediation.md` — `## Interactive remediation`: the
   §0a offer to clear a shape (i) blockage, and the #1226 note that makes each
   single-issue rung its own telemetry run.

Then, for the interactive extension, in this order:

1. `reference/interactive/extension.md` — `## Interactive extension`: when it
   runs, the `grants` counter, and steps 1–4: summarize, offer, answer a
   question, post guidance.
2. `reference/interactive/extension-grant.md` — steps 5–7: the grant and its
   resume, the soft cap, stop.
3. `reference/interactive/extension-ceiling.md` — the #1226, #1576 and #1583
   amendments to step 5: the resume's `loop_args`, the granted ceiling written
   by `record-grant.zsh`, and the carry accounting a granted resume passes.

Every `<!-- moved: … -->` block in those shards is byte-identical to the text it
was carved out of; `scripts/verify-reference-move.zsh` proves that against the
pinned pre-move commit. `interactive-remediation` sits whole in `remediation.md`;
the frozen extension is cut into two such blocks, `interactive-extension` in
`extension.md` and `interactive-extension-steps-5-7` in `extension-grant.md`.

**Everything outside those blocks is outside that proof**: the shard headers,
the opening notes of `remediation.md` and `extension.md`, the #1226 note after
`remediation.md`'s block, the `CLAUDE_PLUGIN_APPROVER=1` note that follows it
(#2133), and the whole of `extension-ceiling.md`. Edit them
knowing the byte check does not cover them.
