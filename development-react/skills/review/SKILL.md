---
name: review
description: Perform a React idioms review — Rules of Hooks, TanStack Query as the one server-state default, and the Vite SPA shape — with one specialized agent. A topic panel — on a React repo the resolve-issue review loop runs it beside /development-javascript:review, never instead of it.
disable-model-invocation: false
---

You are the React review orchestrator. You run **one** agent, `react-idioms-reviewer`, over a JavaScript or
TypeScript change, and you report its findings under one dimension, `react_idioms`.

**You are a topic panel, not a language panel.** On a React repo the review loop (`/development:resolve-issue`
§3.5) dispatches you **beside** the language panel `review-dispatch.zsh plan` chose as `review_skill` — normally
`/development-javascript:review`, because a React repo detects as `javascript`. You join because `plan` lists you
in `topic_review_skills`. It does that when detect-stack reports `is_react` true (ARCHITECTURE.md, *Review-panel
invocation contract*). Bugs, security, performance, code quality, tests and resilience are the language
panel's dimensions, not yours. Review React idioms only, and never repeat a finding a language reviewer owns.
When the language panel beside you is **not** the JavaScript one (a repo that also holds another language and
records it as `primary:`), say so in your report: no reviewer covers the JavaScript-generic dimensions of that
change.

**Scope:** $ARGUMENTS

If the scope is empty, review all React code in the current project. Otherwise, restrict the review to the
specified files, directories, or areas.

