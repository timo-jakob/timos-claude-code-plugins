#!/usr/bin/env bats
#
# Wiring tests for the `resilience` review dimension (#966, epic #964).
#
# The dimension is prose — a `*-resilience-reviewer.md` agent per SERVICE
# language plus a row in that language's review panel — so nothing executable
# enforces it. What can drift, and what these tests pin:
#
#   1. the agent file exists, and its frontmatter `name` matches its filename
#      (the panel launches it by name as `subagent_type`, so a mismatch is a
#      dispatch that silently finds nothing);
#   2. the panel's dimension TABLE lists it against dimension `resilience`;
#   3. the panel's "Launch all N agents" count AGREES WITH THE TABLE — derived
#      from the row count, never hardcoded here, so adding a seventh dimension
#      to Go without renumbering its prose fails this file rather than shipping
#      a panel that launches five of six agents;
#   4. every reviewer covers all four defect classes #966 names, and bounds
#      severity (the review loop only converges because severity is anchored to
#      dependency-failure impact rather than style);
#   5. the deliberate ABSENCE from development-claude-plugin — a plugin repo
#      makes no outbound dependency calls, and an absence nobody asserts is
#      indistinguishable from an omission.
#
# Structural/grep-based and offline, like ops-api-fragment.bats: the agents'
# behaviour is exercised by running a real review, not from here.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Every SERVICE language that owns a review panel. development-claude-plugin
  # is deliberately excluded — see the absence test at the bottom.
  SERVICE_PLUGINS=(development-go development-java development-python development-swift)
}

# agent_file <plugin> — the resilience reviewer's path in that plugin.
agent_file() {
  local plugin="$1" lang="${1#development-}"
  printf '%s/%s/agents/%s-resilience-reviewer.md' "$REPO_ROOT" "$plugin" "$lang"
}

# panel_file <plugin> — that plugin's review SKILL.md.
panel_file() { printf '%s/%s/skills/review/SKILL.md' "$REPO_ROOT" "$1"; }

# table_rows <plugin> — how many agent rows the panel's dimension table has.
# Counts pipe-delimited rows after the header/separator, which is what the
# "launch all N agents" prose must agree with. The separator rule accepts an
# alignment colon (`| :--- |`) so a formatter reflow can't be miscounted as a
# data row, which would look like a phantom renumbering bug.
table_rows() {
  awk '/^\| *Agent *\| *Model *\| *Dimension *\|/ { f = 1; next }
       f && /^\| *:?-+/ { next }
       f && /^\|/ { n++; next }
       f && !/^\|/ { exit }
       END { print n + 0 }' "$(panel_file "$1")"
}

# word_for <n> — the English word a panel spells its dimension count with.
# Derived, not hardcoded, so the word forms track the table like the digits do.
word_for() {
  case "$1" in
    5) printf five ;; 6) printf six ;; 7) printf seven ;; 8) printf eight ;;
    *) printf 'UNMAPPED-%s' "$1" ;;
  esac
}

# ---- 1. the agent files exist and are self-consistent ----------------------

@test "every service plugin ships a resilience reviewer agent" {
  local p
  for p in "${SERVICE_PLUGINS[@]}"; do
    [ -f "$(agent_file "$p")" ]
  done
}

@test "each reviewer's frontmatter name matches its filename EXACTLY" {
  # Go/Java/Python launch the agent by this name as subagent_type, so a mismatch
  # dispatches to nothing. Equality, not substring: `…-reviewer-v2` is just as
  # much a dispatch miss as a typo. All four panels dispatch by name (see the
  # dispatch-convention test below), so this holds for every one of them.
  local p f expected
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(agent_file "$p")"
    expected="${p#development-}-resilience-reviewer"
    [ "$(sed -n 's/^name: //p' "$f" | head -1)" = "$expected" ]
  done
}

