#!/usr/bin/env bats
#
# development-kubernetes plugin skeleton (issue #1151, child 1 of epic #1150).
#
# Why this file exists: the story originally cited tests/check-marketplace-sync.bats
# as its gate, but that suite is FIXTURE-only — it copies tests/fixtures/clean into
# a tmpdir and runs the script against that, never reading the repo's real
# marketplace.json or the new plugin.json. It therefore passes byte-identically
# with this whole change reverted. These tests assert against the REAL repo root,
# so the skeleton's shape is actually gated. Mirrors the same-shape coverage
# tests/react-topic-marker.bats gives development-react's foundation slice.
#
# At this stage the plugin ships no executable behaviour, so the PROSE is the
# contract — every later child of #1150 builds on it. The load-bearing clauses
# are pinned in all four places they are stated (plugin.json, marketplace.json,
# ARCHITECTURE.md, and the plugins.md narrative) so a future edit cannot quietly
# drop "no approver agent" or move the policy path with a green suite.
#
# Three conventions the assertions follow deliberately:
#   * needles are chosen so a NEGATED clause cannot satisfy them ("can itself be
#     PRIMARY", not bare "PRIMARY");
#   * every haystack is SCOPED to the section that must contain the clause, so a
#     coincidental occurrence elsewhere in a 1400-line document cannot satisfy a
#     needle and a MOVED clause is distinguishable from a present one; and
#   * every all-plugins sweep reads its name list into a variable and asserts it
#     non-empty first — a `while read` fed by a process substitution swallows
#     jq's exit status, so a failed/empty jq would otherwise run the loop zero
#     times and report `ok` having asserted nothing. The same hazard applies to
#     `lacks "$(cat …)"`: a failing command substitution in argument position
#     yields an EMPTY haystack, which trivially lacks everything, so each file
#     is existence-guarded before it is read.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/development-kubernetes"
  PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  ENTRY='.plugins[] | select(.name == "development-kubernetes")'

  # the ownership section only — the end address is a generic `^## `, so it
  # stops at whatever H2 follows rather than coupling to one section's name
  ARCH_SECTION="$(sed -n '/^### `development-kubernetes` owns/,/^## /p' "$ARCH")"

  # every marketplace plugin name, read once so jq's status is observable
  PLUGIN_NAMES="$(jq -r '.plugins[].name' "$MARKETPLACE")"

  # development-javascript predates the registry invariants below; tracked in
  # #1168. The exemption is SELF-EXPIRING: each sweep asserts the plugin is
  # genuinely still absent, so the PR that closes #1168 must delete the skip.
  DEFERRED_PLUGIN="development-javascript"

  REVIEW_SKILL="$PLUGIN_DIR/skills/review/SKILL.md"
}

# One `## Step N` section of the review skill, whitespace-normalized.
#
# SCOPING, not convenience: several clauses in that file share a literal with a
# clause in a DIFFERENT step — `<findings-path>.failed.json` is stated in both
# the render half and Step 2, `render-map.json` in both the provenance bullet
# that writes it and the gate that reads it. An unscoped `contains` over the
# whole file cannot tell those apart, so the rule under test could be deleted
# while its twin elsewhere keeps the needle green. Every review-skill needle
# below is therefore asserted against the step that must carry it. This is the
# same discipline tests/kubernetes-dispatcher.bats applies with its section().
rstep() {
  sed -n "/^## Step $1 /,/^## Step /p" "$REVIEW_SKILL" | tr -s '[:space:]' ' '
}

@test "the plugin manifest exists at the conventional path (#1151)" {
  [ -d "$PLUGIN_DIR" ]
  [ -f "$PLUGIN_JSON" ]
  jq -e . "$PLUGIN_JSON" >/dev/null
}

@test "plugin.json's name, the marketplace source and the on-disk directory all agree (#1151)" {
  # derived from the DATA, not from a constant set in setup(): this genuinely
  # couples the three artifacts rather than re-asserting one literal twice
  local name source_dir
  name="$(jq -er '.name' "$PLUGIN_JSON")"
  source_dir="$(basename "$(jq -er "$ENTRY | .source" "$MARKETPLACE")")"
  [ "$name" = "development-kubernetes" ]
  [ "$name" = "$source_dir" ]
  [ -d "$REPO_ROOT/$name" ]
}

@test "the marketplace lists development-kubernetes exactly once (#1151)" {
  run jq '[.plugins[] | select(.name == "development-kubernetes")] | length' "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "marketplace version is DERIVED from plugin.json, not hardcoded twice (#1151)" {
  # the lockstep rule: a bump in one file that misses the other must red here.
  # jq -er (not -r alone) so a MISSING key fails the assignment — plain `jq -r`
  # prints the string "null", which is non-empty and would pass a [ -n ] guard
  local from_plugin from_marketplace
  from_plugin="$(jq -er '.version' "$PLUGIN_JSON")"
  from_marketplace="$(jq -er "$ENTRY | .version" "$MARKETPLACE")"
  # anchored — an unanchored pattern accepts v0.1.0-SNAPSHOT and 0.1.0.9
  matches "$from_plugin" '^[0-9]+\.[0-9]+\.[0-9]+$'
  [ "$from_marketplace" = "$from_plugin" ]
  # the shipped-slice label is pinned by VALUE elsewhere in this file (the README
  # row says "agents and review panel in v0.3", plugins.md says "What's built
  # (v0.3)"), so the manifests must agree — otherwise a PR could land the agents
  # and prose while leaving both manifests at 0.2.0, staying green while installs
  # never see the change.
  # #1154's PIPELINE is all `development/` (a bootstrap template, the SKILL
  # rules, branch-protection.sh), so the MINOR does not move — bumping a plugin
  # whose own capability did not grow advertises what it did not gain. The patch
  # digit does move: #1154 also edits this plugin's review SKILL.md, and
  # MAINTAINING.md's rule admits no exception for content under `<plugin>/`
  # (Claude Code caches by version, so an unbumped edit ships inert). The
  # prefix assertion holds across both.
  starts_with "$from_plugin" "0.3."
}

@test "the marketplace source resolves to the real plugin directory (#1151)" {
  local source
  source="$(jq -er "$ENTRY | .source" "$MARKETPLACE")"
  [ "$source" = "./development-kubernetes" ]
  [ -d "$REPO_ROOT/$source" ]
  [ -f "$REPO_ROOT/$source/.claude-plugin/plugin.json" ]
}

@test "the marketplace entry carries the development category (#1151)" {
  run jq -r "$ENTRY | .category" "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" = "development" ]
}

@test "the manifest carries the discovery fields the marketplace surface depends on (#1151)" {
  # keywords/license/author ARE the plugin's marketplace surface — how it is
  # found and what a user agrees to — so they are asserted by VALUE: presence
  # alone would accept a wrong licence or an author disagreeing with the
  # marketplace entry. (This predates the plugin having any content; it is not
  # about how much it ships, so it does not move as slices land.)
  jq -e '.keywords | index("kubernetes")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("kyverno")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("topic-plugin")' "$PLUGIN_JSON" >/dev/null
  # via intermediate assignments: a failing jq -er in ARGUMENT position expands
  # to "" without failing the test, so [ "" = "" ] would pass vacuously if a
  # refactor dropped .author.name from BOTH files — the lockstep edit this
  # suite exists to police
  local license author_plugin author_marketplace
  license="$(jq -er '.license' "$PLUGIN_JSON")"
  author_plugin="$(jq -er '.author.name' "$PLUGIN_JSON")"
  author_marketplace="$(jq -er "$ENTRY | .author.name" "$MARKETPLACE")"
  [ "$license" = "MIT" ]
  [ "$author_plugin" = "$author_marketplace" ]
}

