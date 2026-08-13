# API styleguide

The org API conventions, and the Spectral rules that enforce them.

**Not yet in force.** From `styleguide-v1.0.0` onward, bootstrap ships a
`.spectral.yaml` pinning this ruleset, and every bootstrapped repo's
`contracts-lint` job runs it. Until that tag is cut and the shim lands, repos
still run the [#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter ruleset and nothing here is enforced anywhere.

When it is in force, `contracts-lint` runs it against **both** the per-major
business contract `contracts/vN/openapi.yaml` **and** the org ops surface
`contracts/ops/vN/openapi.yaml` ([#688](https://github.com/timo-jakob/timos-claude-code-plugins/issues/688))
— the shipped job globs both. That second glob is easy to forget and it is the
whole reason the [ops surface](#the-ops-surface-and-error-bodies) needs its own
section below.

Each **org-owned** rule (`org-*`) links from its own `documentationUrl` to its
section here, so a failing lint line in CI points a reader straight at the
convention. The five codified rules are inherited from `spectral:oas` and keep
Spectral's own documentation links.

## What is enforced, and what is only conventional

Two things share this page, and the difference matters when you are arguing with
a red build:

- **Newly minted** — a convention this styleguide introduces. Nothing in the
  family enforced it before.
- **Codified** — a convention the repos already followed, which the starter
  ruleset ([#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692))
  already carried. The org ruleset promotes it to `error` **where the starter
  had it at `warn`**; two of the five were already errors and carry over
  unchanged.

Where a rule enforces less than the prose asks for, the section says so
explicitly rather than letting you assume the linter has your back.

## The v1 rules

Seven conventions, **eight rule ids** — `operation-operationId` and
`operation-operationId-unique` are one convention expressed as two ids.

| Rule id | Convention | Status |
| --- | --- | --- |
| `operation-operationId` | Every operation has an `operationId` | Codified |
| `operation-operationId-unique` | …and it is unique in the document | Codified |
| `info-description` | The API describes itself | Codified |
| `operation-description` | Every operation describes itself | Codified |
| `operation-tags` | Every operation is tagged | Codified |
| `org-deprecated-operation-has-sunset` | A deprecated operation declares its sunset date | Codified, re-scoped |
| `org-resource-naming` | Paths are kebab-case nouns, never verbs (plurality: convention only — see [Resource naming](#resource-naming)) | Newly minted |
| `org-problem-json-errors` | Errors are RFC 9457 problem documents | Newly minted |

### Operation identity and description

**Codified.** `operationId` is the name your consumers' generated clients will
call, so it is part of the contract whether you chose it or not — and the
deprecation → `@deprecated` mapping keys off it. `info-description`,
`operation-description` and `operation-tags` are the governance-portal
documentation: the portal renders exactly what the spec says, so an undescribed
operation ships as an undocumented one.

**Three of the five** — `info-description`, `operation-description` and
`operation-tags` — were warnings in the starter; the org ruleset makes them
errors. The two `operationId` rules were already errors and are carried over
unchanged. Worth being precise about, because the
[versioning policy](#versioning-policy) keys MAJOR off "a new or stricter
error-severity rule": this ruleset promotes three, not five.

## Deprecation

**Codified, re-scoped.** An operation marked `deprecated: true` must also declare
`x-sunset: <YYYY-MM-DD>` — an [RFC 8594](https://www.rfc-editor.org/rfc/rfc8594)
sunset date. Deprecation without a date is an opinion; with a date it is a plan
a consumer can schedule against.

```yaml
paths:
  /tenants/{tenantId}:
    get:
      operationId: getTenant
      deprecated: true
      x-sunset: "2026-12-31"
```

The starter's version of this rule matched **anything** carrying
`deprecated: true` — parameters, schema properties, even `deprecated: true`
appearing inside example data — which is why it could only ever be a warning.
The org rule is anchored at `$.paths[*]` and matches operations only, which is
what lets it be an error. A deprecated schema property is deliberately not this
rule's business.

## Resource naming

**Newly minted.** Path segments are lowercase kebab-case nouns. The verb is the
HTTP method — a verb in the path means the API is tunnelling RPC over HTTP.
Path parameters (`{tenantId}`) are exempt from the spelling rule.

```yaml
# no
POST /getUser
GET  /Tenant_List

# yes
GET  /users/{userId}
GET  /tenants/{tenantId}/billing-accounts
```

**The linter enforces less than this section asks for, deliberately.** It checks
two things, and you need both to predict what it will reject:

1. every literal segment is lowercase kebab-case;
2. no segment **begins with one of these verbs** followed by a hyphen, an
   underscore, a capital, or the end of the segment —

   `get`, `create`, `update`, `delete`, `remove`, `list`, `fetch`, `retrieve`,
   `add`, `search`, `find`, `submit`, `execute`, `do`, `make`.

That list is exhaustive and worth reading before you name a resource, because
it decides which *nouns* the rule rejects. `/search` is a **verb path** under
this rule and fails — use `/searches`, or a sub-resource like
`/users/{userId}/searches`.

It does **not** check plurality. English pluralization cannot be decided by
regex without flagging legitimate singular collections — `/status`, `/health`
and `/inventory` are all correct and all fail a naive "must end in s" test.
Plurality is a convention this page states and review enforces; the linter
enforces the half it can prove. The rule's message still asks for the full
convention, because a fix hint should describe the target rather than the
subset the checker can see.

The verb guard is scoped by that trailing context on purpose, so nouns that
merely begin with those letters stay clean: `/addresses`, `/listings`,
`/searches` and `/deleted-items` all pass. Each of those three is a case in the
conforming fixture, so the guard cannot quietly widen.

## Error bodies

**Newly minted.** Every `4xx` and `5xx` response returns
[RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details —
`application/problem+json`, with `type`, `title`, `status` and `detail` all
required.

```yaml
responses:
  "404":
    description: No tenant with that id.
    content:
      application/problem+json:
        schema:
          $ref: "#/components/schemas/Problem"
```

**Bare** means bare: an error response must offer `application/problem+json`
and **nothing else** — not `application/json`, not `text/plain`, not
`application/xml`. A client that has to negotiate between two error shapes gets
the worst of both, and in practice every client then parses whichever one it met
first.

`status` is the HTTP status code as an integer — RFC 9457's field, not a
free-form health or state string.

The rule matches numeric status keys (`404`, `503`) **and** the OpenAPI range
keys `4XX` / `5XX`. It deliberately does **not** match `default`: that is the
catch-all, not necessarily an error, and over-firing on it would flag specs
that use `default` for a success shape. If your only error declaration is a
`default` response, the linter has nothing to say and review is what covers you.

### The ops surface and error bodies

The org ops surface ships `503` responses on `/health/live` and `/health/ready`
that return `application/json` with a `{status: "ok" | "down"}` body — a
different field that happens to share RFC 9457's `status` name. Those two
responses **do not satisfy this rule**, and `contracts-lint` lints the ops
fragment with the same ruleset.

This is a known, tracked collision, not something for an adopter to solve:

- **Do not** edit `contracts/ops/vN/openapi.yaml` in your repo to make the lint
  pass. It is an org-standard fragment installed verbatim, its shape is pinned
  by `check-ops-conformance.zsh`, and editing it breaks ops conformance.
- **Do not** add an `overrides:` exclusion. Scoping is fixed by making the
  contract correct, never by silencing a rule.
- The resolution is a **new ops major**
  ([#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330))
  whose probe `503`s return `application/problem+json`, carrying the health
  detail as RFC 9457 extension members. It is a hard prerequisite of the PR that
  pins this ruleset into bootstrap, so no bootstrapped repo ever sees this rule
  fire on a fragment it did not write.

## Versioning policy

The ruleset artifact versions **independently** of the plugins. Its tags are
`styleguide-vX.Y.Z`; `development/plugin.json` and `marketplace.json` never
track them, and they never track the plugins.

| Bump | When |
| --- | --- |
| MAJOR | A new or stricter `error`-severity rule, or a rule-id rename — anything that can redden a downstream repo that was green on the previous pin. |
| MINOR | A new rule shipped at `warn`, or additive `message` / `documentationUrl` coverage that cannot fail a previously-passing spec. |
| PATCH | Fix-hint wording, doc-URL and typo fixes, with no change to severity or to what a rule matches. |

### Tags are immutable

A `styleguide-v*` tag, once cut, is **never moved and never deleted**. A mistake
is superseded by the next version.

This is not fastidiousness. jsDelivr caches by tag, and every consumer pins an
exact one. Re-pointing a tag would hand different repos different rules under
the same version string, with no PR anywhere for anyone to notice — the one
failure mode that exact pinning is supposed to make impossible.

## Adopting it

Consumers pin the published artifact by exact version; see
[Adopt the API styleguide](../how-to/adopt-the-api-styleguide.md).
