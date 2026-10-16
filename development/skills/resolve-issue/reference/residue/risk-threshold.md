<!-- Shard of reference/residue.md (#2056), its one remaining shard (#2601).
     The loop's risk pass reads the threshold states and the definitions
     below; nothing else under reference/residue/ remains. -->

## Risk threshold — assess before filing (#1920)

The residue filing steps this section once preceded were removed with the
filing path (#2600), and the residue ending itself with them (#2580, #2601).
What stays is what the loop's risk pass reads:
`review-loop/risk-pass.md` § *The risk pass* takes its three threshold states
from here and its probability and impact definitions from section 1 below.

**First read the variable — it is invisible until you do.** It lives in the
environment your shell commands inherit (a maintainer sets it in their
settings' `env`), so nothing in the conversation shows it. Read it with a
command that expands nothing, so no worktree guard refuses it:

```bash
printenv corner_case_risk_threshold   # exit 1 → unset
```

Then take exactly one of three states — `scripts/risk-threshold-lib.zsh` parses
the value the same way for every script that reads it:

- **Off — unset, empty, or any spelling of zero (`0`, `0.0`, `.000`).** Skip
  the rest of this section: make no assessment, pass no new flag.
- **Ignored — set to anything else that is not a decimal in [0, 1] with at most
  three decimals** (`30`, `1.5`, `-0.1`, `0.0005`, `abc`). Behave exactly as off
  — no assessment, no new flag — but say so in the PR Summary in one line naming
  the value, so the maintainer learns the setting did nothing.
- **On — any other value** (`0.05`, `.05`, `1`). Everything below applies.

Why it exists: every blocker used to block, however unlikely or harmless, and a
review loop that must fix each one can grow a story far past its scope — epic #1795
grew from 3 children to 21 that way. The threshold lets the maintainer set
a floor on **risk**, and a `WARNING` below it is demoted to a suggestion rather
than blocking.

### 1. Assess every residual blocker — before step 1

For each finding to assess, record two values, each with a one-line rationale:

**Probability `p`** — a decimal in [0, 1] with at most two decimals. Which
definition applies follows the finding's `dimension`:

- **`tests`** (a test-strength finding — "mutation X still passes", "branch Y
  is never tested"): the probability that a plausible future change breaks
  exactly that unpinned behaviour without another test catching it.
- **every other dimension** (a defect finding): the probability that the
  described input or state actually arises in this repository's real use.

**Impact** — exactly one of four anchors, the **highest** the consequence
reaches:

| `impact` | consequence if it happens |
|---|---|
| `1.0` | a false result that is trusted — a green gate, a passing check or a merged PR that should have failed; data loss; a security exposure |
| `0.7` | a hang, runaway resource use (CPU, processes, API quota), or a shipped pipeline or skill that does the wrong thing |
| `0.4` | degraded or misleading output, or a run that needs a manual retry or a human to notice and correct it |
| `0.1` | cosmetic, or a test-only nicety with no behavioural consequence |

For a test-strength finding, impact is the impact of the **defect the unpinned
behaviour would let through**, never of the test gap itself.

**Risk** is `p × impact`, computed in integer thousandths (`p` in hundredths ×
`impact` in tenths), so a risk exactly at the threshold is kept and no
floating-point rounding moves a finding across it. You judge; the scripts do the
arithmetic.