@test "plugin.json's description pins the load-bearing contract clauses (#1151)" {
  local desc
  desc="$(jq -er '.description' "$PLUGIN_JSON")"
  contains "$desc" "policies/kyverno/**/*.{yaml,yml}"
  contains "$desc" "Ships no approver agent"
  # the whole clause, so a rewrite to "is never PRIMARY" cannot satisfy it
  contains "$desc" "can itself be PRIMARY"
  contains "$desc" "Composes ALONGSIDE"
  # the ownership boundary the spec calls the expensive-to-get-wrong decision;
  # marketplace.json's copy is asserted only by equality, so dropping it here
  # silently drops it from the marketplace surface too
  contains "$desc" "Defers Dockerfiles and image builds to language plugins"
  # the slice label must track what actually shipped: v0.3.0 carries the agents
  # and the review panel, so a stale dispatcher-only claim would understate it
  lacks "$desc" "foundation slice"
  lacks "$desc" "adds the maintenance dispatcher"
  contains "$desc" "adds the five agents and the review panel"
}

@test "the marketplace description matches plugin.json's exactly (#1151)" {
  # one plugin, one description: the two drifted apart once already (the
  # marketplace copy silently described a narrower capability set), so pin
  # equality rather than a clause subset
  local from_marketplace from_plugin
  from_marketplace="$(jq -er "$ENTRY | .description" "$MARKETPLACE")"
  from_plugin="$(jq -er '.description' "$PLUGIN_JSON")"
  [ "$from_marketplace" = "$from_plugin" ]
}

@test "the plugin ships the dispatcher, the five agents and the review skill (#1153)" {
  # an asserted decision, not an oversight: the dispatcher landed with #1152, the
  # agents and review panel with #1153. When a later child adds a kind, this test
  # must be updated in the same PR, which is the point. The [ -d "$PLUGIN_DIR" ]
  # guard matters: a mis-derived path makes every child absent, so the assertions
  # below would pass having proven nothing.
  [ -d "$PLUGIN_DIR" ]
  # the whole entry set, not enumerated kinds: a later hooks/, commands/ or
  # templates/ directory would leave a set of [ ! -d ] negatives green while the
  # shipped description still enumerates what the slice contains
  local entries
  # LC_ALL=C: under a glibc en_US.UTF-8 collation punctuation is ignored at the
  # primary level, so `.claude-plugin` would sort as `claudeplugin` and this
  # equality would flip for a maintainer running the suite in a UTF-8 locale
  entries="$(cd "$PLUGIN_DIR" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
  [ "$entries" = ".claude-plugin agents skills " ]
  # the positive half — an entry-set equality alone is satisfied by EMPTY skills/
  # and agents/ directories, which is exactly what a half-applied change looks
  # like. The agent set is asserted EXACTLY: the story ships five and no more,
  # and "no approver agent" is a charter clause, so a sixth file appearing here
  # must be a deliberate edit rather than an inherited one.
  [ -f "$PLUGIN_DIR/skills/maintenance/SKILL.md" ]
  [ -f "$PLUGIN_DIR/skills/review/SKILL.md" ]
  local agents
  agents="$(cd "$PLUGIN_DIR/agents" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
  [ "$agents" = "argocd-advisor.md kubernetes-manifest-fixer.md kubernetes-policy-triage.md kubernetes-reliability-reviewer.md kubernetes-security-reviewer.md " ]
}

@test "every shipped agent's frontmatter carries the four required keys, BY VALUE (#1153)" {
  # EQUALITY, not substring — the same rule tests/resilience-review-dimension.bats
  # applies, and for two distinct reasons:
  #   * `contains "$fm" "name: $base"` is satisfied by `name: argocd-advisor-v2`,
  #     which is exactly the unaddressable-subagent_type dispatch miss this test
  #     exists to prevent;
  #   * `tools:` is an UPPER BOUND on capability. A read-only REVIEWER that
  #     gained `Edit` could "fix" what it is supposed to report, and a bare
  #     presence check accepts that silently. So the two roles are pinned to
  #     their own tool sets.
  local f base fm name model tools desc
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$PLUGIN_DIR/agents" -name '*.md' | sort)
  # guard the glob itself: an empty list makes the loop body run zero times and
  # report ok having asserted nothing
  [ "${#files[@]}" -eq 5 ]
  for f in "${files[@]}"; do
    base="$(basename "$f" .md)"
    fm="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$f")"
    [ -n "$fm" ]
    name="$(printf '%s\n' "$fm" | sed -n 's/^name: //p' | head -1)"
    model="$(printf '%s\n' "$fm" | sed -n 's/^model: //p' | head -1)"
    tools="$(printf '%s\n' "$fm" | sed -n 's/^tools: //p' | head -1)"
    desc="$(printf '%s\n' "$fm" | sed -n 's/^description: //p' | head -1)"
    [ "$name" = "$base" ]
    [ "$model" = "opus" ]
    [ -n "$desc" ]
    # the role split, by value: reviewers are read-only, the two maintenance
    # agents edit and verify
    case "$base" in
    *-reviewer|argocd-advisor) [ "$tools" = "Read, Grep, Glob" ] ;;
    *)                         [ "$tools" = "Read, Edit, Bash, Grep" ] ;;
    esac
  done
}

@test "the review skill names exactly the three review dimensions, and no approver (#1153)" {
  # the dimension set IS the contract #1153 produces (security, reliability,
  # argocd). The row COUNT is derived, not assumed: three `contains` needles
  # plus two `lacks` are all satisfied by a table that also carries a FOURTH
  # row naming some other agent — after which the panel's prose, which
  # hardcodes "three" in three places, launches three of four and the missing
  # dimension is waived in silence.
  local review body
  review="$PLUGIN_DIR/skills/review/SKILL.md"
  [ -f "$review" ]
  body="$(cat "$review")"
  contains "$body" '| security | `kubernetes-security-reviewer` |'
  contains "$body" '| reliability | `kubernetes-reliability-reviewer` |'
  contains "$body" '| argocd | `argocd-advisor` |'

  # every data row under the `| Dimension | Agent |` header, separator excluded
  local rows n agent
  rows="$(awk '/^\| Dimension \| Agent \|/{t=1; next} t && /^\|---/{next} t && /^\|/{print; next} t{exit}' "$review")"
  [ -n "$rows" ]
  n="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
  [ "$n" -eq 3 ]
  # and each derived agent name resolves to a shipped file — a typo'd row would
  # otherwise pass every needle above and fail only at dispatch time
  while read -r agent; do
    [ -f "$PLUGIN_DIR/agents/$agent.md" ]
  done < <(printf '%s\n' "$rows" | sed -n 's/^| [a-z_]* | `\([a-z-]*\)` |$/\1/p')
  [ "$(printf '%s\n' "$rows" | sed -n 's/^| [a-z_]* | `\([a-z-]*\)` |$/\1/p' | wc -l | tr -d ' ')" -eq 3 ]

  # the prose count words must agree with the derived row count, or the table
  # and the instructions that consume it drift apart
  contains "$body" 'Dispatch three agents in parallel'
  contains "$body" 'Wait for all three agents'
  contains "$body" 'When all three dimensions complete'

  # the maintenance-only agents must NOT be dispatched as review dimensions
  lacks "$body" 'kubernetes-manifest-fixer'
  lacks "$body" 'kubernetes-policy-triage'
  # the charter clause, restated where a reader of the panel would look for it
  contains "$body" 'There is no approver dimension'
  # and no approver agent exists to be wired in later
  [ ! -f "$PLUGIN_DIR/agents/kubernetes-approver.md" ]
}

