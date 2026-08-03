#!/usr/bin/env bats
#
# The development-kubernetes maintenance dispatcher (epic #1150, child #1152).
#
# Why this file exists: the dispatcher ships NO executable behaviour — it is a
# skill, so its PROSE is the contract, exactly as tests/kubernetes-plugin-skeleton.bats
# says of the manifest text it pins. Before this file, the only assertion touching
# the dispatcher was that the file exists, which would stay green if #1153 deleted
# the halt-shape rule, dropped `policy_tests` from the routing table, or let the
# escalation-until-#1153 override survive past the PR that makes it false.
#
# Conventions copied from the skeleton suite:
#   * every haystack is SCOPED to the section that must carry the clause, so a
#     coincidental occurrence elsewhere cannot satisfy a needle and a MOVED clause
#     is distinguishable from a present one;
#   * each scoped extraction is asserted non-empty FIRST — a failed `sed` yields an
#     empty haystack, which trivially `lacks` everything and would make the negative
#     assertions vacuous;
#   * needles are chosen so a NEGATED clause cannot satisfy them.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development-kubernetes/skills/maintenance/SKILL.md"
  [ -f "$SKILL" ]
  BODY="$(cat "$SKILL")"
  # the frontmatter only — everything above the second `---`
  # whitespace-normalized so a needle can span the description's line wraps —
  # the frontmatter is a folded YAML scalar, so clause boundaries and line
  # boundaries do not coincide
  FRONTMATTER="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$SKILL" \
    | tr -s '[:space:]' ' ')"
  [ -n "$FRONTMATTER" ]
}

# a `## <name>` section, up to the next `## ` heading, whitespace-normalized so
# the needles can span the source's line wraps
section() {
  sed -n "/^## $1\$/,/^## /p" "$SKILL" | tr -s '[:space:]' ' '
}

@test "the frontmatter declares the skill and its no-approver charter (#1152)" {
  contains "$FRONTMATTER" 'name: maintenance'
  contains "$FRONTMATTER" 'disable-model-invocation: false'
  contains "$FRONTMATTER" 'Ships NO approver'
  # the slice label must track the manifests (0.2.0) and the other registries,
  # which say v0.2 — and this string is reproduced into the generated
  # docs/reference/commands.md, so a stale label is user-visible
  contains "$FRONTMATTER" 'v0.2 REGISTERS the routing table'
  lacks "$FRONTMATTER" 'v1 REGISTERS'
  # the pure-function charter: with this gone a model may re-run detection inside
  # the consumer's repo, which is the orchestrator's job and not this skill's
  contains "$FRONTMATTER" 'runs no detection of its own'
}

@test "the intro scopes 'validation' to the TOOLS, not the payload (#1152)" {
  # unqualified, "you do not run validation yourself" reads as forbidding the
  # very § Validation guards below it — and a model resolving that way skips them
  # and falls through on a broken payload
  local intro
  intro="$(sed -n '/^You are the \*\*kubernetes-topic maintenance dispatcher/,/^## Validation/p' "$SKILL" \
           | tr -s '[:space:]' ' ')"
  [ -n "$intro" ]
  contains "$intro" 'the validation **tools**'
  contains "$intro" '*Payload* validation is a different thing and it **is** yours'
}

@test "validation pins every payload guard (#1152)" {
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  # schema and topic identity: without the second, this dispatcher would plan
  # against a python or java payload
  contains "$s" '.schema_version != "2"'
  contains "$s" '.language != "kubernetes"'
  # the reason the guard is on `language` and not a `topic` key — deleting this
  # rationale is how a well-meaning edit reintroduces `.topic == "kubernetes"`,
  # which would stop on every valid dispatch
  contains "$s" 'there is no `topic` key in the v2 payload'
  # the empty-invocation branch, and the parse branch — five bullets, and the
  # earlier version of this test pinned three
  contains "$s" '`$ARGUMENTS` empty'
  contains "$s" 'does not parse as JSON'
}