@test "each reviewer declares model and read-only tools" {
  # EQUALITY, not substring: the contract is an UPPER bound on capability. A
  # reviewer that gained `Edit` could 'fix' rather than report — which the
  # loop's fix pass owns — and `contains` would have happily passed it.
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(agent_file "$p")"
    [ "$(sed -n 's/^model: //p' "$f" | head -1)" = "opus" ]
    [ "$(sed -n 's/^tools: //p' "$f" | head -1)" = "Read, Grep, Glob" ]
  done
}

@test "every panel dispatches by AGENT NAME, not general-purpose" {
  # A general-purpose dispatch attaches no agent definition, so the launch
  # prompt's "following your instructions" binds to nothing and the dimension
  # runs on improvised instructions with the Model column as fiction. Swift did
  # exactly that until #966; all four are now aligned, and this pins it so a
  # regression is a visible decision rather than a silent capability loss.
  local p
  for p in "${SERVICE_PLUGINS[@]}"; do
    contains "$(cat "$(panel_file "$p")")" 'use its name as the `subagent_type`'
    lacks "$(cat "$(panel_file "$p")")" 'use `subagent_type: general-purpose`'
  done
}

@test "each reviewer's description names the resilience dimension and its panel" {
  local p f desc
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(agent_file "$p")"
    desc="$(sed -n 's/^description: //p' "$f")"
    contains "$desc" "resilience dimension"
    contains "$desc" "/${p}:review"
  done
}

# ---- 2 + 3. the panel lists it, and the counts agree ------------------------