@test "the review skill's machine-readable output contract is pinned (#1153)" {
  # the dispatcher's prose is pinned test-by-test in its own suite; without these the panel's entire
  # CONSUMABILITY is unasserted, and every failure mode below is silent rather
  # than red — a dimension waived in silence is a blocker shipped.
  local review body
  review="$PLUGIN_DIR/skills/review/SKILL.md"
  [ -f "$review" ]
  body="$(cat "$review" | tr -s '[:space:]' ' ')"
  [ -n "$body" ]

  # BY VALUE, for the same reason the agent test above extracts rather than
  # `contains`-es — and more sharply here: `contains 'name: review'` is satisfied
  # by `name: review-panel` or `name: reviewers`, each of which breaks the
  # `development-kubernetes:review` invocation review-dispatch.zsh synthesises as
  # `development-${repo_type}:review`. An unaddressable AGENT loses one
  # dimension; an unaddressable SKILL loses the whole panel, and the sweep in
  # review-dispatch.bats only checks that a SKILL.md exists at the path.
  local fm skill_name dmi desc s1
  s1="$(rstep 1)"; [ -n "$s1" ]
  fm="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$review")"
  [ -n "$fm" ]
  skill_name="$(printf '%s\n' "$fm" | sed -n 's/^name: //p' | head -1)"
  dmi="$(printf '%s\n' "$fm" | sed -n 's/^disable-model-invocation: //p' | head -1)"
  desc="$(printf '%s\n' "$fm" | sed -n 's/^description: //p' | head -1)"
  [ "$skill_name" = "review" ]
  [ "$dmi" = "false" ]
  # the description is reproduced into the generated docs/reference/commands.md
  # and is what a model reads when deciding whether this panel applies; the
  # --check run elsewhere only proves the page matches the generator, not that
  # the description says anything
  [ -n "$desc" ]
  contains "$desc" 'Reviews rendered manifests, not templates.'

  # all SEVEN injected placeholders, each pinned by the PROMPT LINE that binds
  # it — never the bare token. Every token appears twice in this file, once in
  # the maintainer-facing prose that introduces it and once in the prompt
  # template, so a bare needle survives deleting the prompt line entirely: the
  # agents would then receive no scope, no repo root, no render map and no
  # changed-file list while the suite stayed green. An unbound {AGENT NAME}
  # corrupts the `reviewer` field the consolidator keys on; an unbound
  # {DIMENSION} buckets every finding under a literal placeholder string;
  # {RENDER MAP}, {REPO} and {CHANGED FILES} are what make the source-path rule
  # and the app-of-apps identity check obeyable at all — reviewers have no Bash
  # to derive any of them themselves.
  contains "$s1" 'Review scope: {SCOPE}'
  contains "$s1" 'Source repository root: {REPO}'
  contains "$s1" 'Rendered-to-source map: {RENDER MAP}'
  contains "$s1" 'Changed source files in scope: {CHANGED FILES}'
  contains "$s1" 'dimension ("{DIMENSION}")'
  contains "$s1" 'reviewer ("{AGENT NAME}")'
  contains "$s1" 'round ({ROUND})'
  # the COUNT word must track the list: a placeholder added without updating it
  # leaves a caller substituting fewer than the skill actually carries
  contains "$s1" 'substituting **all seven** placeholders'
  # the standalone-run relaxation — pinned by the RULE's own clauses, not by the
  # bare literal `none — standalone run`, which also appears in the placeholder
  # value list and in the prompt line; deleting both statements of the rule
  # would leave that mention behind and the needle green
  contains "$s1" 'no `scope-findings` filter to satisfy'
  contains "$s1" 'never withhold a finding for want of a list'

  # the agents run on their OWN definitions, not a general-purpose subagent —
  # the regression resilience-review-dimension.bats pins for the service panels
  contains "$body" 'use its name as the `subagent_type`'
  lacks "$body" 'subagent_type: general-purpose'

  # the severity vocabulary the injected prompt maps to `severity` — the agents'
  # half is pinned in the agent-body test below, and both halves must name the
  # same three tags or the mapping silently produces a Low
  contains "$s1" 'severity (the CRITICAL|WARNING|SUGGESTION tag from the prose)'

  # the file-path rule (#1153 round 2): a finding whose `file` is not in the
  # story's diff — a rendered temp path, a directory, or an UNCHANGED template
  # when the edit was to values.yaml — is dropped by the loop's diff scoping, so
  # the round records a clean review over a blocker it was told about
  contains "$s1" 'CHANGED SOURCE FILE'
  contains "$s1" 'Never report a directory as `file`'
  # the same two prohibitions inside the INJECTED PROMPT, which is what the
  # agent actually receives — the prose above it is the maintainer's rationale
  contains "$s1" 'Never the rendered temp-tree path, and never a directory'
  contains "$s1" 'MUST be one of the changed source files listed above'
  # and the ESCAPE HATCH that makes the prohibitions followable: without it a
  # reviewer facing an unattributable finding has only prohibitions, so it drops
  # the finding or files it out of scope — where the filter discards it anyway.
  # Pinned in the MAINTAINER prose AND, separately, in the injected prompt: the
  # prose is not what a reviewer receives, so a rule that lives only there is a
  # rule no agent ever reads.
  contains "$s1" 'closest changed file that is in scope'
  contains "$s1" 'equivalent to not reporting it at all'
  contains "$s1" 'Use `line: null` whenever the rendered line has no line'
  local prompt
  prompt="$(sed -n '/^    Review scope: {SCOPE}/,/^Without this block/p' "$review" | tr -s '[:space:]' ' ')"
  [ -n "$prompt" ]
  contains "$prompt" 'MUST be one of the changed source files listed above'
  contains "$prompt" 'never the chart or overlay root the map may name'
  contains "$prompt" 'closest file in scope with line: null'
  # the LOOP-mode half: a finding whose text lives in an unchanged file ties
  # cleanly to "a source file", so the standalone hatch never fires — the
  # reviewer would report a path the filter discards, and the round records
  # clean over a real blocker
  contains "$prompt" 'do NOT report the unchanged file'
  contains "$prompt" 'closest CHANGED file in scope with line: null'
  contains "$prompt" 'reporting nothing is worse than reporting it approximately'

  # Step 2's array-only rule and its sibling failure path, scoped to Step 2 —
  # the render half states the same `.failed.json` sibling rule, so an unscoped
  # needle cannot tell which of the two survived
  local s2 s3
  s2="$(rstep 2)"; [ -n "$s2" ]
  contains "$s2" 'Do not write the findings path'
  contains "$s2" '<findings-path>.failed.json'
  contains "$s2" 'does not parse as a JSON array'
  # the HEADLINE rule of Step 2: delete it and a crashed reviewer becomes an
  # empty array concatenated into a clean aggregate — a dimension waived in
  # silence, which is a blocker shipped
  contains "$s2" 'An agent that fails is not an agent that found nothing'
  contains "$s2" 're-launch it once'
  contains "$s2" 'report the round as **failed** and name the dimension'

  # Step 3's obligation — without it a caller mapping an absent file to []
  # records a clean review that never happened
  s3="$(rstep 3)"; [ -n "$s3" ]
  contains "$s3" '## Findings (JSON)'
}