@test "a payload that fails validation NEVER becomes an empty plan (#1152)" {
  # the load-bearing paragraph: without it a v3 payload, a truncated file or a
  # wrong-topic dispatch returns {"plan": []}, which the orchestrator renders as
  # "the topic's tools ran and found nothing" — a clean bill of health for a
  # payload nobody could read
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" 'Stop on any failure in the block above'
  contains "$s" 'Never fall through to *Response*'
  contains "$s" 'not** for a broken or wrong-version one'
  contains "$s" 'would be a silent failure'
}

@test "the executable guard block implements every documented check (#1152)" {
  # the prose says "Stop on any failure in the block above"; thin or delete the
  # block and that sentence dangles at nothing while every prose needle still
  # passes — including the never-fall-through test, whose subject IS this block
  local block
  block="$(sed -n '/^```bash$/,/^```$/p' "$SKILL" | grep -v '^```')"
  [ -n "$block" ]
  [ "$(printf '%s\n' "$block" | wc -l)" -le 12 ]
  contains "$block" 'command -v jq'
  contains "$block" '[ -n "$ARGUMENTS" ]'
  contains "$block" 'test -f "$ARGUMENTS"'
  contains "$block" 'jq -e . "$ARGUMENTS"'
  contains "$block" ".schema_version == \"2\""
  contains "$block" ".language == \"kubernetes\""
  # the missing-file bullet's own guard, distinct from the parse guard
  contains "$block" 'no payload file at:'
}

@test "an unknown findings_by_tool key HALTS rather than being dropped (#1152)" {
  local s
  s="$(section Validation)"
  [ -n "$s" ]
  contains "$s" 'that the routing table below has no entry for'
  contains "$s" 'rather than dropping it silently'
  # and the halt is a RETURN of the envelope, not an error exit — the two read as
  # opposites, and erroring would have the orchestrator record `dispatch failed`
  # and swallow the very escalation the halt exists to deliver
  contains "$s" 'it **returns** the halt envelope'
  contains "$s" 'swallow it'
}

@test "the routing table names both agents against all three tools (#1152)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" '| `manifest_validation` | `kubernetes-manifest-fixer` |'
  contains "$s" '| `policy` | `kubernetes-policy-triage` |'
  # policy_tests specifically: dropping this row silently un-routes the coverage
  # analogue while every other assertion here stays green
  contains "$s" '| `policy_tests` | `kubernetes-policy-triage` |'
}

@test "policy and policy_tests are grouped into ONE PR (#1152)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'into **one** PR'
  contains "$s" 'racing on the same files'
}

@test "a key with an EMPTY findings array forms no group (#1152)" {
  # manifest_validation: [] is on every payload (presence-detected, checks run in
  # CI) and policy: []/policy_tests: [] is a clean policy set — so treating each
  # routed KEY as a group would escalate the ordinary clean dispatch as "Halted"
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'A group exists only for a ROUTED `findings_by_tool` key whose array is'
  contains "$s" 'it forms no group, no plan entry'
  contains "$s" 'escalate the ordinary clean dispatch'
  # ROUTED is load-bearing: unscoped, this rule contradicts Validation's
  # unknown-key halt for an unknown key carrying an empty array, and silently
  # dropping that key is the routing drift the halt exists to surface
  contains "$s" 'halts on its mere *presence*, empty array or not'
  contains "$s" 'this paragraph does not exempt it'
}

@test "the policy TOOL is distinguished from the payload's top-level policy object (#1152)" {
  # a kubernetes payload carries both; resolving a bare "policy" to the family's
  # maintenance-policy object would read a repo with no Kyverno files as having
  # policies configured — inverting the charter's central skip
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" '`tooling_configured.policy` / `findings_by_tool.policy`'
  contains "$s" '**never** read by this dispatcher'
}

@test "dispatch_filter is honoured, defensively (#1152)" {
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" '.dispatch_filter.only_tools'
  contains "$s" 'an empty plan is the correct result'
}

