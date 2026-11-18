# Scheduled Maintenance Implementation Plan

> **For agentic workers:** this plan is executed through the repo's own pipeline, not through a superpowers
> execution skill. Each task below is one child story of the scheduled-maintenance epic (#3210: tasks 1–10 are
> #3211–#3220); refine it with
> `/development:refine-issue` when the readiness gate asks, and build it with `/development:resolve-issue`. Tasks run
> **in the order given**, each off fresh `origin/main` — they collide on the maintenance `SKILL.md`,
> `ARCHITECTURE.md` and the `development` plugin version.

**Goal:** Maintenance can be started per topic (vulnerabilities, dependency updates, bugs), runs everything in one
documented order, and runs unattended on a Mac inside a per-day working window, ending in one HTML report per night.

**Architecture:** Everything checkable is a zsh script with a bats suite — concern order, budget, bug eligibility,
confirmation, schedule and window parsing, the registry, the lock, the report. The maintenance skill gains one flag
(`--scheduled`) and one concern (`bugs`) and calls those scripts; new prose goes into `reference/` files, not into the
3,600-line `SKILL.md`. Bugs are fixed by `resolve-issue` in its existing unattended mode. One launchd agent per Mac
runs a wave over registered checkouts, one headless Claude Code session per repo.

**Tech Stack:** zsh, bats (`tests/assertions.bash`, stub `gh` / `claude` / `launchctl`), jq, yq, launchd, Markdown
skills and agents.

**Spec:** `docs/superpowers/specs/2026-11-18-scheduled-maintenance-design.md`

## Global Constraints

- Concern order of a full run: `security`, `dependencies`, `bugs`, `codequality`, then topic-plugin checks.
- Default caps per scheduled run: security 5, dependencies 5, bugs 5, codequality 10, topic 10. Open-queue cap 5.
- The bugs cap applies to every run; the other caps only under `--scheduled`.
- Default working window: 02:00 to 07:00 local time, every day. Windows are per Mac, never in `.maintenance.yml`.
- Per-Mac settings are environment variables from the user's Claude Code `settings.json`:
  `CLAUDE_MAINTENANCE_WINDOWS`, `CLAUDE_MAINTENANCE_REPORT_DIR`, and (Task 10) `CLAUDE_MAINTENANCE_REPORT_MAIL_TO`.
- A scheduled run never asks, never installs a tool, never resumes an interrupted run, never approves its own work,
  never works in a dirty checkout.
- An unattended fix needs: author is a code owner, a bug spec on the issue, the `confirmed` label applied by a code
  owner, and a spec unchanged since.
- `.maintenance.yml` stays optional; every new key has a default. macOS + Homebrew only. zsh; line length 120.
- Repo test conventions apply to every new bats file: bump `SWEPT_FILES`, no `[[ ]]` assertions, unset `GIT_*` and
  `GITHUB_ACTIONS` in fixture `setup()`, single-line jq assertions, hide host `/usr/bin` for stubbed tools,
  `git add` new files before the gate, MAINTAINING.md figures.
- Every fixture is invented. No address, account or private repo name appears in a tracked file.

## Review Focus

1. **Issue and PR titles in the report are attacker-controlled text.** A title containing `<script>` or `&` must
   appear escaped in the HTML. → Task 8.
2. **The Mac slept through the window.** launchd fires the missed job on wake; a wave that wakes at or after that
   day's cutoff starts nothing and records `outside-window` for every due repo. → Task 7.
3. **Daylight-saving nights.** A start time that does not exist (spring) or occurs twice (autumn) must produce
   exactly one wave; the cutoff is compared as an absolute instant computed when the wave starts. → Task 7.
4. **A wave that died.** A lock left by a crashed wave must not block every later night: the lock records a pid and
   a start time and is taken over when that pid is gone. → Task 7.
5. **`CODEOWNERS` variety.** Team entries (`@org/team`), e-mail entries, a file with no owners, no file at all, and
   the file in any of its three legal locations. → Task 2.

---

### Task 1: The concern order of a full run

**Files:**

- Create: `development/skills/maintenance/scripts/concern-of.zsh`,
  `development/skills/maintenance/scripts/order-groups.zsh`, `tests/maintenance-concern-order.bats`
- Modify: `development/skills/maintenance/SKILL.md` (Phase 0 `--concern` text, Phase 6 → 8 hand-over),
  `development/skills/maintenance/reference/pr-cycle.md`, `docs/explanation/workflow-maintenance.md`,
  `ARCHITECTURE.md`

**Interfaces:**

- Produces: `concern-of.zsh <tool>` → prints `security` | `dependencies` | `codequality` | `bugs` | `topic`; exit 2
  on an unknown tool. The one place the tool → concern mapping lives; the `--concern` prose points at it.
- Produces: `order-groups.zsh` — stdin: the merged plan's groups as a JSON array (each with `tool`); stdout: the same
  array, stably sorted by concern rank `security < dependencies < bugs < codequality < topic`, each element gaining
  `"concern"`. Stage 0 (coverage pre-flight) is never passed in.

- [ ] **Step 1: Write the suite**, failing: every tool in the Phase 0 list maps to the concern that list gives;
  a topic tool (`plugin_validation`, `c4_drift`, `manifest_validation`) maps to `topic`; an unknown tool exits 2;
  a shuffled five-concern array comes out in rank order; two groups of one concern keep their planner order; an
  empty array stays empty; a sweep asserts every tool named in Phase 0's `--tool` list is known to `concern-of.zsh`.
- [ ] **Step 2: Run** `LC_ALL=C bats tests/maintenance-concern-order.bats` — expect failures.
- [ ] **Step 3: Implement both scripts.**
- [ ] **Step 4: Wire the order in:** after Phase 6 has every plugin's plan, the groups pass through
  `order-groups.zsh` before Phase 8 walks them. Rewrite the sentence that says the three concerns partition all nine
  tools to name the four concerns and the topic position, and update its pin.
- [ ] **Step 5: Document** the order and its rationale in `workflow-maintenance.md` and ARCHITECTURE.md.
- [ ] **Step 6: Run** the new suite and every suite that pins the edited prose — expect green.

### Task 2: Bug analysis — eligibility, the bug spec, confirmation

**Files:**

- Create: `development/skills/maintenance/scripts/codeowners-logins.zsh`,
  `development/skills/maintenance/scripts/list-bugs.zsh`,
  `development/skills/maintenance/scripts/check-bug-confirmation.zsh`,
  `development/agents/bug-analyst.md`, `development/skills/maintenance/reference/bugs.md`,
  `tests/maintenance-bugs.bats`, `tests/bug-spec-contract.bats`, `tests/fixtures/maintenance-bugs/`
- Modify: `development/skills/maintenance/SKILL.md` (Phase 0: `bugs` concern; pointer to `reference/bugs.md`),
  `ARCHITECTURE.md` (new section *Bug spec contract (`bug-spec/v1`)*), `docs/reference/agents.md`

**Interfaces:**

- `codeowners-logins.zsh [--repo-dir <dir>]` → one login per line, sorted, unique; teams resolved to members with
  `gh api`; e-mail entries skipped. Looks in `.github/CODEOWNERS`, `CODEOWNERS`, `docs/CODEOWNERS`, in that order.
  Exit 0 · 3 no file or no resolvable owner (stderr says which).
- The bug spec: in the issue body, prose between `<!-- bug-spec:prose:start -->` and `<!-- bug-spec:prose:end -->`
  with the headings **Observed**, **Expected**, **Verdict**, **Fixed when**; then a collapsed `<details>` with a
  JSON block: `schema` (`"bug-spec/v1"`), `provenance` (`generated_by`, `generated_at`, `prose_sha256`), `verdict`
  (`bug` | `not-a-bug`), `reclassify_as` (`feature` | `change-request` | null), `falsifying_test` (`{ "path",
  "name", "command" }` or null), `repro_steps[]`, `cites[]`, `fixed_when[]`. Hash from
  `refine-issue/scripts/story-spec-prose-hash.zsh`.
- `list-bugs.zsh [--repo <owner/name>]` → JSON array, one object per open `bug`-labelled issue: `number`, `title`,
  `author`, `priority_high` (bool), `created_at`, `state`, `reason`. `state` is one of `not-eligible` (author not a
  code owner, or no CODEOWNERS), `needs-analysis`, `not-a-bug`, `awaiting-confirmation`, `confirmed`, `held` (carries
  `needs-refinement` / `blocked` / `needs-human-decision`, or has an open PR). Sorted: `confirmed` first, then
  `needs-analysis`; within each `priority_high` first, then oldest.
- `check-bug-confirmation.zsh <issue-number>` → exit 0 confirmed · 1 not, with one stderr line `bug-confirmation:
  <reason>` where reason is `no-spec`, `not-a-bug`, `no-label`, `label-not-by-code-owner`, `spec-edited-after-label`
  (the block's `prose_sha256` no longer matches the prose, or the body was edited after the label event).
- Agent `development:bug-analyst` — tools Read, Grep, Glob, Bash; no writes. Returns one JSON object: `observed`,
  `falsifying_test`, `repro_steps`, `expected`, `cites`, `verdict`, `reclassify_as`, `intentional_per` (a charter
  clause or position, or null), `fixed_when`, `draft_prose`.

- [ ] **Step 1: Write `tests/maintenance-bugs.bats`**, failing (stub `gh`):
  - codeowners: each of the three locations; a team entry resolves to its members; an e-mail entry is skipped; no
    file → exit 3; a file with only e-mail owners → exit 3 (Review Focus 5).
  - list: an outsider's bug is `not-eligible`; no CODEOWNERS makes every bug `not-eligible` with that reason; each
    other state from a fixture issue; the sort order.
  - confirmation: each of the five reasons; a `confirmed` label applied by the issue form (actor = non-owner author)
    is `label-not-by-code-owner`; label by owner then body edit → `spec-edited-after-label`; clean case exits 0.
- [ ] **Step 2: Write `tests/bug-spec-contract.bats`**, failing: pins the four headings, "analysis writes to the
  issue only", "where no existing specification says the current behaviour is wrong, it is not a bug", and the
  agent's output keys.
- [ ] **Step 3: Run both** — expect failures.
- [ ] **Step 4: Implement the three scripts.**
- [ ] **Step 5: Write the contract section, the agent, and `reference/bugs.md`** (step 1 of the flow: for each
  `needs-analysis` bug, dispatch `bug-analyst`, write the spec to the issue body, comment once that it awaits a code
  owner's `confirmed` label; for a `not-a-bug` verdict, propose the reclassification in that comment and stop). The
  falsifying test stays text in the spec; no file is written, no PR opened.
- [ ] **Step 6: Run both** — expect green; mutation-check each confirmation reason.

### Task 3: Bug fix — confirmed bugs through `resolve-issue`, fail-first

**Files:**

- Create: `development/skills/resolve-issue/scripts/fail-first.zsh`, `tests/resolve-issue-fail-first.bats`
- Modify: `development/skills/maintenance/reference/bugs.md` (step 2), `development/skills/resolve-issue/SKILL.md`
  and the `reference/` file that owns §2, `development/skills/open-pr/SKILL.md` (the evidence section),
  `ARCHITECTURE.md`

**Interfaces:**

- `fail-first.zsh record --phase <before|after> --sha <commit> --out <file> -- <command…>` runs the command, appends
  `{phase, sha, command, exit, at}` to `<file>`; always exits 0 itself.
- `fail-first.zsh check --base <sha> <file>` → exit 0 when there is a `before` record at `--base` with non-zero exit
  and a later `after` record with exit 0 for the same command · 1 otherwise, stderr `fail-first: <reason>` with
  reason `no-before`, `before-passed`, `before-not-at-base`, `no-after`, `after-failed`, `command-differs`.
- `fail-first.zsh render <file>` → the Markdown **Bug evidence** section for the PR body.
- Consumes: `check-bug-confirmation.zsh`, `list-bugs.zsh` (Task 2); `resolve-session.zsh --inferred unattended`.

- [ ] **Step 1: Write the suite**, failing: each `check` reason from a fixture record file; the passing case;
  `render` shows command, both exits and both shas; a command containing quotes and spaces round-trips.
- [ ] **Step 2: Run** — expect failures. **Step 3: Implement.**
- [ ] **Step 4: Wire `resolve-issue`:** for an issue whose body carries a `bug-spec/v1` block, §2 first adds the
  falsifying test, records `before` at the branch base, and stops the run with outcome `spec-does-not-reproduce`
  when that test passes; after the fix it records `after`; `check` must exit 0 before a PR is opened, and `render`'s
  output goes into the PR body. An issue without the block is untouched by all of this. Pin each sentence.
- [ ] **Step 5: Wire maintenance:** `reference/bugs.md` step 2 — for each `confirmed` bug in `list-bugs.zsh` order,
  re-run `check-bug-confirmation.zsh`, then run `resolve-issue` on it in unattended mode, one after another; a
  clean stop or `spec-does-not-reproduce` is recorded and the next bug starts.
- [ ] **Step 6: Run** the suite and the prose pins — expect green.

### Task 4: `--scheduled` — never ask, caps, the open-queue cap, the cutoff

**Files:**

- Create: `development/skills/maintenance/scripts/apply-run-budget.zsh`,
  `development/skills/maintenance/scripts/count-open-queue.zsh`,
  `development/skills/maintenance/reference/scheduled.md`, `tests/maintenance-run-budget.bats`,
  `tests/maintenance-scheduled-prose.bats`
- Modify: `development/skills/maintenance/SKILL.md` (Phase 0 flag; each `AskUserQuestion` site),
  `development/skills/maintenance/reference/pr-cycle.md`, `ARCHITECTURE.md`

**Interfaces:**

- `count-open-queue.zsh [--repo <owner/name>]` → an integer: open PRs authored by the Maintenance App that have no
  approving review. Vendor-authored PRs are never counted.
- `apply-run-budget.zsh --caps <json> --queue <n> --queue-cap <n> [--scheduled] [--cutoff-epoch <s>] [--now-epoch
  <s>]` — stdin: `order-groups.zsh` output, each group also carrying `opens_pr` (bool). stdout: `{ "run": […],
  "deferred": [ { …group, "deferred_by": "cap" | "queue" | "cutoff" } ] }`. Without `--scheduled` only the `bugs`
  cap applies. A group with `opens_pr: false` (triage or merge of an existing vendor PR) is never deferred by
  `queue`. `--batch=N` is applied by the caller on `run` afterwards.
- Environment a wave passes in: `MAINTENANCE_CUTOFF_EPOCH`, `MAINTENANCE_RUN_DIR` (Task 5).
- The cutoff is re-checked before each group starts; a group in progress finishes.

- [ ] **Step 1: Write `tests/maintenance-run-budget.bats`**, failing: each cap defers the group after it and keeps
  concern order; unscoped attended run caps only bugs at 5; queue at the cap defers every `opens_pr: true` group
  and none of the others; `now ≥ cutoff` defers everything by `cutoff`; caps from `--caps` override defaults; a
  vendor PR in the stubbed PR list is not counted by `count-open-queue.zsh`; an approved bot PR is not counted.
- [ ] **Step 2: Write `tests/maintenance-scheduled-prose.bats`**, failing: pins, in `reference/scheduled.md`, the
  rule for each existing prompt — missing tool or runtime → skip that concern and report, never install; an earlier
  run's checkpoint → discard, start fresh, report; any other prompt → the choice that changes nothing, reported —
  and a sweep asserting every `AskUserQuestion` mention in the maintenance skill sits next to a
  "under `--scheduled`" clause.
- [ ] **Step 3: Run both** — expect failures. **Step 4: Implement the scripts and the reference file; edit each
  prompt site.**
- [ ] **Step 5: Run both** plus the existing checkpoint and payload suites — expect green.

### Task 5: The run record and the *Maintenance log* issue

**Files:**

- Create: `development/skills/maintenance/scripts/write-run-record.zsh`,
  `development/skills/maintenance/scripts/post-maintenance-log.zsh`, `tests/maintenance-run-record.bats`
- Modify: `development/skills/maintenance/reference/report.md`, `development/skills/maintenance/SKILL.md` (Phase 9),
  `ARCHITECTURE.md` (the `maintenance-run/v1` record)

**Interfaces:**

- Record `maintenance-run/v1`, one JSON file per repo per wave at
  `$MAINTENANCE_RUN_DIR/<owner>__<name>.json`: `schema`, `repo`, `started_at`, `ended_at`, `outcome`
  (`completed` | `cut-off` | `could-not-start` | `outside-window` | `skipped-running`), `reason`, `concerns` (per
  concern: `merged[]`, `opened[]`, `waiting[]`, `parked[]`, `deferred[]`, each item `{number, title, url, note}`),
  `bugs` (`analysed[]`, `awaiting_confirmation[]`, `fixed[]`, `not_a_bug[]`, `not_eligible[]`,
  `not_reproducing[]`), `log_comment_url`.
- `write-run-record.zsh --repo <owner/name> --outcome <o> [--reason <text>] [--from <summary.json>]` writes the
  file atomically; usable by the wave itself for a repo whose session never started.
- `post-maintenance-log.zsh <record.json>` finds or creates the open issue titled `Maintenance log` (label
  `maintenance-log`, created on demand), posts one comment rendered from the record, and writes the comment URL back
  into the record. Exit 0 · 1 GitHub unreachable (the record keeps `log_comment_url: null`).

- [ ] **Step 1: Write the suite**, failing: record shape for each outcome; atomic write (no partial file on a
  killed writer); the log issue is created once and reused; the comment lists every non-empty list and omits empty
  ones; GitHub down → exit 1 and the record still valid; a title with a pipe or backtick does not break the comment.
- [ ] **Step 2: Run** — expect failures. **Step 3: Implement.**
- [ ] **Step 4: Wire Phase 9:** under `--scheduled` the run writes its record and posts the log comment as its last
  act, on every exit path including a cut-off run. **Step 5: Run** — expect green.

### Task 6: `schedule:` in `.maintenance.yml`

**Files:**

- Create: `development/skills/maintenance/scripts/read-schedule.zsh`, `tests/maintenance-read-schedule.bats`
- Modify: `ARCHITECTURE.md` (the `.maintenance.yml` contract), bootstrap's `.maintenance.yml` template comment

**Interfaces:**

- Keys: `schedule: true` (short form) or `schedule: { days: [mon, …], concerns: […], caps: { security: n, … },
  open_queue_cap: n }`. No time keys.
- `read-schedule.zsh [--repo-dir <dir>]` → `{ "enabled": bool, "days": […], "concerns": […], "caps": {…},
  "open_queue_cap": n }` with every default filled in (all seven days; all concerns incl. `topic`; caps 5/5/5/10/10;
  queue 5). No file or no key → `enabled: false`, exit 0. Exit 1 on an invalid value, stderr `schedule: <key>:
  <problem>`; a time-like key (`time`, `start`, `cutoff`, `window`) is rejected with a line saying windows are set
  per Mac.

- [ ] **Step 1: Write the suite**, failing: no file; short form; long form with each key; an unknown day; an unknown
  concern; a negative cap; a time key. **Step 2: Run. Step 3: Implement. Step 4: Write the contract. Step 5: Run.**

### Task 7: `/development:schedule-maintenance`, the registry and the launchd agent

**Files:**

- Create: `development/skills/schedule-maintenance/SKILL.md` and, under its `scripts/`: `parse-windows.zsh`,
  `registry.zsh`, `launchd-agent.zsh`, `run-wave.zsh`; `tests/schedule-windows.bats`, `tests/schedule-registry.bats`,
  `tests/schedule-run-wave.bats`, `tests/schedule-maintenance-prose.bats`
- Modify: `docs/reference/commands.md`, `ARCHITECTURE.md`

**Interfaces:**

- `CLAUDE_MAINTENANCE_WINDOWS` notation: comma-separated `<days>=<HH:MM>-<HH:MM>` or `<days>=off`, where `<days>`
  is a day (`mon`…`sun`) or a range (`mon-fri`, `sat-sun`). Example: `mon-fri=02:00-07:00,sat-sun=03:00-12:00`.
- `parse-windows.zsh` (reads the variable) → JSON array of seven `{ "day", "start", "cutoff", "off", "source":
  "default" | "override" }`. A cutoff earlier than its start means the next day. Exit 1 with `windows: <day>:
  <problem>` for: unparseable entry, a day named twice, zero-length window, a window overlapping the next day's.
- `registry.zsh add|remove <checkout-dir>` and `registry.zsh list` → file
  `~/.claude/maintenance-schedule/registry.json`, entries `{ "dir", "repo", "added_at" }`; `add` refuses a
  directory that is not a git checkout or whose `read-schedule.zsh` says `enabled: false` (exit 3, message offers
  the short form).
- `launchd-agent.zsh install|remove|status` — label `com.claude-plugins.development.maintenance`, plist in
  `~/Library/LaunchAgents/`, one `StartCalendarInterval` entry per enabled day at its start time, program
  `run-wave.zsh`. `status` prints installed windows and exits 4 when they differ from `parse-windows.zsh`.
- `run-wave.zsh` — the launchd entry point. Takes the per-Mac lock `~/.claude/maintenance-schedule/wave.lock`
  (`{pid, started_at}`; taken over when the pid is gone). Computes today's cutoff as an epoch once. For each
  registered repo, in registry order: due today per `read-schedule.zsh`? → preflight (checkout clean; default branch
  updatable; `mint-maintenance-token.zsh` succeeds) → start `claude -p "/development:maintenance --scheduled"` in
  that directory with `MAINTENANCE_CUTOFF_EPOCH` and `MAINTENANCE_RUN_DIR`. A repo that fails preflight, or is
  reached at or after the cutoff, gets a record through `write-run-record.zsh` (`could-not-start` /
  `outside-window`) and the wave moves on. A lock held by a live wave → every due repo gets `skipped-running`.
  Ends by calling Task 8's report script when it exists. Log: `~/.claude/maintenance-schedule/logs/<date>.log`.
- Skill actions: `enable`, `disable`, `status`, as the spec's section 5 describes.

- [ ] **Step 1: Write `tests/schedule-windows.bats`**, failing: default with the variable unset; weekday/weekend
  split; a single-day override on top; `off`; a window across midnight; each refusal with its day named.
- [ ] **Step 2: Write `tests/schedule-registry.bats`**, failing: add, list, remove, add twice is idempotent, the
  two refusals, a path with spaces.
- [ ] **Step 3: Write `tests/schedule-run-wave.bats`**, failing (stub `claude`, `launchctl`, `gh`; clock injected
  through `MAINTENANCE_NOW_EPOCH`): two due repos run in registry order, never concurrently; a dirty checkout →
  `could-not-start` and the next repo still runs; token mint fails → `could-not-start` with the reason; woken after
  the cutoff → `outside-window` for all and no `claude` call (Review Focus 2); a spring-forward night and an
  autumn night each yield one wave (Review Focus 3); a live lock → `skipped-running`; a dead-pid lock is taken over
  (Review Focus 4); a repo not due today is not touched.
- [ ] **Step 4: Run the three** — expect failures. **Step 5: Implement the four scripts.**
- [ ] **Step 6: Write the skill and its prose pins** (`enable` with no declaration offers the short form and
  installs nothing; `status` shows each day's window with its source and each repo's last outcome).
- [ ] **Step 7: Verify on a real Mac, once, and record the result in the PR's test plan:** the agent fires; the
  headless session loads the plugins; the token mint works with the screen locked. A failure here is a finding to
  report, not something to work around silently.
- [ ] **Step 8: Run all four suites** — expect green.

### Task 8: The nightly HTML report

**Files:**

- Create: `development/skills/schedule-maintenance/scripts/build-nightly-report.zsh`,
  `development/skills/schedule-maintenance/templates/report.css`, `tests/schedule-nightly-report.bats`,
  `tests/fixtures/nightly-report/` (invented records)
- Modify: `development/skills/schedule-maintenance/scripts/run-wave.zsh` (call it), `ARCHITECTURE.md`

**Interfaces:**

- `build-nightly-report.zsh <run-dir> [--date <YYYY-MM-DD>]` reads every `maintenance-run/v1` record in the
  directory and writes `<report-dir>/<date>.html` and `<report-dir>/latest.html`; prints the dated file's absolute
  path. `<report-dir>` is `CLAUDE_MAINTENANCE_REPORT_DIR`, default `~/Documents/Maintenance Reports`. Exit 0 · 1 no
  records · 2 usage.
- The file is self-contained: the stylesheet is inlined; no `<script>`, no `<link>`, no remote `src`.

- [ ] **Step 1: Write the suite**, failing: summary totals equal the sums over three fixture repos (merged, waiting,
  bugs awaiting confirmation, parked, deferred, could not start); one section per repo, registry order; a
  `could-not-start` repo has a section with its reason; a title `<script>alert(1)</script> & co` appears escaped
  and the output has no `<script` (Review Focus 1); no `http` in any `src=` or `<link`; `latest.html` is
  byte-identical to the dated file; an empty run directory → exit 1 and no file; a report directory with spaces.
- [ ] **Step 2: Run** — expect failures. **Step 3: Implement** with jq producing escaped fragments
  (`@html`). **Step 4: Call it at the end of `run-wave.zsh`**, on every path. **Step 5: Run** — expect green.

### Task 9: Documentation

**Files:**

- Create: `docs/how-to/run-maintenance-on-a-schedule.md`
- Modify: `mkdocs.yml` (nav), `docs/explanation/workflow-maintenance.md`, `docs/reference/commands.md`,
  `docs/reference/agents.md`, `README.md`

- [ ] **Step 1: Write the how-to**, in this order: starting one topic by hand; declaring a schedule; enabling it on
  a Mac; the working window and `CLAUDE_MAINTENANCE_WINDOWS` with a weekday/weekend example; what an always-on Mac
  needs (a logged-in session, the Keychain unlocked, sleep disabled); the two-step bug flow and how to confirm a
  spec; reading the nightly report and the log issue; turning it off.
- [ ] **Step 2: Extend `workflow-maintenance.md`** with the budget and cutoff, the bug flow and why it exists, and
  the unattended rules. **Step 3: Update the reference pages. Step 4: Run** `mkdocs build --strict` — expect green.

### Task 10: Mailing the report (optional)

**Files:**

- Create: `development/skills/schedule-maintenance/scripts/send-nightly-report.zsh`, `tests/schedule-send-report.bats`
- Modify: `run-wave.zsh`, the how-to, `ARCHITECTURE.md`

**Interfaces:**

- `send-nightly-report.zsh <report.html>` — with `CLAUDE_MAINTENANCE_REPORT_MAIL_TO` unset: exit 0, sends nothing,
  prints nothing. Set: sends the HTML as the mail body, subject `Maintenance report <date> — <n> waiting for you`.
  Exit 0 sent · 1 failed (reason on stderr and in the wave log; the wave's own outcome is unaffected).

- [ ] **Step 1: Verify the sending mechanism first** — the spec's assumption is an SMTP account whose password is a
  Keychain item, sent with `curl`; confirm it works from a launchd-started session. If it does not, stop and report
  with the alternatives rather than picking one.
- [ ] **Step 2: Write the suite**, failing (stub `curl` and `security`): unset variable is silent; the message is
  well-formed MIME with an HTML part; the password never appears in argv, stdout, stderr or the log; a send failure
  is exit 1 and leaves the report file untouched.
- [ ] **Step 3: Implement, call it from `run-wave.zsh` after the report is built, document the settings. Step 4:
  Run** — expect green.