@test "the review skill's RENDER-half failure branches are pinned too (#1153)" {
  # the output-contract test above covers collect and aggregate; these are the
  # two render-time branches of the same class, each silent rather than red.
  # Kept in their own test so a failure localizes to the render half — and
  # because the `.failed.json` needle above already matches the Step 2
  # occurrence, so the render-side rule could otherwise be deleted with the
  # suite green.
  # SCOPED to Step 1: Step 2 states the same `.failed.json` sibling rule, so an
  # unscoped needle cannot tell which of the two survived a deletion
  local body
  body="$(rstep 1)"
  [ -n "$body" ]

  # a failed render must FAIL the round: reviewing the partially rendered tree
  # reports a complete three-dimension review over a silently truncated scope,
  # and the chart that failed to render is the one most worth reviewing
  contains "$body" 'if any REMAINING render command fails, the round FAILS'
  # the render-side array-only rule, pinned by a RENDER-UNIQUE needle: the bare
  # `<findings-path>.failed.json` token also occurs in Step 2, so it cannot tell
  # the two occurrences apart and this rule could be deleted with the suite green
  contains "$body" 'report the round as failed to the caller and write the detail to the sibling'

  # without the copy, a repo whose Argo CD resources are plain YAML points
  # argocd-advisor at a tree with no Application document: it emits []
  # deterministically and the round records a clean review of resources no agent
  # read
  contains "$body" 'copy standalone manifests in alongside them'
  contains "$body" 'rendered output *and* the standalone manifests copied in alongside it'

  # ALL FOUR skip categories. The first three FAIL by design when rendered
  # standalone, so deleting any of them turns the failure rule pinned above into
  # a failed round on every repo whose own CI renders green — the opposite of
  # what that rule is for.
  contains "$body" 'before rendering — `type: library` charts'
  contains "$body" 'a `charts/` parent that is itself a chart'
  contains "$body" 'kind: Component'
  # the consumed-base skip: a consumed base renders SUCCESSFULLY but PARTIALLY,
  # so it evades the failure rule entirely and seeds the review tree with
  # documents that never deploy in that form
  contains "$body" 'any kustomization root another root'

  # provenance — without it the reporting rule above cannot be obeyed at all,
  # since reviewers have no Bash and kustomize output carries no source marker.
  # The kustomize bullet is the whole answer to that undifferentiated stream, so
  # it is pinned as specifically as the helm one.
  contains "$body" 'write `<tmp>/render-map.json`'
  contains "$body" 'name that file in the agents'"'"' prompt as the mapping to consult'
  contains "$body" 'helm template --output-dir'
  contains "$body" 'named for that root'
  contains "$body" 'never a single merged file'
  # the third provenance bullet: flattening standalone manifests destroys source
  # attribution for the argocd dimension, whose primary input IS standalone YAML
  contains "$body" 'under their repo-relative paths'
  contains "$body" 'not flattened into one directory'

  # render the WHOLE repo regardless of scope — the absence checks in two of the
  # three agents are only sound over a complete tree
  contains "$body" 'regardless of what `$ARGUMENTS` scopes'
  contains "$body" 'Scope narrows what is *reviewed*, never what is *rendered*'

  # and the empty / nothing-in-scope-rendered gate, without which three agents
  # each correctly emit [] and Step 3 writes a clean aggregate for a change no
  # agent ever reviewed
  contains "$body" 'the temp tree is **empty**'
  contains "$body" 'no rendered document belongs to a changed source'
  contains "$body" 'So do not dispatch'
  # membership by chart/root, NOT map-value equality: equality alone refuses to
  # dispatch on a values-only or overlay-only change, the commonest shape there
  # is and the one the Scope note itself calls typical
  contains "$body" 'membership plus consumption'
  contains "$body" 'or any file in the same chart or kustomize root as that source'
  # consumption too: the step builds only UNCONSUMED roots, so a change confined
  # to a consumed base renders under the overlay's root — same-root membership
  # alone would refuse to dispatch on a change that alters what deploys
  contains "$body" 'transitively consumes'
  # a DELETED path fails every membership test above, so without this branch the
  # round reports not-applicable on a diff that removed a manifest, chart or
  # kustomize root — a change that unambiguously alters what deploys, and the
  # very class this panel's attribution rules legislate for
  contains "$body" 'A DELETED path is always in scope'
  # and the SCOPE that deletion-triggered dispatch carries: a deleted unit
  # renders nothing, so the ordinary "rendered files a changed source produces"
  # rule would bind {SCOPE} to nothing and three agents would read nothing and
  # correctly emit [] — the same clean-round-over-nothing, one step later
  contains "$body" 'makes the WHOLE temp tree the scope'
  # conditioned on the DELETION, not on what triggered dispatch: on a mixed diff
  # (edit chart A, delete an Application) the edit triggers dispatch and binds a
  # good scope of its own, so a trigger-conditioned override would drop the
  # deletion and record clean over the dangling parent
  contains "$body" 'not** whether it is what triggered'
  contains "$body" 'even on a mixed diff'
  contains "$body" 'The deletion branch above overrides this'
  # and the STANDALONE relaxation of this gate — without it "no rendered
  # document belongs to a changed source" is vacuously true on every direct
  # invocation, so the panel reports not-applicable and reviews nothing
  contains "$body" 'applies only when a changed-file list exists'
  contains "$body" 'only the empty-tree shape gates'
}

@test "each agent BODY carries the severity vocabulary the panel depends on (#1153)" {
  # the frontmatter test pins addressability; this pins the substance. The review
  # skill delegates outright — "using the prose reporting format defined in your
  # agent definition" — and maps `severity` to the tag from that prose. A
  # reviewer that drifted to HIGH/MEDIUM/LOW would keep every other assertion in
  # this file green while consolidate-findings.zsh mapped its findings to Low,
  # which never blocks: a whole review dimension permanently non-blocking, in
  # silence. tests/resilience-review-dimension.bats pins exactly this for the
  # four service panels.
  local f base full body flat fm
  local -a files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$PLUGIN_DIR/agents" -name '*.md' | sort)
  [ "${#files[@]}" -eq 5 ]
  for f in "${files[@]}"; do
    base="$(basename "$f" .md)"
    full="$(cat "$f")"
    # the BODY proper — everything after the closing frontmatter fence. The
    # dispatch-pointer needles below live in the frontmatter `description:` and
    # are asserted against $full; everything else must be in the body, or a file
    # reduced to its frontmatter would satisfy assertions about its substance.
    body="$(awk 'f>1 {print} /^---$/ {f++}' "$f")"
    # whitespace-normalized, for needles whose clause spans a line wrap — the
    # prose is hard-wrapped at 79 columns, so a sentence-length needle asserted
    # against $body would pass or fail on where the wrap happens to fall
    flat="$(printf '%s' "$body" | tr -s '[:space:]' ' ')"
    fm="$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside' "$f")"
    [ -n "$fm" ]
    [ -n "$full" ]
    [ -n "$body" ]
    [ -n "$flat" ]
    case "$base" in
    *-reviewer|argocd-advisor)
      # the three REVIEW agents: the panel extracts the tag from this heading
      contains "$body" '### [CRITICAL|WARNING|SUGGESTION] One-line title'
      contains "$body" '**File:**'
      contains "$body" '**Severity guide**'
      # the source-path rule, without which the loop's diff filter discards
      # every finding the agent reports — pinned past the bolded heading, since
      # the three copies are hand-maintained and narrowing any one of them
      # produces the same silent finding-loss
      contains "$body" 'CHANGED SOURCE FILE'
      contains "$flat" 'never a directory'
      contains "$flat" 'Never withhold a finding for want of a list'
      # the LOOP-mode half, in the AGENT body — round 6 pinned it only in the
      # skill's injected prompt, leaving these three hand-maintained copies
      # unread. Trim it from one reviewer and it reports the UNCHANGED file when
      # a story's diff breaks text in untouched YAML; the filter drops the
      # finding and the round records clean over a blocker. Both needles are
      # unique to the LOOP paragraph — the standalone one says "closest file you
      # can identify".
      contains "$flat" 'closest CHANGED file in scope'
      contains "$flat" 'which unchanged file the text is actually in'
      # the dispatch pointer, asserted against the FRONTMATTER: $full is the
      # whole file, so moving the clause into the body would satisfy it — and
      # the frontmatter description is what routes the agent and what the docs
      # generator reproduces
      contains "$fm" 'dimension of /development-kubernetes:review.'
      ;;
    *)
      # the two MAINTENANCE agents carry no severity vocabulary — they are
      # dispatched by the maintenance planner, not the review panel, and a
      # reporting-format section here would imply they are review dimensions
      lacks "$body" '### [CRITICAL|WARNING|SUGGESTION]'
      contains "$fm" 'Used by development-kubernetes:maintenance.'
      # both escalate rather than silently absorbing what they cannot do
      contains "$body" '## Escalations'
      contains "$body" '## Unverified'
      ;;
    esac

    # the ONE clause per agent that decides whether it is useful or harmful.
    # Without these the test above is satisfied by an agent stripped to its
    # frontmatter plus a Reporting Format block.
    # the two absence-checking reviewers share a rule; asserted before the
    # per-agent switch below rather than with a `;;&` fallthrough, which is
    # bash 4+ and this suite must run on macOS's bash 3.2
    case "$base" in
    kubernetes-security-reviewer|kubernetes-reliability-reviewer)
      # absence claims made over a diff-scoped subset produce false blocking
      # findings against resources that were never exposed
      contains "$flat" 'Absence of evidence inside a scope is not evidence of absence'
      contains "$flat" 'search the **entire** rendered tree'
      ;;
    esac

    case "$base" in
    kubernetes-security-reviewer)
      # the carve-out is a CLOSED list, pinned by the prohibition itself — a bare
      # `closed` would be satisfied by "enclosed", "disclosed" or any future
      # prose, and says nothing about what must not be widened
      contains "$flat" 'Exactly three things: missing probes, absent resource limits, and `latest` image tags.'
      contains "$flat" 'Do not widen it by reasoning about `kube-linter`'"'"'s check set'
      contains "$body" 'stay **in scope for you anyway**'
      ;;
    kubernetes-reliability-reviewer)
      # anti-affinity ABSENCE is kube-linter's; only the exists-but-wrong case is
      # this agent's, or the panel duplicates the CI gate.
      # NOTE: needles here are single-line fragments, never `||`-joined
      # alternatives — an `||` tail neutralises errexit for the call before it,
      # exactly the inert-assertion hazard tests/assertions.bats documents.
      contains "$body" 'exists but does not work'
      contains "$body" 'no-anti-affinity'
      contains "$flat" 'That list is closed. Do not extend it by reasoning about what else'
      ;;
    argocd-advisor)
      # resolving paths against the render tree reports every healthy parent as
      # broken; guessing the repo identity waives the check on this repo's apps
      contains "$flat" 'against the SOURCE repository root, never the rendered tree'
      contains "$body" 'repo identity unknown'
      ;;
    kubernetes-manifest-fixer)
      # leaving a failed edit in place while reporting the finding fixed closes
      # the group's PR over a still-red check
      contains "$body" 'revert your edit'
      # and the ESCALATE boundary — the clause that decides whether this agent is
      # safe. It holds Edit+Bash and its output lands in an auto-merge-armed
      # group PR, so a widened Fix section means an agent silently changing
      # replica counts, image tags or RBAC subjects under the label "mechanical".
      # The read-only reviewers' boundaries are all pinned; these were not.
      contains "$body" 'changes **what gets deployed** is not mechanical'
      contains "$flat" 'Anything altering image tags, replica counts, resource values, RBAC subjects, or namespace targets'
      ;;
    kubernetes-policy-triage)
      # flipping the fixture to pass enshrines a match-nothing policy as tested
      contains "$body" 'Never** adjust the fixture'
      contains "$body" 'Do not add policies'
      # the revert-on-failed-verify rule, pinned like its manifest-fixer twin —
      # deleting the fixture half leaves a failing kyverno test in the tree
      # while the agent escalates, the same PR-closes-over-red regression
      contains "$flat" 'revert whatever you edited for it'
      # and the verify-with-the-PRODUCING-check rule: kyverno test after a
      # manifest fix re-evaluates the fixtures, never the edit, so a wrong fix
      # would ship reported-as-verified
      contains "$flat" 'Re-run the check that PRODUCED the finding'
      contains "$flat" 'is verified by `kyverno apply`'
      # the agent's raison d'être — 'Do not add policies' covers ADDING, not
      # EDITING, so without this the case-2 prohibition can be deleted while the
      # agent silently relaxes a consuming repo's architectural commitment
      contains "$body" 'Escalate — do not edit the policy.'
      contains "$flat" 'architectural decision the consuming repo owns'
      ;;
    esac
  done
}

