# Adopt the API styleguide

Pin the org [API styleguide](../reference/api-styleguide.md) ruleset in your
repo, and keep the pin current when Renovate proposes a bump.

**Check which world you are in first.** Bootstrap currently writes the
[#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter ruleset, not the pinned shim, and the `styleguide-v1.0.0` tag the shim
below points at is cut by hand after the ruleset merges. So:

- **Before that tag exists**, the shim will not resolve and `contracts-lint`
  will fail loudly. Nothing to adopt yet — wait.
- **From `styleguide-v1.0.0` onward**, bootstrap ships the pinned shim as the
  only `.spectral.yaml` it writes, so a freshly bootstrapped repo already has
  it. This page is then for a repo bootstrapped before the styleguide existed,
  and for the day a bump PR shows up.

## Pin the ruleset

Replace your repo's `.spectral.yaml` with the shim — the whole file:

```yaml
extends:
  - https://cdn.jsdelivr.net/gh/timo-jakob/timos-claude-code-plugins@styleguide-v1.0.0/styleguide/spectral/ruleset.yaml
```

That is the entire configuration. The rules live in the published artifact, not
in your repo, so a convention change reaches you as a version bump you review
rather than as a file you have to hand-merge.

Nothing else changes: `contracts-lint` references `.spectral.yaml` **by path**,
so swapping the content never touches the pipeline.

Then run the same command CI runs, and fix what it finds — **both** globs, which
is what the shipped job lints:

```sh
npx --yes @stoplight/spectral-cli@6 lint \
  --ruleset .spectral.yaml \
  --fail-severity error \
  contracts/v[0-9]*/openapi.yaml contracts/ops/v[0-9]*/openapi.yaml
```

Use those globs verbatim. Dropping the second one is the easy mistake: you get a
clean local run and then a red PR from a spec you did not write. And a run that
matched **no files** is not a pass — spectral exits 0 having linted nothing, so
check it actually named your specs.

Expect a first run to be noisy on an API that predates the styleguide. The
common findings, and what they mean, are in the
[styleguide reference](../reference/api-styleguide.md) — start with
[error bodies](../reference/api-styleguide.md#error-bodies) and
[resource naming](../reference/api-styleguide.md#resource-naming), which is
where most of the volume will be.

Findings on `contracts/ops/vN/openapi.yaml` are a special case you should not
try to fix: see
[the ops surface and error bodies](../reference/api-styleguide.md#the-ops-surface-and-error-bodies).

## Pin exactly — never float

Use an exact `styleguide-vX.Y.Z` tag. Not `@latest`, not a branch, not a major
alias.

The reason is the failure mode, not the principle: a floating ref means the
rules your CI enforces can change with no PR in your repo. A build that was
green on Friday goes red on Monday because someone else's merge reached you,
and the diff that caused it is not in your history. An exact pin makes every
rule change arrive as a reviewable bump.

The other half of that bargain is that
[tags are immutable](../reference/api-styleguide.md#tags-are-immutable): a
published tag is never re-pointed, so a pin means the same bytes forever.

## Upgrade when Renovate proposes a bump

Once your repo carries the bootstrap `renovate.json`, a Renovate
`customManagers` entry watches the pinned version and opens a bump PR when a new
styleguide version is tagged.

**Two ways you might not get one**, both of which look identical to "no new
version was published" — the same absence-of-signal trap the immutability rule
is written against:

- the customManager ships with the shim, so a repo that pinned by hand and never
  re-bootstrapped has no manager;
- repos on Dependabot rather than Renovate have no equivalent.

In either case, bump by hand: watch the
[tags](https://github.com/timo-jakob/timos-claude-code-plugins/tags) and edit the
version in `.spectral.yaml`. Do not read silence as currency.

When a bump PR does arrive, read it by the version part that moved —
the [versioning policy](../reference/api-styleguide.md#versioning-policy) is
what makes this a two-second triage:

- **PATCH** — wording and doc links only. Nothing that was green can go red.
  Merge on green.
- **MINOR** — new rules, but shipped at `warn`, or additive message coverage.
  Your build cannot start failing. Merge on green, then read the new warnings
  when you have time.
- **MAJOR** — a new or stricter `error` rule, or a renamed rule id. **This one
  can redden your build**, and that is exactly what the major is telling you.
  Expect to fix spec violations in the bump PR itself.

Let CI decide the merge either way: `contracts-lint` runs against the proposed
pin, so a major that breaks your spec fails the bump PR rather than `main`.

## When the pin cannot be fetched

`contracts-lint` fails loudly — a CDN outage or a bad pin reds the job.

That is deliberate, and it is worth knowing before you try to "fix" it: a lint
that degraded to "no rules loaded, 0 problems" would report success while
enforcing nothing, which is strictly worse than a red build. There is no
offline fallback, no vendored copy and no opt-out flag.

If a lint fails to resolve the ruleset at all, check the version in the shim
against the
[published tags](https://github.com/timo-jakob/timos-claude-code-plugins/tags)
first.

**If the pin is correct**, it is an outage or a cold cache, not your repo: a
freshly cut tag can take a few minutes to propagate to jsDelivr. Re-run the job,
and check GitHub and jsDelivr status if it persists.

**Do not downgrade the pin to route around it.** A version that resolves is not
the goal — an older pin silently rolls back the rules your repo enforces, and
nothing in the PR says so.
