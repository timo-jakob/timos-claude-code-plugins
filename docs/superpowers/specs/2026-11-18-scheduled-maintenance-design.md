# Scheduled maintenance — bugs as a concern, a defined order, unattended runs on a Mac

Date: 2026-11-18. Status: draft for maintainer approval. A separate epic from
the product layer (#3194): this is technical upkeep, not product direction.

Items marked **(my call)** were decided by the author of this document, not by
the maintainer; they are open to correction at review.

## Intent and why

Three kinds of upkeep recur in every repo: **bugs** (issues filed in the repo),
**vulnerabilities** (Snyk fix PRs, code scanning, container scans) and
**dependency updates** (Dependabot, Renovate). The maintainer wants to start any
one of them alone, start all of them in one coordinated run, and have that run
happen on a schedule without him.

Today `/development:maintenance` does two of the three (`--concern=security`,
`--concern=dependencies`), has no notion of bugs, runs its concerns in whatever
order the planner ranks them, and only runs when someone types the command.
Scheduling, a budget and looping have been open ideas since the first weeks of
the repo (#56, #57, #55).

## Goals

1. Each of the three topics can be started alone, by one flag.
2. A run of everything works through the concerns in **one documented order**.
3. A repo can declare a schedule; a Mac that has been told to honour it runs
   maintenance unattended at those times.
4. An unattended run never asks a question, never floods the PR queue, and
   always leaves a record of what it did and what it left for a human.
5. No bug is fixed unattended until a code owner has confirmed what is wrong,
   what the correct behaviour is, and that it is a bug at all.
6. One report per night covers every repo the Mac maintained.
7. The order, the budget, the bug rules and the unattended rules are published
   on the docs site, not only in this dated record.

## Non-goals

- Running in the cloud. A later stage, if ever: the bot keys live in the macOS
  Keychain and the toolchain comes from Homebrew.
- One schedule driving all repos of a multi-repo product from the composition
  repo. That arrives with multi-repo delivery (#3201); until then each repo is
  scheduled on its own.
- Coordinating two Macs that both honour the same repo's schedule.
- New kinds of maintenance work. This changes when and in what order existing
  work runs, and adds bugs as a source.
- Fixing a bug in the same night it was filed. Analysis and fix are separate
  runs with a human confirmation between them, by design.
- Bugs reported by anyone who is not a code owner. They are reported, never
  analysed or fixed.

## Anti-goals (a failure even if it works)

- A scheduled run that stops and waits at a prompt nobody will see.
- A nightly run that opens PRs faster than the maintainer approves them.
- A run that fails silently — a locked Keychain or a missing tool at 03:00 must
  be visible the next morning.
- A filed "bug" that was intended behaviour, a feature or a change request gets
  "fixed", and the product moves against its own concept.
- A schedule that exists only on one machine, with nothing in the repo saying
  the repo is meant to be maintained on a schedule.

## Approaches considered

**Where scheduled runs execute.** (a) On a Mac the maintainer owns; (b) in the
cloud. **Chosen: (a)**, by the maintainer — the complete environment is only
guaranteed there, and a rack-mounted Mac will make it 24/7. If the Mac is off,
the run does not happen; that is accepted.

**What fires the run on the Mac.** (a) A launchd agent that starts a headless
Claude Code session; (b) Claude Code's in-session scheduler; (c) cron.
**Chosen: (a)** (my call). launchd is the macOS-native scheduler: it survives
reboots, runs a missed job once after the machine wakes, and runs inside the
logged-in user's session, which is where the Keychain is unlocked. (b) only
fires while a Claude Code session happens to be open. (c) works but has no
catch-up after sleep and sits outside the user session.

**How bugs are worked.** (a) Maintenance fixes bugs itself, like a scanner
finding; (b) maintenance selects the bugs and hands each to `resolve-issue`.
**Chosen: (b)** (my call). A bug fix is a story — it needs a readiness check, an
implementation, the review loop — and `resolve-issue` already runs unattended
chains that stop only for a human decision. Maintenance coordinates; it does not
grow a second implementation path.

## Design

### 1. Bugs as a fourth concern

`--concern=bugs` joins `security`, `dependencies` and `codequality`. A bug moves
through two unattended steps with a human confirmation between them.

**Whose bugs.** Only open issues labelled `bug` (and `type: bug` once issue
types land, #3196) whose **author is a code owner** of the repo (per its
`CODEOWNERS`). Anything else labelled `bug` is listed in the report as "needs a
code owner to re-file" and is otherwise untouched — its text is never fed to an
implementation. A repo with no `CODEOWNERS` has no eligible bugs, and the report
says so.

**Step 1 — analysis.** For an eligible bug with no bug spec yet, the run writes
a **bug spec** onto the issue:

- **Observed** — what happens now, and how to show it on the current code: a
  test that fails today, or, where no test can show it, exact steps.
- **Expected** — the correct behaviour, and which existing story, spec or
  charter clause says so.
- **Verdict** — *bug*, or *not a bug*. Where no existing specification says the
  current behaviour is wrong, it is a feature or a change request: the run
  proposes the reclassification and stops there. A behaviour that the charter or
  a position makes intentional is named as such.
- **Fixed when** — the acceptance criteria: the falsifying test passes, and
  nothing else that is specified changes.

Analysis writes to the issue only. It changes no code and opens no PR; the
falsifying test is part of the spec's text until the fix step.

**Confirmation — a human.** A code owner reads the spec and confirms it by
applying a label (`confirmed`; my call on the name). The run checks from the
issue's event history that a code owner applied it. Editing the spec after
confirmation voids the confirmation, by the same prose-hash mechanism the
story-spec uses.

**Step 2 — fix.** A confirmed bug carrying none of `needs-refinement`,
`blocked`, `needs-human-decision` and with no open PR is handed to
`resolve-issue` as an unattended chain, one bug after another. The fix must
show the falsifying test **failing on the current code first**, then passing
with the fix; both results go into the PR as evidence. A bug whose test cannot
be made to fail on current code is not fixed: the run reports that the spec
does not reproduce.

**Order within the concern:** fixes of confirmed bugs before analyses of new
ones; within each, `priority: high` first, then oldest first.

**Attended use.** A human typing `--concern=bugs` gets the same two steps and
the same confirmation rule. The confirmation is what makes a bug fixable, not
the absence of a human at the keyboard.

### 2. The order of a full run

An unscoped run, attended or not, works the concerns in this order:

1. **security** — vulnerabilities
2. **dependencies** — Dependabot and Renovate updates
3. **bugs**
4. **codequality**, together with the checks of any topic plugin the repo uses
   (plugin validation, docs drift, manifest and policy checks, …)

Topic-plugin checks belong to no concern today and are skipped under
`--concern`. In a full run they take the last position (my call): like code
quality they have no deadline. On a repo whose primary type is a topic
(`claude-plugin`, `kubernetes`) they are most of the work and still run last —
there is little ahead of them there.

Rationale: an open vulnerability is the costliest thing to leave; dependency
updates often *are* the vulnerability fix and go stale fastest; bugs are known
defects with a human waiting; code quality never has a deadline. The existing
coverage pre-flight stays where it is, ahead of everything.

Within a concern the language plugin's planner still ranks the groups. The order
above is between concerns only.

### 3. Budget

Two limits, both with defaults, both overridable in `.maintenance.yml`:

- **Per concern, per run** (my call on the numbers): security 5, dependencies 5,
  bugs 5, codequality 10 — counted in PRs (codequality and bugs set by the
  maintainer). For bugs, a fix and an analysis each count one. A concern that reaches its cap yields
  to the next; what is left waits for the next run. `--batch=N` keeps its
  meaning as a cap on the whole run and applies on top.
- **Open-queue cap:** a run opens no new PR while more than 5 maintenance PRs
  (my call) are open and waiting for a human. It still merges what is green and
  approved, and still reports. This is what keeps a nightly job from flooding
  the queue when nobody has approved for a week, and it replaces the
  "N items per period" idea of #57: caps per run times runs per week *is* the
  period budget.

**What counts** (my call):

- Against a per-concern cap: every PR the run opens, and every existing vendor
  PR (Dependabot, Renovate, Snyk) it merges or brings to mergeable. Looking at a
  vendor PR and leaving it for a human costs nothing.
- Against the open-queue cap: open PRs **authored by the Maintenance bot** that
  wait for a human review, bug-fix PRs included. Vendor-authored PRs never
  count — six parked major bumps must not stop maintenance for good.
- A full queue stops only the opening of new PRs. Triage and merging of
  existing vendor PRs continue.
- Topic-plugin checks have their own cap of 10, the same as codequality and separate from it.

**Attended runs** (my call): a full run typed by hand includes bugs, in the
defined order. The security, dependencies, codequality and topic caps apply
only under `--scheduled`, so nobody typing the command gets less than today.
The **bugs cap of 5 applies always** — each fix is a full `resolve-issue` run
that can take hours, and an uncapped hand-typed run would chain every open bug.
`--concern=bugs --batch=N` is how a human asks for more.

**The clock is the real limit.** A scheduled run starts no new piece of work
after the cutoff of that day's window on the Mac (07:00 by default, section 5);
what is in progress finishes. With several repos registered on one Mac, the cutoff applies
to the whole night's wave, so repos late in the list may get nothing and the
report says which.

### 4. Declaring a schedule

Optional, in `.maintenance.yml`; a repo without it is never run on a schedule.

- The short form turns it on with the default: **every night, all concerns in
  the defined order, default budget**.
- The long form overrides any of: the days, the concerns included, the
  per-concern caps, the open-queue cap.
- **The clock is not in the repo.** When the night's work starts and when it
  stops taking new work belong to the Mac that does it (section 5): one Mac
  works through all its repos in one wave, so two repos asking for different
  hours would have no meaning (my call — the maintainer asked for the times to
  be overridable per Mac; keeping them out of `.maintenance.yml` altogether
  avoids two places that can disagree).
- No per-concern cadences in the first version (my call — one nightly run with
  caps covers the need; a second axis of configuration can come when a real
  repo needs it).

The declaration says the repo *wants* scheduled maintenance. It does not make
any machine do it.

### 5. Honouring a schedule on a Mac

A new skill, `/development:schedule-maintenance`, run in a repo checkout on the
Mac that should do the work:

- **enable** — reads the repo's declaration, registers the checkout in a
  per-user registry on that Mac, and installs one launchd agent per Mac (not
  per repo) if it is not there yet. With no declaration in the repo, it says so
  and offers the short form; it does not invent a schedule.
- **disable** — removes the repo from the registry; removes the launchd agent
  when the registry is empty.
- **status** — lists the registered repos on this Mac, each with its next run
  time and the outcome of its last run.

**The working window is per Mac and per day of the week.** A window is a start
time and a cutoff — when the night's wave starts, and after when it takes no new
work. The default, set by the maintainer, is **02:00 to 07:00 local time on
every day**. One environment variable in the user's Claude Code `settings.json`
(`env`) overrides it, and can give different days different windows — weekdays
one, the weekend another, or a single day its own (the variable's name and
notation are the builder's; one variable, not one per day — my call).

- A day the override names gets that window; a day it does not name keeps the
  default. A day can be switched off, and then nothing runs on it.
- A window may cross midnight (22:00 to 06:00); it belongs to the day it starts.
- A cutoff that is not after its start, or two windows that overlap, are
  refused with a message naming the day — never silently reordered.
- `enable` and `status` show each day's window and whether it is the default or
  an override. A changed variable takes effect after `enable` is run again,
  since the start times live in the launchd agent; `status` says so when the
  installed agent and the variable disagree.

A repo runs on a day only when both agree: the repo's declaration includes the
day, and the Mac has a window on it.

The launchd agent wakes at the start time, and for each registered repo that is
due that day, one after another (never in parallel — the gate is slower
and flakier under load), it updates the checkout's default branch and starts a
headless Claude Code session running `/development:maintenance --scheduled`.
A lock per Mac prevents a second wave from starting while one is running; a
run still going when the next is due makes the next one skip and say so.

A changed declaration takes effect at the next run without re-enabling: the
agent re-reads it from the updated checkout each time.

### 6. What "unattended" means

`--scheduled` puts the run under these rules:

- **It never asks.** `resolve-issue` already has an unattended path for each of
  its questions. Maintenance has none today; this epic gives each of its
  prompts one, and the rule for all of them is **skip and report** (my call):
  - a missing tool or runtime → the affected concern is skipped and reported.
    A scheduled run **never installs anything**;
  - an interrupted earlier run → no resume. The run starts fresh; PRs the
    interrupted run left open are found as existing PRs and handled as such,
    and its checkpoint is discarded with a line in the report;
  - any other prompt → the choice that changes nothing, reported.
- **It never approves its own work.** Approval stays whatever the repo declares
  — the Approver where one is configured, the maintainer otherwise. A scheduled
  run on a human-approved repo therefore ends with PRs waiting, which is what
  the open-queue cap is for.
- **It leaves a record every time**, in three places: a comment on one standing
  *Maintenance log* issue per repo (created on first use, never closed), a log
  file on the Mac, and its section of the night's report (section 7). The comment
  lists per concern what merged, what is open
  and waiting, what was parked and why, what was deferred by a cap, and how long
  the run took.
- **A run that could not start is also a record.** Keychain locked, a tool
  missing, the checkout dirty or not updatable, no network: the agent writes the
  reason to the log file and, when GitHub is reachable, to the log issue. It
  retries nothing by itself; the next scheduled time is the retry.
- **It never works in a dirty checkout.** The registered checkout is for the
  scheduler; a human's uncommitted work there stops the run for that repo.

### 7. The nightly report

One report per night per Mac, across every repo that Mac maintained.

- **Format:** one self-contained HTML file — styles inline, no external
  resources, readable in a browser and as a mail body. A summary first, across
  all repos: merged, waiting for a human, bugs awaiting confirmation, parked,
  deferred by a cap or the cutoff, could not start. Then one section per repo
  with links to its PRs, issues and *Maintenance log* comment.
- **Built from records, not from prose:** each repo's run writes a JSON record;
  a script turns the night's records into the HTML. A repo whose run could not
  start still has a record, and therefore a section.
- **Stored:** one file per night plus `latest.html`, in a folder on the Mac.
- **Mailed — optional, and a later step.** When a recipient is configured, the
  same HTML is sent as the mail body. It ships as its own story after the file
  report works.
- **Configured per Mac, never in the repo:** the report folder and the mail
  settings are environment variables in the user's Claude Code `settings.json`
  (`env`). An address or a mail account has no place in a repo's
  `.maintenance.yml`, least of all a public repo's. Names are the builder's;
  with no folder variable set there is a default folder (my call), and with no
  recipient set no mail is sent and nothing warns about it.

This is deliberately not a PDF + ePub document: it is an operational report
read in a browser or a mail client, not a product document sent to stakeholders.

### 8. Documentation

- `docs/explanation/workflow-maintenance.md` gains the concern order with its
  rationale, the budget and cutoff, the two-step bug flow and why it exists,
  and the unattended rules.
- A new how-to, "Run maintenance on a schedule", covers: declaring a schedule,
  enabling it on a Mac, what a dedicated always-on Mac needs (a logged-in user
  session, the Keychain unlocked, sleep disabled), confirming a bug spec, reading the
  nightly report and the log issue, turning on mail, and turning it off.
- ARCHITECTURE.md gains the `schedule:` and budget keys of `.maintenance.yml`
  and the `--scheduled` contract.
- Reference pages list the new skill, the new flag and the new concern.

## Constraints

- macOS + Homebrew only, by design.
- `.maintenance.yml` stays optional; every new key has a default.
- zsh for new scripts; anything checkable (due-time computation, registry
  edits, cap arithmetic, bug selection, the lock) is a script with bats tests,
  not prose in a skill.
- The existing concern partition is pinned by tests and prose ("the three
  concerns partition all nine tools"); adding a fourth concern that is not a
  tool changes those sentences and their pins deliberately.

## Delivery

One epic, children in this order:

1. The concern order for a full run + its documentation.
2. Bug analysis: eligibility (code owners), the bug spec, the verdict, the
   confirmation check.
3. Bug fix: confirmed bugs through `resolve-issue`, fail-first evidence.
4. `--scheduled`: the unattended contract, per-concern caps, the open-queue
   cap, the cutoff.
5. The run record, the *Maintenance log* issue.
6. `schedule:` in `.maintenance.yml`: contract, defaults, due-time script.
7. `/development:schedule-maintenance` + the launchd agent + the registry.
8. The aggregated HTML report, stored as a file.
9. How-to and reference pages.
10. Mailing the report (optional, last).

Absorbs #55 (looping over batches — a nightly capped run is the loop), #56
(scheduled runs) and #57 (budget). They close as superseded when this epic is
filed.

## Left to the builder

- Key names in `.maintenance.yml`, the registry's location and format, the
  launchd label, log file location.
- How the headless session is launched (the pattern exists in
  `/development-claude-plugin:test`).
- Child-story boundaries, if the size check asks for a further split.

## To verify first (the design assumes these)

- A launchd user agent can read the Keychain items the token-mint scripts use
  while the user is logged in and the screen is locked.
- A headless Claude Code session started by launchd loads the installed plugins
  and can run a plugin command.
- `resolve-issue`'s unattended chain accepts being started by another skill
  with a list of issues, or needs a small entry point for it.
- GitHub's issue event history names who applied a label, reliably enough to
  check it against `CODEOWNERS` (teams in `CODEOWNERS` need resolving to
  members).
- For the mail story: which way of sending from a headless session on the Mac
  is dependable (an SMTP account with its password in the Keychain is the
  assumed one).