@test "both the skills and the agents now reach the generated reference (#1153)" {
  # #1151 shipped this plugin as the generator's first zero-skill PLUGINS entry,
  # exercising the `if not skills: continue` guards; #1152 gave it a skill, and
  # #1153 gives it agents — so BOTH generated pages must now carry it. The
  # agents-page assertion is flipped rather than deleted, so a regression that
  # drops the agents from the generator's scan reds here.
  local commands agents
  [ -f "$REPO_ROOT/docs/reference/commands.md" ]
  [ -f "$REPO_ROOT/docs/reference/agents.md" ]
  commands="$(cat "$REPO_ROOT/docs/reference/commands.md")"
  agents="$(cat "$REPO_ROOT/docs/reference/agents.md")"
  # prove the haystacks are the real generated pages before asserting content
  contains "$commands" '## development-react'
  contains "$agents" '## development-docs'
  contains "$commands" '## development-kubernetes'
  contains "$agents" '## development-kubernetes'
  # the review skill specifically — the commands page carried the dispatcher
  # since #1152, so a bare section heading no longer proves this slice landed
  contains "$commands" '/development-kubernetes:review'
  # and prove that is what the generator WOULD emit, not merely what is committed
  run python3 "$REPO_ROOT/scripts/generate-docs-reference.py" --check
  [ "$status" -eq 0 ]
}

@test "primary: kubernetes now SELECTS the plugin — the gather exists (#1152)" {
  # ARCHITECTURE used to claim primary: kubernetes was treated as stale "until
  # kubernetes is in the detected+supported set". A topic enters supported_topics
  # only when its gather script exists AND is executable (the orchestrator's
  # discovery-by-convention rule is `test -x`), so this asserts the FACT the
  # post-#1152 prose depends on. Flipped rather than deleted, so the claim stays
  # pinned in its new direction.
  [ -x "$REPO_ROOT/development/skills/maintenance/scripts/gather-kubernetes-findings.zsh" ]

  # the Container diagram carried the same time-bounded claims, and nothing else
  # points at that page — so the post-landing strings are pinned here, and the
  # retired ones asserted GONE, which is what makes the flip irreversible-by-accident
  local c4
  c4="$(cat "$REPO_ROOT/docs/architecture/c4-container.md")"
  lacks "$c4" 'dispatches (planned, #1152)'
  lacks "$c4" 'may be primary (skeleton, #1151)'
  contains "$c4" 'Rel(development, development-kubernetes, "dispatches")'
  contains "$c4" 'may be primary")'
}

@test "ARCHITECTURE.md records the ownership boundary (#1151)" {
  [ -n "$ARCH_SECTION" ]
  contains "$ARCH_SECTION" 'Argo CD `Application` / `ApplicationSet` / `AppProject` resources'
  contains "$ARCH_SECTION" 'It does **not** own Dockerfiles or image builds'
}

@test "ARCHITECTURE.md states the policy convention as a GLOB, not directory presence (#1151)" {
  # directory-presence and glob-match are different contracts: a repo whose
  # policies are .yml, or whose policies/kyverno/ exists but is empty, must not
  # be silently reported as "no policies declared" while its policies go unrun
  contains "$ARCH_SECTION" 'policies/kyverno/**/*.{yaml,yml}'
  contains "$ARCH_SECTION" 'skip condition is **no matching files**'
}

@test "ARCHITECTURE.md scopes the never-fails guarantee to ABSENCE, so violations still fail (#1151)" {
  # read broadly, "it never fails" licenses a policy step that always succeeds,
  # which would make the whole mechanism decorative. The needle spans the
  # condition AND its consequence so neither half can be deleted alone.
  contains "$ARCH_SECTION" 'when policies **are** declared, violations'
  contains "$ARCH_SECTION" '**fail** the step'
}

@test "ARCHITECTURE.md records that the plugin ships no policies of its own (#1151)" {
  # this decision directly constrains children #1152-#1155: duplicating
  # kube-linter's generic hygiene means two places to silence one false positive
  contains "$ARCH_SECTION" 'ships **no policies of its own**'
  contains "$ARCH_SECTION" "\`kube-linter\`'s job"
}

@test "ARCHITECTURE.md records the no-approver rationale AND the auto-merge distinction (#1151)" {
  # conflating no-approval with no-auto-merge either over- or under-delivers —
  # the story calls the distinction out explicitly for that reason
  contains "$ARCH_SECTION" '**No approver agent**'
  contains "$ARCH_SECTION" 'not* the same as no auto-merge'
}

@test "ARCHITECTURE.md records the six checks and who owns the pipeline (#1151)" {
  # the constraint #1154 will be reviewed against: the workflow is a BOOTSTRAP
  # template owned by the generic development plugin, not something this
  # plugin's skills run — the same boundary that keeps detection in development
  local flat
  flat="$(printf '%s' "$ARCH_SECTION" | tr -s '[:space:]' ' ')"
  contains "$flat" '**six checks**'
  contains "$flat" 'render → schema → lint → policy → config-scan → argocd'
  # the count word and the list length must not drift: a seventh step appended
  # to the arrow list would otherwise still satisfy the substring needle while
  # the prose kept saying "six"
  lacks "$flat" 'config-scan → argocd →'
  # and at the head — a PREPENDED stage satisfies the substring needle, the tail
  # guard and the literal "six checks" all at once
  lacks "$flat" '→ render'
  contains "$flat" 'a *bootstrap* template owned by the generic `development` plugin'
  # #1154 shipped the template, so the deliberately future-tense wording is now
  # wrong. Pinned in BOTH directions: the retired tense asserted gone, the landed
  # one asserted present, so a regenerate-from-an-older-draft edit cannot restore
  # a "will emit" that describes a file which exists.
  lacks "$flat" '**will emit**'
  contains "$flat" '**emits**'
}

