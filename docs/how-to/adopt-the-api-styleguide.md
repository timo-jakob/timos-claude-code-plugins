# Adopt the API styleguide

Pin the org [API styleguide](../reference/api-styleguide.md) ruleset in your
repo, and keep the pin current **by hand** — no bot bumps it for you
([#1359](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1359)).

**Bootstrap ships the pinned shim as the only `.spectral.yaml` it writes**
([#689](https://github.com/timo-jakob/timos-claude-code-plugins/issues/689)), so
a freshly bootstrapped repo already has it and there is nothing to do here. This
page is for a repo bootstrapped **before** the shim existed — it still carries
the [#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter ruleset, which enforces **at error severity** only two of the ids the
pinned ruleset carries (the `operationId` pair), carries three more of them at
`warn`, and carries none of the org-specific ones — and for the day a bump
lands. The pinned version is named **once** in this file, in the `extends` block
below: that URL is what Renovate's custom manager and the repo-wide pin sweep
both match, and a version restated in a sentence is invisible to both, so it
would survive the very PR that moved the pin. For the rule set itself, read the
[reference page](../reference/api-styleguide.md)'s table — and note it documents
the ruleset in *this* repository, so a rule that is in the source file but not
yet in any tag is marked *pending* there.

## Pin the ruleset

Replace your repo's `.spectral.yaml` with the shim — the whole file:

```yaml
extends:
  - https://cdn.jsdelivr.net/gh/timo-jakob/timos-claude-code-plugins@styleguide-v2.0.0/styleguide/spectral/ruleset.yaml
```

That is the entire configuration. The rules live in the published artifact, not
in your repo, so a convention change reaches you as a version bump you review
rather than as a file you have to hand-merge.

Nothing else changes **for the pin swap itself**: `contracts-lint` references
`.spectral.yaml` **by path**, so replacing the ruleset content never touches the
pipeline. (Your workflow may still need a separate, unrelated refresh — next.)

### Check your own `contracts-lint.yml` first

A workflow is a copy, not a
subscription: the same template-vs-copy rule that means no bot bumps your pin
means your lint job is whatever bootstrap wrote when you ran it. Since
[#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330) the
shipped job lints the **newest major of each family**; a job that predates it
lints **every** major of both families, including frozen ones.

**The test is a `newest_major` helper in the run step**, not the glob — both
versions glob `v[0-9]*`; what #1330 added is the *selection* on top of it. So:
`grep -q newest_major .github/workflows/contracts-lint.yml`. If that finds
nothing, refresh the workflow before trusting the parity claim below — otherwise
your local run and your CI disagree in both directions.

**Refresh it via `/development:bootstrap`, not by copying the template.** The
template is `contracts-lint.yml.tmpl` and it carries
`branches: ["{{DEFAULT_BRANCH}}"]`. Copied verbatim, that placeholder stays
unsubstituted, the `pull_request` filter then matches nothing, and contract
linting **silently stops running** — with nothing going red, because the check is
path-conditional and never a required context. If you must copy by hand,
substitute `{{DEFAULT_BRANCH}}` with your default branch. This is the same trap
the [ops-surface how-to](adopt-the-ops-surface.md#migrate-an-existing-repo-to-ops-v2)
spells out at its step 0.

Then run what CI runs, and fix what it finds — naming the newest major of each
family explicitly rather than globbing:

```sh
npx --yes @stoplight/spectral-cli@6 lint \
  --ruleset .spectral.yaml \
  --fail-severity error \
  contracts/v2/openapi.yaml contracts/ops/v2/openapi.yaml   # your newest of each
```

**Both families, and only the newest of each.** Dropping the ops one is the easy
mistake: you get a clean local run and then a red PR from a spec you did not
write. Adding a *frozen older* major is the opposite mistake — it reports errors
on a file `contracts-semver` forbids you to edit; a post-#1330 job will never
show you those, and a job without the `newest_major` selection will (which is what the
refresh above is for). And a
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
  Expect to fix spec violations in the bump PR itself — with the carve-out
  below.

**Some fixes are themselves BREAKING, and those do not belong in the bump PR.**
A remediation can be a breaking contract change in its own right: adding a
`required: true` `Idempotency-Key` parameter to every POST/PATCH
(`org-idempotency-key-on-post-patch`) is `oasdiff`'s
`new-required-request-parameter`, and turning a bare-array `200` into the
`{items, next_cursor}` envelope (`org-pagination-envelope`) changes a response
shape. `contracts-semver` rejects both as in-place edits to a live major, so the
obvious move — fix it where the linter points — reds the PR on a *different*
gate. When a fix is breaking: do **not** edit the live major, and do **not**
reach for an `overrides:` block (the
[styleguide](../reference/api-styleguide.md) bans silencing outright — it hides
a scoping bug instead of fixing it). Two options, and the choice is not
arbitrary:

- **Ship a new major directory** carrying the fixed shape alongside the pin
  bump — the default, and the only one that keeps CI green. Prefer it whenever
  the live major has consumers. A new major is more than a directory: it needs
  its own `info.version` major and `servers:` URL major (the version triangle in
  your `CONTRACTS.md`), plus the adapter and route wiring.
- **Land the bump with `contracts-lint` knowingly red** — only with a human's
  explicit approval, only with the follow-up issue filed and linked, and say so
  in the PR body. This is a deliberate exception to the green-CI rule, not a
  fallback you may take on your own.

Only editorial and additive fixes belong in the bump PR itself — and even those
need a version bump of that major's `info.version`: at least PATCH for an
editorial fix, at least MINOR for an additive one, or `contracts-semver` reds
the PR for a different reason than the one you were fixing.

**Before a MAJOR bump, check your `contracts-lint.yml` too.** On a repo whose
copy predates [#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330)
(its run step has no `newest_major` selection — the grep above), the
bump reds on **frozen** older majors as well — and those you are not permitted to
edit, because `contracts-semver` rejects an in-place change to a live major. Fix
the workflow, not the frozen spec: see
[Check your own `contracts-lint.yml` first](#check-your-own-contracts-lintyml-first)
above.

**When every remediation is editorial or additive, let CI decide the merge:**
`contracts-lint` runs against the proposed pin, so a major that breaks your spec
fails the bump PR rather than `main`. The one exception is the breaking-fix
carve-out above, whose second option lands a knowingly-red bump — and that one
is a human's call, never CI's.

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

**If the pin names no published tag**, it is a bad bump, not an outage: point it
at the newest published tag. Correcting an unpublished pin is **not** the
downgrade forbidden below — it is the fix.

**If the pin is correct**, it is an outage or a cold cache, not your repo: a
freshly cut tag can take a few minutes to propagate to jsDelivr. Re-run the job,
and check GitHub and jsDelivr status if it persists.

**Do not downgrade a *working* pin to route around it.** A version that resolves
is not the goal — an older pin silently rolls back the rules your repo enforces,
and nothing in the PR says so.
