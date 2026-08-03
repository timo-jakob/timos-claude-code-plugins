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

@test "the manifest carries the discovery fields a content-free plugin depends on (#1151)" {
  # at v0.1.0 the plugin ships nothing else, so keywords/license/author ARE its
  # marketplace surface — asserted by VALUE, since presence alone would accept a
  # wrong licence or an author disagreeing with the marketplace entry
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
  # a foundation slice must say so — v0.1.0 ships no skills or agents
  contains "$desc" "foundation slice"
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

@test "the skeleton really is content-free — no skills or agents yet (#1151)" {
  # an asserted decision, not an oversight: skills land in #1152, agents in #1153.
  # When they arrive this test must be updated in the same PR, which is the point.
  # The [ -d "$PLUGIN_DIR" ] guard matters: a mis-derived path makes every child
  # absent, so both assertions below would pass having proven nothing.
  [ -d "$PLUGIN_DIR" ]
  # the whole entry set, not two enumerated kinds: a later hooks/, commands/ or
  # templates/ directory would leave a pair of [ ! -d ] negatives green while
  # the shipped description still claims the slice contains nothing
  local entries
  entries="$(cd "$PLUGIN_DIR" && ls -A | sort | tr '\n' ' ')"
  [ "$entries" = ".claude-plugin " ]
}

@test "a registered but content-free plugin produces no generated reference section (#1151)" {
  # development-kubernetes is the FIRST entry in the generator's PLUGINS list
  # with zero skills and zero agents, so this change is what first exercises the
  # `if not skills: continue` guards. Landing #1152/#1153 must flip this test.
  local commands agents
  [ -f "$REPO_ROOT/docs/reference/commands.md" ]
  [ -f "$REPO_ROOT/docs/reference/agents.md" ]
  commands="$(cat "$REPO_ROOT/docs/reference/commands.md")"
  agents="$(cat "$REPO_ROOT/docs/reference/agents.md")"
  # prove the haystacks are the real generated pages before asserting absence
  contains "$commands" '## development-react'
  contains "$agents" '## development-docs'
  lacks "$commands" '## development-kubernetes'
  lacks "$agents" '## development-kubernetes'
  # and prove that is what the generator WOULD emit, not merely what is
  # committed: this plugin is its first content-free PLUGINS entry, so this is
  # what first exercises the `if not skills: continue` guards
  run python3 "$REPO_ROOT/scripts/generate-docs-reference.py" --check
  [ "$status" -eq 0 ]
}

@test "the stale-declaration premise is true today — no kubernetes gather exists yet (#1151)" {
  # ARCHITECTURE claims primary: kubernetes is treated as stale "until kubernetes
  # is in the detected+supported set". A topic enters supported_topics only when
  # its gather script exists (the orchestrator's discovery-by-convention rule), so
  # this asserts the FACT the prose depends on. #1152 must flip this test and that
  # paragraph together.
  [ ! -f "$REPO_ROOT/development/skills/maintenance/scripts/gather-kubernetes-findings.zsh" ]

  # the Container diagram carries the same time-bounded claims, and nothing else
  # points at that page — so pin them to THIS trigger, forcing the #1152 author
  # to retire the "planned"/"skeleton" labels in the same PR
  local c4
  c4="$(cat "$REPO_ROOT/docs/architecture/c4-container.md")"
  contains "$c4" 'dispatches (planned, #1152)'
  contains "$c4" 'may be primary (skeleton, #1151)'
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
  contains "$flat" 'Every other `false` entry populates `missing_tooling` normally'
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

@test "ARCHITECTURE.md records the primary capability AND its stale-declaration caveat (#1151)" {
  # promising the pipeline without the caveat over-promises: until #1152
  # registers the marker, primary: kubernetes selects nothing
  contains "$ARCH_SECTION" 'A repo declaring `primary: kubernetes`'
  contains "$ARCH_SECTION" 'treats the declaration as stale'
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
  contains "$topic_row" 'dispatch lands with #1152'
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
  contains "$row" 'ownership boundary only in v0.1'
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
  # the caveat that keeps "can also be primary" honest — pinned in ARCHITECTURE,
  # the dispatch_mode contract and the topic table, and needed here too: this is
  # the page users actually read
  contains "$section" 'Until #1152 lands there is no `kubernetes` topic marker'
  contains "$section" 'is treated as a stale declaration'
  contains "$section" 'creeps into Dockerfiles or application code contradicts'
  contains "$section" "**What's built (v0.1):**"
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