@test "each review panel's table lists the reviewer against dimension resilience" {
  # The DIMENSION CELL is what the panel substitutes for {DIMENSION} in the #558
  # finding schema, so a wrong value buckets findings under a dimension nothing
  # downstream knows. Asserting bare "resilience" against the row would be
  # vacuous — the agent's own NAME contains it.
  local p row
  for p in "${SERVICE_PLUGINS[@]}"; do
    row="$(grep -E "^\| ${p#development-}-resilience-reviewer \|" "$(panel_file "$p")")"
    contains "$row" "| opus | resilience |"
  done
}

@test "each panel's launch count agrees with its own dimension table" {
  # Derived from the table, never hardcoded: adding a dimension without
  # renumbering the prose leaves the panel launching fewer agents than it lists.
  # Numeric -eq, not `contains … "1"` — the latter also accepts 10, 11, 21.
  local p n
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    matches "$n" '^[1-9][0-9]*$'
    [ "$(grep -c "Launch All ${n} Review Agents in Parallel" "$(panel_file "$p")")" -eq 1 ]
    [ "$(grep -c "spawn all ${n} agents below" "$(panel_file "$p")")" -eq 1 ]
    [ "$(grep -c "Launch these ${n} agents in one message" "$(panel_file "$p")")" -eq 1 ]
    [ "$(grep -c "Wait for all ${n} background agents" "$(panel_file "$p")")" -eq 1 ]
  done
}

@test "each panel's frontmatter description agrees with its table count too" {
  local p n
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    matches "$n" '^[1-9][0-9]*$'
    contains "$(sed -n 's/^description: //p' "$(panel_file "$p")")" "${n} specialized parallel agents"
  done
}

@test "no panel carries a count-bearing phrase with the WRONG number" {
  # Derived rather than pinned to the previous counts (5/6), so this keeps
  # guarding after the next dimension lands. Every count-bearing phrasing the
  # positive test asserts is swept — including "Wait for all N background
  # agents", which none of `all N agents` / `these N agents` matches.
  local p n stale
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    # Guard n FIRST: an empty n would make the filter below match everything,
    # so `stale` would be empty and the test would pass having checked nothing.
    matches "$n" '^[1-9][0-9]*$'
    stale="$(grep -oE "(all|these) [0-9]+ (background )?agents|All [0-9]+ Review|[0-9]+ specialized" \
               "$(panel_file "$p")" | grep -vE "(^|[^0-9])${n}([^0-9]|$)" || true)"
    [ -z "$stale" ]
  done
}

@test "each panel's WORD-form dimension count tracks its table too" {
  # The Go panel spells its counts out ("all six dimensions completed"); a
  # digit-only guard would let the word forms drift on the next renumber.
  local p n word prev wrong
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    word="$(word_for "$n")"
    lacks "$word" "UNMAPPED"
    # Whatever word-form dimension counts a panel carries must ALL be this one.
    # A panel carrying none is fine (only Go spells them out today).
    wrong="$(grep -oE "all (four|five|six|seven|eight) dimensions" "$(panel_file "$p")" \
             | grep -v "all ${word} dimensions" || true)"
    [ -z "$wrong" ]
    # The HYPHENATED form too ("a five-dimension array ... a clean six-dimension
    # review"): the partial-round rationale names n-1 and n, and nothing else.
    prev="$(word_for $((n - 1)))"
    lacks "$prev" "UNMAPPED"
    wrong="$(grep -oE "(four|five|six|seven|eight)-dimension" "$(panel_file "$p")" \
             | grep -vE "^(${word}|${prev})-dimension" || true)"
    [ -z "$wrong" ]
    # Membership in {n-1, n} is only half the contract: a partial renumber that
    # left the n-referring phrase at the OLD n (now n-1) has every occurrence
    # equal to prev and would slip through. So when any hyphenated count exists,
    # the n-form must be among them.
    if grep -qE "(four|five|six|seven|eight)-dimension" "$(panel_file "$p")"; then
      grep -q "${word}-dimension" "$(panel_file "$p")"
    fi
  done
}

@test "each panel's Areas-reviewed line names the resilience dimension" {
  # The synthesis template names the dimensions in every emitted report; a
  # panel that launches the reviewer but reports five areas under-reports it.
  local p
  for p in "${SERVICE_PLUGINS[@]}"; do
    contains "$(grep 'Areas reviewed' "$(panel_file "$p")")" "Resilience"
  done
}

# ---- 4. the four defect classes + bounded severity --------------------------

@test "every reviewer covers all four #966 defect classes" {
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    contains "$f" "Missing timeout"
    contains "$f" "Missing circuit breaker"
    contains "$f" "Unbounded or un-backed-off retry"
    contains "$f" "Hard/soft misdeclaration"
  done
}

@test "every reviewer states the six mandates it checks against" {
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    # The rendered numbered form — a bare "Timeout" also matches
    # context.WithTimeout / connectTimeout elsewhere in every file.
    contains "$f" "1. **Timeout**"
    contains "$f" "Circuit breaker"
    contains "$f" "Bounded retry + jittered backoff"
    contains "$f" "Registered fallback"
    contains "$f" "Background reconnect"
    contains "$f" "Stay stable"
  done
}

@test "every reviewer bounds severity to dependency-failure impact" {
  # The convergence guard: severity anchored to what happens when the dependency
  # dies, not to style, and scoped to the diff.
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    contains "$f" "Severity guide"
    contains "$f" "what happens when the dependency dies"
    contains "$f" "the diff actually touches"
    # The reporting HEADER, not just the guide: consolidate-findings maps any
    # severity outside CRITICAL/WARNING to Low, and Low never blocks. A reviewer
    # that drifted to HIGH/MEDIUM/LOW would keep every other assertion here green
    # while its findings became permanently non-blocking.
    contains "$f" "### [CRITICAL|WARNING|SUGGESTION] Title"
    contains "$f" "**File:**"
  done
}

@test "no reviewer mandates what a fallback returns" {
  # The policy enforces that a fallback is WIRED, never its business logic.
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    contains "$f" "not what it returns"
  done
}

@test "every reviewer forbids transitive dependency health" {
  # The cascading health-check-storm anti-pattern the ops-api contract bans.
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    contains "$f" "one hop"
  done
}

@test "each reviewer carries its language's own hang/crash shapes" {
  # A generic reviewer would miss the failure mode that actually bites each
  # runtime. Needles are unique to the hang/crash SECTION — a bare "goroutine"
  # would pass on a generic Go reviewer with that section deleted.
  contains "$(cat "$(agent_file development-python)")" "blocks the whole event loop"
  contains "$(cat "$(agent_file development-java)")" "thread-pool exhaustion"
  contains "$(cat "$(agent_file development-swift)")" "fatalError()"
  contains "$(cat "$(agent_file development-go)")" "unbounded goroutine growth"
}

@test "every reviewer states the runtime defaults it must not misreport" {
  # Each language has a default that a reviewer asserting "no timeout" would get
  # factually wrong; these were live errors caught in review, so they are pinned.
  contains "$(cat "$(agent_file development-python)")" "ClientTimeout(total=300)"
  contains "$(cat "$(agent_file development-java)")" "maxAttempts = 3"
  contains "$(cat "$(agent_file development-swift)")" "7 days"
  # Go's equivalent guard: the broker defaults paragraph is the only thing
  # stopping it emitting a confidently-wrong CRITICAL on a default-constructed
  # client. Needle is unique to the guard, not to a vendor name.
  contains "$(cat "$(agent_file development-go)")" "Do NOT report a default-constructed client as unbounded"
}

@test "every reviewer carries the liveness/readiness misuse rule" {
  # Language-independent (ARCHITECTURE.md: liveness is never a function of a
  # dependency), so all four must flag it — Go originally did not.
  local p f
  for p in "${SERVICE_PLUGINS[@]}"; do
    f="$(cat "$(agent_file "$p")")"
    contains "$f" "liveness is process-only"
    contains "$f" "restart-storm anti-pattern"
  done
}

# ---- 5. the deliberate absence ---------------------------------------------

@test "development-claude-plugin has NO resilience dimension" {
  # A plugin repo makes no outbound dependency calls; adding the dimension there
  # would produce findings nothing can act on. Asserted so the absence reads as
  # a decision rather than an oversight.
  # Positive control FIRST: without it, a renamed plugin or moved agents/ dir
  # would satisfy the absence check for the wrong reason.
  [ -f "$REPO_ROOT/development-claude-plugin/agents/claude-plugin-test-reviewer.md" ]
  # Any *resilience* agent under any name, not one exact filename.
  [ -z "$(ls "$REPO_ROOT"/development-claude-plugin/agents/*resilience* 2>/dev/null)" ]
  run -1 grep -q "resilience" "$REPO_ROOT/development-claude-plugin/skills/review/SKILL.md"
}

# ---- the generated + hand-written reference pages ---------------------------

@test "docs/reference/plugins.md lists every panel's resilience reviewer" {
  # The hand-written reference is part of this contract: a panel that ships the
  # agent while the reference documents the old inventory is drift users see.
  local p
  for p in "${SERVICE_PLUGINS[@]}"; do
    # NB: the backticks are ESCAPED — unescaped they are command substitution,
    # not a regex literal. The Go table backticks its agent names; the other
    # three don't, so both spellings are accepted.
    grep -qE "^\| \`?${p#development-}-resilience-reviewer\`? \|" "$REPO_ROOT/docs/reference/plugins.md"
  done
}

@test "docs/reference/plugins.md's review rows carry each panel's real count" {
  # Derived from the panel table, so this tracks the next dimension too.
  local p n row
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    matches "$n" '^[1-9][0-9]*$'
    row="$(grep -E "^\| Review( panel)? \| \`/${p}:review" "$REPO_ROOT/docs/reference/plugins.md")"
    # Anchored to the count's own phrase. A bare "${n} " substring would be
    # satisfied by the Swift row's "Swift 6 compliance", or by a drifted "16 ".
    matches "$row" "(Spawns|with) ${n} "
  done
}

@test "the generated reference pages are not stale" {
  # .github/workflows/reference-drift.yml runs this on every touched agent or
  # SKILL.md; running it here means the gate fails locally, not in CI.
  run python3 "$REPO_ROOT/scripts/generate-docs-reference.py" --check
  [ "$status" -eq 0 ]
}

# ---- ARCHITECTURE.md ---------------------------------------------------------

@test "ARCHITECTURE.md documents the resilience dimension in the enum" {
  # Scoped to the enum paragraph: `resilience` and `*-resilience-reviewer` also
  # appear in the resilience-policy section, so a whole-file haystack would stay
  # green even if this paragraph were deleted.
  local arch_enum
  arch_enum="$(sed -n '/^\*\*Dimension enum\.\*\*/,/^$/p' "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch_enum" '`resilience`'
  contains "$arch_enum" '`*-resilience-reviewer`'
  # Derived: a hardcoded "seven" would PASS while ARCHITECTURE.md went stale and
  # fail only once someone corrected it — a drift guard pointing backwards.
  local swift_word
  swift_word="$(word_for "$(table_rows development-swift)")"
  lacks "$swift_word" "UNMAPPED"
  contains "$arch_enum" "${swift_word} Swift dimensions"
  # The deliberate exclusion, in wording unique to the decision.
  contains "$arch_enum" 'deliberately absent from `development-claude-plugin`'
}

@test "ARCHITECTURE.md records BOTH downstream gaps, not an automatic-pickup claim" {
  # An earlier draft claimed a new dimension flows downstream automatically. Two
  # surfaces don't: build-dossier drops a CLEAN non-core dimension (#1148), and
  # the Approver neither labels nor looks through one (#1147). Claiming
  # otherwise sends a reader looking for wiring that isn't there.
  local arch
  arch="$(cat "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$arch" 'neither labels nor looks through the `resilience` lens'
  contains "$arch" "#1147"
  # ...and the sibling gap: a CLEAN non-core dimension is absent from the dossier.
  contains "$arch" "only when it reports"
  contains "$arch" "#1148"
}

# ---- the count-bearing surfaces OUTSIDE the panel ---------------------------

@test "the Go manifests' panel count tracks the table (and both stay identical)" {
  # plugin.json and marketplace.json are the installer- and marketplace-facing
  # text. check-marketplace-sync pins their VERSIONS in lockstep, not their
  # descriptions, so a stale agent count here is invisible to every other guard.
  local n a b
  n="$(table_rows development-go)"
  matches "$n" '^[1-9][0-9]*$'
  a="$(jq -r '.description' "$REPO_ROOT/development-go/.claude-plugin/plugin.json")"
  b="$(jq -r '.plugins[] | select(.name=="development-go") | .description' \
        "$REPO_ROOT/.claude-plugin/marketplace.json")"
  [ "$a" = "$b" ]
  contains "$a" "runs ${n} specialist agents"
}

@test "the manifests do NOT conflate the panel count with the Approver's lens count" {
  # The Approver walks FIVE lenses and cannot represent `resilience` at all
  # (#1147). Bumping the panel to 6 must not sweep that clause along with it —
  # this test exists because exactly that over-replacement happened once.
  local a
  a="$(jq -r '.description' "$REPO_ROOT/development-go/.claude-plugin/plugin.json")"
  contains "$a" "5 review dimensions the Approver walks"
  contains "$a" "#1147"
  # ...and the agents it describes really do still say five.
  contains "$(cat "$REPO_ROOT/development-go/agents/go-approver.md")" "five lenses"
}

@test "docs/reference/plugins.md's Go word-form count tracks the table too" {
  local n word wrong
  n="$(table_rows development-go)"
  word="$(word_for "$n")"
  lacks "$word" "UNMAPPED"
  wrong="$(grep -oE "(four|five|six|seven|eight) specialists" "$REPO_ROOT/docs/reference/plugins.md" \
           | grep -v "${word} specialists" || true)"
  [ -z "$wrong" ]
}

# ---- the two documented downstream gaps, pinned BEHAVIOURALLY ---------------

@test "the #1147 gap is real: Approvers still pin the closed enum and five lenses" {
  # ARCHITECTURE.md asserts this gap. Asserting only that the SENTENCE exists
  # would let the doc keep claiming a gap after #1147 closed it. This pins the
  # gap itself, so the doc and the tree fall out of sync loudly.
  # When #1147 lands, this test flips (and ARCHITECTURE's bullet comes out).
  local p f
  for p in development-go development-java development-python development-swift; do
    f="$(cat "$REPO_ROOT/$p/agents/${p#development-}-approver.md")"
    contains "$f" '"dimension": "bugs | security | performance | code_quality | tests | null"'
    lacks "$f" '"dimension": "bugs | security | performance | code_quality | tests | resilience'
    contains "$f" "five lenses"
  done
  contains "$(cat "$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl")" \
    '"dimension": "bugs | security | performance | code_quality | tests | null"'
}

# ---- this suite's own CI trigger -------------------------------------------

@test "script-tests.yml's PR filter covers every tree this suite asserts on" {
  # The suite reads four language plugins plus two docs. GitHub path filters are
  # NOT implicitly **-prefixed, so 'development/**' does not match
  # 'development-swift/**'. Without these entries a PR that renumbers Swift's
  # panel matches no filter and the suite never runs at PR time — it reds only
  # the unfiltered push-to-main run, which is what the filter exists to prevent.
  local wf paths path
  wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  [ -f "$wf" ]
  # Scope to the pull_request paths BLOCK. A whole-file grep would be satisfied
  # by the explanatory comment that names 'development-go/**' in prose, so
  # deleting the real entry would leave this test green.
  paths="$(awk '/^  pull_request:/ {p=1} p && /^    paths:/ {f=1; next}
                f && /^  [a-z]/ {exit} f' "$wf")"
  contains "$paths" "development-go"
  for path in 'development-go/**' 'development-java/**' 'development-python/**' \
              'development-swift/**' 'docs/reference/plugins.md' 'ARCHITECTURE.md' \
              '.claude-plugin/marketplace.json' 'development/skills/bootstrap/templates/**'; do
    grep -qxF "      - '$path'" <<< "$paths"
  done
}

@test "the approver agents' panel-count prose is derived, and its lens half is pinned" {
  # Round 6 added "of the panel's six/seven" to the approver agents to separate
  # the panel's dimension count from the five lenses the Approver actually walks.
  # Both numbers need guarding: the panel half against the next dimension landing
  # (it also feeds the generated docs/reference/agents.md, where --check only
  # proves the page matches the frontmatter — a wrong frontmatter regenerates
  # cleanly), and the lens half against the same 5→6 over-replacement that once
  # slipped into the Go manifests.
  local p f word wrong
  for p in development-go development-swift; do
    word="$(word_for "$(table_rows "$p")")"
    lacks "$word" "UNMAPPED"
    f="$(cat "$REPO_ROOT/$p/agents/${p#development-}-approver.md")"
    contains "$f" "of the panel's ${word}"
    # ...and no OTHER count hiding behind the correct one.
    wrong="$(grep -oE "of the panel's (four|five|six|seven|eight)" \
               "$REPO_ROOT/$p/agents/${p#development-}-approver.md" \
             | grep -v "of the panel's ${word}" || true)"
    [ -z "$wrong" ]
    # The lens half stays five until #1147. Pin the FRONTMATTER positively (the
    # body's "five lenses" needle does not stand in for it), then sweep the WHOLE
    # file: the body spells it without "review" ("five dimensions the Approver
    # walks"), so a frontmatter-only pin would miss a 5->6 over-replacement there
    # — the same accident that already happened once in the Go manifests.
    contains "$(sed -n 's/^description: //p' "$REPO_ROOT/$p/agents/${p#development-}-approver.md")" \
      "five review dimensions the Approver walks"
    wrong="$(grep -oE "(four|five|six|seven|eight) (review )?dimensions the Approver walks" \
               "$REPO_ROOT/$p/agents/${p#development-}-approver.md" \
             | grep -v "^five " || true)"
    [ -z "$wrong" ]
  done
  # ...and the same clause in the hand-written reference, which no generator covers.
  wrong="$(grep -oE "(four|five|six|seven|eight) review dimensions the Approver walks" \
             "$REPO_ROOT/docs/reference/plugins.md" | grep -v "^five " || true)"
  [ -z "$wrong" ]
}
