# Adopt the API styleguide

Pin the org [API styleguide](../reference/api-styleguide.md) ruleset in your
repo, and keep the pin current when Renovate proposes a bump.

**Bootstrap ships the pinned shim as the only `.spectral.yaml` it writes**
([#689](https://github.com/timo-jakob/timos-claude-code-plugins/issues/689)), so
a freshly bootstrapped repo already has it and there is nothing to do here. This
page is for a repo bootstrapped **before** the shim existed — it still carries
the [#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter ruleset and enforces none of the org rules — and for the day a bump
lands.

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

Then run what CI runs, and fix what it finds. Since
[#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330) the
shipped job lints the **newest major of each family** — not every major — so name
those two files explicitly rather than globbing:

```sh
npx --yes @stoplight/spectral-cli@6 lint \
  --ruleset .spectral.yaml \
  --fail-severity error \
  contracts/v2/openapi.yaml contracts/ops/v2/openapi.yaml   # your newest of each
```

**Both families, and only the newest of each.** Dropping the ops one is the easy
mistake: you get a clean local run and then a red PR from a spec you did not
write. Adding a *frozen older* major is the opposite mistake — it reports errors
CI will never show you, on a file `contracts-semver` forbids you to edit. And a
run that matched **no files** is not a pass: spectral exits 0 having linted
nothing, so check it actually named your specs.

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

## Upgrade the pin — by hand, today

**No bump automation ships to your repo.** Say that plainly, because the opposite
assumption is the expensive one: a pin nobody bumps is a repo enforcing last
year's conventions while its build stays green.

The Renovate `customManager` that watches this pin lives in the **plugin repo's
own** `renovate.json` and moves the pin inside the shipped template — it never
runs in your repo. Nor could it be shipped as-is: bootstrap installs
`renovate.json` only for Claude-Code-plugin repos (everything else gets
Dependabot, which has no equivalent to a regex custom manager), and a plugin repo
has no OpenAPI surface and therefore no `.spectral.yaml` at all. Downstream bump
automation is tracked as [#1359](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1359).

So: watch the [tags](https://github.com/timo-jakob/timos-claude-code-plugins/tags)
and edit the version in `.spectral.yaml` yourself. **Do not read silence as
currency** — it is the same absence-of-signal trap the immutability rule is
written against.

Review the bump PR you open by the version part that moved — the
[versioning policy](../reference/api-styleguide.md#versioning-policy) is what
makes this a two-second triage. (If its lint cannot resolve the ruleset at all,
see [When the pin cannot be fetched](#when-the-pin-cannot-be-fetched) below.)

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