@test "ARCHITECTURE.md records the policy/policy_tests missing_tooling exemption (#1151)" {
  # constrains #1152/#1153: without this clause the dispatcher follows the family
  # default (build missing_tooling from tooling_configured false entries) and
  # re-emits the adopt-Kyverno recommendation the charter forbids — in the COMMON
  # case, a repo that has simply declined to declare opinions.
  local flat
  flat="$(printf '%s' "$ARCH_SECTION" | tr -s '[:space:]' ' ')"
  # both keys named: asserting only `policy` would let a narrowing edit that
  # drops policy_tests pass
  contains "$flat" 'This plugin exempts `policy` and `policy_tests`'
  contains "$flat" 'has not failed to configure a tool, it has declined to declare opinions'
  # the scoping half — without it the exemption reads as blanket suppression
  contains "$flat" 'Every other **known** `false` entry populates `missing_tooling` normally'
  # the unknown-key half, mirrored from the dispatcher per the keep-in-agreement note
  # the WHOLE clause: the nearby 'escalates via human_action_required' needle
  # matches the SEPARATE manifest_validation sentence, so without this the
  # unknown-key escalation could be deleted from ARCHITECTURE with the suite
  # green — leaving it and the dispatcher stating different rules, which the
  # dispatcher's own keep-in-agreement note depends on
  contains "$flat" 'is the `tooling_configured` face of routing drift and is escalated via `human_action_required` instead, never listed as missing tooling'
  # the second half of the same rule, added with the dispatcher: manifest_validation
  # is presence detection, so a `false` value is a payload-contract break the
  # dispatcher ESCALATES — not a missing_tooling entry recommending kubeconform to
  # a repo that has no manifests. Unpinned, ARCHITECTURE could drift into
  # licensing the family default the dispatcher forbids.
  contains "$flat" 'presence detection**, not configuration'
  contains "$flat" 'escalates** via `human_action_required`'
  contains "$flat" 'never a `missing_tooling` entry'
}

@test "the plan's reproduced ARCHITECTURE block still matches the shipped section (#1151)" {
  # The plan reproduces this section verbatim under a banner calling it "the
  # shipped text ... do not regenerate from an older draft". Every edit to the
  # section has silently staled that copy, and a later child reconciling the two
  # could delete a shipped clause. Derive the comparison rather than trusting it.
  local plan
  plan="$REPO_ROOT/docs/superpowers/plans/2026-08-02-development-kubernetes.md"
  [ -f "$plan" ]
  # the sed range in setup() INCLUDES its terminating `## ` heading; the plan
  # reproduces the section without it, so compare the body only
  local body plan_text
  plan_text="$(cat "$plan")"
  body="$(printf '%s\n' "$ARCH_SECTION" | sed '/^## /d' | sed -e :a -e '/^\n*$/{$d;N;};/\n$/ba')"
  [ -n "$body" ]
  contains "$plan_text" "$body"

  # the banner covers THREE reproductions, not one. The other two are the
  # manifest description and version, and Task 4 explicitly rewrites the
  # description — at which point those blocks become the "older draft" the
  # banner forbids regenerating from, while every clause needle still matches.
  # the manifest is reproduced TWICE (the plugin.json block and the marketplace
  # block), so a bare `contains` is satisfied by whichever was updated first
  # while the other silently becomes the "older draft" the banner forbids.
  # Derive the site count from the plan rather than hardcoding it.
  local desc version d_sites d_ok v_sites v_ok
  desc="$(jq -er '.description' "$PLUGIN_JSON")"
  version="$(jq -er '.version' "$PLUGIN_JSON")"
  d_sites="$(grep -cF '"description": "Infrastructure-as-code' "$plan")"
  d_ok="$(grep -cF -- "$desc" "$plan")"
  [ "$d_ok" -ge 2 ]
  [ "$d_sites" -eq "$d_ok" ]
  v_sites="$(grep -cF '"version": "' "$plan")"
  v_ok="$(grep -cF "\"version\": \"$version\"" "$plan")"
  [ "$v_ok" -ge 2 ]
  [ "$v_sites" -eq "$v_ok" ]
}

@test "ARCHITECTURE.md records the primary capability, now that it SELECTS (#1152)" {
  # #1152 registered the marker and gather, so the caveat is retired — but the
  # capability itself stays pinned, and the retired wording is asserted gone so
  # the flip cannot be silently reverted
  contains "$ARCH_SECTION" 'A repo declaring `primary: kubernetes`'
  lacks "$ARCH_SECTION" 'treats the declaration as stale'
  contains "$ARCH_SECTION" '**selects this'
  # #1154 shipped the pipeline, so the "gates are still outstanding" remainder is
  # retired — flipped rather than deleted, and its replacement pinned just as
  # tightly, or the section would understate a plugin whose findings a CI check
  # now enforces. The retired wording is asserted gone so the flip cannot be
  # silently reverted.
  lacks "$ARCH_SECTION" 'The **gates themselves** arrive'
  lacks "$ARCH_SECTION" 'no CI check enforces the manifests on a PR'
  contains "$ARCH_SECTION" '**#1154 landed the gates themselves**'
  # the #1153 half, previously the ONE restatement of the routing claim with no
  # assertion: the other two sites (plugins.md, the dispatcher SKILL) are pinned,
  # so a coordinated revert to the escalates-to-a-human wording shipped green
  contains "$ARCH_SECTION" '**#1153 landed the second half**'
  contains "$ARCH_SECTION" 'the dispatcher now **routes**'
  lacks "$ARCH_SECTION" 'escalates each group to a human rather'
}

@test "the dispatch_mode payload contract states the stale-declaration rule too (#1151)" {
  # the ownership section and the payload contract must not disagree about what
  # a stale primary does — a model implementing the orchestrator reads the
  # latter, and the two rules are opposites if only one is stated.
  # SCOPED to the dispatch_mode paragraph: asserted against the whole file, the
  # phrase "every target" is satisfied by the ownership section itself, so the
  # contract's consequence clause could be deleted with the test still green.
  local dm
  dm="$(sed -n '/^\*\*`dispatch_mode`\*\* is/,/^$/p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$dm" ]
  contains "$dm" 'is **stale**'
  contains "$dm" 'every target dispatches as `"primary"`'
  contains "$dm" '`primary: kubernetes` before #1152'
}

@test "the language-first section points at the ownership boundary with a resolving anchor (#1151)" {
  # a fourth restatement site; ARCHITECTURE.md is outside the mkdocs tree, so
  # nothing else validates that this anchor resolves
  local lf
  lf="$(sed -n '/^### Language-first principle/,/^### /p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$lf" ]
  contains "$lf" '`development-kubernetes` plugin defers to'
  contains "$lf" '(#development-kubernetes-owns)'
  # the anchor's target: a heading whose GitHub slug is development-kubernetes-owns
  contains "$(cat "$ARCH")" '### `development-kubernetes` owns'
}