@test "the until-#1153 escalation override is pinned, and self-expiring (#1152)" {
  # this is the whole of v0.2's runtime behaviour: routing an agent that does not
  # exist would have the orchestrator spawn an undefined subagent_type. The pin is
  # deliberately self-expiring — #1153 must delete it, which reds this test and
  # forces the deletion to be considered rather than inherited.
  local s
  s="$(section Routing)"
  [ -n "$s" ]
  contains "$s" 'Until #1153 lands, this table dispatches nothing'
  contains "$s" 'return every group as a `human_action_required` entry'
  contains "$s" 'Delete this paragraph in #1153'
  # the frontmatter restates the same rule and is NOT covered by "this paragraph",
  # so the deletion instruction must name it too — otherwise #1153 leaves a
  # description licensing escalation against a body licensing routing
  contains "$s" 'rewrite the "v0.2 REGISTERS ... NO agents" sentence'
  contains "$FRONTMATTER" 'ships NO agents'
}

@test "the coverage analogue does not contradict the escalation override (#1152)" {
  # 'the group is still dispatched ... Never drop the group' read alone yields a
  # plan entry naming an agent this plugin does not ship — precisely what Routing
  # forbids. The qualifier is what keeps the two sections stating one rule.
  local s
  s="$(section 'No coverage gate, one analogue')"
  [ -n "$s" ]
  contains "$s" 'once #1153 ships `kubernetes-policy-triage`'
  contains "$s" '*Routing* wins until its paragraph is deleted'
  # the destination itself must survive the qualifier
  contains "$s" 'ordering-blocking'
  contains "$s" 'Never drop the group'
  contains "$s" 'primary-mode only'
}

@test "auxiliary mode omits policy_tests and keeps the other two (#1152)" {
  # the primary/auxiliary split: planning fixture-writing on a repo whose primary
  # is Java is the category error the model exists to prevent — but suppressing a
  # declared policy's violation would lose a real defect with no trace
  local s
  s="$(section 'Dispatch mode')"
  [ -n "$s" ]
  contains "$s" '`policy_tests` → **omitted entirely** in auxiliary mode'
  contains "$s" '`manifest_validation` → routed as usual'
  contains "$s" '`policy` → routed as usual'
  # the VALUE, not just the phrase: rewriting it to "auxiliary" is the single
  # highest-consequence edit in this section (every payload lacking dispatch_mode
  # would omit the policy_tests group), and a needle stopping one word short
  # accepts it
  contains "$s" 'absent is treated as'
  contains "$s" '`"primary"`**, per `ARCHITECTURE.md`'
  # the enum closed over a third value, so a hand-built payload cannot fall into
  # no branch at all
  contains "$s" 'Any **other** value is a payload-contract break'
}

@test "the response envelope carries every field, and the halt keeps plan (#1152)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" '"schema_version": "2"'
  contains "$s" '"ci_fixer_agent": null'
  contains "$s" '"human_action_required"'
  # the DELIVERY rule: a dispatcher rewritten to write a response file satisfies
  # every field needle above while producing something the orchestrator reads as
  # "not a JSON object carrying plan" — i.e. `dispatch failed`
  contains "$s" 'inline** (NOT via a file)'
  # the load-bearing half: java's and go's halt objects omit `plan`, and a
  # response without it is moved to unsupported_topics as `dispatch failed`
  contains "$s" 'keeps `plan` and'
  contains "$s" '`missing_tooling`**'
  contains "$s" 'unsupported_topics'
}

@test "ci_fixer_agent is null and no other plugin's fixer is substituted (#1152)" {
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" 'escalates to the user'
  contains "$s" 'does **not** substitute'
}

@test "policy and policy_tests are EXEMPT from missing_tooling (#1152)" {
  # without this the dispatcher follows the family default and re-emits the
  # adopt-Kyverno recommendation the charter forbids — in the COMMON case, a repo
  # that has simply declined to declare opinions
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" 'ONE deliberate exception: `policy` and `policy_tests`'
  contains "$s" 'declined to declare opinions'
  # the scoping half — without it the exemption reads as blanket suppression
  contains "$s" 'Every other **known** `false` entry'
  contains "$s" 'populates `missing_tooling` normally'
  # the UNKNOWN half: the gather emits findings_by_tool keys only for CONFIGURED
  # tools, so a future tool absent from a repo arrives ONLY as
  # tooling_configured.<new>: false — the unknown-key halt never fires, and an
  # unscoped default would recommend adopting a tool this dispatcher cannot route
  contains "$s" 'An **unknown** key arriving `false` does not'
  # the WHOLE two-halved sentence. Pinning only 'never in missing_tooling' would
  # survive deleting the escalation half — after which an unknown key lands in
  # NEITHER list and is dropped with no trace, which is the drift this rule was
  # added to surface. Same hazard the manifest_validation test below documents.
  contains "$s" 'Treat both as the same event: note it in `human_action_required`, **never** in `missing_tooling`'
}

