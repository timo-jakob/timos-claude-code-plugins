# Evidence — #588 end-to-end validation of dependency-aware resolve-issue (epic #583)

Goal: prove the shipped dependency gate (#584 reader, #585 precheck, #586
interactive remediation, #587 epic-as-dependency recursion) behaves as
specified, end to end, against **real GitHub-native `blockedBy` relationships**
— and record the runs as the epic's validation evidence.

Test bed: nine throwaway issues in this repo (#630–#638, label `test-bed`,
closed *not planned* after the runs), wired into three native graphs:

- **Transitive plain chain** — #632 ← #630 (depth 1) ← #631 (depth 2)
- **Cycle** — #633 ← #634 ← #638 ← #633 (see the 2-cycle finding below)
- **Epic blocker** — #637 ← #636 (an `epic`-labelled issue with open child #635)

Two layers of evidence, matching how the feature is built:

- **Script-level** — `dependency-precheck.zsh` run directly against the test
  bed (real GraphQL, no stubs; the bats suites pin the same contracts against
  stubs).
- **Skill-level** — a *separate headless Claude session* loading the local
  plugins (`/development-claude-plugin:test` harness, fresh-context judge)
  actually driving `/development:resolve-issue` on a blocked issue, once per
  mode.

All runs 2026-07-08, plugin `development` 1.75.x, evidence verified by a
fresh-context judge where noted.

---

## S1. Open plain-issue block → rejected with argumentation (script-level)

`dependency-precheck.zsh --issue 632` → **exit 10**, decision
`REJECT_BLOCKED`:

```json
{ "decision": "REJECT_BLOCKED", "open_blockers": [630, 631],
  "blockers": [
    { "number": 630, "open": true, "kind": "issue", "depth": 1 },
    { "number": 631, "open": true, "kind": "issue", "depth": 2 } ] }
```

The `comment_md` argumentation names **every** open blocker with kind + depth
and carries the machine-findable `<!-- dependency-precheck: REJECT_BLOCKED -->`
marker. The transitive blocker (#631, depth 2) is reached through #630 — the
depth field is exactly the deepest-first ordering input #586 consumes.

Counter-run: the same command against a `PROCEED` issue (#588 itself, after
its blockers #586/#587 closed) → exit 0, `open_blockers: []` — closed blockers
are recorded but never block.

## S2. Autonomous mode → comment + `blocked` label, no auto-chain (skill-level)

Headless child session, task framed as **unattended pipeline** run of
`/development:resolve-issue 632`. Judge verdict: **PASS** —

- ran the step-0a precheck → `REJECT_BLOCKED` (#630 d1, #631 d2);
- posted the argumentation as a real comment on #632 (marker present, both
  blockers named), created + applied the **`blocked`** label;
- **stopped**: no branch, no PR, nothing implemented;
- **no auto-chain**: zero comments/PRs/branches on blockers #630/#631.

## S3. Interactive mode → both options offered; decline stops (skill-level)

Headless child session, task framed as **human present**, operator **declines**
both options. Judge verdict: **PASS** —

- precheck `REJECT_BLOCKED` as in S1, argumentation reported
  **in-conversation** — no comment, no label (interactive mode posts nothing);
- offered exactly the two #586 options, stated verbatim: *(1) resolve the
  dependencies AND the named issue* — clear **#631 then #630** (deepest-first),
  re-verify, then build #632 in the same run — and *(2) resolve just the
  dependencies*, then stop;
- on decline: stopped with **zero** GitHub writes and no auto-chain.

**"Both"/"just" execution semantics past the choice point** were not executed
on the test bed — resolving synthetic blockers would have manufactured junk
PRs. They are pinned by SKILL.md (#627) and were **instantiated live by this
epic itself**: #588 sat precheck-`REJECT_BLOCKED` behind #586/#587, the
dependencies were resolved first (PRs #627/#628, each merged before the next
branched), the precheck was re-run on #588 and returned `PROCEED`, and only
then did #588 proceed — the "both" path's resolve → re-verify → proceed cycle
on real issues.

## S4. Epic blocker → classified, named, whole-epic rule (script-level + prose)

`dependency-precheck.zsh --issue 637` (blocked by epic #636 with open
child #635) → **exit 10**, blocker classified **`kind: "epic"`** at depth 1; the
argumentation calls it out as an **open epic**:

```text
- #636 — open **epic**, depth 1
```

That classification is the #587 dispatch point: remediation must run the full
Epic flow (E1–E5) on #636 and #637 stays queued until the epic is **closed**.
The whole-epic execution was likewise not run on a synthetic epic (junk-PR
manufacturing); the reuse-the-epic-flow semantics are pinned by SKILL.md
(#628), and the Epic flow itself is exercised for real by every run of this
epic (#583).

## S5. Dependency cycle → refused cleanly (script-level)

`dependency-precheck.zsh --issue 633` → **exit 11**, decision `REJECT_CYCLE`:

```json
{ "decision": "REJECT_CYCLE", "cycles": [[633, 634, 638, 633]] }
```

The cycle wins over the blocker list (its members are never offered as
"resolve these first"), and the argumentation names the closing path and the
fix (remove whichever relationship points the wrong way).

**Finding — GitHub half-guards cycles.** The GraphQL API **rejects a direct
2-cycle** (`addBlockedBy` on A←B when B←A exists fails with *"this dependency
would create a cycle"*) but **accepted our transitive 3-cycle** of
`#633←#634←#638←#633`. So `REJECT_CYCLE` is not defensive dead code: real graphs
can cycle, GitHub only validates one hop, and the reader's own cycle detection
is what actually protects the flow.

---

## Verdict

Every #588 scenario ran green: open-issue block (S1), autonomous escalation
(S2, judge-verified with real writes), interactive offer/decline (S3,
judge-verified, zero writes), epic-blocker classification + queue rule (S4),
cycle refusal (S5) — with the multi-PR execution semantics of S3/S4
deliberately evidenced by this epic's own lived history instead of synthetic
junk PRs. Docs updated: SKILL.md carried the precheck/remediation/recursion
steps as of #623/#627/#628, ARCHITECTURE.md the dependency model + helper
contract, README the dependency-gate summary (this PR).