@test "no shipped plugin is still listed as a future topic in ARCHITECTURE.md (#1151)" {
  # the CLASS of defect, not just its kubernetes instance: the family tree and the
  # category table are real registries, so a plugin that ships must leave the
  # "future" lists in the SAME change
  local name topic tree_line tree_future topic_row after_future
  [ -n "$PLUGIN_NAMES" ]

  tree_line="$(grep -F 'future topics:' "$ARCH")"
  topic_row="$(grep -E '^\| \*\*Topic\*\* \|' "$ARCH")"
  [ -n "$tree_line" ]
  [ -n "$topic_row" ]
  # one line each — with two, the comma-adjacency the needles rely on breaks at
  # the line boundary, and ${topic_row#*future:} would strip to the SECOND row's
  # marker and silently discard the first row's examples
  [ "$(printf '%s\n' "$tree_line" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(printf '%s\n' "$topic_row" | wc -l | tr -d ' ')" -eq 1 ]
  # assert the marker exists before stripping on it: with no match the strip is a
  # no-op returning the WHOLE row, and the sweep would then red on every plugin
  contains "$topic_row" 'future:'

  # comma-delimit both future lists so the match is on a WHOLE token: every
  # plugin name starts with "development", so a substring test would flag the
  # generic plugin against any list at all
  tree_future=",$(printf '%s' "${tree_line#*future topics:}" | tr -d ' '),"
  after_future="${topic_row#*future:}"
  [ -n "$after_future" ]

  while read -r name; do
    # the tree lists bare topic tokens ("opentofu"), the table full plugin names
    topic="${name#development-}"
    if [ "$topic" != "$name" ]; then
      lacks "$tree_future" ",$topic,"
    fi
    lacks "$after_future" "\`$name\`"
  done <<< "$PLUGIN_NAMES"

  # and the shipped plugin is positively listed in BOTH registries — the table
  # check is scoped to the pre-future segment, so a mention in the future list
  # cannot satisfy it, and it pins the caveat that keeps the row honest
  contains "${topic_row%%future:*}" '`development-kubernetes`'
  lacks "$topic_row" 'dispatch lands with #1152'
  lacks "$topic_row" 'agents land with #1153'
  # #1154 shipped the pipeline, so this row's caveat is retired like the two
  # above it — asserted gone rather than merely unpinned, so a regenerate from
  # an older draft cannot restore a row advertising a landed capability as
  # forthcoming
  lacks "$topic_row" 'CI pipeline lands with #1154'
  contains "$topic_row" '`development-kubernetes`, future:'
  # the tree is column-aligned, so match the gap as whitespace rather than
  # pinning a literal run of spaces that reflows when a longer name is added
  matches "$(grep -F 'development-kubernetes ' "$ARCH" | head -n1)" \
    'development-kubernetes[[:space:]]+← topic: infrastructure-as-code.*'
}

@test "no shipped plugin is described as unimplemented in the user-facing docs (#1151)" {
  # motivation.md's aspirational list told readers a plugin they can install does
  # not exist. Scoped to the ASPIRATIONAL SENTENCE and swept on the bare token,
  # so the invariant is independent of list position and phrasing — the earlier
  # positional needles missed the terminal and standalone-sentence forms.
  # Whitespace-normalized so a docs rewrap cannot silently void it.
  local motivation para aspirational name
  motivation="$REPO_ROOT/docs/explanation/motivation.md"
  [ -f "$motivation" ]
  [ -n "$PLUGIN_NAMES" ]
  # terminate on a blank line: item 5 is the LAST numbered item, so a
  # /^[0-9]\./ end address never matches, the range runs to EOF, and `sed '$d'`
  # would delete a real content line rather than the delimiter
  para="$(sed -n '/topic plugins are still aspirational/I,/^$/p' "$motivation" | tr -s '[:space:]' ' ')"
  [ -n "$para" ]
  aspirational="${para%%but not implemented*}"
  [ -n "$aspirational" ]
  [ "$aspirational" != "$para" ]

  while read -r name; do
    lacks "$aspirational" "\`$name\`"
  done <<< "$PLUGIN_NAMES"

  # and the positive half — otherwise deleting the sentence outright also passes
  contains "$para" '`development-kubernetes` has landed'
}

@test "every marketplace plugin is registered in the docs-reference generator (#1151)" {
  # PLUGINS is hardcoded, so an unregistered plugin is SILENTLY skipped: the
  # generator never scans it, --check compares two equally incomplete files, and
  # the drift gate passes while the reference pages omit the plugin entirely.
  local gen name block
  gen="$REPO_ROOT/scripts/generate-docs-reference.py"
  [ -f "$gen" ]
  [ -n "$PLUGIN_NAMES" ]
  block="$(sed -n '/^PLUGINS = \[/,/^\]/p' "$gen")"
  [ -n "$block" ]

  while read -r name; do
    if [ "$name" = "$DEFERRED_PLUGIN" ]; then
      continue
    fi
    contains "$block" "\"$name\""
  done <<< "$PLUGIN_NAMES"

  # self-expiring exemption: registering the deferred plugin (i.e. closing
  # #1168) reds this line, forcing the skip above to be deleted in that same PR
  lacks "$block" "\"$DEFERRED_PLUGIN\""
}

@test "every marketplace plugin has a row in the README plugin table (#1151)" {
  # a user-facing registry in the same class as the ARCHITECTURE ones above
  local readme table name
  readme="$REPO_ROOT/README.md"
  [ -f "$readme" ]
  [ -n "$PLUGIN_NAMES" ]
  table="$(grep -E '^\| \*\*development' "$readme")"
  [ -n "$table" ]

  while read -r name; do
    if [ "$name" = "$DEFERRED_PLUGIN" ]; then
      continue
    fi
    contains "$table" "**$name**"
  done <<< "$PLUGIN_NAMES"

  lacks "$table" "**$DEFERRED_PLUGIN**"

  # the row's time-bounded claim, pinned like every other restatement site, so
  # the child that lands the dispatcher must retire it deliberately
  local row
  row="$(grep -F '| **development-kubernetes** |' "$readme")"
  [ -n "$row" ]
  lacks "$row" 'ownership boundary only in v0.1'
  lacks "$row" 'maintenance dispatch in v0.2'
  contains "$row" 'agents and review panel in v0.3'
  # #1154's pipeline is named here too, but ATTRIBUTED: it ships as a
  # `development` bootstrap template, so the row must not read as a
  # development-kubernetes capability whose version never moved
  contains "$row" 'CI pipeline ships as a `development` bootstrap template'
}

@test "every marketplace plugin has a section in the plugin overview (#1151)" {
  # README advertises plugins.md as the full command + agent inventory, so an
  # unlisted plugin is invisible in the one place a reader is sent to look
  local headings name
  [ -f "$REPO_ROOT/docs/reference/plugins.md" ]
  [ -n "$PLUGIN_NAMES" ]
  headings="$(grep -E '^## development' "$REPO_ROOT/docs/reference/plugins.md")"
  [ -n "$headings" ]

  while read -r name; do
    if [ "$name" = "$DEFERRED_PLUGIN" ]; then
      continue
    fi
    # whole-line, not substring: "## development" is otherwise satisfied by
    # "## development-swift", so the generic plugin's section would be ungated
    grep -qx "## $name" "$REPO_ROOT/docs/reference/plugins.md"
  done <<< "$PLUGIN_NAMES"

  run -1 grep -qx "## $DEFERRED_PLUGIN" "$REPO_ROOT/docs/reference/plugins.md"
}

@test "the plugins.md narrative restates the charter without contradicting ARCHITECTURE (#1151)" {
  # this section is the user-facing statement of the same contract, so it is
  # pinned to the same clause set rather than to a bare heading. Whitespace-
  # normalized so the needles can span the source's line wraps, and delimited by
  # a generic `^## ` so inserting a section between does not widen the haystack.
  local section
  section="$(sed -n '/^## development-kubernetes/,/^## /p' "$REPO_ROOT/docs/reference/plugins.md" \
               | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  contains "$section" 'policies/kyverno/**/*.{yaml,yml}'
  contains "$section" 'no approver agent'
  contains "$section" '**no policies of its own**'
  # the whole clause — bare "can also be" is satisfied by "can also be auxiliary"
  contains "$section" 'it can also be **primary**'
  # the never-fails scoping must survive here too, or the published contract
  # reads as decorative while ARCHITECTURE says otherwise
  contains "$section" 'When policies *are* declared, violations fail'
  # the caveat that kept "can also be primary" honest is retired with #1152 —
  # the marker exists — but its REPLACEMENT must be pinned just as tightly, or
  # the page users actually read would over-promise a plugin that routes nothing
  lacks "$section" 'Until #1152 lands there is no `kubernetes` topic marker'
  lacks "$section" 'is treated as a stale declaration'
  # #1153 ships the agents, so the routes-nothing caveat is retired — flipped
  # rather than deleted, and its replacement pinned just as tightly, or the page
  # users actually read would understate a plugin that now routes every group
  lacks "$section" 'until #1153 lands the dispatcher routes nothing'
  contains "$section" 'the dispatcher now routes every group to a shipped agent'
  contains "$section" 'creeps into Dockerfiles or application code contradicts'
  contains "$section" "**What's built (v0.3):**"
  # #1154 shipped the pipeline, so the "rest of the epic follows" framing is
  # retired — flipped, not deleted, and its replacement pinned as tightly, or the
  # page users read would still describe the checks as forthcoming
  lacks "$section" 'The rest of epic'
  contains "$section" 'six separately requirable checks'
  # ATTRIBUTION, pinned as tightly as the capability: #1154's PIPELINE landed in
  # the `development` plugin — a page claiming it for this plugin would explain
  # the unmoved minor as an omission rather than a boundary. The claim is now
  # scoped to the pipeline, because #1154 DOES move this plugin's patch (it edits
  # the review skill), so a flat "not here" would be the false half of the truth.
  contains "$section" 'the **pipeline** is not here'
  contains "$section" 'moves only by a patch'
  # the boundary and the rendered-output property, restated here because this
  # page is where a user decides what the plugin does
  contains "$section" '**bootstrap** template owned by the generic `development` plugin'
  contains "$section" 'consumes the **rendered** output'
  # the Agents tables every agent-shipping plugin section carries — nothing
  # mechanical catches their absence (reference-drift regenerates only
  # commands.md/agents.md), so they are pinned here. Split review vs
  # maintenance, the development-go convention: the two sets are reached by
  # different entry points and conflating them hides that the fixer and triage
  # agents are NOT review dimensions.
  contains "$section" '**Agents (review panel):**'
  contains "$section" '**Agents (maintenance):**'
  # DERIVED from the shipped agent set, not a hand-picked subset: naming only
  # two of the five let a missing row for any of the other three pass, and this
  # page is the only gate on them (reference-drift regenerates commands.md and
  # agents.md, never plugins.md). Every other registry sweep in this file
  # derives its list from data for the same reason.
  # read into a variable FIRST and guard it, per this file's own header rule: a
  # `while read` fed by a process substitution swallows the producer's status,
  # so a mis-derived PLUGIN_DIR or an empty agents/ would run the loop zero
  # times and report ok having asserted nothing — on the page this comment
  # itself calls the only gate on those rows
  # scoped to the two AGENT TABLES, not the whole section: the Skills table's
  # dispatcher row already names `kubernetes-manifest-fixer` and
  # `kubernetes-policy-triage` in backticks, so a section-wide sweep is
  # satisfied for 2 of the 5 by text other than its target — deleting both rows
  # of the maintenance table would pass
  local agent agent_names tables
  tables="$(sed -n '/^\*\*Agents (review panel):\*\*/,/^## /p' \
              "$REPO_ROOT/docs/reference/plugins.md" | tr -s '[:space:]' ' ')"
  [ -n "$tables" ]
  agent_names="$(cd "$PLUGIN_DIR/agents" && LC_ALL=C ls -A | LC_ALL=C sort | sed 's/\.md$//')"
  [ -n "$agent_names" ]
  [ "$(printf '%s\n' "$agent_names" | wc -l | tr -d ' ')" -eq 5 ]
  while read -r agent; do
    contains "$tables" "\`$agent\`"
  done <<< "$agent_names"
  # the review skill's own row, so the panel is discoverable from the overview
  contains "$section" '`/development-kubernetes:review [scope]`'
}

@test "ARCHITECTURE registers this plugin's three review dimensions, derived from the panel (#1153)" {
  # ARCH_SECTION is scoped to '### `development-kubernetes` owns', which ends
  # before the Dimension enum paragraphs — so #1153's enum registration was the
  # one restatement site in this change with no assertion anywhere. Drift here
  # buckets the panel's findings under a value the schema never declares.
  # SCOPED to this plugin's registration paragraph, not the whole Dimension-enum
  # section: that section runs ~215 lines to the next H2 and contains the core-
  # five list and the resilience paragraph, so `security` and `reliability` would
  # be satisfied far outside the sentence under test — deleting `security` from
  # the registration would pass.
  local enum
  enum="$(sed -n '/^`development-kubernetes` (#1153) extends it/,/^$/p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$enum" ]
  contains "$enum" 'ships **three** dimensions in total'

  # DERIVED from the review skill's table, so the enum and the panel cannot
  # name different dimensions: every row's dimension AND its agent must appear
  local review rows dim agent
  review="$PLUGIN_DIR/skills/review/SKILL.md"
  [ -f "$review" ]
  rows="$(awk '/^\| Dimension \| Agent \|/{t=1; next} t && /^\|---/{next} t && /^\|/{print; next} t{exit}' "$review")"
  [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" -eq 3 ]
  while IFS='|' read -r _ dim agent _; do
    dim="$(printf '%s' "$dim" | tr -d ' ')"
    agent="$(printf '%s' "$agent" | tr -d ' `')"
    [ -n "$dim" ]
    [ -n "$agent" ]
    # the PAIRING, not the two tokens independently: asserting each separately
    # accepts a swapped table (reliability -> argocd-advisor), which is exactly
    # the drift this test exists to catch
    contains "$enum" "**\`$dim\`** (\`$agent\`)"
  done <<< "$rows"

  # the reliability-vs-resilience distinction, in BOTH sites that state it — a
  # single review round resolves one repo_type, so the two can never co-occur
  # in one round, and an edit collapsing them would make the #1148 $core-gap
  # rationale describe a plugin that no longer matches
  # the reliability-vs-resilience distinction lives in the FOLLOWING paragraph,
  # so it gets its own scoped haystack rather than widening the one above
  local distinction
  distinction="$(sed -n '/^\*\*`reliability` is not `resilience`/,/^$/p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$distinction" ]
  contains "$distinction" 'A single review *round* never emits both'
  local pl
  pl="$(sed -n '/^## development-kubernetes/,/^## /p' "$REPO_ROOT/docs/reference/plugins.md" | tr -s '[:space:]' ' ')"
  [ -n "$pl" ]
  contains "$pl" 'is not the family'
  contains "$pl" 'A single review round never emits both'
  # the #1153 fallback ASYMMETRY, at the site that stated the superseded rule.
  # review-dispatch.zsh requires ZERO detected languages for the kubernetes
  # branch (pinned behaviourally in tests/review-dispatch.bats), so a page
  # saying an unsupported-language repo "still reaches this one" describes the
  # pre-fix behaviour — and it sat inside this very haystack, green.
  lacks "$pl" 'still reaches this one'
  contains "$pl" 'reached only when **no** language is detected at all'
}

