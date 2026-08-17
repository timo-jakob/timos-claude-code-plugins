# API styleguide

The org API conventions, and the Spectral rules that enforce them.

**In force.** Bootstrap ships a `.spectral.yaml` pinning this ruleset at an exact
`styleguide-vX.Y.Z` tag, and every bootstrapped repo's `contracts-lint` job runs
it. A repo bootstrapped **before** the pin shim ([#689](https://github.com/timo-jakob/timos-claude-code-plugins/issues/689))
still carries the [#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter ruleset: it enforces **at error severity** only the two `operationId`
rules — it carries three more of the codified conventions at `warn`, plus its own
document-wide `deprecation-has-sunset` warning, and none of the org-specific
rules — until it adopts the pin, see
[Adopt the API styleguide](../how-to/adopt-the-api-styleguide.md).

This page documents the ruleset **in this repository**. It currently matches the
published major exactly: every rule id below is carried by the pinned artifact,
including the [pagination](#pagination) and [header](#headers) rules
([#944](https://github.com/timo-jakob/timos-claude-code-plugins/issues/944)).

**No version is named here on purpose.** The pin is quoted at exactly three
sites — the bootstrap shim, this ruleset's own header, and
[Adopt the API styleguide](../how-to/adopt-the-api-styleguide.md) — and both
guards that keep those three in lockstep (the repo-wide sweep and Renovate's
custom manager) key on the **jsDelivr URL shape**, not on prose. A version
restated in a sentence is invisible to both, so the next bump would leave it
claiming a major that is no longer pinned, with nothing red. The live version is
whatever the shim's `extends` names.

**Do not pin a MAJOR before its tag exists** — jsDelivr serves a 404 to every
`contracts-lint` run in a repo that pins a tag nobody has cut, and the failure
surfaces in that repo rather than this one. When this page runs ahead of the tag,
the rows in the table below are marked *pending* until the tag is cut; no row is
pending today.

`contracts-lint` runs it against **both** contract families — the business
contract `contracts/vN/openapi.yaml` **and** the org ops surface
`contracts/ops/vN/openapi.yaml` ([#688](https://github.com/timo-jakob/timos-claude-code-plugins/issues/688)).
Since [#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330)
it lints only the **newest major of each family**: a frozen older major is
immutable by contract, so linting it against a ruleset cut after it froze could
only produce red nobody is permitted to fix. That second family is easy to forget
and it is the whole reason the [ops surface](#the-ops-surface-and-error-bodies)
needs its own section below.

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

## The rules

Twelve conventions, **fifteen rule ids** — a convention can need more than one
id (`operation-operationId` and `operation-operationId-unique` are one
convention expressed as two; cursor pagination needs three).

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
| `org-pagination-cursor-params` | A collection GET takes `cursor` + `limit` | Newly minted |
| `org-pagination-no-offset-params` | …and never `page` / `offset` / their friends | Newly minted |
| `org-pagination-envelope` | …and returns `{items, next_cursor}`, never a bare array | Newly minted |
| `org-idempotency-key-on-post-patch` | POST and PATCH take a required `Idempotency-Key` | Newly minted |
| `org-retry-after-on-throttled` | A 429 — and a non-ops 503 — returns `Retry-After` | Newly minted |
| `org-deprecation-sunset-headers` | A deprecated operation returns `Deprecation` + `Sunset` | Newly minted |
| `org-no-bespoke-correlation-headers` | Correlation rides `traceparent`, never `X-Request-Id` | Newly minted |

All fifteen are what the published major enforces today. A row would read
**pending** only while this file ran ahead of the tag; none does.

The last seven arrived together and are all `error`-severity, which is what made
the artifact's most recent revision a **MAJOR** under the
[versioning policy](#versioning-policy)'s existing MAJOR row
([#944](https://github.com/timo-jakob/timos-claude-code-plugins/issues/944)).
Exact pinning is what makes that cheap: nobody's build changes until they move
their pin, so a MAJOR costs a consumer one reviewable PR.

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
error-severity rule": of these **five codified** ids the ruleset promotes three,
not all five. Counting the re-scoped
[`org-deprecated-operation-has-sunset`](#deprecation) below, the whole-ruleset
total is **four** promotions plus nine newly-minted errors.

The plugin's compatibility note quotes the **published** breakdown — four
promotions plus nine newly minted, over fifteen ids — because that is what the
pinned major carries. It moves in lockstep with the tag and the pin, in the same
PR.

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
regex without flagging legitimate singular collections — `/health` and
`/inventory` are both correct and both fail a naive "must end in s" test, while
`/status` passes it for the wrong reason.
Plurality is a convention this page states and review enforces; the linter
enforces the half it can prove. The rule's message still asks for the full
convention, because a fix hint should describe the target rather than the
subset the checker can see.

The verb guard is scoped by that trailing context on purpose, so nouns that
merely begin with those letters stay clean: `/addresses`, `/searches` and
`/deleted-items` all pass. Each of those three is a case in the conforming
fixture, so the guard cannot quietly widen.

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

**Resolved — ops v2 clears this rule.** `contracts-lint` lints the ops fragment
with the same ruleset, and **ops v1** shipped `503` responses on `/health/live`
and `/health/ready` returning `application/json` with a `{status: "ok" | "down"}`
body — a different field that happens to share RFC 9457's `status` name. Those two
responses do **not** satisfy this rule.

[#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330)
fixed it with a new ops major whose probe `503`s return
`application/problem+json` with an integer `status`, carrying the health detail
in a `components` extension member. Bootstrap installs **ops v2**, and
`contracts-lint` lints only the newest major per family, so a freshly bootstrapped
repo never sees this rule fire on a fragment it did not write.

The collision survives in **two** shapes. Whichever you are in, the two
prohibitions are the same:

- **Do not** edit `contracts/ops/v1/openapi.yaml` to make the lint pass. It is an
  org-standard fragment installed verbatim, and a frozen major that
  `contracts-semver` forbids editing in place. `check-ops-conformance.zsh` will
  not vindicate an edited v1 either — since #1330 it asserts the **v2** probe-503
  shape and reports a v1 `{"status":"down"}` body as an *unmigrated payload*.
- **Do not** add an `overrides:` exclusion. Scoping is fixed by making the
  contract correct, never by silencing a rule.

**Shape 1 — your newest ops major is still v1.** Migrate to ops v2; the procedure
is in [Adopt the ops surface](../how-to/adopt-the-ops-surface.md#migrate-an-existing-repo-to-ops-v2).

**Shape 2 — you already have ops v2, but your `contracts-lint.yml` predates
[#1330](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1330)**, so
it lints *every* major and v1 still reddens. Migrating again is a no-op here — the
fix is the **workflow**, not any spec. Check with
`grep -q newest_major .github/workflows/contracts-lint.yml` and refresh it per
[the ops how-to's step 0](../how-to/adopt-the-ops-surface.md#migrate-an-existing-repo-to-ops-v2).

## Pagination

**Newly minted.** Collections paginate by **cursor**, and only by cursor.

Offset-style pagination — `page`, `offset`, `skip` and their friends — is banned
outright. Under concurrent writes it double-counts rows and skips others: a row
inserted before your position shifts everything down a slot, so page 2 re-serves
what page 1 already gave you, and a deletion silently swallows a row nobody ever
sees. Its cost also grows with the page number, because the database has to walk
and discard everything before the offset.

**Request.**

| Parameter | Where | Schema | Required |
| --- | --- | --- | --- |
| `cursor` | `in: query` | `type: string`, **opaque to the client** | no |
| `limit` | `in: query` | `type: integer`, `minimum: 1`, `maximum: 200`, `default: 50` | no |

**Response.** A `200` on a collection is an **object**, never a bare array, with
`items` and `next_cursor` both **required**:

```yaml
TenantPage:
  type: object
  required: ["items", "next_cursor"]
  properties:
    items:
      type: array
      items:
        $ref: "#/components/schemas/Tenant"
    next_cursor:
      type: ["string", "null"]
      description: Cursor for the next page; null on the last page.
```

`next_cursor` is **`null` on the last page** — never omitted, never an empty
string. A client that has to distinguish "absent" from "empty" from "null" will
get it wrong in one of the three cases, and it is always the last page.

These parameter names are banned anywhere in a spec, in **any** `in:` location
— a `page` header is the same defect wearing a different hat:

`offset`, `page`, `page_size`, `per_page`, `skip`, `start`, `start_index`.

**Deliberately not adopted:** [RFC 8288](https://www.rfc-editor.org/rfc/rfc8288)
`Link` headers and `X-Total-Count`. One shape, in the body, machine-readable
without header parsing. An exact total is not computable cheaply over a cursor
scan, and under concurrent writes it would be a lie by the time the client read
it.

### What counts as a collection

The linter needs a mechanical answer, and this is it. A **collection operation**
is a `GET` whose `200` `application/json` schema is either:

- **(a)** a top-level `type: array`, or
- **(b)** an object with a **required** property named `items` of `type: array`.

Everything else is out of the reach of `org-pagination-cursor-params` —
**including an object that carries an array under any other name**.
`org-pagination-envelope` is not gated by it either, and its two clauses are
deliberately *broader*: clause (a) rejects **any** bare-array `200`, and clause
(b) fires on **any** body whose `required` contains `items` — whatever that
`items` member turns out to be — and demands `next_cursor` alongside it. So a
body that opts into the envelope's name owes the cursor even if its `items` is
not an array, which is a shape detection would not call a collection.

That split is deliberate and self-reinforcing: detection (a) catches the naive
bare-array collection and pushes it into the envelope, and the envelope rule
then keeps the envelope honest. A fixed, non-growing lookup returning an object
with a differently-named array simply is not in scope for either, so no
`x-no-pagination` escape hatch is minted.

**`org-pagination-no-offset-params` is not gated by this definition**, and that
asymmetry is deliberate. The banned names are rejected on *every* parameter in
the document — collection or not, any `in:` location, including one declared
under `components.parameters`. Being out of scope for collection *detection* is
not a licence to keep `page`.

It is also what keeps the [ops surface](#the-ops-surface-and-error-bodies) clean
with no exclusion anywhere: `/info` returns `required: ["build", "api"]`, its
array named `api`. Neither shape matches, so the shared fragment is invisible to
these rules — scoping fixed by being correct, never by an `overrides:` block.

**The linter enforces less than this section asks for, deliberately.** A
genuinely growing collection can evade detection by naming its array `results`.
The normative rule is *every collection paginates*; Spectral enforces the
detectable subset and review covers the rest.

**Declare the parameters on the operation.** `org-pagination-cursor-params` is
anchored at the operation object, because `parameters` is a sibling of
`responses` there. A path-item-level declaration is legal OpenAPI the rule does
not see — and because the rule also requires the operation to *have* a
`parameters` list, hoisting `cursor`/`limit` into the path item does not merely
lose you the check: the detected collection GET is **flagged**. Repeat them on
each operation.

### What the pagination rules actually check

Per the page's own [rule](#what-is-enforced-and-what-is-only-conventional), here
is where the linter stops short of the prose above. Spectral checks:

- a parameter **named** `cursor` and one **named** `limit`, each `in: query`;
- that the `200` schema is not a bare array, and that a body requiring `items`
  also requires `next_cursor`;
- that no parameter anywhere carries a banned offset name.

It does **not** check:

- any of the *schemas* — `limit`'s `minimum: 1`, `maximum: 200` and
  `default: 50`, `cursor`'s `type: string`, or `next_cursor`'s
  `type: ["string", "null"]`. A spec declaring
  `limit: {type: integer, maximum: 10000}` or a non-nullable `next_cursor` lints
  green and is still wrong;
- a collection whose success response is declared only as the **range key
  `2XX`**. `org-pagination-cursor-params` and `org-pagination-envelope` both key
  on the literal `200`, so such an operation is invisible to *those two* —
  unlike [`org-problem-json-errors`](#error-bodies), which matches `4XX`/`5XX`,
  and [`org-deprecation-sunset-headers`](#sunset-headers), which matches `2XX`.
  Declare the concrete `200` if you want the linter's help.
  `org-pagination-no-offset-params` never inspects responses and is unaffected:
  a banned parameter name is rejected regardless.

Those are review-enforced, and a green `contracts-lint` is not evidence for
them.

## Headers

**Newly minted.** Four conventions about what an operation puts on the wire.
Spelling and placement are exact, because a spec is text.

### Idempotency-Key

Every **POST** and **PATCH** takes an `Idempotency-Key` **request parameter** —
`in: header`, `required: true`, `schema: {type: string}`, a UUIDv4 recommended.
A retried write that the network ate must not create a second resource.

```yaml
parameters:
  - name: Idempotency-Key
    in: header
    required: true
    schema:
      type: string
```

**PUT and DELETE are exempt**: they are idempotent by method, so replaying them
converges on the same state and a key would be noise. The rule id names both
covered methods — `org-idempotency-key-on-post-patch` — precisely so it can
never be misread as POST-only.

The rule checks the parameter's `name`, its `in: header`, and `required: true`.
It does **not** check `schema: {type: string}`, and it cannot check that the
value is a UUIDv4 — both are review-enforced.

**Declare the parameter on the operation.** Like
[`org-pagination-cursor-params`](#pagination), this rule is anchored at the
operation object, so an `Idempotency-Key` hoisted once into the path item's own
`parameters:` — legal OpenAPI, and the DRY spelling when a resource's POST and
PATCH both need it — is not seen, and both operations are flagged. Repeat it on
each — the same over-fire [`org-pagination-cursor-params`](#pagination) has, and
for the same reason. Those two are the only places a rule is stricter than the
prose about **where a declaration must live**, so both are worth knowing before
you factor a declaration out. (`org-pagination-envelope`'s clause (b) is stricter
in a different way — it fires on any body that opts into the `items` name,
collection or not; see [Pagination](#pagination).)

### Retry-After

Every declared `429` and `503` returns a `Retry-After` **response header**,
`schema: {type: integer}` — delta-seconds. "Come back later" without a number is
an invitation to a retry storm.

```yaml
"429":
  description: Too many requests.
  headers:
    Retry-After:
      schema:
        type: integer
```

**One exemption, on the 503 half only: operations tagged `ops`.** A probe's 503
addresses an orchestrator — *shed my traffic* — not a client that should come
back at a stated time, and `tags: ["ops"]` is an intrinsic property of every
operation in the shared fragment rather than a path-based silencer. The `429`
half has no exemption at all.

The `ops` tag is **reserved** for the shared operations surface. A business
operation that tags itself `ops` is a styleguide violation — one this rule
cannot currently catch, and a candidate for a follow-up rule.

**The rule keys on the literal `429` and `503` response keys.** Unlike
[`org-problem-json-errors`](#error-bodies), which deliberately matches the
`4XX` / `5XX` range keys, this one does not: `5XX` covers `500` and `501` as
much as `503`, and `4XX` covers `404` as much as `429`, so matching a range key
would demand `Retry-After` on responses that owe no retry delay. **Declare the
concrete status** if you want the linter's help — a spec whose only unavailable
declaration is `5XX` is review-enforced here, not linted.

### Sunset headers

An operation marked `deprecated: true` returns **both**
[`Deprecation`](https://www.rfc-editor.org/rfc/rfc9745) and
[`Sunset`](https://www.rfc-editor.org/rfc/rfc8594) response headers on **every
2xx** response.

```yaml
"200":
  description: The tenant.
  headers:
    Deprecation:
      schema:
        type: string
    Sunset:
      schema:
        type: string
```

This is the **runtime** half of [`x-sunset`](#deprecation). The spec extension
tells whoever reads the contract when the operation dies; these headers tell a
running client, on every response, without anyone having read anything.

Like `org-deprecated-operation-has-sunset`, this rule is anchored at `$.paths[*]`
**operation objects only** — never a document-wide `$..`, which also matches a
deprecated schema property and a deprecated parameter and is exactly what forced
the [#692](https://github.com/timo-jakob/timos-claude-code-plugins/issues/692)
starter down to a warning.

### Correlation

Correlation rides W3C [`traceparent`](https://www.w3.org/TR/trace-context/),
propagated by the OpenTelemetry SDK the [ops surface](../how-to/adopt-the-ops-surface.md)
already requires. `traceparent` and `tracestate` are explicitly allowed if a spec
declares them.

**Bespoke correlation headers are banned**, whether declared as parameters or as
response headers: `X-Request-Id`, `X-Correlation-Id`, `Request-Id`,
`X-Trace-Id`. The rule's pattern is case-**insensitive**, so `x-request-id` and
`X-REQUEST-ID` are caught alongside the canonical spelling — header names are
case-insensitive on the wire, and a ban that a shift key defeats is not a ban.
It reaches parameters and response headers declared inline **and** under
`components`.

That list is exhaustive: a fifth spelling nobody has thought of is not banned by
this rule, and review covers it.

Every service inventing its own correlation header is how a trace stops crossing
a service boundary: two hops agree on the name, the third does not, and the
request id dies there. One propagated standard, already implemented by the SDK,
is worth more than four spellings of the same idea.

**ETag / conditional-request caching is out of scope.** It needs its own
precondition semantics (`If-Match`, `412`) and deserves its own story.

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
