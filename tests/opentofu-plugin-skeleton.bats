#!/usr/bin/env bats
#
# development-opentofu plugin skeleton (issue #1159, child 1 of epic #1158).
#
# Why this file exists: tests/check-marketplace-sync.bats is FIXTURE-only — it
# copies tests/fixtures/clean into a tmpdir and runs the script against that,
# never reading the repo's real marketplace.json or the new plugin.json, so it
# passes byte-identically with this whole change reverted. These tests assert
# against the REAL repo root, exactly as tests/kubernetes-plugin-skeleton.bats
# does for the sibling plugin.
#
# At this stage the plugin ships NOTHING executable, so the PROSE is the whole
# contract — every later child of #1158 builds on it. The load-bearing clauses
# are pinned in all four places they are stated (plugin.json, marketplace.json,
# ARCHITECTURE.md, and the plugins.md narrative) so a future edit cannot quietly
# drop "no approver agent", move the policy glob, or relax the state-encryption
# opinion with a green suite.
#
# Three conventions inherited from the sibling suite, deliberately:
#   * needles are chosen so a NEGATED clause cannot satisfy them ("can itself be
#     PRIMARY", not bare "PRIMARY");
#   * every haystack is SCOPED to the section that must contain the clause, so a
#     coincidental occurrence elsewhere in a 300 KB document cannot satisfy a
#     needle and a MOVED clause is distinguishable from a present one; and
#   * every file read into a `lacks`/`contains` argument is existence-guarded
#     first — a failing command substitution in argument position yields an
#     EMPTY haystack, which trivially lacks everything.
#
# The all-plugins registry sweeps (docs generator, README table, plugins.md
# headings, the ARCHITECTURE future lists, motivation.md) are NOT duplicated
# here: tests/kubernetes-plugin-skeleton.bats already derives them from
# marketplace.json, so they cover this plugin the moment its entry lands. What
# is asserted here instead is the POSITIVE half those sweeps cannot state — that
# each registry names *this* plugin, and says the right thing about it.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/development-opentofu"
  PLUGIN_JSON="$PLUGIN_DIR/.claude-plugin/plugin.json"
  MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"
  ENTRY='.plugins[] | select(.name == "development-opentofu")'

  # the ownership section only — the end address is a generic `^##`, so it stops
  # at the next heading of ANY level rather than coupling to one section's name.
  # H2-only would silently swallow a sibling H3 ownership section added after
  # this one, which is exactly what #1159 did to the kubernetes suite.
  ARCH_SECTION="$(sed -n '/^### `development-opentofu` owns/,/^##/p' "$ARCH")"
  # whitespace-normalized: ARCHITECTURE.md hard-wraps at ~79 columns, so any
  # needle longer than a few words must be matched against flattened text
  ARCH_FLAT="$(printf '%s' "$ARCH_SECTION" | tr -s '[:space:]' ' ')"
}

@test "the plugin manifest exists at the conventional path (#1159)" {
  [ -d "$PLUGIN_DIR" ]
  [ -f "$PLUGIN_JSON" ]
  jq -e . "$PLUGIN_JSON" >/dev/null
}

@test "plugin.json's name, the marketplace source and the on-disk directory all agree (#1159)" {
  # derived from the DATA, not from a constant set in setup(): this genuinely
  # couples the three artifacts rather than re-asserting one literal twice
  local name source_dir
  name="$(jq -er '.name' "$PLUGIN_JSON")"
  source_dir="$(basename "$(jq -er "$ENTRY | .source" "$MARKETPLACE")")"
  [ "$name" = "development-opentofu" ]
  [ "$name" = "$source_dir" ]
  [ -d "$REPO_ROOT/$name" ]
}

@test "the marketplace lists development-opentofu exactly once (#1159)" {
  run jq '[.plugins[] | select(.name == "development-opentofu")] | length' "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1 ]
}

@test "marketplace version is DERIVED from plugin.json, not hardcoded twice (#1159)" {
  # the lockstep rule: a bump in one file that misses the other must red here.
  # jq -er (not -r alone) so a MISSING key fails the assignment — plain `jq -r`
  # prints the string "null", which is non-empty and would pass a [ -n ] guard
  local from_plugin from_marketplace
  from_plugin="$(jq -er '.version' "$PLUGIN_JSON")"
  from_marketplace="$(jq -er "$ENTRY | .version" "$MARKETPLACE")"
  # anchored — an unanchored pattern accepts v0.1.0-SNAPSHOT and 0.1.0.9
  matches "$from_plugin" '^[0-9]+\.[0-9]+\.[0-9]+$'
  [ "$from_marketplace" = "$from_plugin" ]
  # the shipped-slice label is pinned by VALUE in two OTHER tests in this file —
  # "the README plugin-table row states the slice HONESTLY" (README's "only in
  # v0.2") and the plugins.md narrative test ("What's built (v0.2)") — so the
  # manifests must agree with both; otherwise a PR could land a later child's
  # content and prose while leaving both manifests at 0.1.0, staying green while
  # installs never see the change. (Round 1 of #1159's review caught this
  # comment claiming the README half was covered when nothing read README.md;
  # the assertion, not the comment, is what makes it true.)
  starts_with "$from_plugin" "0.2."
}

@test "the marketplace source resolves to the real plugin directory (#1159)" {
  local source
  source="$(jq -er "$ENTRY | .source" "$MARKETPLACE")"
  [ "$source" = "./development-opentofu" ]
  [ -d "$REPO_ROOT/$source" ]
  [ -f "$REPO_ROOT/$source/.claude-plugin/plugin.json" ]
}

@test "the marketplace entry carries the development category (#1159)" {
  run jq -r "$ENTRY | .category" "$MARKETPLACE"
  [ "$status" -eq 0 ]
  [ "$output" = "development" ]
}