@test "ARCHITECTURE pins the fallback ordering AND the kubernetes zero-language rule (#1153)" {
  # the second restatement site of the same rule, and previously read by no test
  # at all: ARCH_SECTION stops at the ownership section and the enum extraction
  # starts later, so this bullet — the change's central new dispatch rule — had
  # one behavioural gate and zero prose gates.
  local fb
  fb="$(sed -n '/^- \*\*The two fallbacks are ordered/,/^- \*\*/p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$fb" ]
  # the superseded single-trigger phrasing must be GONE
  lacks "$fb" 'reached only when `.languages` contains no supported review language, and are keyed'
  # both triggers, stated separately
  contains "$fb" 'their triggers differ'
  contains "$fb" '`claude-plugin` is reached when `.languages` contains no **supported** review language'
  contains "$fb" '`kubernetes` additionally requires **no detected language at all**'
  # and the rationale, without which a later editor "harmonises" the two
  contains "$fb" 'definitional for what the repo *is*'
  contains "$fb" 'routinely incidental to an application repo'
}

@test "the bats suite's PR path filter covers every tree this file reads (#1151)" {
  # asserted in LIST-ENTRY form, so commenting an entry out while leaving the
  # rationale prose behind reds instead of passing; and driven off the full list
  # of trees this suite actually reads, so pruning any of them later reds here
  # rather than silently ungating a sweep at PR time
  local paths p
  paths="$(sed -n '/^  pull_request:/,/^  push:/p' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  [ -n "$paths" ]
  for p in 'ARCHITECTURE.md' 'README.md' 'docs/architecture/**' 'docs/explanation/**' \
           'docs/reference/**' '.claude-plugin/marketplace.json' 'scripts/**' \
           'development/skills/**/scripts/**' 'tests/**' 'docs/index.md' 'mkdocs.yml' \
           'docs/superpowers/**' \
           'development-kubernetes/**' '.github/workflows/script-tests.yml'; do
    contains "$paths" "      - '$p'"
  done
}
