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

# flat_file <path> — the file with every run of whitespace collapsed to one
# space. EVERY multi-word needle and count sweep in this file goes through this.
# These docs are prose hard-wrapped at 65-120 columns, so a line-oriented grep is
# blind to any phrase the wrap splits — `go-approver.md` really does carry "not
# six full / reviews" across two lines. A sweep that cannot see the stale phrase
# reports green, which is exactly how two stale "five-lens" sentences shipped
# inside #1147's own first round.
flat_file() { tr -s '[:space:]' ' ' < "$1"; }

# flat_text — the same normalisation for an already-extracted block (sed output).
flat_text() { tr -s '[:space:]' ' '; }

# prose_block <file> <start-ere> <end-ere> — a sed-scoped section, flattened.
# Scoping matters as much as flattening: a whole-file haystack lets an unrelated
# part of the document satisfy a needle about one section — the mirrors' JSON
# schema block lists every dimension, so it would stand in for the prose lens
# list the check is actually about.
#
# `sed -E` (ERE), NOT the default BRE. BSD sed — the macOS default, and this
# repo is macOS-only — does not support GNU's `\|` alternation in a BRE, so an
# end pattern like `\(A\|B\)` matches NOTHING there: the range silently runs to
# EOF and the "scoped" block becomes the whole rest of the file, restoring the
# very vacuity the scoping exists to remove. That regression was caught only by
# mutation-testing this helper, so keep the -E and write end patterns as `(A|B)`.
prose_block() { sed -nE "/$2/,/$3/p" "$1" | flat_text; }

# table_pairs <plugin> — one `<agent> <dimension>` line per dimension-table row.
# The machine-readable half of the same table `table_rows` counts, so the #1147
# guards can assert the Approver's lens walk and enum against the panel itself
# instead of against hardcoded needles. Deriving it is what makes the NEXT
# dimension a red test rather than a silent blind spot — the very failure #1147
# was.
table_pairs() {
  awk -F'|' '/^\| *Agent *\| *Model *\| *Dimension *\|/ { f = 1; next }
             f && /^\| *:?-+/ { next }
             f && /^\|/ {
               agent = $2; dim = $4;
               gsub(/^[ \t`]+|[ \t`]+$/, "", agent);
               gsub(/^[ \t`]+|[ \t`]+$/, "", dim);
               print agent, dim;
               next }
             f && !/^\|/ { exit }' "$(panel_file "$1")"
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
  # Flattened: the `lacks` is the dangerous direction. These panels wrap at ~110
  # columns and already carry this needle mid-line, so a regression whose
  # sentence happened to wrap would match nothing and pass VACUOUSLY — the
  # capability loss ships green. A blind `contains` merely reds.
  local p panel
  for p in "${SERVICE_PLUGINS[@]}"; do
    panel="$(flat_file "$(panel_file "$p")")"
    [ -n "$panel" ]
    contains "$panel" 'use its name as the `subagent_type`'
    lacks "$panel" 'use `subagent_type: general-purpose`'
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
  local p n stale flat
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    # Guard n FIRST: an empty n would make the filter below match everything,
    # so `stale` would be empty and the test would pass having checked nothing.
    matches "$n" '^[1-9][0-9]*$'
    # Flattened, like every sweep in this file: these panels wrap at ~110-120
    # columns and already split a hyphenated count across lines, so a
    # line-oriented sweep can miss a stale phrase the wrap divides.
    flat="$(flat_file "$(panel_file "$p")")"
    [ -n "$flat" ]
    stale="$(grep -oE "(all|these) [0-9]+ (background )?agents|All [0-9]+ Review|[0-9]+ specialized" \
               <<< "$flat" | grep -vE "(^|[^0-9])${n}([^0-9]|$)" || true)"
    [ -z "$stale" ]
  done
}