@test "an unrecognized dispatch_mode HALTS rather than routing (#1152)" {
  # any non-empty human_action_required IS the halt branch, and Phase 7 skips
  # every remaining phase for the target — so "treat it as primary and note it"
  # would build a plan the orchestrator discards, and the routed work would
  # silently never run
  local s
  s="$(section 'Dispatch mode')"
  [ -n "$s" ]
  contains "$s" 'Any **other** value is a payload-contract break'
  contains "$s" '**route nothing** and return the halt envelope'
  contains "$s" 'that single entry is the trace for the whole payload'
  # POSITIVE pins for the prohibition and its rationale. A `lacks` cannot do this
  # job: the file spells the anti-pattern only INSIDE its own prohibition, so the
  # phrase is a substring of the very sentence that forbids it — and the
  # rationale (why routing-and-noting is incoherent) would otherwise carry no
  # assertion at all and could be deleted with this test green.
  contains "$s" 'Do **not** "treat it as primary and carry on"'
  contains "$s" 'any non-empty `human_action_required` *is* the halt branch'
  contains "$s" 'Phase 7 skips'
}

@test "manifest_validation's presence semantics are stated, not assumed (#1152)" {
  # it is presence of renderable manifests, NOT configured tooling, so the family
  # default would tell a repo with no manifests to adopt kubeconform
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" 'presence detection*, not configuration'
  contains "$s" 'cannot be `false` on a payload that reached you'
  # the WHOLE clause: 'route nothing' alone survives deleting the escalation
  # half, which turns a payload the section itself calls a contract break into
  # the plain empty-plan envelope — a clean bill of health
  contains "$s" 'note it in `human_action_required` and route nothing'
  # and the scoping half, or the same payload produces a per-group escalation
  # storm over a problem that is global
  contains "$s" 'the trace for the **whole** payload'
  contains "$s" 'do not additionally enumerate'
}

@test "the ARCHITECTURE cross-reference is a MAINTAINER note, not a dispatch step (#1152)" {
  # at dispatch time this skill runs in the consumer's repo, where this plugin
  # repo's ARCHITECTURE.md is absent or belongs to someone else; an unqualified
  # "verify the two agree" has no branch for either outcome
  local s
  s="$(section Response)"
  [ -n "$s" ]
  contains "$s" '*Maintainers of this file:*'
  contains "$s" 'This is an editing note, **not** a dispatch step'
  contains "$s" 'never let its absence affect the response'
}

@test "absent policies are a skip reproduced NOWHERE in the response (#1152)" {
  local s
  s="$(section 'Absent policies are not a finding')"
  [ -n "$s" ]
  contains "$s" 'the gather'"'"'s glob `policies/kyverno/**/*.{yaml,yml}` matched nothing'
  contains "$s" 'Do not synthesise a finding'
  contains "$s" 'not this plugin'"'"'s'
}

@test "the dispatcher spawns nothing and approves nothing (#1152)" {
  local s
  s="$(section 'What you never do')"
  [ -n "$s" ]
  contains "$s" 'Don'"'"'t edit any file or spawn any agent'
  contains "$s" 'Don'"'"'t run the gather or re-derive findings'
  contains "$s" 'no approver agent'
  contains "$s" 'echo the finding objects through **in full**'
}

@test "the plugin ships no agents directory for the table to route to yet (#1152)" {
  # the FACT the Routing override depends on — asserted here so the override and
  # its premise are retired together in #1153
  [ ! -d "$REPO_ROOT/development-kubernetes/agents" ]
}
