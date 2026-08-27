# Maintaining this plugin repo

Three things live here: **per-merge plugin version bumps** (critical, every PR
that changes plugin content), a **quarterly template refresh** (slower-paced,
the original purpose of this doc), and the **propagation-invariant pattern**
plus the registry of invariants in force — a repo-wide testing convention rather
than a template task, at the end of this file, which two bats suites assert
against.

> **Writing or moving documentation?** See the
> [Authoring guide](docs/how-to/authoring-guide.md) for where each kind of page
> belongs (the Diátaxis buckets) and the repo-specific docs mechanics — nav
> registration, strict link checking, and the generated command/agent reference
> (don't hand-edit `docs/reference/commands.md` or `agents.md`).
>
> **Adding a repo type?** It needs a `resolve-profile` skill in its plugin —
> `development-<repo_type>/skills/resolve-profile/SKILL.md`, carrying the six
> contract headings — so `/development:resolve-issue` loads that type's driver
> rules at §1b instead of accreting them in the shared conductor (ARCHITECTURE.md,
> *Resolve profile contract*).

## Per-merge: bump plugin versions whenever you change a plugin

**Every PR that modifies content under `<plugin>/`** (a SKILL.md, an agent
file, a script, anything Claude Code loads at plugin install time) must
bump that plugin's `version` field in **both**:

- `<plugin>/.claude-plugin/plugin.json`
- `.claude-plugin/marketplace.json` (the entry for that plugin)

SemVer-ish:

- **Patch** (`1.1.0 → 1.1.1`) — bug fix in an existing SKILL, agent, or
  script. No new capability.
- **Minor** (`1.1.0 → 1.2.0`) — new agent, new skill, new script, or a
  meaningful behavior change in an existing one.
- **Major** (`1.x → 2.0.0`) — breaking change to a plugin's external
  contract (input schema, response shape, expected file layout).

**One plugin-local override.** A plugin whose version prefix is pinned to a
**shipped-slice label** moves only its patch digit until the slice itself grows,
whatever the table above would say. Today that is `development-kubernetes`,
where `tests/kubernetes-plugin-skeleton.bats` asserts the `0.3.` prefix and the
label is reproduced in `README.md` and `docs/reference/plugins.md`. So a
`development`-side story that also edits that plugin's review SKILL.md takes a
patch there and a minor in `development` — moving its minor means moving both
label sites in the same PR, and the test enforces it.

**Why this matters.** Claude Code caches plugins by version in
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`. If you ship a
change without bumping the version, end users (including you on subsequent
test runs) keep loading the stale cached copy — even after `update`. Bugs
"come back from the dead" and fixes appear inert. We've been bitten by this.

The change is one line per file. Make the version bump part of the same
commit as the content change, never a follow-up — that way the cache
boundary lines up with the content boundary.

Plugins that didn't change in a given PR keep their existing version
(don't blanket-bump everything).

**This rule is enforced in CI** by `.github/workflows/marketplace-sync.yml`,
which runs `scripts/check-marketplace-sync.zsh` on every PR touching a
`plugin.json` or `marketplace.json`. If `plugin.json`'s `version` and
`marketplace.json`'s entry for the same plugin disagree, the workflow
fails the PR with a diagnostic showing both versions. Run the script
locally before pushing to catch drift early:

```sh
./scripts/check-marketplace-sync.zsh
```

The check was added in #188 after eight bumps of drift accumulated
silently across PRs #177 → #186 and #187 reset the baseline.

### Two-stage refresh: what end users (including you) need to know

The per-merge version bump above invalidates the per-version cache so
Claude Code stops serving stale content. But the cache is only ONE of
TWO local copies of your plugin source. The other is the marketplaces
clone:

```text
~/.claude/plugins/marketplaces/<marketplace>/
```

This is a git clone of the marketplace repo, checked out to whatever
commit `/plugin marketplace add` initially pulled. Claude Code reads
plugin source from there, not from GitHub directly. Without an explicit
pull, this clone stays at a stale commit indefinitely — even after the
maintainer bumps the version on `main`. The user sees the old templates
even though `git log` on `main` shows the fix landed.

**The end-user-side dance, after a release ships:**

```sh
# In Claude Code (the slash command):
/plugin marketplace update <marketplace>
```

This `git pull`s the marketplaces clone, picking up the new commit
(with the version bump). The version-keyed cache invalidation then
takes effect on next plugin load.

**Verification command** — confirm the marketplaces clone has the
expected version after the refresh:

```sh
grep version ~/.claude/plugins/marketplaces/<marketplace>/<plugin>/.claude-plugin/plugin.json
```

If the version is still the old one, the marketplace refresh hasn't
happened yet. Re-run `/plugin marketplace update`.

**Why this is easy to misdiagnose.** When a published fix appears
inert, the cache is the natural first suspect. But removing a stale
cache directory just causes Claude Code to re-populate it from the
marketplaces clone — which is itself stale — so the next load still
serves old content. Order matters: marketplace refresh first, cache
second (if needed). Diagnosing this in reverse order can burn
substantial time. This was the root cause of the
[ai-doc-organizer 1.3.3 → 1.3.4 misadventure on 2026-06-04](https://github.com/timo-jakob/timos-claude-code-plugins/issues/100).

**Recovery if a release shipped without a version bump.** Past PRs
have occasionally landed without the corresponding version bump (the
exact failure mode the per-merge rule above is designed to prevent).
If a user is stuck on a cached version and `/plugin marketplace update`
alone doesn't dislodge it because the version field on `main` matches
the cached one:

```sh
# Force-invalidate the cache after refreshing the marketplaces clone
rm -rf ~/.claude/plugins/cache/<marketplace>/<plugin>/<stale-version>
```

Then re-invoke any plugin command to re-extract from the (now refreshed)
marketplaces source. This is a hack, not a fix — the right answer is
to land a follow-up release PR that bumps the version. See PR #94 for
the canonical example of a one-line catch-up release.

---

## Quarterly: refresh pinned versions inside `bootstrap` templates

The bootstrap skill generates projects from pinned templates — GitHub Actions
versions, pre-commit hook revs, Docker image tags, brew formulas, language
runtime versions. **GitHub Action `uses:` pins are now tracked automatically
by Renovate** — the custom regex manager in `renovate.json` watches the `.tmpl`
files and raises PRs (see #110), so they're no longer part of this manual pass.
Everything else still lives in `.tmpl` files that neither Dependabot nor any
Renovate manager scans, so the rest of this checklist stays manual.

The pragmatic solution is a manual refresh, roughly **once per quarter**.
Run through this checklist; expect ~10–15 minutes end-to-end.

A newly-bootstrapped project will pick up the latest versions for *its own*
files via its own Dependabot config, so template drift only affects the
moment of first bootstrap — not the ongoing life of any project. Don't lose
sleep if a refresh slips by a month.

## When to refresh

- **Default cadence**: quarterly. Pick a date (e.g., the 1st of every March,
  June, September, December) and stick to it.
- **Trigger refresh sooner if**: a major security advisory affects something
  we pin (rare), or a contributor reports that a bootstrapped project starts
  with conspicuously stale tooling.

## Setup

Make sure these CLIs are available:

```sh
brew install jq gh
```

`gh auth login` if you haven't.

## Step 1 — Inventory what's pinned

```sh
# GitHub Actions versions
grep -rhn -E "uses:\s+[^@\s]+@" development/skills/bootstrap/templates/ | sort -u

# Pre-commit hook revisions
grep -rhn -E "^\s*rev:\s+" development/skills/bootstrap/templates/ | sort -u

# Docker images (FROM and image: fields)
grep -rhn -E "^\s*(image|FROM):\s+" development/skills/bootstrap/templates/ | sort -u

# Runtime versions in setup-* actions
grep -rhn -E "(python|node|go|java)-version:" development/skills/bootstrap/templates/ | sort -u

# brew formula names referenced in preflight.sh
grep -E '"[a-z-]+"' development/skills/bootstrap/scripts/preflight.sh | grep -v "^\s*#" | sort -u

# CLI tool versions a workflow template downloads itself (#1154's kubernetes-ci
# installs kubeconform, kube-linter, kyverno and yq by release URL — these are
# NOT `uses:` pins, so Renovate never sees them and Step 2 never covers them)
grep -rhn -E "^\s*[A-Z_]+_VERSION:\s+" development/skills/bootstrap/templates/ | sort -u

# …and the two sites that MIRROR the templates' yq pin. Both exist so the bats
# suite exercises the same mikefarah yq the shipped workflows use (their own
# comments say so), and neither lives under templates/, so the sweep above
# cannot see them. YQ_VERSION is a FOUR-site lockstep — kubernetes-ci.yml.tmpl,
# no-cluster-deploy.yml.tmpl (#1206) and these two. Bump all four together or
# the suite stops testing what ships.
grep -rn -E "YQ_VERSION[:=]" tests/Dockerfile .github/workflows/script-tests.yml

# …and the two IaC toolchain pins with no `*_VERSION:` upstream (#1199). The
# kubernetes-ci real-tool harness renders with helm and kustomize, which the
# template does NOT install (ubuntu-latest ships both), so there is nothing for
# the sweep above to find. They are pinned in the harness instead, to the
# versions of the `ubuntu-latest` runner image the workflow targets — the one
# class of pin whose upstream is a runner image rather than a release tag, so
# Renovate cannot see it and neither can any grep over templates/.
grep -n -E "^local (helm|kustomize)_v=" tests/iac-tools.zsh

# …and a GUARD, not a to-do list: the IaC docs must name NO version literal.
# They used to, and it was a standing drift hazard — bumping a template pin left
# four documents telling the next reader to reproduce at the old version and to
# treat a red there as a regression, with nothing asserting them. They now point
# at `tests/iac-tools.zsh --print-pins` instead, which cannot drift. This grep
# must print NOTHING; a hit means a literal has crept back in and should be
# replaced by the command, not updated. tests/iac-tools.bats enforces the same
# rule, so a reappearance reds the suite rather than waiting for this sweep.
# The pattern tolerates a backtick/quote around the tool name and a `v` prefix
# on the version, because those are the two shapes a reintroduction most likely
# takes in prose that writes tool names as `code`.
grep -rn -E "(helm|kustomize|kubeconform|kube-linter|kyverno|yq)[\`'\"]?[[:space:]]+v?[0-9]+\.[0-9]+\.[0-9]+" \
  tests/README.md tests/fixtures/kubernetes-repo*/README.md
```

Capture the output in a scratch file. You'll compare it to upstream below.

## Step 2 — GitHub Actions versions (now automated by Renovate)

You no longer refresh these by hand. Since #541 every template ref is pinned to
a full commit SHA with a `# <tag>` comment (the shipped semgrep gate blocks
mutable tags in downstream repos, so templates can't float on major tags).
Renovate's custom regex manager watches those pins in the `.tmpl` templates and
opens a batched **github-actions** PR covering digest refreshes and tag bumps
alike. Your job is to **review and merge** those PRs; for a major bump, read
the release notes first.

Renovate covers **two** things here, in two separate PRs: the batched
**github-actions** PR above, and its own **api-styleguide** PR bumping the org
Spectral pin (#689). That second one is deliberately kept out of the batch — it
changes what every **newly** bootstrapped repo's CI enforces (existing repos keep
their own pin until a human bumps it, #1359), so it gets its own review —
and it moves a **three-site lockstep**: `templates/common/.spectral.yaml`,
`styleguide/spectral/ruleset.yaml` and `docs/how-to/adopt-the-api-styleguide.md`
must all quote the SAME pin. A repo-wide sweep in
`tests/api-styleguide-ruleset.bats` fails any partial bump, so if you ever move
the pin by hand, move all three.

The remaining steps below (pre-commit revs, Docker tags, runtime strings, brew
formulas, and the `*_VERSION:` CLI pins a template downloads by release URL)
Renovate doesn't see, so those stay manual. The `*_VERSION:` class is worth a deliberate look each pass:
`YQ_VERSION` is a **four-site lockstep** — `kubernetes-ci.yml.tmpl`,
`no-cluster-deploy.yml.tmpl` (#1206), `tests/Dockerfile` and
`.github/workflows/script-tests.yml` — because the bats suite asserts both
templates' `yq -o=json` behaviour; move all four or the suite validates the
shipped workflows under a different yq than they ship with.

`tests/iac-tools.zsh`'s `helm_v` / `kustomize_v` are the odd pair out (#1199):
their upstream is the **`ubuntu-latest` runner image**, not a release tag, so
"current" means whatever that image ships today.

**Confirm which image that label resolves to before reading anything** — it
moves on GitHub's schedule, not this repo's, and `kubernetes-ci.yml.tmpl` pins
`runs-on: ubuntu-latest`. Reading a stale manifest is worse than not reading one:
you would bump the constants to the *previous* image's versions and stamp a
provenance line claiming they came from `ubuntu-latest`.

```sh
# 1. which image does the ubuntu-latest LABEL resolve to today? The label
#    mapping lives in the runner-images root README — NOT in the images/ubuntu
#    listing, whose highest-numbered manifest is usually a newer image that
#    ships under its own label first and is not yet ubuntu-latest.
gh api repos/actions/runner-images/contents/README.md \
  --jq .content | base64 -d | grep -iE 'ubuntu-latest|ubuntu-2[0-9]'
# 2. then read THAT manifest — substitute the version step 1 confirmed
gh api repos/actions/runner-images/contents/images/ubuntu/Ubuntu2404-Readme.md \
  --jq .content | base64 -d | grep -iE '^- (Helm|Kustomize) '
```

Bump the two constants to match, and update the date in that script's
`PROVENANCE` comment. A drift here is quiet rather than red: the harness keeps
passing, it just stops rendering the fixtures with the helm the consumer's CI
actually uses.

Actions to pay particular attention to when reviewing a major bump (most likely
to ship breaking changes between majors):

| Action | Major bumps usually need |
| --- | --- |
| `actions/checkout` | Node version bumps — usually safe |
| `actions/setup-*` | Verify the cache key format hasn't changed |
| `docker/build-push-action` | Read release notes — output and input names change |
| `docker/metadata-action` | Tag pattern syntax sometimes evolves |
| `aquasecurity/trivy-action` | Versioned by date-ish tags (0.28.0, 0.29.0) — usually safe |
| `SonarSource/sonarqube-scan-action` | New majors often require config changes — read notes |
| `ossf/scorecard-action` | Check the v2 → v3 if/when it happens |
| `sigstore/cosign-installer` | Stable; minor cosmetic changes only |

## Step 3 — Refresh pre-commit hook versions

Inside `development/skills/bootstrap/templates/common/.pre-commit-config.yaml.tmpl`,
each hook block has a `rev: vX.Y.Z`. Compare each `repo:` URL against:

```sh
# Latest release tag for the upstream pre-commit hook repo
gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'
```

Repos to check:

- `pre-commit/pre-commit-hooks` — standard hooks, very stable
- `gitleaks/gitleaks` — adds new secret patterns regularly
- `returntocorp/semgrep` — fast-moving; check for new rules
- `astral-sh/ruff-pre-commit` — fast-moving Python linter
- `golangci/golangci-lint` — major bumps sometimes change config schema
- `pre-commit/mirrors-eslint` — eslint+TS plugins, version-matched

After bumping, run `pre-commit run --all-files` against a sample bootstrapped
project to verify nothing breaks. New rule additions in ruff/semgrep
sometimes produce surprise warnings; that's a feature, not a bug.

## Step 4 — Refresh Docker image tags

Look for `image: <name>:<tag>` in the templates. Current pins:

| Image | Where | Refresh policy |
| --- | --- | --- |
| `sonarqube:community` | `templates/private/infra/sonarqube/docker-compose.yml.tmpl` | Stable tag; pulls latest on `docker compose pull`. No template change needed unless SonarQube introduces a breaking change. |
| `postgres:16-alpine` | same | Bump major (16 → 17) once per Postgres release cycle (~yearly). Test that SonarQube CE still works against it. |
| `cyclonedx/cyclonedx-cli:latest` | quality workflows | `:latest` is intentional — we want fresh CycloneDX validation. No bump needed. |
| `returntocorp/semgrep` | quality-public.yml | Same — using floating tag. No bump needed. |

Always read upstream release notes before bumping a major like Postgres.

## Step 5 — Refresh runtime versions

These are language version strings, NOT actions. Dependabot doesn't know
about them and neither does Renovate's stock managers.

Locations:

```sh
grep -rn "python-version\|node-version\|go-version\|java-version" development/skills/bootstrap/templates/
```

Decisions:

- `python-version: "3.12"` — bump to a new minor when one is released and a
  reasonable rollout window has passed (3 months after release is a safe
  default). Verify your default linter (ruff) and test runner support it.
- `node-version: "20"` — Node ships major LTS releases yearly. Bump when the
  current LTS hits maintenance mode (consult
  [nodejs.org/en/about/previous-releases](https://nodejs.org/en/about/previous-releases)).
- `go-version: "stable"` — evergreen, no bump needed.
- `java-version` — bump on LTS releases (8, 11, 17, 21, 25 …).

Be conservative. A runtime version bump in the template forces every newly
bootstrapped project onto that version; existing projects keep their own.

## Step 6 — Refresh brew formula names

The bootstrap preflight script (`scripts/preflight.sh`) installs brew
formulas by name. Names occasionally change (we hit this with
`snyk` → `snyk-cli`). Spot-check:

```sh
# Show the current required formulas
grep -E '"[a-z-]+"' development/skills/bootstrap/scripts/preflight.sh | grep -v "^\s*#"

# For any formula you suspect, confirm it still exists and has the same name
brew search <name>
brew info <name>
```

If a formula has been renamed, update `preflight.sh` and verify the binary
name still maps correctly via the `bin=...` case statement.

## Step 7 — Verify nothing broke

```sh
# Shell scripts still parse
find development/skills/bootstrap/scripts -name "*.sh" -exec bash -n {} \;

# YAML templates would still parse if you stripped placeholders
# (manual; quick visual scan is usually enough)

# Run preflight in dry-run mode
./development/skills/bootstrap/scripts/preflight.sh \
  --visibility public --languages "" --has-dockerfile false
```

If you can spin up a test project, run `/development:bootstrap` against it
and confirm:

- All generated files have no remaining `{{PLACEHOLDER}}` text.
- A `gh workflow view` of the generated workflows shows no parse errors
  on GitHub's side.

## Step 8 — Commit

Open a single PR per quarter titled `chore/template-refresh-YYYY-Qn`. Body
lists the bumps and any notes (deprecations seen, breaking changes
avoided, runtime versions deferred and why). Self-review through the
existing bootstrap-* review agents if the changes are significant.

---

## What this checklist explicitly skips

- **Renovate in the bootstrap templates** — deliberately not done. Renovate now
  runs on *this* repo to track the GitHub Action pins inside the `.tmpl`
  templates (the gap Dependabot can't cover — see #110), but we do **not** swap
  Dependabot for Renovate in the templates we ship downstream. Bootstrapped
  projects have standard manifests Dependabot handles well, without imposing a
  third-party bot (Mend, Inc.). Renovate here, Dependabot everywhere we ship.
- **Self-hosted updater workflow** — possible but adds ~150 lines of
  code to maintain. The manual cadence is cheaper at our throughput.
- **Automated runtime-version policy** — `python-version` and friends are
  judgment calls, not pure version bumps. Manual review per release.

If the manual cadence ever starts feeling tedious, revisit the
self-hosted-updater option. Until then, this checklist is the cheapest
path.

## Propagation invariants

This repo deliberately **restates** each cross-cutting rule in many artifacts —
a skill, a template, a workflow header, a script header, a how-to,
`ARCHITECTURE.md`, this file. The redundancy is a feature for whoever is reading
one of those artifacts and a trap for whoever is editing the rule: a change is
an N-site edit, and the sites that lag get found **one review round at a time**.
The #687 review loop spent rounds 7, 8 *and* 9 on a single partially-propagated
clause; roughly 20 of its 49 blocking findings across those rounds were one rule.

A **propagation invariant** is the fix. It is a test that **derives** a rule's
restatement sites and holds every site that *states* a clause to that clause,
gating on the sites that do, so a half-finished propagation reds the suite
rather than surfacing as a review finding a round later.

**When to add one.** A rule restated in **three or more** artifacts, or **any**
rule a review has already caught partially propagated. Add the assertion in the
**same PR that introduces the clause** — a sweep only pins the clauses someone
thought to pin, and #687's escapee was a clause added to a rule that already had
a sweep.

**Name the authoritative site.** Exactly one artifact states the rule; the others
follow it. Name it in the test and in the table below, so a disagreement has a
defined winner instead of a debate about which copy is right.

**Derive the roster, never transcribe it.** A closed hand-written file list rots
— #936 broke #1188's within a week, and #1206's own round 3 found this file
naming four sites when there were seven. Four discovery mechanisms are in use (two of them `find`, at different scopes)
and the criterion is neutral among them; which one fits is a property of the
rule:

| Mechanism | Fits a rule whose sites | In use by |
| --- | --- | --- |
| `git ls-files` | span the repo, or share a filename token | `tests/messaging-position.bats`, `tests/no-inert-permission-barriers.bats` |
| `find` over a named tree | are confined to one tree | `tests/kubernetes-plugin-skeleton.bats`, `tests/no-inert-bracket-assertions.bats`, `tests/render-docs-templates.bats` |
| `find` over the repo root | span the repo, where untracked files must count | `tests/api-styleguide-ruleset.bats` |
| `grep -rl` over named directories (fixed string or ERE) | are identified by a distinctive phrase | `tests/no-cluster-deploy.bats`, `tests/iac-selection-rule.bats` |

**`git ls-files` has one live caveat, and one that is now historical.**
`api-styleguide-ruleset.bats` uses `find` over the repo root *deliberately*,
because `git ls-files` skips **untracked** files — a new doc quoting a stale pin
then passes locally and fails in CI (#1189's lesson). That reason is live: weigh
it whenever untracked files must count. It also *used* to fatal in the Docker
lane's worktree checkout, inspecting nothing while reporting success (#1330);
**#1360 repaired that** by bind-mounting the git dir and the git common dir in
`tests/run-script-tests.zsh`, and two sweeps in the table above rely on it
working there today. So a `git ls-files` sweep is fine — it just has to run
under that runner.

**One rule, one discovery.** A rule that already has a derived roster gets its
new clause added to *that* sweep. Two rosters for one rule can disagree, and a
site would then be swept by one clause test and not another.

**Scope the needle to the statement, not the file.** In an artifact large enough
that an unrelated paragraph could satisfy the needle — a 5000-line `SKILL.md`, a
2000-line `ARCHITECTURE.md` — a file-scoped sweep reports green having proved
nothing about the statement it was written to pin. Locate the gate phrase's line
with `prose_gate_lines` and assert over `prose_window`; `prose_body` is safe only
on a file whose whole subject is the rule. The same applies to a needle *inside*
the authoritative site: pin the full clause, because a short phrase that recurs
elsewhere in the file survives the rule statement losing it.

**Gate on every spelling the sites use.** A gate is a literal, and one literal
finds one wording. If the rule is stated three ways across the roster, gate on
all three — a statement written in an ungated spelling is invisible to the sweep
*and* to the tripwire, so the file looks covered while its other restatements
drift freely. Keep each gate short enough to survive a reflow: `prose_gate_lines`
matches per line, so a gate phrase that wraps stops matching silently.

**Gate the clause, and prove the gate fired.** Not every roster member restates
every clause — a summary that points elsewhere ("see `SETUP.md` §3h for the three
exemptions") should not be forced to carry one. So gate each clause on a needle
that identifies the sites which do state it, and assert `gated >= 1` as the
anti-no-op floor, or a needle that quietly stopped matching turns the sweep into
a green no-op. A floor alone is weak, though — it is satisfied by one surviving
site — so **record the exact gated count in the table below** and tie it to the
derivation, as the invariants in force do.

**Carry a roster tripwire.** A derived sweep answers *do the sites I found
agree?* and never *did a site appear or vanish?* — so a new restatement can land
tomorrow, carry every clause, and pass in silence. Record the derived count and
tie the recorded figure to the derivation, so adding or removing a site reds
until this file is updated in the same PR. Record every figure that moves
independently: a roster count alone will not notice a seventh *statement* inside
files already on the roster.

**Carry a non-vacuity control.** Mutate at least two real sites — **one prose
site and one code/template site** — and assert the sweep reds on each. Two file
kinds, because the normalisation these sweeps depend on (stripping comment
markers, so a clause wrapped across two `#` lines still reads as prose) can fail
on one kind and not the other. Record both mutations in the test file, or the
control rots into a tautology nobody can audit. Cover each distinct *gap kind*
the sweep can report, too — an arm no control exercises is an arm that can rot
unnoticed.

**These sweeps pin WORDING, not meaning.** A needle is a literal, so a
substantively-correct rephrase at one site reds the suite. That is the intended
cost: the red is telling you to reword all N sites, not reporting a bug. Say so
to yourself before "fixing" the test.

### Invariants in force

| Invariant | Authoritative site | Sweep | Derived roster |
| --- | --- | --- | --- |
| **#1206 direct-to-cluster gate** — the v1 command set and the three exemptions, including the guarded-creator narrowing (#1432) | `templates/common/scripts/check-no-cluster-deploy.zsh` header | `tests/no-cluster-deploy.bats` | `grep -rln 'no-cluster-deploy'` over `development/skills/bootstrap docs MAINTAINING.md ARCHITECTURE.md`, minus wiring, index and authoritative sites — 6 restatements plus the authoritative header, 5 enumerating the ephemeral exemption (gated on `ctlptl`), 5 ephemeral-exemption statements |
| **IaC selection rule** — at most one IaC workflow per repo; the condition is the marker, not merely the absence of a language (the dual-marker halt is a #1162 specification, not current behaviour) (#1432) | `ARCHITECTURE.md` | `tests/iac-selection-rule.bats` | `grep -rlE 'iac[-_]only'` over `development docs ARCHITECTURE.md`, minus the authoritative site and `docs/superpowers/` — 6 roster files, 4 stating the selection, 8 selection statements |
| **Closing-sweep grant** — the review loop's closing full sweep gets a one-round grant past the ceiling, once (#1434). *(Summarised, not restated: carrying the pinned clause here would make this registry a fourth governed site.)* | `development/skills/resolve-issue/scripts/resolve-story-loop.zsh` — `closing_sweep_round=$(( round + 1 ))`, the line the sweep derives its increment from rather than transcribing it. The one-round bound is *also* enforced by the `--resume` adoption clamp (`closing_sweep_round > effective_max + 1`), which the sweep does not derive from — see residue 4 | `tests/review-loop-budget-consistency.bats` | `git ls-files '*.md'` minus `docs/superpowers/**`, kept to the sites carrying the literal grant clause — 3 roster files (`development/skills/resolve-issue/reference/review-loop.md` — the grant moved there with the AWAITING_FIX branch in #1503, `docs/explanation/review-loop.md`, `ARCHITECTURE.md`), each gated on exactly 1 statement, so gated == roster == 3 |
| **Resolve profile contract** — every `development-<repo_type>:resolve-profile` skill matches the contract stated at the authoritative site: its `##` heading roster in the declared order, each heading carrying a body (one with nothing to say says `none`), a `name: resolve-profile`, and a description beginning `Loaded by /development:resolve-issue — not for direct use` (#1504). *(Summarised, not restated: the heading strings live in the authoritative site, in every shipped profile, and in this sweep's own `HEADINGS` array. Naming them here would add one more governed site, which is the drift this column exists to avoid.)* | `ARCHITECTURE.md` — *Resolve profile contract* | `tests/resolve-profile-contract.bats` | `git ls-files 'development-*/skills/resolve-profile/SKILL.md'` — 6 profiles today (`development-claude-plugin`, `development-python`, `development-java`, `development-go`, `development-swift`, `development-kubernetes` — every `repo_type` the dispatcher can emit, #1505), gated on every clause above, so gated == roster == 6. The sweep reads that figure back **out of this row** and compares it to the derived count — and does the same for `ARCHITECTURE.md`'s `Profiles populated today: **N**` sentence, so **three** figures move together or the PR reds: the test's own count, this row, and that sentence. Since #1505 the set is also gated **both ways** against the dispatcher's own `repo_type` list, so a new repo type without a profile reds the suite |
| **Review-panel loop duties** — every review panel states that an EMPTY scope from the loop is never a licence to widen, and that on a **delta** round **carrying nothing** it must still write `[]` — never on a full round, and never against a non-empty (or, on a round >= 2, null) carry — and that it reports how many carried entries it confirmed on any round whose carry is non-empty, whatever it writes to the findings file, and that from round 2 on it forwards the plan's two carry paths into every agent's prompt (#1434). *(The invariant is the two duties, not the wording: each panel spells them in its own scope vocabulary.)* | `ARCHITECTURE.md` — *the emission directive lives in one place* | `tests/review-loop-budget-consistency.bats` | `git ls-files 'development-*/skills/review/SKILL.md'` — 6 panels, each gated on both duties, so gated == roster == 6 |

**Every roster is deliberately scoped, and no scope is an accident.** The
closing-sweep roster (#1434) is the widest and the simplest: every tracked
`*.md` outside `docs/superpowers/**`, narrowed to the sites that carry the
literal grant clause. It can afford that width because the clause is a distinct
sentence rather than a flag name, so membership needs no proxy — and it must
have it, because the rule's restatements are spread across an instruction skill,
a user-facing explanation and the contract doc rather than clustered in one
plugin. The panel-duties roster (#1434) is the narrowest and needs no clause
proxy at all: its members are identified by *path* — every
`development-*/skills/review/SKILL.md` — so the roster cannot drift from the
population, and the needles it then applies are load-bearing fragments rather
than whole sentences, because the two duties are deliberately worded per panel.
The profile roster (#1504) is the same path-identified shape, one directory
over: every `development-*/skills/resolve-profile/SKILL.md`. It is the only one
whose population is expected to *grow on a schedule* — #1505 adds five profiles
at once — which is why its count is recorded here and asserted exactly rather
than as a floor: the growth has to be a deliberate edit to this row, not a
silent widening.
The other two are narrower than the closing sweep's, for the reasons below. The
gate's own roster (#1206) sweeps `development/skills/bootstrap`, `docs/`, this file and
`ARCHITECTURE.md`; a restatement of the gate's rules landing in the root
`README.md`, a sibling topic plugin or `tests/` is out of roster on purpose,
because those describe the gate rather than state its rules. Widen it if that
stops being true.

**The IaC roster is scoped to the `development` plugin and `docs/`, and that is
a decision.** Membership is decided by naming the *flag*; the clause is judged on
how the site states the *rule*. Sibling topic plugins
(`development-kubernetes/`, `development-opentofu/`) and `README.md` describe
primary-**eligibility** — which plugin may declare `primary:` for a
language-less repo — rather than which CI workflow gets rendered, so they are
out of roster on purpose. Widen the roster if that ever stops being true.

**Known residue, so the registry is not read as stronger than it is.** The
entries below are recorded here rather than fixed, each wanting its own issue —
stated without a count so the next addition cannot desynchronise it:

1. `tests/bootstrap-iac-pipeline.bats`'s *the `--iac-only` qualifier is stated
   identically at every restatement* (#1154) walks a **closed, hand-written
   three-file list**. It predates this pattern and should be converted to a
   derived roster.
2. **The three pre-#1432 clause sweeps in `tests/no-cluster-deploy.bats` are
   still file-scoped** — the three-exemptions, `--dry-run`-value and
   command-set sweeps flatten the whole file and needle it. On
   `bootstrap/SKILL.md` that is near-vacuous for the command-set sweep, whose
   needles include bare `create`, `delete` and `install`: dropping a verb from
   §3a's restatement is satisfied by any other use of the word in a 5000-line
   document. Only the #1432 guarded-creator sweep is statement-scoped. So
   *Scope the needle to the statement* describes where this invariant is going,
   not everywhere it already is.
3. The **IaC roster is derived from sites naming the `--iac-only` flag**, not
   from the rule's own spellings, so sibling topic plugins, the plugin
   manifests, `README.md` and `development/skills/maintenance/SKILL.md` state
   the selection outside its reach. `tests/iac-selection-rule.bats`'s header
   enumerates them.
4. **Both #1434 sweeps are file-scoped and carry no recorded mutation
   control.** The closing-sweep grant sweep and the panel-duties sweep in
   `tests/review-loop-budget-consistency.bats` needle whole files — including a
   5000-line `SKILL.md` and `ARCHITECTURE.md` — rather than the statement, and
   neither records the two-site mutation control *Carry a non-vacuity control*
   asks for. What each does carry is a **derived roster with an asserted size**,
   which is the property that stops a new site landing unguarded; the needles
   are then load-bearing fragments of the rules themselves (`exactly one round` … `beyond`,
   `never a licence to`, `fix_verification_path` — split here on purpose: the
   grant sweep derives its roster by grepping every tracked `*.md` for that
   needle as ONE line, so quoting it whole would add this file to the roster
   and red the test with no rule having changed), not incidental
   words, so file scope costs less here than it does for the command-set sweep
   in residue 2. Read the two rows as "the roster cannot rot", not as "the
   statement cannot drift within a file". The closing-sweep row carries a
   second, narrower gap of the same kind: the grant's one-round size is stated
   twice in the script — once as the promotion's `round + 1`, which the sweep
   derives from, and once as the `--resume` adoption clamp's `effective_max + 1`,
   which nothing derives from. A retune would have to move both.

### The #1206 lockstep, in detail

**The #1206 gate has a prose lockstep of its own.** Its v1 command set and its
three exemptions are restated in **seven** places — the checker's header
(`templates/common/scripts/check-no-cluster-deploy.zsh`) is the authoritative
one, and the other six must follow it:

| Site | Carries |
| --- | --- |
| `templates/common/scripts/check-no-cluster-deploy.zsh` header | **authoritative** — full command set, three exemptions, known gaps, the guarded-creator narrowing |
| `templates/common/.github/workflows/no-cluster-deploy.yml.tmpl` header | the three exemptions, in summary + the guarded-creator clause (#1432) |
| `templates/common/SETUP.md.tmpl` §3h | the consumer-facing table + all three exemptions + known gaps + the guarded-creator clause |
| `templates/common/CLAUDE.md.tmpl` | the agent-facing CI bullet + the guarded-creator clause (#1432) |
| `templates/common/CONTRIBUTING.md.tmpl` | the contributor-facing CI bullet — a summary that points at §3h, so deliberately outside the exemption-enumerating gate |
| `development/skills/bootstrap/SKILL.md` §3a | the bootstrap instruction's own restatement + the guarded-creator clause (#1432) |
| `docs/how-to/keep-app-repos-out-of-the-cluster.md` | this repo's how-to + the guarded-creator clause + **its own `Known gaps (v1)` mirror** (#1432) |

Widening the command set or changing an exemption's scope moves all seven; the
checker's header says "anywhere this script's rules are restated, all three have
to be", and this is the list of where. **Rebuild the list rather than trusting
it** — a prose lockstep rots exactly as this one did (#1206's own round 3 found
it naming four sites when there were seven, after a `--dry-run` rule change
reached only two):

```sh
grep -rln 'no-cluster-deploy' development/skills/bootstrap docs MAINTAINING.md \
  ARCHITECTURE.md | LC_ALL=C sort \
  | grep -vE '^(MAINTAINING|ARCHITECTURE)\.md$|/scripts/|^docs/how-to/index\.md$'
```

The bare `grep` returns twelve paths; the filter above drops the **six** that
are **wiring, index or authoritative** sites and carry no restatement —
`MAINTAINING.md`, `ARCHITECTURE.md`, `docs/how-to/index.md`, and three paths
under a `scripts/` directory (two wiring scripts plus the authoritative
header) — leaving the six the table lists. `restatement_sites()` in `tests/no-cluster-deploy.bats` is
the authoritative filter — this snippet mirrors it, so if the two ever disagree,
the test wins.

`tests/no-cluster-deploy.bats` pins the substantive clauses across the
restatements, so a rule change that misses one reds rather than drifting. And
`kubernetes-ci.yml.tmpl` pins `KYVERNO_VERSION`, where a Kyverno minor can add
policy *kinds* the pinned CLI cannot evaluate — which that workflow reports as a
failure rather than silently passing, so a stale pin surfaces as a red check in
a consumer repo.
