# `c4_drift` findings

`c4_drift` is the maintenance finding source that keeps a repo's C4 Container
diagram true. It is owned by the **`development-docs`** topic plugin and runs
whenever a repo has a `docs/architecture/` directory. It mechanically compares the
containers the diagram **declares** against the containers detection **finds** in
the code, and reports the differences as normal maintenance findings.

To act on a finding, see [Amend a C4 diagram](../how-to/amend-a-c4-diagram.md).
For the declared-container shape the comparison relies on, see
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).

## Finding types

| Type | Meaning | Usual resolution |
| --- | --- | --- |
| `detected_not_declared` | The code builds a container the diagram does **not** declare (a Dockerfile, compose service, or build image with no matching diagram entry). | Add the container to the Container diagram. Mostly mechanical — the diagram was behind reality. |
| `declared_not_detected` | The diagram declares a container detection **cannot** find. | A judgement call: the container was removed or renamed (fix the entry), or it is real but built by a mechanism detection doesn't resolve (leave it, make it detectable). Escalated for human review. |

## How detection confidence changes what is reported

Detection reports a `detection_confidence` of `complete` or `inconclusive`
alongside the containers it found (`{name, source, evidence}` each):

- On **`complete`**, both finding types are reported normally.
- On **`inconclusive`**, `declared_not_detected` findings are **suppressed** — a
  suppression note is emitted instead. Absence of detection is not evidence of
  absence, and a false "your diagram declares a phantom container" finding would
  only train you to ignore the source. `detected_not_declared` is unaffected.

## No-op and degraded cases

- **No `docs/architecture/`** — the source does not apply; nothing is reported.
- **`docs/architecture/` present but `c4-container.md` absent or unparseable** —
  the gather degrades to an empty finding list plus a note, rather than crashing
  the maintenance payload. Fix the page (see the how-to) so it parses.

## What happens to a finding

The `development-docs` maintenance dispatcher routes a non-empty `c4_drift`
finding list to the **`docs-c4-drift-advisor`** agent, which applies the
mechanical `detected_not_declared` additions and escalates the judgement calls
(removals and renames) for human review.
