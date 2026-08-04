---
name: maintenance
description: >
  Kubernetes/IaC maintenance dispatcher. Receives a v2 maintenance payload (a
  file path in $ARGUMENTS) that /development:maintenance built from the
  kubernetes topic gather (gather-kubernetes-findings.zsh), validates it, and
  returns a plan routing each finding group to an agent. A TOPIC plugin that can
  also be PRIMARY: a GitOps repo with no application language declares
  `primary: kubernetes` and gets the full pipeline. It ROUTES each finding group
  by the live routing table (manifest_validation → kubernetes-manifest-fixer;
  policy + policy_tests → kubernetes-policy-triage, grouped into one PR).
  A single invocation returns the plan; the per-group work agents are the
  orchestrator's job. Pure function of its JSON input; runs no detection of its
  own. Ships NO approver — a cluster definition is approved by a human.
disable-model-invocation: false
---

# Kubernetes maintenance dispatcher

Read the payload at `$ARGUMENTS`. Spawn nothing.

You are the **kubernetes-topic maintenance dispatcher**. You receive a v2
maintenance payload that `/development:maintenance` built from the kubernetes
topic gather, and you return a **plan**: an ordered list of finding groups, each
routed to the agent that fixes that category. You do **not** run detection, the
gather, or the validation **tools** (kubeconform / kube-linter / `kyverno test`,
which run in CI — #1154) yourself, and you do **not** spawn the work agents —
Phase 8 of the orchestrator does, one PR per group. *Payload* validation is a
different thing and it **is** yours: see *Validation* immediately below.

Like the other topic plugins (`development-docs`, `development-claude-plugin`),
you have **no language coverage gate and no Phase A/B dance** — a topic has no
application test suite of its own. This dispatcher is a single invocation
returning one `plan`. Its one analogue is `policy_tests` (see *No coverage gate,
one analogue*).

## Validation

Each check terminates — a dispatcher that routes whatever happens to parse is
worse than one that stops:

- `$ARGUMENTS` empty → print one line explaining this is a dispatch target for
  `/development:maintenance`, not a standalone command, and **stop**.
- the file is missing, or does not parse as JSON → **error and stop**.
- `.schema_version != "2"` → **error and stop**, naming the version found.
- `.language != "kubernetes"` → **error and stop**. (For a topic dispatch the
  orchestrator carries the TOPIC name in `language`; there is no `topic` key in
  the v2 payload, so a `.topic == "kubernetes"` guard would stop on every valid
  dispatch.)
- a key appears in `findings_by_tool` that the routing table below has no entry
  for → **halt** with `human_action_required`, rather than dropping it silently.

```bash
command -v jq >/dev/null 2>&1 || { echo "jq not found on PATH — cannot validate the payload"; exit 1; }
[ -n "$ARGUMENTS" ] || { echo "development-kubernetes:maintenance is a dispatch target for /development:maintenance, not a standalone command"; exit 1; }
test -f "$ARGUMENTS" || { echo "no payload file at: $ARGUMENTS"; exit 1; }
jq -e . "$ARGUMENTS" >/dev/null 2>&1 || { echo "payload is not valid JSON: $ARGUMENTS"; exit 1; }
jq -e '.schema_version == "2"' "$ARGUMENTS" >/dev/null \
  || { echo "unexpected payload schema (want 2, found: $(jq -r '.schema_version // "absent"' "$ARGUMENTS"))"; exit 1; }
jq -e '.language == "kubernetes"' "$ARGUMENTS" >/dev/null \
  || { echo "payload is not a kubernetes dispatch (language: $(jq -r '.language // "absent"' "$ARGUMENTS"))"; exit 1; }
```

**Stop on any failure in the block above** — every check except the unknown-key
bullet (the bullets and the guards are not 1:1; the JSON bullet is two guards).
Never fall through to *Response* and return the empty-plan envelope for a payload
you could not validate: the empty plan is for a *valid* v2 payload that carries no
kubernetes findings, **not** for a broken or wrong-version one, and masking a
payload-contract break (a future v3 orchestrator, say) as "nothing to do" would be
a silent failure.

**The unknown-key bullet is the one exception, and it is not a fall-through.**
That payload *did* validate — it is well-formed v2 for this topic; only its
routing is unknown. So it does not error out: it **returns** the halt envelope
defined in *Response* (the four fields plus `human_action_required`), which is
the only way the escalation reaches a human. Erroring instead would make the
orchestrator record `dispatch failed` in `unsupported_topics` and swallow it.

## Dispatch mode

`dispatch_mode` is `"primary"` | `"auxiliary"`; **absent is treated as
`"primary"`**, per `ARCHITECTURE.md` § *Primary / auxiliary model* (the language
dispatchers restate it; the sibling topic dispatchers only accept the field).
Any **other** value is a payload-contract break, and it is handled exactly like
the `manifest_validation: false` case in *Response*: **route nothing** and return
the halt envelope with **one** `human_action_required` entry naming the value
found — that single entry is the trace for the whole payload, so do not
additionally enumerate the groups. Do **not** "treat it as primary and carry on":
any non-empty `human_action_required` *is* the halt branch, and Phase 7 skips
every remaining phase for the target, so a plan built alongside the note would be
discarded and the routed work would silently never run. The orchestrator only
ever emits the two values, so a third means the payload was not built by it.
This topic composes ALONGSIDE a language plugin, so auxiliary is the expected
case for a repo that **declares a language primary** — note that a repo which
declares no primary at all dispatches every target as `"primary"`, so auxiliary
is not simply the default. Here is the disposition of all three routed keys, so
nothing falls through to a guess:

- `manifest_validation` → routed as usual. Mechanical, always in scope.
- `policy` → routed as usual. A violation of a policy the repo *declared* is a
  real defect whatever the repo's primary language is; suppressing it would lose
  the finding with no trace.
- `policy_tests` → **omitted entirely** in auxiliary mode. This is the app-grade
  coverage analogue, and it is the only one that is. Planning ordering-blocking
  fixture-writing on a repo whose primary is Java or Go is exactly the category
  error the primary/auxiliary split exists to prevent.

## Routing

**One name, two things — read the qualified paths.** This topic's `policy`
*tool* is `tooling_configured.policy` / `findings_by_tool.policy`. The payload
also carries a **top-level `policy` object** (`{coverage_threshold,
severity_gate, …}`) — the family's maintenance policy, present and truthy on
every payload, and **never** read by this dispatcher. Resolving a bare "policy"
to that object would read a repo with no Kyverno files as having policies
configured, inverting the charter's central skip.

**This table is live** — every row routes, and its entries also define the
known-key universe *Validation*'s unknown-key check tests against. Both agents
ship with this plugin (`development-kubernetes/agents/`), so a routed group
names a `subagent_type` that exists.

| Finding tool | Agent |
|---|---|
| `manifest_validation` | `kubernetes-manifest-fixer` |
| `policy` | `kubernetes-policy-triage` |
| `policy_tests` | `kubernetes-policy-triage` |

**A group exists only for a ROUTED `findings_by_tool` key whose array is
NON-EMPTY.** A routed key present with an **empty** array means "configured, and
it found nothing" —
it forms no group, no plan entry, and no `human_action_required`
entry either. This is not a corner case: `manifest_validation: []` is on *every*
payload this dispatcher receives, because that tool is presence-detected and its
checks run in CI, and `policy: []`/`policy_tests: []` is the shape of a clean
policy set. Treating each routed *key* as a group would escalate the ordinary
clean dispatch — the most common payload there is — to a human as "Halted".

**"Routed" is the load-bearing word, and *Validation* wins over this rule for
anything else.** An **unknown** key — one this table has no row for — halts on
its mere *presence*, empty array or not; it is not a group and this paragraph
does not exempt it. The two rules answer different questions: this one asks "is
there work here?", *Validation*'s asks "do I still understand this payload?".
A future gather adding a presence-detected tool would ship exactly that shape —
an unknown key with an empty array — and silently dropping it is the routing
drift the halt exists to surface.

Group `policy` and `policy_tests` into **one** PR: they touch the same
directory, and splitting them would produce two PRs racing on the same files.

Respect `dispatch_filter` if present: only build groups for tools listed in
`.dispatch_filter.only_tools`. In practice the orchestrator **omits
`dispatch_filter` for topics** and skips topic dispatch entirely under
`--tool`/`--concern`, so this handling is **defensive**: if a filter naming no
kubernetes tool ever did arrive, an empty plan is the correct result.

## No coverage gate, one analogue

A topic has no application test suite, so there is no line-coverage pre-flight.
The analogue is `policy_tests`: a declared policy set with no `kyverno test`
fixtures. Treat a `policy_tests` finding as **ordering-blocking** for the group —
the group is dispatched to `kubernetes-policy-triage` (that
agent is what WRITES the missing fixtures) and the plan must order
fixture-writing before any policy-driven manifest fix in it. Never drop the
group: that would permanently preserve the untested-policy state the gate exists
to eliminate.

The ordering rule is also **primary-mode only** — in auxiliary mode the
`policy_tests` group is omitted before it is ever formed (see *Dispatch mode*).

## Absent policies are not a finding

`tooling_configured.policy: false` means the repo declared no policies — the
gather's glob `policies/kyverno/**/*.{yaml,yml}` matched nothing. Return a plan
with no policy group. The gather's "no policies declared" note stays in the
gather payload and is reproduced **nowhere** in the response — not in
`missing_tooling`, not in the plan (see *Response*; `missing_tooling` would turn
a deliberate skip into an adopt-Kyverno recommendation). Do not synthesise a
finding, and do not suggest the repo adopt policies — that is the consumer's
decision, not this plugin's.

## Response

Return the family's v2 envelope **inline** (NOT via a file) — every field, every
time; the orchestrator's per-group CI cycle branches on `ci_fixer_agent` and its
summary renders `missing_tooling`:

```json
{
  "schema_version": "2",
  "ci_fixer_agent": null,
  "plan": [],
  "missing_tooling": []
}
```

"Every field, every time" scopes to the **non-halt** path. The halt branch in
*Validation* adds a fifth top-level field — but **keeps `plan` and
`missing_tooling`**. The orchestrator moves a topic whose response "is not a
JSON object carrying `plan`" to `unsupported_topics` with a `dispatch failed`
note, which would swallow the very escalation the halt exists to deliver:

```json
{
  "schema_version": "2",
  "ci_fixer_agent": null,
  "plan": [],
  "missing_tooling": [],
  "human_action_required": [
    { "reason": "...", "recommendation": "..." }
  ]
}
```

**`missing_tooling` — the positive rule.** The family default builds it from
`tooling_configured` entries that are `false`. This dispatcher takes ONE
deliberate exception: `policy` and `policy_tests`. A repo with no matching
policy file has not failed to configure a tool — it has declined to declare
opinions, which is the charter's whole point, and listing it would re-emit the
adopt-Kyverno recommendation as a "here's how to add it".

Every other **known** `false` entry — one the routing table has a row for —
populates `missing_tooling` normally. An **unknown** key arriving `false` does
not: that is the `tooling_configured` face of the very routing drift *Validation*
halts on, and it reaches you *instead of* that halt, because the gather emits
`findings_by_tool` keys only for **configured** tools. So the same future tool
splits by repo — present, and the unknown key halts; absent, and only
`tooling_configured.<new_tool>: false` arrives. Treat both as the same event:
note it in `human_action_required`, **never** in `missing_tooling`. Recommending
that a repo adopt a tool this dispatcher cannot route is the same category error
the policy exemption prevents.

Of the known keys there is today exactly one besides the two exempted ones,
`manifest_validation`, and **it cannot be `false` on a
payload that reached you**. It is *presence detection*, not configuration: the
gather sets it from the same `find`/`grep` recipe the orchestrator's topic marker
uses, so a repo with no manifests never fires the marker and never dispatches
here. If one ever does arrive `false` — the two recipes having drifted, or a
hand-built payload — **note it in `human_action_required` and route nothing**:
"no manifests found" is not "kubeconform is unconfigured", and emitting the
family's adopt-a-tool recommendation for it would be the same category error the
policy exemption exists to prevent. That one halt entry is the trace for the
**whole** payload — do not additionally enumerate the other groups, because the
payload itself is what is suspect.

*Maintainers of this file:* this exemption is also recorded in the plugin
repo's `ARCHITECTURE.md`, under `### development-kubernetes owns` (shipped
with #1151) — keep the two in agreement, and never add a third statement of it.
This is an editing note, **not** a dispatch step: at dispatch time you are in the
consumer's repo, where that file is absent or belongs to someone else, so never
read it, and never let its absence affect the response.

`ci_fixer_agent` is `null`: this topic ships no CI fixer, so on a red PR the
orchestrator **escalates to the user** in its summary. It does **not** substitute
another plugin's fixer — reusing one requires naming it, which is exactly what
`null` does not do (`development-docs` states the same rule;
`development-react` names `js-ci-fixer` because it genuinely reuses it).

## What you never do

- Don't edit any file or spawn any agent — you only plan.
- Don't run the gather or re-derive findings — trust the payload (the
  orchestrator already gathered).
- Don't trim or restructure the payload's findings when echoing them into a
  group's `findings` list — echo the finding objects through **in full**, ids
  included (Phase 8 builds the work agent's prompt from them).
- Don't approve anything. This plugin ships **no approver agent** — a cluster
  definition is the origin of everything running on it, so a human approves.
