<!-- Shard of reference/review-loop.md (#2055), read in its index's order:
     the risk subagent brief. -->

#### Risk subagent brief

The risk subagent makes one round's risk assessment in place of the conductor.
This brief states what it does and what the conductor does around it; the
assessment itself — what is eligible, how `p` and `impact` are judged, the
`risk-<R>.json` shape — is *The risk pass*
(`<skill-base-dir>/reference/review-loop/risk-pass.md`) and `reference/residue.md` §
*1. Assess every residual blocker*, and is restated by neither. The conductor
dispatches `subagent_type: round-risk`, in the foreground
(`run_in_background: false`), one fresh subagent per job; the risk subagent
dispatches nothing.

**The conductor, before the dispatch.**

- **Threshold.** Read `corner_case_risk_threshold` and take one of its three
  states, as *The risk pass* says. **Off** or **ignored**, or **hook mode**:
  dispatch no risk subagent and pass no `--risk`; ignored keeps its narration
  line and PR Summary note. **On**, in step mode: dispatch it every round, the
  promotion sub-loop's rounds and the closing sweep included.
- **Sequencing.**
  1. Dispatch the risk subagent only after reading an `ok` decide verdict for
     the round's latest decide dispatch.
  2. Pass `--risk` only with the `risk_file` of an `ok` risk verdict whose
     dispatch came after that decide verdict.
  3. Whenever the aggregate changes after a risk dispatch — a fresh decide
     dispatch (the CADENCE sequence) or a carry recovery's merge — re-dispatch
     the risk subagent before the next invocation that passes `--risk`.
- **The handoff.** Write `handoff-<R>-risk.json` with `round-handoff.zsh
  write-handoff`: `aggregate_findings_file` the file the round passes as
  `--findings-file` (*Risk pass, then consolidation* above; on a promotion
  sub-loop's round 1, the seeded file, built in the work-dir),
  `worktree_root` as *What the conductor puts in a handoff* says for every kind,
  and `tree_id` the round's `T`.
- **Clear before every risk dispatch.** Delete `<work-dir>/verdict-<R>-risk.json`
  and `<work-dir>/risk-<R>.json`. A delete that fails is report-and-stop.

**The risk subagent.** Read your handoff with `round-handoff.zsh read-handoff
--file <the handoff path your prompt names>`; the scripts are under
`<skill-base-dir>/scripts/`. Then:

1. **Confirm `worktree_root`**: `git -C <worktree_root> rev-parse
   --show-toplevel` must print that path. If it does not, write no risk file,
   and write a `failed` / `wrong-worktree-root` verdict with `round-handoff.zsh
   write-verdict`, carrying `risk_file` and `assessed_count` both `null`.
2. **Assess** every `CRITICAL` and `WARNING` finding in
   `aggregate_findings_file` as *The risk pass* says: afresh, never copied from
   an earlier round, with `p`, `impact` and both rationales.
3. **Write `<work-dir>/risk-<R>.json` once, atomically**, in the #1920 shape —
   the identity verbatim, a digit-string `line` as the number it spells, `[]`
   when nothing is eligible — to a temporary file in the work-dir, then `mv` it
   into place.
4. **Write a `risk` verdict** with `round-handoff.zsh write-verdict --work-dir
   <work_dir>`: `ok` with `cause: null`, `risk_file` = `<work-dir>/risk-<R>.json`
   and `assessed_count` the number of entries in it. Return to the conductor
   only that the verdict was written.

When you cannot read or parse the aggregate, or cannot assess an eligible
finding, write no risk file and return `failed` / `assessment-failed`. A
`failed` verdict carries `risk_file` and `assessed_count` both `null`. The risk
subagent edits no repository file, and never commits, pushes or runs the gate.

**The conductor, after the verdict.**

- **Passing it on.** On an `ok` risk verdict, pass the verdict's `risk_file` as
  `--risk` unopened, and the handoff's `aggregate_findings_file` as
  `--findings-file`. Open neither file. Narrate from `assessed_count`, the
  `risk-<R>.json` path, the status JSON and the progress block; demotions show
  in the progress block.
- **Not-ok and stall.** A risk verdict that validates but is not `ok` is
  report-and-stop. The stall retry above applies unchanged: one fresh
  re-dispatch on a `read-verdict` exit 3, then report-and-stop. Never fall back
  to threshold off, and never invoke the loop without `--risk` while the
  threshold is on.
- **A loop exit 2 naming `--risk`** — a malformed risk file, which writes no
  status JSON: make one fresh risk dispatch whose prompt carries that stderr
  line verbatim, then re-invoke the same round with the same flags. A second
  such exit 2 in the same round is report-and-stop.