@test "the manifest carries the discovery fields the marketplace surface depends on (#1159)" {
  # keywords/license/author ARE the plugin's marketplace surface — how it is
  # found and what a user agrees to — so they are asserted by VALUE: presence
  # alone would accept a wrong licence or an author disagreeing with the
  # marketplace entry. `terraform` is asserted deliberately: the plugin is named
  # for OpenTofu but supports the other dialect, and a consumer searching the
  # word it actually types must find it.
  jq -e '.keywords | index("opentofu")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("terraform")' "$PLUGIN_JSON" >/dev/null
  jq -e '.keywords | index("conftest")' "$PLUGIN_JSON" >/dev/null
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

@test "plugin.json's description pins the load-bearing contract clauses (#1159)" {
  local desc
  desc="$(jq -er '.description' "$PLUGIN_JSON")"
  # the policy path as a GLOB, not a directory: an empty or non-.rego directory
  # must skip exactly like an absent one
  # the charter framing itself: this phrase is the marketplace surface's ONLY
  # statement that the plugin ships mechanism rather than built-in policy (the
  # other two sites say "ships no policies of its own"), so without it the
  # encryption exception reads on an install screen as an unbounded licence
  contains "$desc" "Charter — mechanism only"
  contains "$desc" "policies/conftest/**/*.rego"
  # clause AND its rationale: the README row and ARCHITECTURE both pin the
  # reason, so unpinned here the marketplace surface could assert the policy
  # with the safety justification deleted
  contains "$desc" "Ships no approver agent — a provisioning change can destroy state no rollback recovers, so a human approves"
  # the whole clause, so a rewrite to "is never PRIMARY" cannot satisfy it
  contains "$desc" "can itself be PRIMARY"
  contains "$desc" "Composes ALONGSIDE"
  # the ownership boundary — the expensive-to-get-wrong decision, and the one
  # that distinguishes this plugin from its sibling. marketplace.json's copy is
  # asserted only by equality, so dropping it here silently drops it from the
  # marketplace surface too.
  # the WHOLE deferral, both halves. The language-first half was pinned nowhere
  # in the suite — the ARCHITECTURE needle covers a different sentence in a
  # different file — so a reword could drop it from the marketplace surface with
  # the byte-equality test still green, losing the boundary that keeps this
  # topic plugin out of Dockerfiles and application code.
  contains "$desc" "Defers what the modules deploy INTO a cluster to development-kubernetes, and images and application code to the language plugins (language-first)"
  # the one opinion the plugin holds, stated as a CHECK rather than a policy —
  # without this clause the "no policies of its own" charter reads as absolute
  # and #1160's state_encryption finding looks like a charter violation
  # the WHOLE encryption clause: 'state encryption must be configured' alone is
  # satisfied by a rewrite to '… — the `encryption` block', which is exactly the
  # reading the ARCHITECTURE site forbids with a `lacks`. The marketplace copy is
  # asserted only by equality, so the narrowed form would reach an adopter's
  # install screen with the suite green.
  contains "$desc" "state must be encrypted at rest — checked dialect-aware, not one dialect's block, and binding only where the repo owns state"
  # the file-set boundary and the policy-step-only skip, both pinned at the
  # ARCHITECTURE and plugins.md sites and previously unpinned here — the header's
  # own discipline is that a load-bearing clause is pinned everywhere it is stated
  contains "$desc" "the boundary is the file set, so cluster resources expressed in HCL stay here"
  contains "$desc" "the policy step alone skips when no file matches; the static checks always run"
  # the ownership scope, pinned at this site too — the marketplace surface is
  # where an adopter first reads what the plugin claims to own
  contains "$desc" ".tf/.tf.json sources, module structure, provider and version constraints, backend and state configuration, and .tfvars hygiene"
  # the naming decision, so it is not re-litigated: the name is a
  # recommendation, never a restriction on what the plugin reads
  contains "$desc" "BUSL-licensed Terraform is supported, not endorsed"
  # the slice label must track what actually shipped: v0.1 is the boundary only,
  # so a claim of shipped agents or a dispatcher would overstate it. Pinned
  # POSITIVELY, on the future-tense enumeration every later child must edit —
  # the two `lacks` needles here previously ("adds the four agents", "adds the
  # maintenance dispatcher") were transplanted from the sibling's phrasing,
  # which this description never uses, so neither could fail under any plausible
  # rewrite and the whole slice-label guarantee rested on one `contains`.
  contains "$desc" "This slice adds the maintenance dispatch"
  contains "$desc" "the bootstrap check pipeline (#1162), and the self-contained test fixtures (#1163) follow."
  # every remaining child named, so the manifest cannot silently drop one — the
  # marketplace description is byte-equal, so an omission here reaches users
  local child
  for child in 1160 1161 1162 1163; do
    contains "$desc" "(#$child)"
  done
}

@test "the marketplace description matches plugin.json's exactly (#1159)" {
  # one plugin, one description: the sibling's two copies drifted apart once
  # already (the marketplace copy silently described a narrower capability set),
  # so pin equality rather than a clause subset
  local from_marketplace from_plugin
  from_marketplace="$(jq -er "$ENTRY | .description" "$MARKETPLACE")"
  from_plugin="$(jq -er '.description' "$PLUGIN_JSON")"
  [ "$from_marketplace" = "$from_plugin" ]
}

@test "the plugin's entry set is exactly the manifest and the dispatcher skill (#1160)" {
  # the entry set is the one place a half-applied later child shows up, so each
  # child widens this equality in its own PR (see the note below the assertion).
  # The [ -d "$PLUGIN_DIR" ] guard matters: a mis-derived path makes `ls` fail
  # and the equality below compare two empty strings.
  [ -d "$PLUGIN_DIR" ]
  local entries
  # LC_ALL=C: under a glibc en_US.UTF-8 collation punctuation is ignored at the
  # primary level, so `.claude-plugin` would sort as `claudeplugin` and this
  # equality would flip for a maintainer running the suite in a UTF-8 locale
  entries="$(cd "$PLUGIN_DIR" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
  # #1160 added skills/ (the maintenance dispatcher). #1161 adds agents/, and
  # must widen this equality again in the same PR — that is the point: the entry
  # set is the one place a half-applied later child shows up.
  [ "$entries" = ".claude-plugin skills " ]
  # and the charter's negative half, asserted where it will still be asserted
  # after #1161 fills agents/: no approver agent, ever
  [ ! -e "$PLUGIN_DIR/agents/opentofu-approver.md" ]
}

@test "the README plugin-table row states the slice HONESTLY (#1159)" {
  # the sibling suite's README sweep asserts only that a ROW EXISTS for every
  # marketplace plugin; its content assertions are hard-coded to
  # development-kubernetes. So this row — on the one table most users read — is
  # gated nowhere else, and a later child could land the agents while it still
  # says "only in v0.2", or drop the no-approver clause entirely.
  local row
  row="$(grep -F '| **development-opentofu** |' "$REPO_ROOT/README.md")"
  [ -n "$row" ]
  [ "$(printf '%s\n' "$row" | wc -l | tr -d ' ')" -eq 1 ]
  # the time-bounded claim a later child must retire deliberately
  contains "$row" 'only in v0.2'
  # the charter clause, restated where a user first meets the plugin
  contains "$row" 'no approver agent'
  contains "$row" 'can destroy state no rollback recovers'
  # and the primary capability, whole-clause so "may be *primary*" cannot be
  # satisfied by a negation
  contains "$row" 'may be *primary*'
}

@test "motivation.md says this plugin HAS LANDED, not merely that it is absent from the aspirational list (#1159)" {
  # the sibling suite's sweep is one-directional: it asserts no shipped plugin
  # name appears BEFORE "but not implemented", which deleting the paragraph
  # outright also satisfies. The sibling pins its own positive half for exactly
  # that reason, and this is its opentofu twin — without it, the user-facing
  # page can silently go back to omitting a plugin users can install.
  local motivation para landed
  motivation="$REPO_ROOT/docs/explanation/motivation.md"
  [ -f "$motivation" ]
  para="$(sed -n '/is still aspirational/,/^$/p' "$motivation" | tr -s '[:space:]' ' ')"
  [ -n "$para" ]
  # scoped to the segment AFTER the aspirational clause, so a mention in the
  # not-implemented half cannot satisfy it — that half is what the sibling's
  # sweep forbids, and satisfying this needle from there would be a direct
  # contradiction rather than a pass
  landed="${para#*but not implemented}"
  [ -n "$landed" ]
  [ "$landed" != "$para" ]
  contains "$landed" '`development-opentofu`'
  # then scoped AGAIN, past this plugin's own name. The landing phrase is
  # word-for-word what the KUBERNETES sentence in the same paragraph says, so
  # asserting it against the whole post-aspirational segment proves nothing
  # about this plugin: the opentofu clause could be reworded to "will land" —
  # the exact regression this test exists to catch — and the sibling's sentence
  # would keep the needle green.
  local mine
  mine="${landed#*\`development-opentofu\`}"
  [ -n "$mine" ]
  [ "$mine" != "$landed" ]
  # ONE contiguous needle binding the claim to the issue that landed it, rather
  # than two independent ones. Independent needles are satisfiable from
  # DIFFERENT sentences: the left strip only removes text before this plugin's
  # name, so `mine` still runs to the end of the paragraph, and under a reorder
  # (or an appended third-plugin sentence) a reworded "will land" clause here
  # would take the landing phrase from a neighbouring sentence and the issue
  # link from its own — passing while stating exactly the regression this test
  # documents itself as catching. Contiguity forces both from one sentence.
  contains "$mine" 'has landed its ownership boundary and marketplace registration ([#1159]'
}

@test "ARCHITECTURE.md records the ownership boundary and the disjoint-sibling rule (#1159)" {
  [ -n "$ARCH_SECTION" ]
  # the WHOLE scope clause, not its first half: backend and state configuration
  # is exactly what the plugin's one opinion operates on (a Terraform-dialect
  # repo encrypts at the backend), so a charter narrowed to `.tf` sources would
  # put the state-encryption check's own subject outside the declared boundary —
  # and #1160's gather script is scoped against this section
  contains "$ARCH_FLAT" '`.tf` and `.tf.json` sources, module structure, provider and version constraints, backend and state configuration, and `.tfvars` hygiene'
  contains "$ARCH_FLAT" 'It does **not** own anything the modules deploy *into* a cluster'
  contains "$ARCH_FLAT" 'nor container images, nor application code'
  # the disjointness claim is what makes "a repo holding both runs both
  # pipelines" true; without it the two IaC plugins read as overlapping and a
  # later reader invents coordination neither needs
  # the WHOLE sentence, not just its first clause. The unpinned remainder is
  # where a tense edit shipped ungrammatical prose in the authoritative charter
  # with the suite green — the plugins.md twin was pinned word-for-word and did
  # not break, which is the argument for pinning this one too.
  contains "$ARCH_FLAT" 'own **disjoint file sets**, so a repo holding both **does** detect both topics and runs both **maintenance** pipelines with no coordination between them, now that #1160 has registered the marker'
  # and the maintenance-vs-CI scoping where it is FIRST stated, not only in the
  # collision paragraph 200 lines later
  contains "$ARCH_FLAT" 'The **CI** half is narrower'
  # the TIEBREAK that makes the two clauses above consistent. Without it, "does
  # not own what the modules deploy into a cluster" reads as a resource-kind
  # rule, and a kubernetes_manifest or helm_release in a .tf file is deferred by
  # this plugin's agents while the sibling — which never reads .tf — can never
  # receive it: a privileged pod reviewed by nobody.
  contains "$ARCH_FLAT" 'The boundary is the FILE SET, not the resource kind'
  contains "$ARCH_FLAT" 'they live in a `.tf` file, which the sibling never reads'
  contains "$ARCH_FLAT" 'reviewed by nobody'
  # and the ownership/marker asymmetry, now SETTLED rather than merely recorded:
  # ownership covers .tf.json, the marker globs *.tf only, and #1160 took the
  # "record why" branch of the choice #1159 left it — so a JSON-only module tree
  # is owned but not detected, deliberately. The reason is pinned, not just the
  # outcome: without it a later reader reads the narrow glob as an oversight and
  # widens it across three copies plus #1162's inline twin.
  contains "$ARCH_FLAT" 'the topic MARKER does not — and that is the recorded decision, not an oversight'
  contains "$ARCH_FLAT" 'machine-*generation* target rather than a hand-authored one'
  contains "$ARCH_FLAT" '**owned but not detected**'
  # the cross-link's target must exist, or the boundary points at nothing —
  # ARCHITECTURE.md is outside the mkdocs tree, so nothing else validates it
  contains "$ARCH_FLAT" '(#development-kubernetes-owns)'
  contains "$(cat "$ARCH")" '### `development-kubernetes` owns'
}

@test "ARCHITECTURE.md records the both-dialects scope AND the naming rationale (#1159)" {
  # the story's third acceptance criterion: written down so it is not
  # re-litigated later. Both halves — the precedent that justifies one plugin,
  # and what the name does and does not claim.
  contains "$ARCH_FLAT" 'on the `development-javascript` precedent'
  contains "$ARCH_FLAT" 'BUSL-licensed Terraform is supported, not endorsed'
  # the clause that keeps the name from being read as a restriction
  contains "$ARCH_FLAT" 'the name states a recommendation, never a restriction'
}

@test "ARCHITECTURE.md states the policy convention as a GLOB, not directory presence (#1159)" {
  # directory-presence and glob-match are different contracts: a repo whose
  # policies/conftest/ exists but holds no .rego must not be silently reported
  # as "no policies declared" while a real policy set goes unrun
  contains "$ARCH_FLAT" '`policies/conftest/**/*.rego`'
  contains "$ARCH_FLAT" 'skip condition is **no matching files**'
}

@test "ARCHITECTURE.md scopes the never-fails guarantee to ABSENCE, so violations still fail (#1159)" {
  # read broadly, "it never fails" licenses a policy step that always succeeds,
  # which would make the whole mechanism decorative. The needle spans the
  # condition AND its consequence so neither half can be deleted alone.
  contains "$ARCH_FLAT" 'when policies **are** declared, violations **fail** the step'
  # and the untested-policy finding, which is the same defect one level up: an
  # untested policy matches nothing, so it passes everything
  contains "$ARCH_FLAT" 'an untested policy directory is a finding'
  # the THIRD state, which the sibling closes explicitly and this section did
  # not: a declared set the pinned Conftest cannot evaluate. Conftest silently
  # matches nothing for a policy in a package the step never invokes, so without
  # this clause #1160/#1162 can ship a green check over unenforced policies.
  contains "$ARCH_FLAT" 'CANNOT EVALUATE never skips'
  contains "$ARCH_FLAT" 'no-matching-file is the one and only skip condition'
  contains "$ARCH_FLAT" 'a package outside the namespaces the step invokes'
  # BOTH consumers bound, in the terms each has: #1162's rendered job fails the
  # step, #1160's gather has no step to fail and must emit findings under the
  # configured `policy` key. Stated CI-only, the gather is free to watch Conftest
  # exit 0 having matched nothing and report an empty policy set — the
  # green-over-unenforced state this rule exists to forbid, with
  # opentofu-policy-triage never handed the defect.
  contains "$ARCH_FLAT" '**Both consumers of that rule are bound by it too**'
  contains "$ARCH_FLAT" 'In #1160'"'"'s gather there is no step to fail, so they are **findings**'
  contains "$ARCH_FLAT" '**#1160 pins the Conftest version**'
  # the actionable half, not just the headline: unpinned, the two pins can drift
  # and a policy set evaluates differently in CI than in maintenance
  contains "$ARCH_FLAT" '**hard-codes the same pin**'
  contains "$ARCH_FLAT" 'must be bumped together**'
}

@test "ARCHITECTURE.md exempts policy/policy_tests from the missing_tooling rule (#1159)" {
  # constrains #1160 directly: without this clause the dispatcher follows the
  # family default (build missing_tooling from every tooling_configured false
  # entry) and re-emits the adopt-Conftest-policies recommendation the charter
  # forbids — in the COMMON case, a repo that has simply declined to declare
  # opinions. The sibling states the identical carve-out.
  # both keys named: asserting only `policy` would let a narrowing edit that
  # drops policy_tests pass
  contains "$ARCH_FLAT" 'This plugin exempts `policy` and `policy_tests`'
  contains "$ARCH_FLAT" 'declined to declare opinions'
  # the scoping half. #1160 replaced the old "every OTHER known false entry
  # populates missing_tooling normally" with the rule the shipped dispatcher
  # actually applies — the other five keys are presence detection and cannot
  # legitimately be false, so nothing is left for the family default and
  # missing_tooling is always empty here. The two documents prescribed opposite
  # handling before, and SKILL.md requires them kept in agreement.
  contains "$ARCH_FLAT" 'leaves `missing_tooling` ALWAYS EMPTY on this topic'
  contains "$ARCH_FLAT" '**presence detection, not configuration**'
  contains "$ARCH_FLAT" 'is not "tflint is unconfigured"'
  # and the unknown-key branch, which must stay distinct from the five
  contains "$ARCH_FLAT" 'An **unknown** key arriving `false` is the'
  contains "$ARCH_FLAT" 'face of routing drift and is escalated the same way'
  # the DECLARED-BUT-UNTESTED case, and its SINGLE carrier. Both keys stay out
  # of missing_tooling here too, and the finding travels solely under the
  # configured `policy` key — stated that way round because both alternatives
  # are wrong: routing it through missing_tooling as well emits one defect twice
  # (two issues, two PRs, one fix), and suppressing it in both places reports it
  # nowhere, with `conftest verify` exiting green over a test-less directory so
  # the pipeline is silent too.
  contains "$ARCH_FLAT" 'The declared-but-untested case has exactly ONE carrier, and it is the `policy_tests` key'
  # #1160 corrected this record: the gather sets tooling_configured.policy_tests
  # from policy PRESENCE (true whenever a .rego matches) and emits the defect
  # under findings_by_tool.policy_tests, which is what the dispatcher orders its
  # group by. The old wording named the `policy` key and a false policy_tests,
  # so a model keeping ARCHITECTURE and the gather in agreement would have
  # "fixed" the script and destroyed the ordering-blocking rule.
  contains "$ARCH_FLAT" 'travels **solely under `findings_by_tool.policy_tests`**'
  contains "$ARCH_FLAT" '**mirrors policy presence**'
  contains "$ARCH_FLAT" 'would emit one defect twice'
  contains "$ARCH_FLAT" 'would report it nowhere at all'
  # and the UNKNOWN-key branch the bolded "known" alludes to. Stated only as an
  # emphasis, it tells a dispatcher that unknown keys differ without saying how,
  # leaving the family default (recommend a tool for a drifted key) as the only
  # readable rule — which is what the sibling forbids.
  # the escalation channel is now named in the five-keys paragraph above (which
  # this test pins separately); here the unknown-key branch must still say it is
  # escalated the SAME way and stays out of missing_tooling
  contains "$ARCH_FLAT" 'face of routing drift and is escalated the same way'
  contains "$ARCH_FLAT" 'never listed as missing tooling'
  contains "$ARCH_FLAT" 'escalated via'
  contains "$ARCH_FLAT" '`human_action_required`'
}

@test "ARCHITECTURE.md records the ONE opinion — state encryption — and its scope (#1159)" {
  # this constrains #1160 and #1161 directly: without the exception the charter
  # reads as "no opinions at all" and the state_encryption finding looks like a
  # violation of it; without the scoping the exception reads as licence to add
  # more built-in policy, which is the tflint/trivy duplication the design
  # spec rejected Checkov over.
  contains "$ARCH_FLAT" 'ships **no policies of its own**'
  contains "$ARCH_FLAT" 'first-class check rather than a policy: state encryption'
  # the CARRIER and the routing ruling — a zero-of-one-site clause, pinned
  # nowhere before. A reworded key leaves the gather emitting a name the
  # dispatcher never matches (the finding reaches no agent), and without the
  # ruling the plugin's one opinion could be wired to an auto-fixer that
  # rewrites a consumer's backend configuration unattended.
  contains "$ARCH_FLAT" "the gather's \`state_encryption\` key"
  contains "$ARCH_FLAT" '**never to an auto-fixer**'
  # and the ROUTING TAIL: the positive destination plus the interim escalation.
  # The tail is a clean grammatical deletion (stop at "never to an auto-fixer"),
  # and without it #1160 wires the finding straight at an agent file #1161 has
  # not written yet — so the one opinion this plugin holds surfaces to nobody
  # for the whole #1160 slice, with no human_action_required fallback.
  contains "$ARCH_FLAT" 'routes to an **advisory** agent (→ `opentofu-security-reviewer`)'
  contains "$ARCH_FLAT" 'escalated via `human_action_required` until #1161 lands that agent'
  contains "$ARCH_FLAT" 'the failure is silent and severe'
  # the MECHANISM sentence must state the requirement, not one dialect's
  # artifact. Stated as "checks that an `encryption` block is configured", it
  # contradicts the dialect-aware paragraph directly below it, and an
  # implementer reading top-down builds the block-only check that fires
  # permanently and unfixably on every Terraform-dialect repo.
  contains "$ARCH_FLAT" 'checks that **state encryption is configured — in whichever form the repo'
  lacks "$ARCH_FLAT" 'checks that an `encryption` block is configured'
  contains "$ARCH_FLAT" "belongs to \`tflint\` and \`trivy\`"
  # the DIALECT scoping, without which the one opinion is unsatisfiable in the
  # dialect the same section declares supported: the encryption block is
  # OpenTofu-native and BUSL Terraform rejects it, so an unconditional demand
  # fires permanently on every Terraform repo — including ones whose state IS
  # encrypted — and the only way to clear it would be to break the repo's tool
  contains "$ARCH_FLAT" 'The check is dialect-aware, because the mechanism is not'
  contains "$ARCH_FLAT" 'is the **requirement** — state must be encrypted at rest'
  contains "$ARCH_FLAT" 'neither may narrow the rule to the OpenTofu block alone'
  # BOTH consumers bound, not just #1160: the rendered CI job cannot call this
  # plugin's gather script, so #1162 embeds its own copy of the rule and is just
  # as able to narrow it to the OpenTofu-only block
  contains "$ARCH_FLAT" '**Both consumers of the rule are bound by it**'
  contains "$ARCH_FLAT" "#1162's \`state-encryption\` job must implement the same dialect-aware rule"
  # and the permissive reading made explicit, so "in whichever form the repo's
  # dialect provides" cannot be read as one-form-per-dialect — an OpenTofu repo
  # encrypting at the backend must clear the check too
  contains "$ARCH_FLAT" 'any at-rest form the repo'
  # the NO-STATE branch, bound by the same "both consumers must carry it"
  # sentence as the dialect half above and therefore pinned as tightly. Dropped,
  # both consumers implement an unconditional check that fires permanently and
  # unclearably on every module-library repo — a shape this charter owns and the
  # marker detects.
  contains "$ARCH_FLAT" 'The requirement binds only where the repo owns state'
  # the CI half of the exemption — also zero-of-one-site. "Reports nothing" is
  # gather vocabulary; the obvious CI realisation is a job-level skip, and a
  # SKIPPED job reports no status context, so a REQUIRED `state-encryption`
  # context would sit at `expected` forever and block every PR on exactly the
  # repo shape this charter claims. Rule and consequence, as elsewhere.
  contains "$ARCH_FLAT" 'job **passes**, still reporting'
  contains "$ARCH_FLAT" 'a required context that never reports would sit at `expected`'
  contains "$ARCH_FLAT" '**reusable-module library**'
  # and the DISCRIMINATOR, which is the whole of the branch: keyed on backend
  # absence it would clear a root on the implicit local backend — the plaintext
  # state file this opinion exists to catch
  contains "$ARCH_FLAT" 'keys on module-library shape, never on backend absence alone'
  # the rationale contiguously, not the bare two-word term: the consequence is
  # the half that makes the discriminator arguable, and a short needle is
  # satisfiable by any future mention — including one inside an exempting clause
  contains "$ARCH_FLAT" 'runs on the **implicit local backend** and owns a plaintext `terraform.tfstate`'
  # the section deliberately does NOT write the classifier — it constrains it
  # and delegates. These three invariants are what a later child is held to, and
  # the delegation is what stops this charter over-reaching into #1160's design.
  contains "$ARCH_FLAT" '**#1160 owns the classifier; this section states only what it must satisfy.**'
  contains "$ARCH_FLAT" 'never report a repo whose state **is** encrypted at rest'
  contains "$ARCH_FLAT" 'never clear a repo that owns unencrypted state, including a root on the implicit local backend'
  contains "$ARCH_FLAT" 'resolve every shape the same way in both consumers'
  # the TRANSMISSION PATH and the assertion owner, without which invariant 3 is
  # aspirational: the gather could record its resolution only inside its own
  # script, which the rendered job cannot read, and the two would drift with
  # nothing positioned to notice
  contains "$ARCH_FLAT" 'records the decision it took in this section'
  contains "$ARCH_FLAT" 'not only inside its own script, which the job #1162 renders cannot read'
  contains "$ARCH_FLAT" "#1163's fixtures exercise both embeddings over the same shape set, and asserting that they agree is #1162's to own"
  # and the scoping of invariant 3's gloss — on a language repo no IaC workflow
  # renders at all, so there is no CI verdict to agree with
  contains "$ARCH_FLAT" '**where both run**'
  # the second named finding the epic calls out, and the reason it is not a
  # style note — the IaC equivalent of an irreproducible build
  contains "$ARCH_FLAT" 'An unpinned provider is likewise a finding, not a style note'
  # and WHICH KIND of claim that is: severity, not a second built-in check.
  # Unstated, #1160 must guess between implementing a second check (violating
  # "exactly one exception") and classifying tflint's output (vacuous on a repo
  # with no tflint) — two different gather scripts.
  contains "$ARCH_FLAT" '**severity, not mechanism**'
  contains "$ARCH_FLAT" "\`terraform_required_providers\` rule"
}

@test "ARCHITECTURE.md records the static-now / plan-disabled decision (#1159)" {
  # the seam #1162 must build: the plan job is PRESENT and OFF, so enabling it
  # is a repository-variable change rather than a pipeline redesign. Pinned
  # here because #1162 is reviewed against this section.
  contains "$ARCH_FLAT" 'a repository variable that defaults off'
  contains "$ARCH_FLAT" 'enabling it later is configuration, not a redesign'
  # and the rejected alternative, without which a later contributor "helpfully"
  # adds the source-level destroy heuristic the design spec refused
  contains "$ARCH_FLAT" 'not* a source-level destroy-detection heuristic'
  contains "$ARCH_FLAT" 'trains people to stop checking'
}

@test "ARCHITECTURE.md ENUMERATES the six requirable checks by name (#1159)" {
  # a count word alone is unusable: these six job ids ARE the branch-protection
  # contexts #1162 must require, and a guessed set makes branch-protection.sh
  # demand a context no workflow reports, blocking every merge on the repo it
  # was meant to protect. The sibling enumerates its six for the same reason.
  contains "$ARCH_FLAT" 'the **seven jobs**'
  contains "$ARCH_FLAT" '**credential-free six will be the requirable set**'
  # ONE contiguous needle rather than six independent ones. A per-token loop
  # pins membership only, and two of those tokens occur elsewhere in this
  # section (`policy` in the missing_tooling exemption), so dropping one from
  # the enumeration would stay green — the guessed-set hazard this test exists
  # to prevent. The contiguous form pins membership, ORDER and adjacency at
  # once, and it is bounded at BOTH ends — the leading `in pipeline order:` and
  # the trailing `. Those` — because a tail bound alone is satisfied by a
  # PREPENDED id, which presents seven ids as the requirable six while every
  # count word in the paragraph still reads correctly. That is the sibling's
  # two-ended discipline (`lacks '→ render'` beside `lacks 'config-scan →
  # argocd →'`), which the first draft of this needle transplanted by half.
  contains "$ARCH_FLAT" 'in pipeline order: `fmt`, `validate`, `lint`, `config-scan`, `state-encryption`, `policy`. Those'
  # the seventh, and why it is deliberately NOT requirable — required-and-
  # disabled sits at `expected` forever and blocks every PR
  contains "$ARCH_FLAT" 'The seventh, `plan-policy`'
  contains "$ARCH_FLAT" 'deliberately **not** requirable'
  # and the ownership boundary for the workflow itself: a bootstrap template in
  # `development`, not something this plugin's skills run
  contains "$ARCH_FLAT" 'a *bootstrap* template owned by the generic `development` plugin'
  # the static list must reach the same six, or #1162 cannot derive them from
  # the prose this suite designates as its baseline. `-recursive` is part of the
  # needle: without it `tofu fmt -check` inspects the working directory alone,
  # so a module tree's submodules go unchecked while the job reports green.
  # bounded at the head by the em-dash that introduces it, for the same reason
  # as the job-id list above: an unbounded head lets a seventh tool be prepended
  # while the prose still says six
  contains "$ARCH_FLAT" 'Static analysis — `tofu fmt -check -recursive`, `tofu validate`, `tflint`, `trivy config`, the state-encryption check, and Conftest over HCL —'
  # `-backend=false` is the qualifier the whole credential-free claim rests on,
  # and it was pinned nowhere: dropped, #1162 renders `validate` behind a bare
  # `tofu init`, which initialises the consumer's remote backend — turning one
  # of the six REQUIRABLE contexts credentialed and failing it permanently on
  # every remote-backend repo. Rule and consequence, as with `-recursive`.
  contains "$ARCH_FLAT" 'the credential-free claim holds **only** under that flag'
  contains "$ARCH_FLAT" 'fail permanently on every remote-backend repo'
  # TENSE, pinned in both directions like the sibling's `will emit`/`emits` pair:
  # no such template exists yet, so a landed-tense claim here would describe a
  # file that is not there — and #1162 must flip it deliberately when it lands.
  # The negative needle KEEPS THE EMPHASIS MARKERS: the landed form this section
  # will take is the sibling's `template **emits**`, which a marker-free needle
  # never matches — so the guard would have been unable to fire on the one form
  # it exists to forbid.
  contains "$ARCH_FLAT" '**will emit**'
  lacks "$ARCH_FLAT" 'template **emits**'
  # the whole section is one tense: the static/plan paragraph describes the same
  # unbuilt template, so a landed-tense claim there contradicts the enumeration
  contains "$ARCH_FLAT" 'it **will run** on every pull request'
  contains "$ARCH_FLAT" 'the generated pipeline **will contain** the plan stage'
}

@test "ARCHITECTURE.md records that NEITHER half of the branch-protection contract is wired yet (#1159)" {
  # the enumeration above names branch-protection.sh as the consumer of those six
  # contexts, but that script's IaC path is a BOOLEAN --iac-only resolving to a
  # literal kubernetes context set, and detect-stack.sh's derivation takes a repo
  # declaring `primary: opentofu` OFF that path rather than onto it. Unsaid,
  # #1162 is pointed at a flag that cannot select its set.
  contains "$ARCH_FLAT" 'Neither half of that contract is wired yet, and #1162 owns both'
  contains "$ARCH_FLAT" 'is today a **boolean**'
  contains "$ARCH_FLAT" 'taking a repo **off** that path rather than onto it'
  contains "$ARCH_FLAT" 'a specification for #1162, not a description of a flag that'
  # the PRESCRIPTION half, not just the diagnosis: everything after the colon is
  # the only instruction #1162 has, and the third site is the whole reason the
  # paragraph names three artifacts rather than two. Unpinned, #1162 widens the
  # flag and the derivation and leaves bootstrap's own procedure documenting a
  # boolean kubernetes-only flag that no longer exists.
  contains "$ARCH_FLAT" 'widening `--iac-only` (and the `iac_only` derivation, including the `primary: opentofu` arm) is that story'
  contains "$ARCH_FLAT" 'the §3l / Step 4b prose in `development/skills/bootstrap/SKILL.md`'
  # and BOTH facts it describes must actually hold — the widening has not
  # happened on either side. Read through plain assignments so a failed read
  # propagates under errexit (a command substitution in ARGUMENT position
  # discards its status and yields an empty haystack, which trivially `lacks`
  # everything), and anchor each haystack positively before the negative.
  local bp bp_body ds ds_body
  bp="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  [ -f "$bp" ]
  bp_body="$(cat "$bp")"
  contains "$bp_body" '--iac-only'
  lacks "$bp_body" 'state-encryption'
  # the second half: detect-stack.sh's recorded-primary veto has no opentofu arm
  # yet, which is the ONLY reason the prose's "takes a repo off that path" claim
  # holds. Unpinned, #1162 could add that arm and leave ARCHITECTURE stating the
  # opposite of the code with this suite green.
  ds="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  [ -f "$ds" ]
  ds_body="$(cat "$ds")"
  contains "$ds_body" 'iac_only='
  # #1160 landed `is_opentofu` in this file, so a bare "opentofu appears nowhere"
  # sweep no longer expresses the claim. What the prose still hangs on is
  # narrower and is what is pinned now: `iac_only` is derived from the KUBERNETES
  # marker alone, and the recorded-primary veto has no opentofu arm. #1162 adds
  # both and must retire these two deliberately.
  contains "$ds_body" 'if [[ "$is_kubernetes" == "true" && ${#langs[@]} -eq 0 ]]; then'
  lacks "$ds_body" 'is_opentofu" == "true" && ${#langs[@]}'
  lacks "$ds_body" '"opentofu")'
}

@test "ARCHITECTURE.md records the job-id collision with the sibling, and who owns it (#1159)" {
  # three of the six ids are byte-identical to the kubernetes pipeline's, and a
  # required status context is matched by NAME — so left unrecorded this reads
  # as contradicting the disjoint-file-sets claim in the same section. It is a
  # known, accepted collision: exactly one IaC workflow renders per repo because
  # a dual-marker repo halts, and #1394 owns the slice that must render both.
  contains "$ARCH_FLAT" 'Three of those six ids will collide with the sibling'
  # the three ids NAMED, not just counted — the count word alone can go stale
  # against either enumeration without anything forcing this paragraph to be
  # re-checked, and these three are the intersection a reader must be able to act on
  contains "$ARCH_FLAT" '`lint`, `config-scan` and `policy` are enumerated byte-identically to the shipped kubernetes template'
  contains "$ARCH_FLAT" 'matched by **name**'
  contains "$ARCH_FLAT" 'known, accepted collision'
  # the bound is AT MOST one workflow, not exactly one: a repo with an
  # application language takes neither IaC path, so "exactly" overstates it
  contains "$ARCH_FLAT" '**at most one IaC workflow is rendered per repo**'
  contains "$ARCH_FLAT" 'It is the *maintenance* pipelines that compose freely'
  # the clause that makes the at-most-one argument CHECKABLE, and states a fact
  # about the very derivation #1162 must widen
  contains "$ARCH_FLAT" 'the condition is the **marker**, not merely the absence of a language'
  contains "$ARCH_FLAT" "what #1162's widening must preserve"
  # and the instruction that keeps a later reader from "fixing" it into a
  # contradiction with #1162, which renders the ids exactly as enumerated
  contains "$ARCH_FLAT" 'Do not "fix" any of this by renaming the ids here'
}

@test "ARCHITECTURE.md states the dual-marker halt as SPECIFICATION, not current behaviour (#1159)" {
  # the collision paragraph's safety argument leans on a halt that does not
  # exist: bootstrap keys its IaC path on the kubernetes marker alone, so a
  # zero-language dual-marker repo today renders the SIBLING's workflow. Stated
  # in the present indicative it reads as an invariant #1160/#1162 may rely on —
  # so neither builds it, #1162 ships the colliding ids, and a required
  # lint/config-scan/policy context is satisfied by the wrong pipeline's job.
  contains "$ARCH_FLAT" 'The dual-marker case is a specification, not current behaviour'
  contains "$ARCH_FLAT" 'nothing does that today'
  contains "$ARCH_FLAT" '**#1162 owns adding the halt**'
  contains "$ARCH_FLAT" 'it is an acceptance criterion of that story'
  # the forward pointer too: without it an accepted, known collision is left
  # with no owner anyone can look up, which is how accepted becomes unowned
  contains "$ARCH_FLAT" 'that criterion cites **#1394** — the later slice that must render both workflows'
  contains "$ARCH_FLAT" 'bounded by the absence of an `opentofu` marker rather than by a check'
  # and the fact the paragraph asserts must actually hold: no opentofu marker
  # exists for bootstrap to key on yet
  local skill
  skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  [ -f "$skill" ]
  # scoped to the §3l block ARCHITECTURE's prescription actually names, not a
  # whole-file needle satisfied by any of ~30 `--iac-only` mentions: a refactor
  # moving that contract out of §3l would leave ARCHITECTURE directing #1162 at
  # a site that no longer exists, with the suite green
  local skill_3l
  skill_3l="$(sed -n '/^### 3l\./,/^### /p' "$skill" | tr -s '[:space:]' ' ')"
  [ -n "$skill_3l" ]
  # the POSITIVE wiring clause, not the bare token: §3l states `--iac-only true`
  # in both polarities (its conflict branch says "never emit the workflow or
  # pass `--iac-only true`"), so a bare needle is satisfied by the negated
  # mention alone — the negated-clause hazard this file's header forbids, and it
  # would survive the very relocation this scoped haystack exists to catch.
  contains "$skill_3l" '`branch-protection.sh` with `--iac-only true`'
  # #1160 put opentofu into this file at TWO sites — the detect-stack exit-2
  # contract (either marker can abort the run) and the `is_opentofu` output-key
  # bullet — so the whole-file sweep is replaced by a SCOPED one: §3l is where
  # the IaC wiring lives, and it is §3l that must stay free of an opentofu arm
  # until #1162 generalises it. That keeps the claim ("the branch-protection
  # contract is not wired yet") checkable without forbidding accurate mentions
  # elsewhere.
  run -1 grep -qi 'opentofu' <<<"$skill_3l"
  # both legitimate mentions pinned positively, so neither can be lost — and the
  # second states the reads-it-nowhere-yet fact #1162 must retire deliberately
  # whitespace-normalised: the bullet wraps mid-clause, so a raw-file needle
  # would be pinning the line break rather than the sentence
  local skill_flat
  skill_flat="$(tr -s '[:space:]' ' ' < "$skill")"
  contains "$skill_flat" 'is_opentofu: false'
  contains "$skill_flat" 'Bootstrap reads it nowhere yet'
}

@test "ARCHITECTURE.md records the no-approver rationale AND the auto-merge distinction (#1159)" {
  # conflating no-approval with no-auto-merge either over- or under-delivers,
  # exactly as the sibling section calls out — and the rationale is stated in
  # its sharpest form here, which is the story's own wording
  contains "$ARCH_FLAT" '**No approver agent**'
  contains "$ARCH_FLAT" 'can destroy state that no rollback recovers'
  contains "$ARCH_FLAT" 'not* the same as no auto-merge'
}

@test "ARCHITECTURE.md records the primary claim as LIVE now the marker and gather landed (#1160)" {
  # #1159 asserted the caveat ("stale until the marker lands") to stop the
  # section over-promising, and named #1160 as the child that must retire it.
  # This is that retirement: the topic is in the detected+supported set because
  # the gather script exists and is executable, so the claim is now LIVE and it
  # is the caveat's ABSENCE that this test pins.
  contains "$ARCH_FLAT" 'A repo declaring `primary: opentofu`'
  # the PREDICATE, not just the subject — a needle on the sentence's subject is
  # satisfied by a rewrite to "will NOT select this plugin", which is exactly
  # the negated-clause hazard this file's header forbids, and it would delete
  # the one statement the primary/auxiliary model and #1160 hang on
  contains "$ARCH_FLAT" '**selects this plugin for maintenance dispatch**'
  contains "$ARCH_FLAT" 'since #1160 registered the topic marker and the gather script'
  # the caveat that replaced the stale-declaration one: the maintenance half is
  # live, the CI half is not, and that asymmetry is deliberate rather than a gap
  contains "$ARCH_FLAT" 'no longer treated as stale'
  contains "$ARCH_FLAT" 'the maintenance half is live while the CI half is not'
  # the slice-content claim, the ARCHITECTURE counterpart of the entry-set test
  # above — without it the section can keep describing a slice the manifest and
  # the on-disk tree contradict
  contains "$ARCH_FLAT" '**#1159 landed the boundary; #1160 landed the dispatch.**'
  contains "$ARCH_FLAT" 'the marker in three parity-pinned copies'
  # the caveat that replaces "nothing executable": routing waits on the agents
  contains "$ARCH_FLAT" 'Until #1161 lands, the dispatcher routes nothing'
  contains "$ARCH_FLAT" 'creeps into Dockerfiles, cluster manifests or application code'
  # every remaining child named here too, so ARCHITECTURE and the manifest
  # cannot enumerate different remainders — asserted against the REMAINDER
  # PARAGRAPH, not the whole section: #1160 and #1162 are each cited several
  # times elsewhere in it (the marker-asymmetry and dialect paragraphs, the
  # stale-primary caveat), so a section-wide loop would stay green with either
  # dropped from the enumeration it is meant to gate.
  local rest child
  rest="$(sed -n '/^\*\*#1159 landed the boundary; #1160 landed the dispatch\.\*\*/,/^$/p' "$ARCH" \
            | tr -s '[:space:]' ' ')"
  [ -n "$rest" ]
  # #1160 is still named here — as what LANDED rather than as a remainder — so
  # the loop keeps its full span and the enumeration cannot silently shrink
  for child in 1160 1161 1162 1163; do
    contains "$rest" "#$child"
  done
  # the gather script genuinely DOES exist now, and is executable — the
  # orchestrator partitions on `test -x`, so that is the fact the retired
  # stale-primary caveat turned on. Asserted rather than assumed: prose saying
  # the topic dispatches while the file is missing or non-executable would be
  # the same over-promise #1159's caveat existed to prevent, inverted.
  [ -x "$REPO_ROOT/development/skills/maintenance/scripts/gather-opentofu-findings.zsh" ]
}

@test "the dispatch_mode payload contract names this stale case too (#1159)" {
  # the ownership section and the payload contract must not disagree about what
  # a stale primary does — a model implementing the orchestrator reads the
  # latter. SCOPED to the dispatch_mode paragraph: asserted against the whole
  # file, 'primary: opentofu' is satisfied by the ownership section itself.
  local dm
  dm="$(sed -n '/^\*\*`dispatch_mode`\*\* is/,/^$/p' "$ARCH" | tr -s '[:space:]' ' ')"
  [ -n "$dm" ]
  contains "$dm" '`primary: opentofu` before #1160'
}

@test "the family tree and the category table list this plugin as SHIPPED (#1159)" {
  # the negative half — no shipped plugin left in a "future" list — is swept for
  # every marketplace plugin by tests/kubernetes-plugin-skeleton.bats. This is
  # the positive half it cannot state: that the registries name THIS plugin, in
  # the right list, with the right characterisation.
  local tree_line topic_row
  # the tree is column-aligned, so match the gap as whitespace rather than
  # pinning a literal run of spaces that reflows when a longer name is added.
  # NOTE the deliberate asymmetry with the C4 entry and the Topic row, both of
  # which carry a slice caveat: the family TREE is a caveat-free capability
  # list by convention — the sibling's row reads "may be primary" flat and did
  # so from its own skeleton slice onward — so nothing here is time-bounded and
  # #1160 has no caveat to retire at this site.
  tree_line="$(grep -F 'development-opentofu ' "$ARCH" | head -n1)"
  [ -n "$tree_line" ]
  matches "$tree_line" 'development-opentofu[[:space:]]+← topic: infrastructure-as-code.*may be primary.*'
  contains "$tree_line" 'cloud provisioning'

  topic_row="$(grep -E '^\| \*\*Topic\*\* \|' "$ARCH")"
  [ -n "$topic_row" ]
  [ "$(printf '%s\n' "$topic_row" | wc -l | tr -d ' ')" -eq 1 ]
  contains "$topic_row" 'future:'
  # scoped to the pre-future segment, so a mention in the FUTURE list cannot
  # satisfy it — which is precisely the state this change leaves behind
  contains "${topic_row%%future:*}" '`development-opentofu`'
}

@test "the C4 Container diagram declares this plugin, UNCAVEATED now the dispatch landed (#1160)" {
  # dogfood-c4.bats derives the declared SET and the count words from
  # marketplace.json, so those are already gated. What it cannot state is that
  # the entry says the right thing — and since #1160 the right thing is the
  # UNCAVEATED form: the marker, the gather and the dispatcher have landed, so
  # `primary: opentofu` genuinely dispatches. A REINSTATED caveat is now what
  # would make the diagram the one restatement site contradicting ARCHITECTURE
  # and plugins.md, which is why both retired strings are pinned by absence.
  # (#1159 pinned the opposite direction for exactly the same reason, and named
  # #1160 as the child that must retire them — this is that retirement.)
  local c4
  [ -f "$REPO_ROOT/docs/architecture/c4-container.md" ]
  c4="$(cat "$REPO_ROOT/docs/architecture/c4-container.md")"
  contains "$c4" 'Container(development-opentofu, "development-opentofu", "Claude Code plugin",'
  # #1160 landed the marker, the gather and the dispatcher, so BOTH caveats the
  # skeleton slice carried are retired and their absence is what is pinned now.
  # CLAUDE.md requires docs/architecture/ to be kept true in the same PR as the
  # structural change; a reinstated caveat would make the diagram the one
  # restatement site contradicting ARCHITECTURE and plugins.md.
  contains "$c4" 'Rel(development, development-opentofu, "dispatches")'
  lacks "$c4" 'skeleton, #1159'
  lacks "$c4" 'dispatches (planned, #1160)'
  # inside the TOPIC boundary, not the language one: the two boundaries are what
  # the diagram uses to say which plugins are marker-dispatched. The end address
  # is indent-AGNOSTIC — pinning eight literal spaces would fail OPEN on a
  # reformat of the fenced block (the range would run to EOF and the membership
  # needle would be satisfied by the Container line wherever it sits).
  local topics
  topics="$(sed -n '/Container_Boundary(topics,/,/^[[:space:]]*}/p' \
              "$REPO_ROOT/docs/architecture/c4-container.md")"
  [ -n "$topics" ]
  contains "$topics" 'Container(development-opentofu,'
  # proof the extraction stopped at the boundary rather than running past it.
  # A sed range only ever extends FORWARD, so forbidding a language-boundary
  # container (which sits ABOVE the start address) could never fire — the count
  # is what actually catches over-extension, since losing the closing brace
  # sweeps in the tests runner and every later Container line.
  lacks "$topics" 'System_Ext('
  # a forward-over-extension bound rather than a hardcoded topic count, which
  # would red this test — titled for the opentofu entry — every time an
  # unrelated topic plugin ships. Note what it does and does not catch: the
  # boundaries are NESTED, so losing only the topics `}` terminates the range at
  # the enclosing marketplace `}` one line later, sweeping in a single brace
  # line that satisfies no membership needle (harmless). This backstops the
  # both-braces-lost / de-fenced case, where the runner and everything after it
  # would otherwise be swept in.
  lacks "$topics" 'Container(tests,'
}

@test "the ARCHITECTURE topic-category row lists the plugin UNCAVEATED now the marker landed (#1160)" {
  # the row's "Dispatched when" cell is the topic marker. #1159 caveated this
  # entry ('dispatch lands with #1160') because listing it plainly would have
  # advertised a dispatch the same document said did not exist; #1160 landed the
  # marker, so the caveat is retired and its ABSENCE is what is pinned — a
  # reinstated caveat would understate a topic that now genuinely dispatches.
  local topic_row
  topic_row="$(grep -E '^\| \*\*Topic\*\* \|' "$ARCH")"
  [ -n "$topic_row" ]
  contains "$topic_row" '`development-opentofu`'
  lacks "$topic_row" 'dispatch lands with #1160'
  # and the marker itself now appears in the row's trigger list, beside the
  # sibling's — the cell is what tells a reader when the topic fires
  contains "$topic_row" '.tf files'
}

@test "the plugins.md narrative restates the charter without contradicting ARCHITECTURE (#1159)" {
  # this section is the user-facing statement of the same contract, so it is
  # pinned to the same clause set rather than to a bare heading. Whitespace-
  # normalized so the needles can span the source's line wraps, and delimited by
  # a generic `^## ` so inserting a section between does not widen the haystack.
  local section
  section="$(sed -n '/^## development-opentofu/,/^## /p' "$REPO_ROOT/docs/reference/plugins.md" \
               | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  contains "$section" '`policies/conftest/**/*.rego`'
  contains "$section" 'no approver agent'
  # and its rationale: this page is where an adopter decides whether the missing
  # approver is a gap or a decision, so the reason is the load-bearing half here
  contains "$section" 'can destroy state that no rollback recovers'
  contains "$section" '**no policies of its own**'
  # the whole clause — bare "can also be" is satisfied by "can also be auxiliary"
  contains "$section" 'it can also be **primary**'
  # the never-fails scoping must survive here too, or the published contract
  # reads as decorative while ARCHITECTURE says otherwise
  contains "$section" 'When policies *are* declared, violations fail'
  # the two clauses the ARCHITECTURE tests single out as the expensive ones,
  # pinned at this site as well — the suite's discipline is that a load-bearing
  # clause is pinned at EVERY site that states it, and this page can otherwise
  # drift into a resource-kind boundary or a two-state skip rule while
  # ARCHITECTURE says otherwise, with the suite green
  # the ownership scope enumeration, pinned here as at the other two sites and
  # kept CONTIGUOUS: a two-needle form is satisfiable from two different
  # sentences, and narrowing this page's copy to `.tf` sources would put the
  # state-encryption check's own subject outside the boundary an adopter reads
  contains "$section" '`.tf` / `.tf.json` sources, module structure, provider and version constraints, backend and state configuration, and `.tfvars` hygiene'
  # the untested-policy defect, stated here and pinned only at ARCHITECTURE
  # before — deletable alone, which would leave the published contract implying
  # a test-less policy set is acceptable
  contains "$section" 'an untested policy directory is itself a finding'
  contains "$section" '`conftest verify` **exits green** over a test-less directory'
  contains "$section" 'one defect, one carrier'
  contains "$section" 'The split between the two is the **file set**, not the resource kind'
  contains "$section" 'deferred by this plugin and never reach the sibling'
  # rule AND consequence, matching the ARCHITECTURE twin: the bare phrase alone
  # survives a rewrite that drops the failure consequence
  contains "$section" 'or a failing `conftest verify` run — fails as well'
  contains "$section" 'no-matching-file is the only thing that skips'
  # the dialect-aware encryption REQUIREMENT — the block-only reading is the one
  # that fires permanently and unfixably on every Terraform-dialect repo, so it
  # is pinned here exactly as it is at the ARCHITECTURE site
  contains "$section" 'state is encrypted *at rest*'
  contains "$section" 'the check is dialect-aware'
  # the no-state branch at this site too — rule and consequence, and the
  # discriminator that keeps it from clearing a local-backend root
  contains "$section" 'It also binds only where the repo owns state'
  contains "$section" 'so it has nothing to encrypt and the check reports nothing there'
  contains "$section" 'keys on module-library shape, never on backend absence alone'
  # the unpinned-provider ruling as SEVERITY, not a second built-in check —
  # unpinned here, this page can drift into contradicting the "exactly one
  # exception" charter the same suite pins in ARCHITECTURE
  # contiguous and negation-proof: the bare fragment is still satisfied by a
  # rewrite that inserts a "not" before it
  contains "$section" "a severity ruling on \`tflint\`'s existing rule, not a second built-in check"
  # and the plan stage present-but-disabled: a security-relevant claim about a
  # credentialed job, which could otherwise flip to "runs on every PR" unnoticed
  contains "$section" 'behind a repository variable defaulting off'
  contains "$section" 'enabling it later is configuration, not a redesign'
  # the pipeline's home and TENSE, pinned in both directions like ARCHITECTURE's:
  # the template does not exist, so the present tense here would contradict it
  contains "$section" 'it **will ship** as a bootstrap template'
  # the negative half must match the form the LANDED text will take, and every
  # plausible one carries emphasis (the sibling's landed sentence is pinned as
  # '**bootstrap** template owned by the generic `development` plugin'). So the
  # emphasis is stripped from a copy first and the marker-free form forbidden
  # there — a marker-free needle against the raw section is the same half-inert
  # guard this suite already had to fix at the ARCHITECTURE site.
  local section_plain
  section_plain="${section//\*/}"
  [ -n "$section_plain" ]
  contains "$section_plain" 'it will ship as a bootstrap template'
  lacks "$section_plain" 'it ships as a bootstrap template'
  # the tense of the static/plan paragraph, pinned at this site too — the same
  # unbuilt template must not be described in two tenses on one page
  contains "$section" 'Static analysis needs no credentials and **will run** on every pull request'
  contains "$section" 'the generated pipeline **will contain** that stage'
  # and the CI-vs-maintenance scoping, without which this page tells a user that
  # a both-markers repo gets both check pipelines while ARCHITECTURE says at
  # most one workflow is rendered
  # landed tense since #1160, matching the ARCHITECTURE twin — the two reference
  # documents must not disagree about whether the capability exists
  contains "$section" 'runs both **maintenance** pipelines, now that #1160 has registered the marker'
  contains "$section" 'at most one of them is rendered per repo, which is what makes that safe'
  # the render-both slice, named as still open here. NOTE the asymmetry: the
  # #1394 OWNER is pinned at the ARCHITECTURE site only — this page states the
  # fact without the issue number, so this needle gates the claim, not the
  # pointer.
  contains "$section" 'the slice that renders both (disambiguating those ids) is still open'
  # the state-encryption exception and the naming decision, restated where a
  # user decides what the plugin does
  contains "$section" 'first-class check rather than a policy: **state encryption**'
  contains "$section" 'BUSL-licensed Terraform is **supported, not endorsed**'
  contains "$section" "**What's built (v0.2):**"
  # the remaining-children enumeration, swept here as at the manifest and
  # charter sites — scoped PAST the built-so-far heading because #1160 is cited
  # elsewhere in this section, so an unscoped loop would be satisfied by those
  local built child
  built="${section#*What\'s built (v0.2):}"
  [ -n "$built" ]
  [ "$built" != "$section" ]
  # #1160 has landed, so it is cited in the built-so-far half rather than the
  # remaining-children enumeration; the three still-open children stay swept
  for child in 1161 1162 1163; do
    contains "$built" "issues/$child"
  done
  # the honest caveats. #1160 retired two of them by landing the marker and the
  # dispatch — the "nothing executable yet" claim and the stale-declaration one —
  # and replaced them with the caveat that IS now true: the dispatcher routes
  # nothing until #1161 ships the agents. The pipeline-lands-in-`development`
  # caveat is untouched and still a claim #1162 must retire deliberately.
  contains "$section" 'Until #1161 lands the agents, the dispatcher routes nothing'
  # rule AND consequence, the pairing discipline this file applies everywhere
  # else — the premise alone leaves the user-facing page silent on what the
  # escalation actually buys
  contains "$section" 'naming the agent the group will route to'
  contains "$section" 'it **will ship** as a bootstrap template in the generic `development` plugin'
}

@test "the design spec's SUPERSEDED paragraphs stay banner-covered (#1159)" {
  # the spec is the one artifact a later implementer may read INSTEAD of
  # ARCHITECTURE, and five of its paragraphs now state superseded rules: §2's
  # resource-kind boundary, §4's block-only encryption check (the reading this
  # suite forbids in ARCHITECTURE, because it fires permanently and unfixably on
  # every Terraform-dialect repo), §5's CI-scoped policy-tests reading, §6's
  # `*.tf`-only detection marker, and §8's free-CI-composition claim (at most one
  # IaC workflow renders). Only
  # the banners keep them from misinstructing #1160 and #1162 — and nothing read
  # this file at all until now, so a later "tidy the design doc" edit could drop
  # a banner with the suite green. docs/superpowers/** is in the PR path filter
  # precisely so a spec-only edit triggers this suite.
  local spec spec_flat
  spec="$REPO_ROOT/docs/superpowers/specs/2026-08-02-opentofu-iac-plugin-design.md"
  [ -f "$spec" ]
  # strip the blockquote prefix BEFORE flattening: all five banners are `>` quotes,
  # so a bare `tr` leaves a stray `>` at every line wrap and any needle spanning
  # one silently fails to match — which would look like a missing banner
  spec_flat="$(sed 's/^> \{0,1\}//' "$spec" | tr -s '[:space:]' ' ')"
  [ -n "$spec_flat" ]

  # the superseded sentences are asserted POSITIVELY as still present: the
  # convention is annotate-don't-rewrite, so the pair reads "still recorded AND
  # still banner-covered" rather than licensing a silent rewrite of the record
  # each banner is scoped to FOLLOW the sentence it supersedes, by stripping
  # past that sentence first. Independent needles over the whole flattened file
  # would survive a tidy-up that de-quotes a banner into plain prose or moves it
  # away from its paragraph — and 'Superseded in part by #1159' appears in all
  # five banners, so any one of them satisfies a shared needle.
  local after_enc after_compose after_owns after_tests after_marker
  contains "$spec_flat" 'checks that an `encryption` block is configured'
  after_enc="${spec_flat#*checks that an \`encryption\` block is configured}"
  [ -n "$after_enc" ]
  [ "$after_enc" != "$spec_flat" ]
  # RIGHT-bounded at the next heading as well: a strip that only bounds from
  # above enforces ordering, not adjacency, so relocating a banner into an
  # appendix at the end of the document would keep every needle green while the
  # paragraph it covers reads as unqualified
  after_enc="${after_enc%%## *}"
  [ -n "$after_enc" ]
  contains "$after_enc" 'Superseded in part by #1159'
  contains "$after_enc" "read \`ARCHITECTURE.md\`'s"
  contains "$after_enc" 'in whichever form the repo'
  # the banner's SECOND correction, at the one site whose whole purpose is to
  # stop the superseded paragraph misinstructing #1160 — pinned contiguously so
  # the exemption and its counterexample cannot be split by a rewrite
  contains "$after_enc" 'binds only where the repo **owns** state'
  contains "$after_enc" 'a reusable-module library is exempt, a root on the implicit local backend is not'
  # §8's banner, added for the same reason one slice later
  contains "$spec_flat" 'detects both topics and runs both pipelines'
  after_compose="${spec_flat#*detects both topics and runs both pipelines}"
  [ -n "$after_compose" ]
  [ "$after_compose" != "$spec_flat" ]
  after_compose="${after_compose%%## *}"
  [ -n "$after_compose" ]
  contains "$after_compose" 'Superseded in part by #1159'
  contains "$after_compose" 'authoritative text is `ARCHITECTURE.md`'
  contains "$after_compose" 'It does **not** hold for the bootstrap-rendered **CI** workflows'
  # §2's banner — the third site whose plain reading is the resource-kind rule
  # ARCHITECTURE had to add the file-set tiebreak for, and whose consequence
  # this suite pins at two other sites as "reviewed by nobody"
  contains "$spec_flat" 'anything the modules deploy *into* a cluster'
  after_owns="${spec_flat#*anything the modules deploy \*into\* a cluster}"
  [ -n "$after_owns" ]
  [ "$after_owns" != "$spec_flat" ]
  after_owns="${after_owns%%## *}"
  [ -n "$after_owns" ]
  contains "$after_owns" 'Superseded in part by #1159'
  contains "$after_owns" 'The boundary is the **file set**'
  # and the fourth banner, over the policy-tests paragraph whose CI-scoped
  # reading would have #1162 fail a consumer's build on a state the charter
  # routes to the maintenance gather
  contains "$spec_flat" 'An untested policy directory is a finding'
  after_tests="${spec_flat#*An untested policy directory is a finding}"
  [ -n "$after_tests" ]
  [ "$after_tests" != "$spec_flat" ]
  after_tests="${after_tests%%## *}"
  [ -n "$after_tests" ]
  contains "$after_tests" 'the rendered pipeline is **silent** on that state'
  contains "$after_tests" 'one defect, one carrier'
  # the verify leg bounded, so the banner cannot be read as "the job fails ONLY
  # on a failing verify run" — violations and the cannot-evaluate states fail it
  # too, which the sibling paragraphs state and this one must not contradict
  contains "$after_tests" 'this bounds the verify leg, not the job'
  # the LABEL inside the bounded segment too, as the other scopes do — the raw
  # count proves five openers exist somewhere, not that this one adjoins this
  # paragraph
  contains "$after_tests" 'Superseded in part by #1159'
  # and the fifth banner, over §6's detection-marker sentence. It is the one
  # paragraph that describes #1160's OWN work, so an implementer reading the
  # spec instead of the charter resolves the `.tf.json` asymmetry by omission —
  # shipping the narrow marker as settled and recording nothing, which is
  # exactly what the banner forbids. Scoped like the other four rather than
  # left to the raw count, which proves five openers exist SOMEWHERE.
  contains "$spec_flat" 'presence of `*.tf` files'
  after_marker="${spec_flat#*presence of \`\*.tf\` files}"
  [ -n "$after_marker" ]
  [ "$after_marker" != "$spec_flat" ]
  after_marker="${after_marker%%## *}"
  [ -n "$after_marker" ]
  contains "$after_marker" 'Superseded in part by #1159'
  # the OBLIGATION, contiguously — a banner that merely notes the asymmetry
  # without binding #1160 to act leaves the omission licensed
  contains "$after_marker" 'widen the glob to match the ownership statement or record why the JSON syntax is out of scope'
  # ...and the OUTCOME, so the banner cannot keep posing a decision #1160 made:
  # a later implementer reading the spec instead of the charter would otherwise
  # treat the narrow glob as unsettled and widen it
  contains "$after_marker" 'took the second branch'
  contains "$after_marker" 'owned but not detected'
  contains "$after_marker" 'nothing downstream may assume the narrower reading here was deliberate'
  # the QUOTING itself, asserted on the raw text: the blockquote prefix is
  # stripped before flattening, so a banner de-quoted into plain prose would
  # flatten identically and satisfy every needle above
  # COUNTED, not merely present: all five banners open with the same raw line,
  # so a presence needle is satisfied by any one of them and de-quoting a single
  # banner would stay green — the very hole this raw check exists to close.
  [ "$(grep -c '^> \*\*Superseded in part by #1159' "$spec")" -eq 5 ]
}

@test "the orchestrator's topic-plugin dispatch list now NAMES this plugin (#1160)" {
  # #1159 pinned this row's OMISSION and predicted exactly this flip: "when
  # #1160 registers the marker the row could silently stay stale while the
  # orchestrator dispatches a plugin the list does not name." The marker landed,
  # so the guard is inverted rather than deleted — the row is on the page README
  # advertises as the full inventory, and a topic that dispatches but is absent
  # from it is invisible to every reader who trusts that page.
  local maint_row
  maint_row="$(grep -F '| Maintenance | `/development:maintenance' "$REPO_ROOT/docs/reference/plugins.md")"
  [ -n "$maint_row" ]
  [ "$(printf '%s\n' "$maint_row" | wc -l | tr -d ' ')" -eq 1 ]
  # the positive anchor keeps the negative from going vacuous on a mis-derived row
  # no trailing paren: that would additionally pin the sibling as the LAST entry
  # in the orchestrator's topic list, reding this opentofu-titled test whenever
  # an unrelated topic plugin is appended. The name occurs once in the row, so
  # the anchor stays non-vacuous without encoding list order.
  contains "$maint_row" '`development-kubernetes`'
  contains "$maint_row" '`development-opentofu`'
}

@test "the plugin is registered with the docs generator, which now emits its command but no agents (#1160)" {
  # PLUGINS is hardcoded, so an unregistered plugin is SILENTLY skipped: the
  # generator never scans it, --check compares two equally incomplete files, and
  # the drift gate passes while the reference pages omit the plugin entirely.
  # The all-plugins sweep lives in the sibling suite; what is asserted here is
  # the pair of facts that only hold at THIS slice — registered, and emitting
  # its maintenance COMMAND (#1160 landed the skill) while the agents page must
  # stay empty until #1161 ships them. Each half flips with its own child.
  local gen block commands agents
  gen="$REPO_ROOT/scripts/generate-docs-reference.py"
  [ -f "$gen" ]
  block="$(sed -n '/^PLUGINS = \[/,/^\]/p' "$gen")"
  [ -n "$block" ]
  contains "$block" '"development-opentofu"'

  [ -f "$REPO_ROOT/docs/reference/commands.md" ]
  [ -f "$REPO_ROOT/docs/reference/agents.md" ]
  commands="$(cat "$REPO_ROOT/docs/reference/commands.md")"
  agents="$(cat "$REPO_ROOT/docs/reference/agents.md")"
  # prove the haystacks are the real generated pages before asserting absence —
  # otherwise a mis-derived path makes both `lacks` trivially true
  contains "$commands" '## development-kubernetes'
  contains "$agents" '## development-kubernetes'
  # #1160 landed the dispatcher skill, so the COMMANDS page now carries it; the
  # agents page still must not, until #1161. Each half is asserted separately so
  # the flip is one child at a time rather than a single blanket expectation.
  contains "$commands" '## development-opentofu'
  contains "$commands" '/development-opentofu:maintenance'
  lacks "$agents" '## development-opentofu'
  # and prove that is what the generator WOULD emit, not merely what is committed
  run python3 "$gen" --check
  [ "$status" -eq 0 ]
}

@test "the bats suite's PR path filter covers this plugin's tree (#1159)" {
  # asserted in LIST-ENTRY form, so commenting the entry out while leaving the
  # rationale prose behind reds instead of passing. 'development/**' does NOT
  # match 'development-opentofu/**' — GitHub path filters are literal — which is
  # the same hazard every per-plugin line in that file records.
  # driven off the full list of trees THIS suite reads, the sibling's
  # convention, so pruning any of them later reds here rather than silently
  # ungating a check at PR time
  local paths p
  paths="$(sed -n '/^  pull_request:/,/^  push:/p' "$REPO_ROOT/.github/workflows/script-tests.yml")"
  [ -n "$paths" ]
  for p in 'development-opentofu/**' 'development/skills/**/SKILL.md' \
           'development/skills/**/scripts/**' 'docs/superpowers/**' \
           'docs/reference/**' 'docs/architecture/**' 'docs/explanation/**' \
           'ARCHITECTURE.md' 'README.md' 'scripts/**' 'tests/**' \
           '.claude-plugin/marketplace.json' '.github/workflows/script-tests.yml'; do
    contains "$paths" "      - '$p'"
  done
}