@test "each panel's WORD-form dimension count tracks its table too" {
  # The Go panel spells its counts out ("all six dimensions completed"); a
  # digit-only guard would let the word forms drift on the next renumber.
  local p n word prev wrong flat
  for p in "${SERVICE_PLUGINS[@]}"; do
    n="$(table_rows "$p")"
    word="$(word_for "$n")"
    lacks "$word" "UNMAPPED"
    flat="$(flat_file "$(panel_file "$p")")"
    [ -n "$flat" ]
    # Whatever word-form dimension counts a panel carries must ALL be this one.
    # A panel carrying none is fine (only Go spells them out today).
    wrong="$(grep -oE "all (four|five|six|seven|eight) dimensions" <<< "$flat" \
             | grep -v "all ${word} dimensions" || true)"
    [ -z "$wrong" ]
    # The HYPHENATED form too ("a five-dimension array ... a clean six-dimension
    # review"): the partial-round rationale names n-1 and n, and nothing else.
    prev="$(word_for $((n - 1)))"
    lacks "$prev" "UNMAPPED"
    wrong="$(grep -oE "(four|five|six|seven|eight)-dimension" <<< "$flat" \
             | grep -vE "^(${word}|${prev})-dimension" || true)"
    [ -z "$wrong" ]
    # Membership in {n-1, n} is only half the contract: a partial renumber that
    # left the n-referring phrase at the OLD n (now n-1) has every occurrence
    # equal to prev and would slip through. So when any hyphenated count exists,
    # the n-form must be among them.
    if grep -qE "(four|five|six|seven|eight)-dimension" <<< "$flat"; then
      grep -q "${word}-dimension" <<< "$flat"
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

@test "ARCHITECTURE.md records the REMAINING downstream gap, not an automatic-pickup claim" {
  # An earlier draft claimed a new dimension flows downstream automatically. One
  # surface still doesn't: build-dossier drops a CLEAN non-core dimension
  # (#1148). Claiming otherwise sends a reader looking for wiring that isn't
  # there. The Approver's half closed with #1147, so the doc must NOT still
  # describe it as a gap — a stale caveat is drift a reader acts on.
  # Scope the #1148 needles to the caveat BULLET, the way the enum test above
  # scopes to its paragraph: `#1148` also appears in the unrelated Review-dossier
  # section, so a whole-file haystack stays green even if the bullet this test is
  # named for were deleted outright.
  local arch bullet para go_word swift_word wrong
  arch="$(flat_file "$REPO_ROOT/ARCHITECTURE.md")"
  [ -n "$arch" ]
  bullet="$(prose_block "$REPO_ROOT/ARCHITECTURE.md" \
              '^- \*\*`build-dossier.zsh` carries a new dimension' '^$')"
  [ -n "$bullet" ]
  contains "$bullet" "only when it reports"
  contains "$bullet" "#1148"
  lacks "$arch" 'neither labels nor looks through the `resilience` lens'
  # ...and it records the closure positively, so the section still tells a reader
  # where the Approver's dimension list comes from. Scoped to its own paragraph
  # for the same reason, and its two counts DERIVED from the panel tables — a
  # hardcoded pair would pass while the paragraph went stale, which is the
  # drift-guard-pointing-backwards failure the enum test above warns about.
  para="$(prose_block "$REPO_ROOT/ARCHITECTURE.md" '^The \*\*Approver\*\* does now label' '^$')"
  [ -n "$para" ]
  contains "$para" "does now label and look through every dimension its panel"
  contains "$para" "#1147"
  # The sentence says "N lenses on Go/JAVA/PYTHON", so Go's count stands in for
  # three panels. Pin that premise before relying on it: without these two, a
  # Java panel that grew a seventh dimension would leave the sentence false AND
  # this test green — the very one-language-grows scenario #1147 is about — while
  # the corrected prose would be reported as the wrong number.
  [ "$(table_rows development-java)" -eq "$(table_rows development-go)" ]
  [ "$(table_rows development-python)" -eq "$(table_rows development-go)" ]
  go_word="$(word_for "$(table_rows development-go)")"
  lacks "$go_word" "UNMAPPED"
  swift_word="$(word_for "$(table_rows development-swift)")"
  lacks "$swift_word" "UNMAPPED"
  contains "$para" "${go_word} lenses on Go/Java/Python"
  contains "$para" "${swift_word} lenses on Swift"
  # The enum test's Swift exemption branches on this documented split, so pin the
  # sentence it rests on — otherwise rewording it silently invalidates that
  # branch and nothing reds.
  contains "$para" "on Go/Java/Python, the enum too"
  # ...and the authority the paragraph attributes to the TEMPLATE. Both ends are
  # pinned (the template side sits with the other template needles below),
  # because this sentence already drifted once: the template was corrected to
  # name the review panel while ARCHITECTURE.md still said the overlay decides,
  # and nothing was red. ARCHITECTURE.md is the contract authority here, so a
  # reader syncing the two would have reverted the fix.
  contains "$para" "panel's dimension table decides"
  # Sweep the STEM, not one guessed sentence: the pre-fix wording differed
  # between the two documents, so a needle pinned to either spelling misses a
  # revert phrased the other way (or a second, contradicting sentence added
  # beside the correct one). The live text reads "— not the overlay, which
  # carries only …", so it cannot collide.
  wrong="$(grep -oE "the overlay('s [a-z ]+)? decides" <<< "$para" || true)"
  [ -z "$wrong" ]
  # ...and no OTHER lens count hiding in the same paragraph.
  wrong="$(grep -oE "(four|five|six|seven|eight) lenses" <<< "$para" \
           | grep -vE "^(${go_word}|${swift_word}) lenses" || true)"
  [ -z "$wrong" ]
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

@test "the manifests' Approver lens count tracks the panel table too" {
  # Since #1147 the Approver walks the panel's WHOLE dimension table, so the two
  # counts coincide — but they are still two independent strings, and the one
  # that drifts is the one nothing derives. Derived from the table, so the next
  # dimension fails here rather than shipping a manifest promising N-1 lenses.
  local n a wrong
  n="$(table_rows development-go)"
  matches "$n" '^[1-9][0-9]*$'
  a="$(jq -r '.description' "$REPO_ROOT/development-go/.claude-plugin/plugin.json")"
  contains "$a" "${n} review dimensions the Approver walks"
  # ...and no OTHER count hiding behind the correct one.
  wrong="$(grep -oE "[0-9]+ review dimensions the Approver walks" <<< "$a" \
           | grep -v "^${n} " || true)"
  [ -z "$wrong" ]
  # ...and the agent it describes really does walk that many. Guard the word form
  # like every other call site: unguarded, a panel grown past the word table
  # fails as "go-approver lost its lens count" and sends the reader to the wrong
  # file.
  local word
  word="$(word_for "$n")"
  lacks "$word" "UNMAPPED"
  contains "$(flat_file "$REPO_ROOT/development-go/agents/go-approver.md")" "${word} lenses"
}

@test "docs/reference/plugins.md's Go word-form count tracks the table too" {
  local n word wrong flat
  n="$(table_rows development-go)"
  word="$(word_for "$n")"
  lacks "$word" "UNMAPPED"
  # One flattened copy for the whole test: this page wraps at ~75 columns and
  # both swept phrases are long enough that an edit can push them across a wrap,
  # where a line-oriented grep — and a `cat`-based positive control — see nothing.
  flat="$(flat_file "$REPO_ROOT/docs/reference/plugins.md")"
  [ -n "$flat" ]
  # Positive control FIRST — the sweep below ends in `|| true`, so without it a
  # reworded or renamed page makes grep match nothing, `wrong` is empty, and the
  # test reports green having checked nothing.
  contains "$flat" "${word} specialists"
  wrong="$(grep -oE "(four|five|six|seven|eight) specialists" <<< "$flat" \
           | grep -v "${word} specialists" || true)"
  [ -z "$wrong" ]
  # The same page ALSO states which of those specialists double as Approver
  # lenses. Since #1147 that is all of them, and this sentence is covered by no
  # generator — it said "the first five" while the approver row two hundred
  # lines below said six, and nothing was red.
  contains "$flat" "all ${word} double as risk-register lenses"
  wrong="$(grep -oE "(first|all) (four|five|six|seven|eight) double as risk-register lenses" \
             <<< "$flat" \
           | grep -v "^all ${word} double as risk-register lenses$" || true)"
  [ -z "$wrong" ]
}

# ---- the two documented downstream gaps, pinned BEHAVIOURALLY ---------------

@test "#1147: no Approver pins a dimension enum its panel can exceed" {
  # The inverse of the gap this file used to pin. Every approver agent — and its
  # operator mirror, where it restates the enum — must admit `resilience`, and
  # Swift `swift6_compliance` too. Asserting the CLOSED form is absent as well as
  # the open one present: a file that grew a second, still-closed enum elsewhere
  # would otherwise pass on the first needle alone.
  # Membership is asserted per DIMENSION, derived from the panel table — a tail
  # needle like `| resilience | null"` would pass an enum that silently dropped
  # `code_quality`, which is exactly the "bucketed under a dimension nothing
  # downstream knows" failure the table-cell test above exists to prevent.
  local p f mirror enum dim agent pairs
  for p in "${SERVICE_PLUGINS[@]}"; do
    # Materialise the derivation and prove it before trusting it — a `while read`
    # fed by process substitution swallows the producer's status, so an awk that
    # matched nothing (renamed plugin dir, moved SKILL.md, changed table header)
    # would run the body zero times and report green having asserted no dimension
    # at all. Pinning the line count against table_rows also catches a table
    # parsed only in part.
    pairs="$(table_pairs "$p")"
    [ -n "$pairs" ]
    [ "$(wc -l <<< "$pairs" | tr -d ' ')" -eq "$(table_rows "$p")" ]
    f="$(cat "$REPO_ROOT/$p/agents/${p#development-}-approver.md")"
    lacks "$f" '"dimension": "bugs | security | performance | code_quality | tests | null"'
    # Select the enum line by a part that is NOT itself asserted: grepping for
    # `bugs` would make the `dim=bugs` iteration tautological, since the selector
    # already guaranteed it.
    enum="$(grep '"dimension": "' <<< "$f" | grep ' | null"' | head -1)"
    [ -n "$enum" ]
    # Every dimension the panel ships must be a legal value, and `null` with it.
    while read -r agent dim; do
      [ -n "$dim" ]
      contains "$enum" "$dim"
    done <<< "$pairs"
    contains "$enum" "null"
    # ...and the instruction that keeps the list OPEN, which is the durable half
    # of #1147: the enum's current membership can be correct while the agent is
    # told to treat it as closed, and the next dimension is then a defect again.
    contains "$f" "not a fixed set"
    contains "$f" "dimension table is authoritative"
    # The mirror restates the enum on Go/Java/Python; Swift's is a delta-doc that
    # carries only the walk. Branch on the DOCUMENTED split (ARCHITECTURE.md:
    # "and, on Go/Java/Python, the enum too") rather than probing for the enum —
    # a probe is skipped by the very regression it guards, so a mirror whose enum
    # was dropped or reordered would take the false branch and assert nothing.
    mirror="$(cat "$REPO_ROOT/$p/docs/${p#development-}-approver.md")"
    lacks "$mirror" '"dimension": "bugs | security | performance | code_quality | tests | null"'
    contains "$mirror" "not a closed enum"
    if [ "$p" != development-swift ]; then
      enum="$(grep '"dimension": "' <<< "$mirror" | grep ' | null"' | head -1)"
      [ -n "$enum" ]
      while read -r agent dim; do
        contains "$enum" "$dim"
      done <<< "$pairs"
      contains "$enum" "null"
    else
      # Pin the documented ABSENCE, so the branch cannot be silently skipped by
      # the regression it guards: if the Swift delta-doc ever grows a schema
      # block (its agent tells editors to "keep the four in sync"), this reds and
      # forces the exemption to be revisited rather than quietly exempting the
      # one mirror whose panel carries swift6_compliance.
      [ -z "$(grep '"dimension": "' <<< "$mirror" | grep ' | null"' || true)" ]
    fi
  done
  # The bootstrap template ships to every new repo, so it must not re-seed the
  # gap. Positive needles on BOTH sites that name the non-core dimensions: the
  # `lacks` alone catches only a full revert, not a partial one dropping
  # swift6_compliance from either the schema block or the dossier bullet.
  # Flattened, like every other multi-word needle here: this template is prose
  # hard-wrapped at ~70 columns and the authority sentence below already splits
  # across a line, so a raw haystack would red a correct file — and, on the
  # `lacks` side, could miss a wrapped re-introduction of the closed enum.
  f="$(flat_file "$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl")"
  [ -n "$f" ]
  lacks "$f" '"dimension": "bugs | security | performance | code_quality | tests | null"'
  contains "$f" 'not** a closed enum'
  contains "$f" 'resilience | swift6_compliance'
  contains "$f" 'swift6_compliance on Swift'
  # The template side of the authority sentence ARCHITECTURE.md describes. The
  # `lacks` matters as much as the `contains`: the template used to defer to
  # "the overlay's review panel", a section NO shipped overlay contains, so the
  # rendered policy sent the Approver to a table that isn't there.
  contains "$f" "panel's own dimension table is the authority"
  lacks "$f" "the overlay's review panel"
}

@test "#1147: every approver's lens walk covers its panel's whole dimension table" {
  # The register is only as wide as the walk. The BULLET LIST is derived from the
  # panel table, not pinned by a hardcoded `resilience` needle: a future dimension
  # whose author updates the count prose (the obvious edit) but not the step-10
  # list would otherwise pass every assertion here — which is #1147 itself.
  local p word f agent dim pairs walk mirror flat
  for p in "${SERVICE_PLUGINS[@]}"; do
    word="$(word_for "$(table_rows "$p")")"
    lacks "$word" "UNMAPPED"
    pairs="$(table_pairs "$p")"
    [ -n "$pairs" ]
    [ "$(wc -l <<< "$pairs" | tr -d ' ')" -eq "$(table_rows "$p")" ]
    f="$REPO_ROOT/$p/agents/${p#development-}-approver.md"
    contains "$(cat "$f")" "${word} lenses"
    # SCOPE to the register step before asserting the bullets: a whole-file
    # haystack is satisfied by any backticked mention of the agent, so deleting
    # the bullet list while leaving a prose mention would keep this green.
    walk="$(sed -n '/isk register — fed by the review dimensions/,/onfidence calibration/p' "$f")"
    [ -n "$walk" ]
    # UPPER bound too, exactly as the mirror block below. A reworded step-11
    # heading makes this range run to EOF, and BOTH other guards survive that:
    # the block is non-empty, and each approver carries exactly `table_rows`
    # matching bullets FILE-WIDE, so the cardinality check below passes on the
    # unscoped block as well. The enum tail sits only past step 11 in all four.
    lacks "$walk" ' | null"'
    # One walked-lens bullet per panel row, keyed on the REVIEWER AGENT rather
    # than the dimension cell: the bullets spell `code_quality` in prose as "code
    # quality", so a dimension-keyed needle would fail on a lens that is present.
    # The agent name is the unambiguous join between table row and bullet.
    while read -r agent dim; do
      [ -n "$agent" ]
      contains "$walk" "(\`${agent}\`"
    done <<< "$pairs"
    # ...and no EXTRA bullet for a dimension the panel has since retired.
    [ "$(grep -cE '^ *- \*\*.+\*\* \(`[a-z0-9-]+`' <<< "$walk")" -eq "$(table_rows "$p")" ]
    # The operator mirror states the same count AND enumerates the same lenses.
    # Count alone would let a mirror drop `resilience` from its prose list while
    # every other guard in this file stayed green — the operator-facing half of
    # #1147 reverting silently.
    #
    # SCOPE to the mirror's own lens paragraph, exactly as the agent walk above
    # is scoped. A whole-file haystack does NOT work here: the Go/Java/Python
    # mirrors restate the full `"dimension": "bugs | … | resilience | null"` enum
    # in their JSON schema block, so every dimension matches that one line and
    # the check passes no matter what the prose list says. That vacuity hid
    # behind a green mutation test, because only the Swift mirror — a delta-doc
    # with no schema block — actually bound the assertion.
    mirror="$REPO_ROOT/$p/docs/${p#development-}-approver.md"
    contains "$(flat_file "$mirror")" "${word} lenses"
    # The numbered mirrors head the section "Risk register — fed by the review
    # dimensions" and end at "Confidence calibration"; the Swift delta-doc says
    # "The risk register is fed by the review dimensions" and ends at the next
    # `- **` bullet. One alternation covers both.
    flat="$(prose_block "$mirror" 'isk register.*fed by the review dimensions' '(onfidence calibration|^- \*\*)')"
    [ -n "$flat" ]
    # Positive control: the extracted block really is the lens paragraph, not
    # some other slice that happens to be non-empty.
    contains "$flat" "${word} lenses"
    # UPPER bound as well as lower. `sed` runs a range to EOF when the END
    # pattern never matches, so rewording a mirror's step-11 heading would
    # silently make this "scoped" block the whole rest of the file — re-arming
    # the exact vacuity above, with both guards still green (a huge block is
    # non-empty, and the start line still carries the count). The enum tail lives
    # only in the schema block and in none of the four lens paragraphs, so its
    # absence proves the range really did stop.
    lacks "$flat" ' | null"'
    while read -r agent dim; do
      [ -n "$dim" ]
      # Either spelling counts: the mirrors render `code_quality` as "code
      # quality" but keep `swift6_compliance` underscored, so demanding one form
      # would fail on a lens that is present and correctly written.
      if ! grep -qF -- "$dim" <<< "$flat"; then
        contains "$flat" "${dim//_/ }"
      fi
    done <<< "$pairs"
  done
}

@test "#1147: no approver or mirror carries a lens count with the WRONG number" {
  # The positive `${word} lenses` guard proves A correct count exists; it says
  # nothing about the file's OTHER count-bearing phrases. The panel SKILL.md has
  # had this negative sweep since #966; the approvers had none, and two stale
  # "five-lens risk register ... not five full reviews" sentences shipped green
  # inside #1147's own first round because of it.
  # Every sweep runs over a WHITESPACE-NORMALISED copy. These files are prose
  # hard-wrapped at ~65 columns, so a line-oriented grep misses any phrase the
  # wrap splits — `go-approver.md` already splits "not six full / reviews", which
  # would have left this very sweep blind on the file it was written for.
  local p word f wrong flat
  for p in "${SERVICE_PLUGINS[@]}"; do
    word="$(word_for "$(table_rows "$p")")"
    lacks "$word" "UNMAPPED"
    for f in "$REPO_ROOT/$p/agents/${p#development-}-approver.md" \
             "$REPO_ROOT/$p/docs/${p#development-}-approver.md"; do
      [ -f "$f" ]
      flat="$(tr -s '[:space:]' ' ' < "$f")"
      [ -n "$flat" ]
      # Both spellings: the hyphenated adjective ("the six-lens risk register")
      # and the plural noun ("walk the six lenses").
      wrong="$(grep -oE "(four|five|six|seven|eight)[ -]lens(es)?" <<< "$flat" \
               | grep -vE "^${word}[ -]lens(es)?$" || true)"
      [ -z "$wrong" ]
      # ...and the sibling phrasing in the same sentence, which names the count
      # again without the word "lens" ("not six full reviews").
      wrong="$(grep -oE "not (four|five|six|seven|eight) full reviews" <<< "$flat" \
               | grep -v "^not ${word} full reviews$" || true)"
      [ -z "$wrong" ]
    done
    # Positive control for the "not N full reviews" phrasing: without it a
    # rewording retires that sweep silently, exactly the vacuous-guard shape
    # this test exists to close. Only Go and Swift carry a cost section that
    # phrases it, so key the control on the COUNT-FREE part of the sentence —
    # a file carrying "full reviews" at all must carry the right number. That
    # cannot be skipped by a count regression, only by deleting the sentence.
    flat="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/$p/agents/${p#development-}-approver.md")"
    if grep -qF "full reviews" <<< "$flat"; then
      contains "$flat" "not ${word} full reviews"
    fi
  done
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

@test "the approver agents' panel-count prose is derived, lens count included" {
  # Since #1147 the lens count IS the panel count — the register walks the whole
  # table — so both halves derive from the same number instead of tracking
  # separately. Still worth pinning: the frontmatter feeds the generated
  # docs/reference/agents.md, where --check only proves the page matches the
  # frontmatter, so a wrong frontmatter regenerates cleanly.
  local p f word wrong flat desc agent dim
  for p in development-go development-swift; do
    word="$(word_for "$(table_rows "$p")")"
    lacks "$word" "UNMAPPED"
    f="$REPO_ROOT/$p/agents/${p#development-}-approver.md"
    # Flattened for the same reason as every other sweep: the BODY carries these
    # phrases in ~65-column wrapped prose ("— the panel's six, in / full (#1147)"),
    # so a line-oriented sweep is one reflow away from going silent.
    flat="$(flat_file "$f")"
    [ -n "$flat" ]
    contains "$flat" "the panel's ${word}"
    # ...and no OTHER count hiding behind the correct one.
    wrong="$(grep -oE "the panel's (four|five|six|seven|eight)" <<< "$flat" \
             | grep -v "the panel's ${word}" || true)"
    [ -z "$wrong" ]
    # Pin the FRONTMATTER positively (the body's "N lenses" needle does not stand
    # in for it), then sweep the WHOLE file: the body spells it without "review"
    # ("N dimensions the Approver walks"), so a frontmatter-only pin would miss a
    # partial renumber there — the accident that already happened once in the Go
    # manifests.
    desc="$(sed -n 's/^description: //p' "$f")"
    [ -n "$desc" ]
    contains "$desc" "${word} review dimensions the Approver walks"
    wrong="$(grep -oE "(four|five|six|seven|eight) (review )?dimensions the Approver walks" \
               <<< "$flat" | grep -v "^${word} " || true)"
    [ -z "$wrong" ]
    # The description also ENUMERATES the dimensions inline, and that list is
    # half of what #1147 widened. The count phrase above does not cover it: a
    # revert dropping `resilience` from the parenthetical while leaving "six"
    # intact passes every count guard AND regenerates docs/reference/agents.md
    # cleanly (--check only proves page == frontmatter), so the user-facing
    # reference would advertise a lens list the panel contradicts.
    while read -r agent dim; do
      [ -n "$dim" ]
      if ! grep -qF -- "$dim" <<< "$desc"; then
        contains "$desc" "${dim//_/ }"
      fi
    done <<< "$(table_pairs "$p")"
  done
  # ...and the same clause in the hand-written reference, which no generator
  # covers. Scoped per approver row: Go/Java say six, Swift seven, so a
  # whole-file sweep against one word would be wrong by construction.
  local row checked
  checked=0
  for p in development-go development-java development-swift; do
    word="$(word_for "$(table_rows "$p")")"
    lacks "$word" "UNMAPPED"
    # `|| true` so the emptiness check below is the guard, rather than errexit on
    # the assignment — otherwise a reader "simplifying" this line would silently
    # remove a protection they believe the next line provides.
    row="$(grep -E "^\| \`?${p#development-}-approver\`? \|" \
             "$REPO_ROOT/docs/reference/plugins.md" || true)"
    [ -n "$row" ]
    contains "$row" "${word} review dimensions the Approver walks"
    wrong="$(grep -oE "(four|five|six|seven|eight) review dimensions the Approver walks" \
               <<< "$row" | grep -v "^${word} " || true)"
    [ -z "$wrong" ]
    # These rows also NAME the dimensions #1147 added ("resilience included",
    # "swift6_compliance and resilience included") — the NON-CORE ones only, not
    # the whole table, so derive exactly that set rather than every row. Count-only
    # would pass a row that kept "seven" while dropping a dimension: the same gap
    # closed on the agent frontmatter above, and this page is hand-written, so no
    # generator's --check ever sees it.
    while read -r agent dim; do
      [ -n "$dim" ]
      case "$dim" in
        bugs | security | performance | code_quality | tests) continue ;;
      esac
      contains "$row" "$dim"
    done <<< "$(table_pairs "$p")"
    checked=$((checked + 1))
  done
  # Completeness: the per-row loop replaced a whole-file sweep, so without this
  # a FOURTH occurrence — a python-approver row added later, or the clause
  # appearing in surrounding prose — would be matched by no assertion at all and
  # could carry a stale count indefinitely.
  # Counted as OCCURRENCES on a FLATTENED page, not as matching lines in the raw
  # one: the clause is ~40 chars in ~75-column prose, so the "surrounding prose"
  # half of that promise needs the wrap closed, and two occurrences sharing a
  # line would otherwise count as one. (`grep -o | wc -l` also yields 0 with
  # status 0 on no match, where a bare `grep -c` exits 1 and trips errexit.)
  local total ref
  ref="$(flat_file "$REPO_ROOT/docs/reference/plugins.md")"
  [ -n "$ref" ]
  # `[0-9]+` as well as the word forms: the SAME clause is spelled with a digit
  # in the Go manifest ("6 review dimensions the Approver walks", pinned above),
  # so a fourth occurrence copied from that phrasing would be counted by neither
  # this tripwire nor the per-row loop — the precise hole this exists to close.
  total="$(grep -oE "(four|five|six|seven|eight|[0-9]+) review dimensions the Approver walks" \
             <<< "$ref" | wc -l | tr -d ' ')"
  [ "$total" -eq "$checked" ]
}