**The whole-project fallback is for a standalone invocation only.** When the
**review loop** drives this panel (`/development:resolve-issue` §3.5), the scope
it hands you is a round's `changed_files` — and from round 2 on that is the
*delta* since the previous round, which can legitimately be empty (#1434). An
empty scope from the loop is never a licence to re-review the whole project:
that is exactly the independent-repeat behaviour delta scoping removes, and the
in-diff findings it produced would be consolidated as the round's result. The
loop's caller is required to re-plan or stop rather than run a panel over an
empty delta, so if you are invoked by the loop with nothing in scope, say so and
review nothing — but still write `[]` to this round's findings file. A panel
that produces no file at all is refused as `STALE_FINDINGS`, so the round cannot
be consumed at all; what the driving session does about that is split by cause
in `/development:resolve-issue` §3.5 step 2, and re-running you is only one of
its arms.

**On a DELTA round that `[]` also needs an accounted-for CARRY.** A delta round
claims two things, not one: that nothing changed since the previous round, *and*
that the previous round's fixes landed. An empty scope covers only the first. So
when the plan names a `fix_verification_path` holding at least one entry, do not
write a bare `[]`: account for every carried entry of your own dimension. For each
carried entry report ONE of: confirmed (name the file:line where the fix is), re-raised (name the
file:line and the unchanged text or the passing mutation you observed still
present), unconfirmed (you could not establish either).
Never re-raise on the absence of a fix. A re-raise goes into the findings file
at its original severity, citing the carried entry; an unconfirmed entry goes
into your report only, never into the findings file — the loop, not you, decides
what a carried entry nobody confirmed or re-raised means (#1583).

If you re-raised nothing and found nothing new, `[]` **is** correct — including
when some carried entries are unconfirmed: the triple, not the findings file,
carries the unconfirmed count, and the loop decides what it means. The rule
forbids a `[]` that skipped the verification, not one that reported it.

**Report the triple whenever your own carry is non-empty** — `say in your report that
you confirmed N carried entries, re-raised M and left K unconfirmed, of TOTAL` —
**whatever you write to the findings file**, `[]` or otherwise. That count is the
only thing that tells a caller a result which passed verification from one that
skipped it, so a round that confirms the carry and *also* finds new blockers
still owes it. Omitting it is treated as a failed round.

**Each reviewer is handed only its own dimension's carry (#2010).** Split the
carry with `review-dispatch.zsh split-carry --fix-verification <path>`: it
prints a `{dimension: path}` map (in hook mode the loop exports that map as
`$REVIEW_FIX_VERIFICATION_BY_DIMENSION`), and each reviewer's Fix
verification line names only the path its own dimension maps to. A reviewer
whose dimension is not in the map gets no Fix verification line and reports
no triple, so every carried entry is accounted for by exactly one reviewer,
its owner, and the reviewers' TOTALs sum to the length of the carry. The
caller-slip rule below is judged against the whole-round carry, never
against one dimension's file.

**A `null` or unreadable carry on a round ≥ 2 is a caller slip, not an empty
carry.** Read it from the plan's `fix_verification_path` **or, in hook mode,
from `$REVIEW_FIX_VERIFICATION`** (`$REVIEW_ADJUDICATED` carries the waived
list) — a hook-mode panel sees no dispatch descriptor at all, so treating a
null `fix_verification_path` as decisive there would declare every hook-mode
round's carry absent when the loop had in fact passed one. The terminal fires
only when **neither** names a readable carry; then it means
`--fix-verification` was omitted. You
cannot enumerate what to re-raise and have no entry to cite, so do not write
`[]` and do not write a findings file at all: report to the caller that the
carry path was absent or unreadable and that the round could not be verified,
naming `--fix-verification` as what to fix. Absence of the carry is never
evidence of an empty one.

**In hook mode, write the accounting too (#1583).** The loop's hook mode reads
the per-entry records behind your triple from `$REVIEW_FINDINGS.carry.json` — an
array of `{file, dimension, title, confirmed[], re_raised[], unconfirmed[]}`
records, one per carried entry, naming its owning reviewer (#2010) — and
refuses the round (CARRY-UNACCOUNTED) without it whenever the carry is
non-empty. In step mode the driving session assembles the same records from
your per-entry lines and passes them as `--carry-accounting`.

**That `[]` is the DELTA-round rule.** Read `scope_mode` from the round's
dispatch descriptor (in hook mode, `$REVIEW_SCOPE_MODE`). An empty scope on a
**full** round is a different fact: it means the *story diff itself* is empty,
so the story changed nothing. Do **not** write `[]` there — zero blockers on a
full round is the loop's CONVERGED condition, and a run that changed nothing
would converge and open a PR. Report the empty story diff to the caller and
write no findings file.

**What is in scope.** React sources: `.jsx` and `.tsx`, and `.js` and `.ts` files, because hooks live in plain
modules too. The scope also covers the `package.json`, `vite.config.*` and `index.html` the diff touches.
Build output, installed dependencies and generated code (`node_modules/`, `dist/`, `build/`, `coverage/`, and a
client generated from an OpenAPI or proto contract) are not: nobody edits them by hand, so a finding against
them cannot be acted on. Say so if the scope named them explicitly.

**A non-empty scope with no in-scope file is NOT APPLICABLE, not clean.** When the loop hands you files but none
of them is in scope (a docs-only story, a workflow-only fix pass), the story changed nothing React. On a
**full** round whose carry holds no `react_idioms` entry, report the round **not applicable** to the caller,
naming the out-of-scope files, and write **nothing** to the findings path. A `[]` there would be the loop's
CONVERGED condition over a change no agent read. Because you run as a topic panel, the driving session reads
that verdict as a panel with nothing to add. It joins nothing for you, and the language panel's verdict alone
decides the round (`development/skills/resolve-issue/reference/review-loop.md`, *Topic panels*). On a **delta**
round, apply the delta-round rules above unchanged. Without launching the agent, write `[]` only when the carry
is empty. **On either kind of round, a carry holding a `react_idioms` entry means you launch the agent**, so
that entry is accounted for even though no file in scope is React, and you write its findings as Step 4 says.
The case is real: a fix pass that deleted or reverted the React file behind a blocker leaves the closing full
sweep with no React file and that blocker still carried, and a bare not-applicable there would leave it
unaccounted, which `review-loop.md` answers by re-dispatching you into the same verdict.

**The carry is shared by every panel of the round.** An entry of another panel's dimension is that panel's to
confirm or re-raise, and the driving session judges the accounting over every panel's per-entry lines together
(`review-loop.md`, *Topic panels*, cited above). So when the carry holds **no** `react_idioms` entry, it counts
as empty for this panel. The rules above about a non-empty carry apply only to this panel's own entries.

**Where you write, beside another panel.** Every panel of a round shares one descriptor, so one `findings_path`
— and in hook mode one `$REVIEW_FINDINGS` and one `$REVIEW_FINDINGS.carry.json` sidecar. **Every** rule in this
skill that tells you to write "the findings file", a `[]` or the carry sidecar — above this paragraph or below
it, Steps 2 and 4 included — assumes you are the round's only panel, and this paragraph governs it. Beside a
language panel, write your array and your carry records **only to paths the driving session or the hook gave
this panel specifically**. Given only the round's shared paths, write **neither** file: return the array under
`## Findings (JSON)` and the per-entry lines in your report, and the joiner concatenates them into the round's
one file and one sidecar (`review-loop.md`, *Topic panels*). Writing the shared file would clobber the language
panel's findings or its carry records; declining to write while also returning nothing would lose yours. Run
standalone, as the only panel, write both as the rules above say.

**Tell the agent the runtime.** Put the React version on the scope line: the `react` entry of the
`package.json` `dependencies` block nearest the files in scope, or `react version unknown` when none declares
it (e.g. `Review scope: src/** (react ^19.1.0)`). React 19 changed which hooks may be called conditionally, so
an agent that has to guess should say so rather than assume the latest.

## Step 1: Launch the Review Agent

Use the Task tool to spawn the agent below with `run_in_background: true`. It is defined in this plugin's
`agents/` directory and already knows what to look for — just pass the review scope.

| Agent | Model | Dimension |
| --------------------- | ----- | ------------ |
| react-idioms-reviewer | opus | react_idioms |

Use its name as the `subagent_type` (`subagent_type: react-idioms-reviewer`) so it runs on the model declared
in its definition, and pass the prompt below — substituting its **Dimension** (from the table above) for
`{DIMENSION}`, its **name** for `{AGENT NAME}`, and the current review **round** for `{ROUND}` (`1` for a
standalone run). This is where the machine-readable JSON layer is wired in, so the reviewer definition stays
pure prose.

The dimension is **prefixed with the topic's own name** on purpose. Several panels join one round, and a
finding's dimension is what the carry accounting and `consolidate-findings.zsh`'s file + line + dimension
dedup key on. A shared name such as `bugs` would merge this panel's findings with the JavaScript panel's
(ARCHITECTURE.md, *Registering a review topic*).

When the **review loop** drives this panel from round 2 on, its dispatch plan
also carries two paths — `fix_verification_path` and `adjudicated_path` — and
the reviewer must be told about both. The first is the only way a fix that
silently did not land gets re-raised (a delta round cannot re-derive it), and the
second is what stops the panel re-litigating what the human already waived. Add
each line below only when the plan names a **non-null** path for it — a
standalone run has no descriptor at all, and on round 1 the loop's own caller
passes no `--fix-verification`. The carry holds every panel's blockers, but the
split-carry map (above) hands the agent only the `react_idioms` entries: the
Fix verification line carries that path, never `fix_verification_path` itself,
and is added only when the map holds `react_idioms` (#2010).

```text
Review scope: {the review scope}
Fix verification (round >= 2): {own_fix_verification_path} — the previous round's blockers. Confirm each one actually landed BEFORE looking for anything new. For each carried entry report ONE of confirmed / re-raised / unconfirmed, as one line keyed by the carry's own spelling — carried entry "<title>" (<file>, <dimension>): confirmed at <file:line> | re-raised (see finding) | unconfirmed — re-raising ONLY what you observed still present, at its ORIGINAL severity, citing the carried entry and the file:line plus the unchanged text or passing mutation in the findings file, even when its file is outside this round's scope; never re-raise on the absence of a fix. A re-raise is a finding whose file, dimension and title are the carried entry's own spelling (title verbatim) and whose line is the carried line or null, with what you observed in its description — under a different title it is not matched to the carry and the round is refused. Every entry in that file is of your own dimension ("{DIMENSION}", which the identity includes) and is yours alone to account for: no other reviewer is shown it. End your report with the triple: carried: confirmed N / re-raised M / unconfirmed K of TOTAL, where TOTAL is the number of entries in that file.
Already waived (round >= 2): {adjudicated_path} — suggestions earlier rounds surfaced and the human waived. Do not re-raise them as Suggestions, EXCEPT in a file the PREVIOUS ROUND'S FIX PASS touched (on a delta round that is this round's scope; on a closing full sweep that NO fix pass preceded the set is empty, so withhold them — but on a sweep the residue promotion earned, a fix pass did run, so the exemption applies as on any round). A genuinely blocking re-raise at CRITICAL/WARNING is always allowed.

Analyze all React code in scope following your instructions. Report every finding using the prose reporting format defined in your agent definition.

Then, after the prose, emit those same findings once more as a single fenced `json` block — a JSON array of finding objects — per the Review finding schema in ARCHITECTURE.md. Each object has exactly: severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line (integer, or null when file-level), title, description, suggested_fix (may be ""), reviewer ("{AGENT NAME}"), round ({ROUND}). Emit [] if you found nothing.
```

## Step 2: Collect Results

Wait for the agent to complete, then read its output.

**An agent that fails is not an agent that found nothing.** If it errors, times out, or returns prose with no
fenced `json` block, re-launch it once. If it fails again:

1. Name the missing `react_idioms` dimension in the Overview and in Metrics, and
2. **Do not write the findings file at all.** Report the round as **failed** to the caller, naming the dimension
   that did not run.

As a topic panel, a failed round fails the whole loop round, exactly as the language panel failing does. The
driving session never consolidates the JavaScript panel's findings as if this one had reported clean. This gate
applies only once the agent was launched: an empty-delta round that carries nothing launches none and still
produces `[]` — written or returned exactly as *Where you write, beside another panel* says, and never to the
round's shared `findings_path`, where a `[]` would replace the language panel's findings with a clean round.

## Step 3: Synthesize the Review

Write the agent's findings up as one review report with this structure:

```text
# React Review Summary

## Overview
Brief summary of what was reviewed and the React health of the change.

## Critical Issues
{every CRITICAL finding — normally Rules of Hooks violations}

## Warnings
{every WARNING finding — normally server state outside TanStack Query}

## Suggestions
{every SUGGESTION finding — normally Vite SPA shape and component-structure deviations, plus any finding
 the agent filed below its row}

## Metrics
- **Total findings:** X (Y critical, Z warnings, W suggestions)
- **Carried entries:** confirmed N / re-raised M / unconfirmed K of TOTAL — required
  on any round whose `fix_verification_path` holds entries, whatever this
  report's findings are (#1583, #2010: with one agent every entry is its own —
  reproduce each reviewer's per-entry lines under this line; they are the
  source of the accounting records)
- **Areas reviewed:** React idioms (`react_idioms`) — on a failed round, **Areas not reviewed:** React idioms

## Verdict
One-paragraph overall assessment with the most important action items.
```

## Step 4: Emit the machine-readable findings file

Alongside the report, take the agent's fenced `json` block (schema: ARCHITECTURE.md → *Review finding schema*)
as this round's findings array — **only when the agent completed** (Step 2 owns the failed case, and it does
not reach here). Every finding already carries its own `reviewer`, `dimension` and `round`. Preserve every
finding: the consolidator (#561) deduplicates downstream.

Always include the array inline as one fenced `json` block under a `## Findings (JSON)` heading, so a caller
reading stdout can pick it up. Then write it to a file under *Where you write, beside another panel* (above):
run standalone, to the path the caller passed, or `review-findings-round-<round>.json` when none is given
(default `round` 1); beside a language panel, only to a path given to this panel specifically, and otherwise to
no file at all — **never** the round's shared `findings_path`, which is the language panel's to write and the
joiner's to extend.
