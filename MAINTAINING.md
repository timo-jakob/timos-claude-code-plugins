# Maintaining this plugin repo

Two unrelated upkeep tasks live here: **per-merge plugin version bumps**
(critical, every PR that changes plugin content) and a **quarterly template
refresh** (slower-paced, the original purpose of this doc).

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
runtime versions. **Dependabot can't update these because they live in
`.tmpl` files**, not real workflow files.

The pragmatic solution is a manual refresh, roughly **once per quarter**.
Run through this checklist; expect ~20 minutes end-to-end.

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
```

Capture the output in a scratch file. You'll compare it to upstream below.

## Step 2 — Refresh GitHub Actions versions

For each `uses: <owner>/<repo>@<version>` found in Step 1:

```sh
# Latest release tag for a given action
gh api repos/<owner>/<repo>/releases/latest --jq '.tag_name'
```

Compare. If the upstream major version is newer, **read the release notes
before bumping** — major versions can have breaking changes. Apply with:

```sh
# Find-and-replace, single file at a time so you can review
git grep -l "uses: <owner>/<repo>@<old>" -- '*.tmpl' | xargs sed -i '' "s|uses: <owner>/<repo>@<old>|uses: <owner>/<repo>@<new>|g"
```

(macOS `sed -i ''`; on Linux drop the empty string.)

Actions to pay particular attention to (most likely to ship breaking
changes between majors):

| Action | Major bumps usually need |
|---|---|
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
|---|---|---|
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

- **Renovate / Dependabot integration** — discussed and declined. Renovate
  would solve the technical problem cleanly but adds a third-party bot
  (Mend, Inc.) and creates inconsistency with the Dependabot we generate
  for bootstrapped projects.
- **Self-hosted updater workflow** — possible but adds ~150 lines of
  code to maintain. The manual cadence is cheaper at our throughput.
- **Automated runtime-version policy** — `python-version` and friends are
  judgment calls, not pure version bumps. Manual review per release.

If the manual cadence ever starts feeling tedious, revisit the
self-hosted-updater option. Until then, this checklist is the cheapest
path.
