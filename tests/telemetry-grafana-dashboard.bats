#!/usr/bin/env bats
#
# Behavioral tests for the Grafana hand-off artifacts (#1008, epic #740 child
# (f)): the committed reference dashboard, its field manifest, and the
# hand-off contract page.
#
# WHAT THESE CAN AND CANNOT PROVE. This repo cannot execute a Grafana stack, so
# nothing here asserts that the dashboard *renders* — that is owner-verified once
# on import and is deliberately not a CI gate. What is checkable is the
# STRUCTURAL contract: the export parses, its datasource indirection is intact,
# and every telemetry field its queries touch is a real envelope key.
#
# THE ANTI-DRIFT RULE THAT MATTERS: the envelope key list is read from the
# ENFORCER (`validate-telemetry.zsh --print-envelope-keys`), never copied here.
# A test that hard-coded the 14 names would be a second source of truth — the
# exact drift this contract exists to remove — and would pass happily while the
# validator and the docs disagreed. The same reasoning drives the manifest: the
# panel->field mapping is read from reference-dashboard.fields.json rather than
# restated in a local array.
#
# EVERY LOOP HERE GUARDS ITS OWN INPUT for non-emptiness before iterating. A
# sibling @test pinning the same list is not enough: the guard and the loop then
# live in different tests, so editing one silently disarms the other, and the
# vacuous test is not the one that goes red.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TELEMETRY_DIR="$REPO_ROOT/development/scripts/telemetry"
  VALIDATE="$TELEMETRY_DIR/validate-telemetry.zsh"
  DASH="$TELEMETRY_DIR/grafana/reference-dashboard.json"
  MANIFEST="$TELEMETRY_DIR/grafana/reference-dashboard.fields.json"
  REF_PAGE="$REPO_ROOT/docs/reference/telemetry-grafana-handoff.md"
  EXP_PAGE="$REPO_ROOT/docs/explanation/telemetry-grafana-handoff.md"
}

# The authoritative envelope key list, straight from the enforcer, one per line.
envelope_keys() {
  zsh "$VALIDATE" --print-envelope-keys | jq -r '.[]'
}

# The panel titles the contract fixes, one per line.
expected_titles() {
  printf '%s\n' 'Runs over time' 'Outcome mix' 'Escalation rate' 'Per-pipeline breakdown'
}

# EVERY target expression of a panel, one per line — not just `.targets[0]`.
# A second target (`refId: "B"`, the natural way to split the Escalation-rate
# ratio) is an ordinary Grafana edit; reading only the first would leave that
# query checked by nothing, and every assertion below would keep passing while it
# referenced `schema`, dropped the kind filter, or used an un-manifested field.
#
# A missing or empty expr is an ERROR, not empty output. `jq -r` prints the
# four-character string `null` for an absent key, so `[ -n "$expr" ]` would pass
# on a deleted query; and `-e` alone is not enough either, since it takes its
# status from the LAST output value — on `[{expr: null}, {expr: "…"}]` (exactly
# the multi-target shape this helper exists for) jq would exit 0 and let the
# literal `null` flow downstream. An explicit `error` covers every position.
panel_exprs() {
  jq -er --arg t "$1" '
    .panels[] | select(.title == $t) | .targets[]
    | (.expr | select(type == "string" and length > 0)
       // error("missing or empty expr in panel \($t)"))' "$DASH"
}

# THE FIELD-EXTRACTION RULE, implemented exactly as the contract page states it.
# A "field reference" inside a LogQL expr is, and is only:
#
#   1. a JSON-extraction label assignment `| json <name>="<name>"` — matched
#      inside a `| json …` stage (which ends at the next `|` or `)`), keeping
#      only pairs whose two halves are IDENTICAL, so a renaming assignment like
#      `short="pipeline"` is not silently read as a reference to `short`;
#   2. the left-hand side of a label-filter comparison `<name> = "…"` /
#      `<name> != "…"` appearing AFTER a `| json` stage.
#
# The whitespace around the operator in rule 2 is load-bearing, not cosmetic: it
# is what distinguishes a label FILTER from a stream SELECTOR. The `Escalation
# rate` panel divides two sub-queries, so a second `{job="claude-telemetry"}`
# appears after the first `| json` — without the spacing requirement `job` would
# be extracted as a telemetry field it is not, and assertion (c) below would fail
# on a correct dashboard.
#
# Deliberately NO LogQL parser: the rule is narrow precisely so the test never
# needs one. Narrow means it FAILS OPEN on any other LogQL construct, which is
# why the closure guard below exists — see "the rule's blind spots".
extract_fields() {
  local expr="$1"
  {
    printf '%s' "$expr" \
      | grep -oE '[|] json [^|)]*' \
      | grep -oE '[A-Za-z_][A-Za-z0-9_]*="[A-Za-z_][A-Za-z0-9_]*"' \
      | awk -F'="' '{ rhs = substr($2, 1, length($2) - 1); if ($1 == rhs) print $1 }'
    printf '%s' "${expr#*| json }" \
      | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]+!?=[[:space:]]+"' \
      | grep -oE '^[A-Za-z_][A-Za-z0-9_]*'
  } | sort -u
}

# An expr with its `| json …` stages and `{…}` stream selectors removed — what is
# left is exactly the part the closure guard reasons about.
expr_remainder() {
  printf '%s' "$1" | sed -E 's/[|] json [^|)]*//g; s/\{[^}]*\}//g'
}

# THE CLOSURE GUARD, as ONE predicate: 0 if `$1` stays inside the shapes
# extract_fields can see, 1 if it reaches for anything else.
#
# It is a single function on purpose. When the arms lived inline in the @tests
# and the probes hand-copied their expressions, deleting an arm left every probe
# green — a guard nobody could regress-test, wearing a test that implied
# otherwise. Now the guard @tests below loop this predicate over the committed
# queries and every probe calls this same predicate, so removing any arm reddens
# a probe immediately.
#
# ALLOWLIST, not blacklist, for the two things that matter:
#
#   * PARSER STAGES. A stage that auto-extracts (`| json` with no parameters,
#     `| logfmt`, `| unpack`) makes Loki expose EVERY envelope key as a label, so
#     `sum by (repo)` becomes a real reference to `repo` with nothing for
#     extract_fields to match — assertion (c) then compares an under-counted
#     `found` against an under-counted manifest and passes. Naming the offenders
#     one by one only ever closes the spellings someone remembered, so instead
#     every `|` stage in the remainder must be one of the few shapes the rule can
#     reason about. The next LogQL construct nobody thought of fails closed.
#   * JSON-STAGE BODIES. `| json kind, outcome` is LogQL shorthand for the
#     identity pairs — a genuine read of two fields that matches no `name="name"`
#     pattern. So a stage body must reduce to NOTHING once identity pairs, commas
#     and whitespace are removed; a bare identifier, a renaming assignment or a
#     backquoted parameter all leave residue and red.
guard_expr() {
  local expr="$1" rest stage body pairs pair lhs rhs stages

  # --- json-stage bodies: identity pairs only, at least one -------------------
  stages="$(printf '%s' "$expr" | grep -oE '[|] json[^|)]*' || true)"
  # NB: a query with NO `| json` stage at all — including one spelled `|json`,
  # which this pattern deliberately does not match — needs no arm of its own. An
  # empty `$stages` still yields one (empty) loop iteration below, whose empty
  # `$pairs` is rejected by the bare-json arm. An explicit `[ -z "$stages" ]`
  # check here WAS present and the mutation harness proved it dead: neutralising
  # it reddened no probe, because that arm caught the case first.
  while IFS= read -r stage; do
    body="${stage#|}"
    body="${body# }"
    body="${body#json}"
    # every assignment must be the IDENTITY form — a renaming `p="pipeline"`
    # really reads `pipeline` while extract_fields discards it
    pairs="$(printf '%s' "$body" | grep -oE '[A-Za-z_][A-Za-z0-9_]*="[^"]*"' || true)"
    if [ -n "$pairs" ]; then
      while IFS= read -r pair; do
        lhs="${pair%%=*}"
        rhs="${pair#*=\"}"
        rhs="${rhs%\"}"
        if [ "$lhs" != "$rhs" ]; then return 1; fi  # ARM:identity-pair
      done <<< "$pairs"
    fi
    # remove the pairs, then commas and whitespace. ANYTHING left is a form the
    # rule cannot see: a bare stage (empty body), or LogQL's shorthand
    # `| json kind, outcome`, or a backquoted parameter.
    body="$(printf '%s' "$body" | sed -E 's/[A-Za-z_][A-Za-z0-9_]*="[^"]*"//g' | tr -d ', \t')"
    if [ -n "$body" ]; then return 1; fi  # ARM:body-residue
    # An empty body means a BARE `| json`, which auto-extracts every key — and,
    # via the empty iteration noted above, this is also what rejects a query
    # carrying no rule-visible `| json` stage at all.
    if [ -z "$pairs" ]; then return 1; fi  # ARM:bare-json
  done <<< "$stages"

  # --- everything outside the json stages and the stream selectors ------------
  rest="$(expr_remainder "$expr")"
  # Comparisons the rule matches are neutralised first, using the SAME
  # whitespace class as extract_fields' rule 2 so the guard can never red a
  # query the rule handles perfectly. The marker is deliberately alphanumeric —
  # a `<…>` placeholder would trip the operator check three lines below.
  rest="$(printf '%s' "$rest" \
          | sed -E 's/[A-Za-z_][A-Za-z0-9_]*[[:space:]]+!?=[[:space:]]+"[^"]*"/RULEMATCHEDCMP/g')"
  # Any surviving comparison operator is a shape the rule cannot see:
  # `=~`, `!~`, `>`, `<`, a spaceless `field="value"`, an unquoted `field = 5`.
  # `~` is in the class for a reason that is easy to lose: a NEGATED-REGEX LINE
  # FILTER `!~ "…"` contains none of `=`, `<`, `>`, and it can sit either before
  # the first stage (which the stage loop below skips) or trailing after a
  # rule-matched filter (which the loop's prefix match accepts) — so without `~`
  # it reads record content with nothing to extract and nothing to notice.
  if printf '%s' "$rest" | grep -qE '=|<|>|~'; then return 1; fi  # ARM:operator

  # --- the stream selector may only match on `job` ----------------------------
  # expr_remainder strips `{…}` before every other arm, so a matcher on a
  # PROMOTED envelope label — `{job="…", outcome="escalated"}`, natural once a
  # scrape config labels `outcome` — would read a field with nothing to extract
  # and nothing to notice. Allowlisting the one label the contract documents
  # closes that, and is also what lets `sum by (job)` below be accepted rather
  # than falsely rejected.
  local sel key
  sel="$(printf '%s' "$expr" | grep -oE '\{[^}]*\}' || true)"
  if [ -n "$sel" ]; then
    while IFS= read -r key; do
      if [ "$key" != "job" ]; then return 1; fi  # ARM:selector-key
    done <<< "$(printf '%s' "$sel" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[!=~]*=' \
                | grep -oE '^[A-Za-z_][A-Za-z0-9_]*')"
  fi

  # --- label lists must name fields the rule can actually see -----------------
  # `sum by (repo) (…)` is a genuine read of `repo`, but it lives in the
  # aggregation PREFIX — the first `|`-segment, which the stage loop below skips
  # — so nothing else here would look at it. The same is true of the
  # vector-matching lists (`on`, `ignoring`, `group_left`, `group_right`), which
  # name labels in the metric layer. Every such label must be extracted by an
  # identity pair, or be the `job` stream label allowed above.
  local groups grp labels label
  groups="$(printf '%s' "$expr" \
            | grep -oE '(by|without|on|ignoring|group_left|group_right)[[:space:]]*\([^)]*\)' || true)"
  if [ -n "$groups" ]; then
    while IFS= read -r grp; do
      labels="$(printf '%s' "$grp" \
                | sed -E 's/^(by|without|on|ignoring|group_left|group_right)[[:space:]]*\(//; s/\)$//' \
                | tr ',' '\n')"
      while IFS= read -r label; do
        label="$(printf '%s' "$label" | tr -d '[:space:]')"
        if [ -z "$label" ]; then continue; fi
        if [ "$label" = "job" ]; then continue; fi
        if ! printf '%s' "$expr" | grep -qE "[|] json [^|)]*${label}=\"${label}\""; then
          return 1  # ARM:label-list
        fi
      done <<< "$labels"
    done <<< "$groups"
  fi

  # --- label-rewriting functions read a label by name, invisibly --------------
  # `label_replace(v, "dst", "$1", "repo", "(.*)")` names `repo` in a plain
  # function argument — no operator, no stage, no label list. Named explicitly
  # because there is no structural handle to allowlist it by.
  if printf '%s' "$rest" | grep -qE 'label_replace|label_join'; then return 1; fi  # ARM:label-rewrite

  # Every remaining `|` stage must be one the rule can reason about. A segment
  # carries trailing query syntax (`RULEMATCHEDCMP)[$__auto]))`), so the test is
  # what it STARTS with. This is the allowlist half: `logfmt`, `unpack`,
  # `unwrap`, `line_format`, `label_format`, `pattern`, `regexp` and anything
  # else nobody has thought of all fail here without being named.
  while IFS= read -r stage; do
    stage="${stage#"${stage%%[![:space:]]*}"}"
    if [ -z "$stage" ]; then continue; fi
    case "$stage" in
      RULEMATCHEDCMP*) ;;                # a label filter the rule extracted
      *) return 1 ;;  # ARM:stage-allowlist
    esac
  done <<< "$(printf '%s' "$rest" | tr '|' '\n' | tail -n +2)"

  return 0
}

# First-column backticked cells of the page's markdown tables. The page carries
# exactly TWO tables — the flag table (rows keyed on `--flag`) and the envelope
# table (rows keyed on a bare key) — so the leading `--` separates them with no
# section parsing. A third table added to the page would need this split
# revisited; the guard test below pins the count so that cannot happen silently.
page_table_keys() {
  grep -oE '^\| `[^`]+`' "$REF_PAGE" | sed -E 's/^\| `//; s/`$//'
}

# The body of one `## …` section of the reference page, so a needle asserted
# "in the boundary section" cannot be satisfied by a coincidental match in
# unrelated prose elsewhere on the page.
page_section() {
  awk -v want="$1" '
    /^## / { inside = ($0 == want) ; next }
    inside { print }
  ' "$REF_PAGE"
}

# The body of one `### …` subsection, stopping at the NEXT heading of any level.
# Needed where a `##` section carries several bullet lists and only one of them
# is the list under assertion.
#
# Deliberately fence-UNAWARE: a shell comment inside a future fenced block would
# truncate the section early. That fails CLOSED — the bullet-set equality below
# loses entries and reds — so it is a known limit, not a hazard.
page_subsection() {
  awk -v want="$1" '
    /^#+ / { inside = ($0 == want) ; next }
    inside { print }
  ' "$REF_PAGE"
}

# ------------------------------------------------------- the dashboard export

@test "the reference dashboard is parseable JSON" {
  run jq -e . "$DASH"
  [ "$status" -eq 0 ]
}

@test "the field manifest is parseable JSON" {
  run jq -e . "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "the export declares the DS_TELEMETRY datasource input for the loki plugin" {
  # The __inputs indirection is what lets a SECOND repo import this file: without
  # it the export would carry whatever uid this repo's Grafana happened to use.
  run jq -e '[.__inputs[] | select(.name == "DS_TELEMETRY"
             and .type == "datasource" and .pluginId == "loki")] | length == 1' "$DASH"
  [ "$status" -eq 0 ]
}

@test "every panel points at the DS_TELEMETRY input, never a hard-coded uid" {
  run jq -e '[.panels[].datasource] | unique == [{"type": "loki", "uid": "${DS_TELEMETRY}"}]' "$DASH"
  [ "$status" -eq 0 ]
}

@test "no hard-coded uid hides anywhere else in the export" {
  # Panel-level datasources are asserted above; targets carry their own, and a
  # stray environment-specific uid in any of them would break the import just as
  # badly. Every uid in the file must be the input placeholder or null.
  run jq -e '[.. | objects | select(has("uid")) | .uid]
             | map(select(. != null and . != "${DS_TELEMETRY}")) | length == 0' "$DASH"
  [ "$status" -eq 0 ]
}

@test "the dashboard carries exactly the four contract panels" {
  run jq -r '[.panels[].title] | sort | .[]' "$DASH"
  [ "$status" -eq 0 ]
  [ "$output" = "$(expected_titles | LC_ALL=C sort)" ]
}

@test "every panel has at least one target with a non-null, non-empty expr" {
  # panel_exprs itself raises on a null or empty expr, so the assignment below is
  # the real guard. (An earlier `lacks "$exprs" "null"` here was dead once that
  # landed — and worse than dead: it could only ever fire spuriously, on a future
  # query legitimately containing the substring `null`.)
  local titles t exprs
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ "$(printf '%s' "$exprs" | grep -c '')" -ge 1 ]
  done <<< "$titles"
}

@test "panel_exprs raises on a null or empty expr rather than yielding one" {
  # Pins the helper's contract directly, in the multi-target position where a
  # plain `jq -e` would have exited 0 (its status comes from the LAST value).
  local fixture="$BATS_TEST_TMPDIR/dash.json"
  DASH="$fixture"

  jq '(.panels[] | select(.title == "Outcome mix") | .targets)
      = [{"refId":"A","expr":null}, {"refId":"B","expr":"sum(count_over_time(({job=\"x\"} | json kind=\"kind\" | kind = \"run\")[$__auto]))"}]' \
    "$TELEMETRY_DIR/grafana/reference-dashboard.json" > "$fixture"
  run panel_exprs 'Outcome mix'
  [ "$status" -ne 0 ]
  contains "$output" "missing or empty expr in panel Outcome mix"

  jq '(.panels[] | select(.title == "Outcome mix") | .targets) = [{"refId":"A","expr":""}]' \
    "$TELEMETRY_DIR/grafana/reference-dashboard.json" > "$fixture"
  run panel_exprs 'Outcome mix'
  [ "$status" -ne 0 ]
  contains "$output" "missing or empty expr in panel Outcome mix"
}

@test "grep -o emits EVERY match on a line, which the occurrence counts rely on" {
  # Several checks depend on grep -o emitting EVERY match on a line, and the
  # suite runs on both GNU grep (ubuntu) and BSD grep (macos). If either returned
  # only the first match, extract_fields would see one identity pair per json
  # stage instead of all of them, and guard_expr's label-list scan would see
  # `on(job)` but not `group_left(repo)`. Both would then go RED — (c)'s set
  # equality and the group_left probe respectively — on that leg only. This test
  # exists to LOCALIZE that: without it, two seemingly unrelated failures on one
  # CI leg point nowhere near the grep behaviour that caused them.
  local n
  n="$(printf 'a|a|a' | grep -oF 'a' | grep -c '')"
  [ "$n" -eq 3 ]
  n="$(printf 'a|a|a' | grep -oE 'a' | grep -c '')"
  [ "$n" -eq 3 ]
}

# --------------------------------------------- the kind = "run" filter, per query
#
# The single most missable rule in the contract: an enrichment's `outcome`
# describes the enrichment event, so an unfiltered aggregation double-counts
# every enriched run. Asserted per AGGREGATION, not per panel — `Escalation rate`
# is a ratio of two `count_over_time` sub-queries, and dropping the filter from
# only the denominator silently inflates the run count while a bare `contains`
# still finds the needle in the numerator.

@test "every count_over_time aggregation carries its own filter, selector and interval" {
  local titles t exprs expr aggs fragment rem
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ -n "$exprs" ]
    while IFS= read -r expr; do
      # Per AGGREGATION, not per expr. A whole-expr count equality passes when a
      # filter merely MOVES — both filters landing in the numerator keeps the
      # totals equal while the denominator counts enrichments, which is exactly
      # the double-count the contract page calls the rule most likely to be
      # missed. Splitting on the aggregation keyword checks each one in place.
      aggs="$(printf '%s' "$expr" | grep -oF 'count_over_time(' | grep -c '')"
      [ "$aggs" -ge 1 ]
      # Split on the literal aggregation keyword with parameter expansion, not
      # awk: BSD awk (the macOS CI leg) treats RS as a regex and rejects the `(`.
      rem="$expr"
      while [ "${rem#*count_over_time\(}" != "$rem" ]; do
        rem="${rem#*count_over_time\(}"
        fragment="${rem%%count_over_time\(*}"
        contains "$fragment" 'kind = "run"'
        # Same reasoning, same seam, for the two properties that were previously
        # asserted EXISTENTIALLY over the whole target. `Escalation rate` has two
        # aggregations, so a `[5m]` hard-coded in the denominator — or a diverged
        # `{job="other"}` there — was satisfied by the numerator's copy and shipped
        # green. The guard cannot catch either: it allowlists the selector KEY,
        # never its value, and never looks at range vectors at all.
        contains "$fragment" '{job="claude-telemetry"}'
        matches "$fragment" '.*\[\$__(auto|range)\].*'
      done
      # NB: the LOOP is the per-aggregation seam; there is deliberately no
      # count-comparison assertion, which would be true by construction.
      # `[ "$aggs" -ge 1 ]` is the non-vacuity guard, the three per-fragment
      # assertions above are the actual checks.
    done <<< "$exprs"
  done <<< "$titles"
}

# --------------------------------------------------- per-panel grouping construct
#
# One @test per panel, so a failure names the panel. Asserting the GROUPING
# construct literally, because the field name alone is worthless as a needle: it
# already appears in the `| json` extraction stage, so `contains "$expr" outcome`
# passes with `by (outcome)` deleted — which collapses the panel to a single
# aggregate series and destroys its meaning.

# Per-panel, and per TARGET. `panel_exprs` exists because a second target is an
# ordinary Grafana edit; asserting against the newline-joined blob would only
# check the property EXISTENTIALLY, so a second target that dropped the grouping
# construct — or hard-coded `[5m]` instead of the dashboard interval — would pass.

@test "Runs over time buckets over the dashboard interval" {
  local exprs expr
  exprs="$(panel_exprs 'Runs over time')"
  [ -n "$exprs" ]
  while IFS= read -r expr; do
    contains "$expr" '[$__auto]'
    contains "$expr" 'sum(count_over_time('
  done <<< "$exprs"
}

@test "Outcome mix groups by outcome" {
  local exprs expr
  exprs="$(panel_exprs 'Outcome mix')"
  [ -n "$exprs" ]
  while IFS= read -r expr; do
    contains "$expr" 'sum by (outcome)'
  done <<< "$exprs"
}

@test "Escalation rate puts the escalated filter in the NUMERATOR only" {
  # Asserting merely that both `) / sum(` and the escalated filter appear
  # somewhere would pass on an INVERTED ratio — all-runs over escalated-runs —
  # which is a number greater than 1 rendered on a percentunit field clamped to
  # max 1, i.e. a stat panel silently pegged at 100%. The sibling per-aggregation
  # kind-filter test cannot see it either, since both halves stay filtered.
  #
  # The split is done PER TARGET: on a joined multi-target blob the `%%`/`#`
  # expansions would straddle a newline and `num`/`den` would be arbitrary.
  local exprs expr num den
  exprs="$(panel_exprs 'Escalation rate')"
  [ -n "$exprs" ]
  while IFS= read -r expr; do
    contains "$expr" ') / sum('
    num="${expr%%) / sum(*}"
    den="${expr#*) / sum(}"
    # guard: if the split marker ever vanished, both halves would equal the whole
    # expr and the two assertions below would contradict each other rather than
    # silently no-op
    [ "$num" != "$expr" ]
    contains "$num" 'outcome = "escalated"'
    lacks "$den" 'outcome = "escalated"'
  done <<< "$exprs"
  # The break the contract page and the panel description BOTH single out:
  # adding `by (outcome)` to the two halves does not blank the panel, it PEGS it.
  # The numerator's single {outcome="escalated"} series matches the denominator's
  # identically-labelled one, divides to a constant 1, and the other outcome
  # series are dropped — a clamped percentunit stat stuck at 100%, which reads as
  # plausible. It changes no extracted field and passes every guard arm, so this
  # is the only thing that can catch it.
  #
  # Asserted over the UNION (a negative check is stronger there), and as "carries
  # NO grouping clause at all" rather than the literal `sum by (`: LogQL takes the
  # clause in either position, so the postfix spelling `sum(…) by (outcome)`
  # produces the identical peg while never containing that substring. The
  # committed expr has no `by`/`without` token, so this cannot false-red.
  run grep -qE '(by|without)[[:space:]]*\(' <<< "$exprs"
  [ "$status" -ne 0 ]
  # …and the check really does reject both spellings
  run grep -qE '(by|without)[[:space:]]*\(' <<< 'sum(count_over_time((x)[$__range])) by (outcome)'
  [ "$status" -eq 0 ]
  run grep -qE '(by|without)[[:space:]]*\(' <<< 'sum by (outcome) (count_over_time((x)[$__range]))'
  [ "$status" -eq 0 ]
}

@test "Per-pipeline breakdown groups by pipeline" {
  local exprs expr
  exprs="$(panel_exprs 'Per-pipeline breakdown')"
  [ -n "$exprs" ]
  while IFS= read -r expr; do
    contains "$expr" 'sum by (pipeline)'
  done <<< "$exprs"
}

@test "the Escalation rate panel is a clamped percentunit field" {
  # The numerator/denominator test's stated rationale — an inverted ratio pegs a
  # stat panel at 100% — depends on this field config, so pin it rather than let
  # the reasoning silently become false.
  run jq -e '.panels[] | select(.title == "Escalation rate") | .fieldConfig.defaults
             | .unit == "percentunit" and .min == 0 and .max == 1' "$DASH"
  [ "$status" -eq 0 ]
}

@test "no query and no manifest entry references schema — the shared directory is v1-only" {
  # A missing-schema tolerance encoded here would be a standing claim that the
  # shared directory is mixed-version, which the contract says it is not.
  local titles t exprs
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ -n "$exprs" ]
    lacks "$exprs" "schema"
  done <<< "$titles"
  run jq -e '[.[][]] | index("schema") == null' "$MANIFEST"
  [ "$status" -eq 0 ]
}

# ------------------------------------------------- the three-way anti-drift check

@test "the manifest covers exactly the dashboard's panels" {
  run jq -r 'keys_unsorted | sort | .[]' "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "$(expected_titles | LC_ALL=C sort)" ]
}

@test "(a) every manifest field is a real envelope key, per the enforcer" {
  # WHOLE-KEY membership, not a substring: `contains` over the newline-joined
  # blob would accept a truncated or typo'd `outcom`, `run` or `pipe`, because
  # `outcome`, `run_id` and `pipeline` are all in there. An exact-line match is
  # the claim the test's title actually makes.
  local keys fields field
  keys="$(envelope_keys)"
  [ -n "$keys" ]
  fields="$(jq -r '.[][]' "$MANIFEST" | sort -u)"
  [ -n "$fields" ]
  while IFS= read -r field; do
    run grep -qxF "$field" <<< "$keys"
    [ "$status" -eq 0 ]
  done <<< "$fields"
}

@test "(b) every manifest field is present in its panel's queries as a whole token" {
  # Same defect, same fix: a bare substring check passes `kin` against
  # `kind="kind"`. The word-boundary form is what makes this assert presence of
  # the FIELD rather than of some prefix of another one.
  local titles t exprs declared field
  titles="$(jq -r 'keys_unsorted[]' "$MANIFEST")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ -n "$exprs" ]
    declared="$(jq -r --arg t "$t" '.[$t][]' "$MANIFEST")"
    [ -n "$declared" ]
    while IFS= read -r field; do
      run grep -qE "(^|[^A-Za-z0-9_])${field}([^A-Za-z0-9_]|$)" <<< "$exprs"
      [ "$status" -eq 0 ]
    done <<< "$declared"
  done <<< "$titles"
}

@test "(c) every rule-matched field reference in a query is declared in the manifest" {
  # The direction that actually stops drift: (b) alone would let an
  # un-manifested field hide inside a query. Every target is checked, and the
  # union across a panel's targets must equal that panel's manifest entry.
  local titles t exprs expr found declared
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ -n "$exprs" ]
    found=""
    while IFS= read -r expr; do
      found="$(printf '%s\n%s' "$found" "$(extract_fields "$expr")" | grep -v '^$' | sort -u)"
    done <<< "$exprs"
    [ -n "$found" ]
    declared="$(jq -r --arg t "$t" '.[$t][]' "$MANIFEST" | sort -u)"
    [ "$found" = "$declared" ]
  done <<< "$titles"
}

# ------------------------------------------------------ the rule's blind spots
#
# extract_fields is narrow by design, so it FAILS OPEN: a reference written with
# a regex filter, a numeric comparison, an unquoted comparison, or a bare `| json`
# stage (no parameters) is invisible to (c), and CI would stay green while an un-manifested field
# sat in a query. The closure guard below removes that hole from the other side —
# it keeps the committed queries inside the shapes the rule can see, so reaching
# for uncovered LogQL is a RED test rather than a silent gap.

@test "closure guard: every committed query stays inside the extraction rule's reach" {
  local titles t exprs expr
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    exprs="$(panel_exprs "$t")"
    [ -n "$exprs" ]
    while IFS= read -r expr; do
      run guard_expr "$expr"
      [ "$status" -eq 0 ]
    done <<< "$exprs"
  done <<< "$titles"
}

# ------------------------------------------- one probe per guard arm, at least
#
# These call the SAME `guard_expr` the test above does. That is the whole point:
# when the arms were inline and these probes hand-copied their expressions,
# deleting an arm left every probe green — a guard that could silently stop
# guarding while wearing a test implying it could not. Now removing any arm
# reddens the probe for that shape immediately.

@test "guard probe: a regex label filter is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | pipeline =~ ".*"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a negated regex label filter is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | pipeline !~ ".*"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a numeric comparison is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | wall_s > 0'
  [ "$status" -eq 1 ]
  run guard_expr '{job="x"} | json kind="kind" | wall_s < 9'
  [ "$status" -eq 1 ]
}

@test "guard probe: an unquoted comparison is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | issue = 5'
  [ "$status" -eq 1 ]
}

@test "guard probe: a spaceless label filter outside a json stage is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | outcome="failed"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a negated-regex LINE filter is rejected in both positions" {
  # Not the same shape as the label filter probed above. A line filter operates
  # on the raw record, carries none of `=`/`<`/`>`, and sits either before the
  # first stage or trailing after a rule-matched filter — the two places the
  # stage allowlist cannot reach.
  run guard_expr '{job="x"} !~ "escalated" | json kind="kind" | kind = "run"'
  [ "$status" -eq 1 ]
  run guard_expr '{job="x"} | json kind="kind" | kind = "run" !~ "escalated"'
  [ "$status" -eq 1 ]
}

@test "guard probe: grouping on a label no json stage extracts is rejected" {
  # `by (…)` lives in the aggregation prefix, which the stage loop skips — this
  # is the only arm that looks at it.
  run guard_expr 'sum by (repo) (count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
  # …and the committed shape, whose grouping label IS extracted, still passes
  run guard_expr 'sum by (outcome) (count_over_time(({job="x"} | json kind="kind", outcome="outcome" | kind = "run")[$__range]))'
  [ "$status" -eq 0 ]
}

@test "guard probe: the without spelling of the label list is checked too" {
  # Without this, dropping `|without` from either the grep or the sed — a
  # one-token edit — would red nothing while `sum without (repo)` started
  # passing.
  run guard_expr 'sum without (repo) (count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
  run guard_expr 'sum without (outcome) (count_over_time(({job="x"} | json kind="kind", outcome="outcome" | kind = "run")[$__range]))'
  [ "$status" -eq 0 ]
}

@test "guard probe: the vector-matching label lists are checked too" {
  # `on`/`ignoring`/`group_left` name labels in the metric layer, the same
  # position as `by (…)` and equally invisible to the extraction rule.
  run guard_expr 'sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])) and on(repo) sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
  run guard_expr 'sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])) and ignoring(repo) sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
  # …and the two many-to-one spellings, so no alternative in the arm's regex is
  # unpinned. Dropping `|group_left|group_right` is a one-token edit.
  run guard_expr 'sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])) * on(job) group_left(repo) sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
  run guard_expr 'sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])) * on(job) group_right(repo) sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
}

@test "guard probe: a multi-label grouping is checked label by label" {
  # Pins the comma split: without it the arm would look for one label literally
  # named `outcome, pipeline` and red every legitimate multi-label grouping.
  run guard_expr 'sum by (outcome, pipeline) (count_over_time(({job="x"} | json kind="kind", outcome="outcome", pipeline="pipeline" | kind = "run")[$__range]))'
  [ "$status" -eq 0 ]
  run guard_expr 'sum by (outcome, repo) (count_over_time(({job="x"} | json kind="kind", outcome="outcome" | kind = "run")[$__range]))'
  [ "$status" -eq 1 ]
}

@test "guard probe: a stream selector may only match on job" {
  # `{…}` is stripped before every other arm, so a matcher on a promoted
  # envelope label would otherwise be an unguarded read.
  run guard_expr '{job="x", outcome="escalated"} | json kind="kind" | kind = "run"'
  [ "$status" -eq 1 ]
  run guard_expr '{job="claude-telemetry", filename=~"timo-jakob-.*"} | json kind="kind" | kind = "run"'
  [ "$status" -eq 1 ]
  # grouping on the allowed stream label is legitimate and must NOT red
  run guard_expr 'sum by (job) (count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range]))'
  [ "$status" -eq 0 ]
}

@test "guard probe: a label-rewriting function is rejected in both spellings" {
  run guard_expr 'label_replace(sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])), "dst", "$1", "repo", "(.*)")'
  [ "$status" -eq 1 ]
  # `label_join` is named in the arm and on both pages; without its own probe,
  # deleting `|label_join` from the alternation would red nothing.
  run guard_expr 'label_join(sum(count_over_time(({job="x"} | json kind="kind" | kind = "run")[$__range])), "dst", ",", "repo", "pipeline")'
  [ "$status" -eq 1 ]
}

@test "guard probe: two shapes the guard deliberately rejects TODAY, pinned as decisions" {
  # Neither is a defect; both are limits worth meeting as a decision rather than
  # as a surprise red. If a future story needs either, extend the rule AND the
  # guard together and change these probes deliberately.
  #
  # 1. a nested-path extraction — `payload.event` cannot be written in identity
  #    form, so the enrichment panels epic 3 will want are not expressible yet.
  run guard_expr '{job="x"} | json event="payload.event" | kind = "run"'
  [ "$status" -eq 1 ]
  # 2. any stream-selector label other than `job`, even a legitimate one a
  #    reporting repo might add (e.g. an environment label).
  run guard_expr '{job="x", env="prod"} | json kind="kind" | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a query with no rule-visible json stage is rejected" {
  # The `[ -z "$stages" ]` arm. Every other probe carries a well-formed
  # `| json kind="kind"`, so without this one that arm is unexercised — and an
  # editor "tidying" it to `return 0` ("no json stage, nothing to guard") would
  # let a SPACELESS `|json` through in silence. Note WHY that is dangerous: it is
  # not auto-extraction (that is the BARE `| json` arm below) — `|json kind="kind"`
  # extracts exactly `kind`. It is that the extraction rule's `[|] json ` pattern
  # requires the space, so the stage's identity pairs go unextracted while the
  # query still reads those fields.
  run guard_expr '{job="x"} |json kind="kind" | kind = "run"'
  [ "$status" -eq 1 ]
  run guard_expr '{job="x"} | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a backquoted json parameter is rejected" {
  # Named as rejected by the guard's comment and by the contract page; without a
  # probe it is rejected only incidentally, by the pairs regex failing to match.
  run guard_expr '{job="x"} | json `kind`="kind" | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a comparison OUTSIDE any pipeline stage is rejected" {
  # The stage allowlist below splits on `|` and skips the first segment, so a
  # metric-level comparison written after the aggregation lives in no stage at
  # all and reaches only the operator check. Without this probe that check looks
  # redundant — removing it reddens nothing — and the next editor deletes it.
  run guard_expr 'sum(count_over_time(({job="x"} | json kind="kind")[$__auto])) > 5'
  [ "$status" -eq 1 ]
}

@test "guard probe: unwrap is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | unwrap wall_s'
  [ "$status" -eq 1 ]
}

@test "guard probe: line_format is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | line_format "{{.tokens}}"'
  [ "$status" -eq 1 ]
}

@test "guard probe: label_format is rejected" {
  run guard_expr '{job="x"} | json kind="kind" | label_format p=pipeline'
  [ "$status" -eq 1 ]
}

@test "guard probe: a bare json stage is rejected" {
  # Loki would auto-extract EVERY envelope key, so `sum by (repo)` becomes a real
  # reference to `repo` that extract_fields cannot see.
  run guard_expr '{job="x"} | json | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: LogQL's shorthand json parameter is rejected" {
  # `| json kind, outcome` is shorthand for the identity pairs — a genuine read
  # of two fields matching no `name="name"` pattern.
  run guard_expr '{job="x"} | json kind="kind", outcome | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: a renaming json assignment is rejected" {
  run guard_expr '{job="x"} | json p="pipeline" | kind = "run"'
  [ "$status" -eq 1 ]
}

@test "guard probe: another auto-extracting parser stage is rejected without being named" {
  # The allowlist half. `logfmt` and `unpack` are as auto-extracting as a bare
  # `| json`; nothing in guard_expr mentions either by name, and both still red —
  # which is what makes the next construct nobody thought of fail closed too.
  run guard_expr '{job="x"} | json kind="kind" | logfmt'
  [ "$status" -eq 1 ]
  run guard_expr '{job="x"} | json kind="kind" | unpack'
  [ "$status" -eq 1 ]
}

@test "guard probe: a rule-visible query with generous whitespace is ACCEPTED" {
  # The guard must never red a query the rule handles: extract_fields' rule 2
  # accepts any run of whitespace around the operator, so the guard's
  # neutralisation has to as well. A false red here is what invites someone to
  # weaken the check.
  run guard_expr '{job="x"} | json kind="kind" | kind  =  "run"'
  [ "$status" -eq 0 ]
  run guard_expr '{job="x"} | json kind="kind" | outcome != "failed"'
  [ "$status" -eq 0 ]
}

# ------------------------------------------------ the arm <-> probe harness
#
# Both docs pages and ARCHITECTURE.md state that every `guard_expr` arm is pinned
# by at least one probe, so that narrowing the guard reddens a test instead of
# quietly widening the hole. Until now that pairing was maintained by REVIEW, and
# it had already gone false twice — `group_left`/`group_right` and `label_join`
# were named in an arm while no probe exercised them (#1008 review rounds 5-6).
#
# This makes the claim true BY CONSTRUCTION: each rejection site in `guard_expr`
# carries an `# ARM:<name>` marker; the test neutralises one arm at a time (the
# `return 1` becomes a no-op, leaving every OTHER arm live) and requires the
# probe suite to fail. An arm added without a probe fails here immediately.
#
# The mutant runs from $BATS_TEST_TMPDIR with a copy of assertions.bash beside it
# (bats resolves `load` relative to the test file), filtered to `guard probe` —
# those probes call `guard_expr` and nothing else, so they need no repo paths.

# Every `# ARM:<name>` marker in this file, one name per line.
guard_arm_names() {
  grep -oE '# ARM:[a-z-]+' "$BATS_TEST_FILENAME" | sed 's/^# ARM://' | LC_ALL=C sort -u
}

# A copy of this file with ONE arm's rejection neutralised.
_mutant_for() {
  local arm="$1" dir="$2"
  cp "$BATS_TEST_DIRNAME/assertions.bash" "$dir/assertions.bash"
  sed "s|return 1\(.*# ARM:${arm}\$\)|:\1|" "$BATS_TEST_FILENAME" > "$dir/mutant.bats"
}

@test "harness control: an UNMUTATED copy passes the probe suite" {
  # Without this, a harness whose mutant could never run (a bad copy, an
  # unresolvable `load`) would report every arm as pinned while proving nothing.
  local dir="$BATS_TEST_TMPDIR/control"
  mkdir -p "$dir"
  _mutant_for '__no_such_arm__' "$dir"
  run bats --filter 'guard probe' "$dir/mutant.bats"
  [ "$status" -eq 0 ]
  contains "$output" "ok "
}

@test "every guard arm is pinned: neutralising it reddens at least one probe" {
  local arms arm dir
  arms="$(guard_arm_names)"
  [ -n "$arms" ]
  # the marker set must not silently shrink
  [ "$(printf '%s' "$arms" | grep -c '')" -ge 8 ]
  while IFS= read -r arm; do
    dir="$BATS_TEST_TMPDIR/mut-$arm"
    mkdir -p "$dir"
    _mutant_for "$arm" "$dir"
    # the mutation must actually have changed the file, or this proves nothing
    run diff -q "$BATS_TEST_FILENAME" "$dir/mutant.bats"
    [ "$status" -ne 0 ]
    run bats --filter 'guard probe' "$dir/mutant.bats"
    [ "$status" -ne 0 ]
  done <<< "$arms"
}

@test "the extraction rule rejects a stream selector and a renaming assignment" {
  # Guards the rule itself. If either half loosened, (c) would start extracting
  # non-fields and would fail on a CORRECT dashboard — a false red that invites
  # someone to weaken the check.
  local got
  got="$(extract_fields '{job="claude-telemetry"} | json kind="kind" | kind = "run"')"
  [ "$got" = "kind" ]
  got="$(extract_fields '{job="x"} | json short="pipeline" | kind = "run"')"
  [ "$got" = "kind" ]
}

@test "the extraction rule rejects a stream selector that appears AFTER a json stage" {
  # The case above proves nothing about the whitespace requirement: a selector
  # written before the first `| json` is removed by the prefix strip, so the rule
  # never runs on it, and relaxing `[[:space:]]+` to `*` would leave it green.
  # The committed Escalation-rate query is a ratio, so it really does carry a
  # second `{job="…"}` past the first parser stage — this is that shape.
  local got
  got="$(extract_fields '{job="x"} | json kind="kind" | kind = "run" / {job="claude-telemetry"} | json kind="kind"')"
  [ "$got" = "kind" ]
}

@test "the extraction rule matches the != spelling of a label filter" {
  # The `!?` branch of rule 2 is otherwise exercised by nothing — the committed
  # queries only use `=`, so that half could break unnoticed.
  local got
  got="$(extract_fields '{job="x"} | json kind="kind" | outcome != "failed"')"
  [ "$got" = "$(printf 'kind\noutcome')" ]
}

@test "(c) would catch an un-manifested field sneaking into a query" {
  # Proves the assertion has teeth rather than passing vacuously: an extra
  # extracted field must not equal the manifest's declared set.
  local found declared
  found="$(extract_fields "$(panel_exprs 'Outcome mix')
    | json repo_type=\"repo_type\"")"
  declared="$(jq -r '.["Outcome mix"][]' "$MANIFEST" | sort -u)"
  contains "$found" "repo_type"
  [ "$found" != "$declared" ]
}

# ------------------------------------------------------ the contract page

@test "the reference page carries a section for each of the six contract topics" {
  local heading
  for heading in "## Where" "## The glob" "## The envelope" "## The join" \
                 "## Legacy" "## Versioning"; do
    run grep -qxF "$heading" "$REF_PAGE"
    [ "$status" -eq 0 ]
  done
}

@test "the provides/does-not-provide section names each concern as its own bullet" {
  # Asserted against the SECTION, and on the bullet form: "Grafana stack" and
  # "aggregation service" both also occur in unrelated prose elsewhere on the
  # page, so a whole-page substring check would stay green with the boundary
  # bullets deleted.
  local section
  section="$(page_section '## What this repo provides / does not provide')"
  [ -n "$section" ]
  contains "$section" "- The **Grafana stack**"
  contains "$section" "- **Datasource provisioning**"
  contains "$section" "- The **aggregation service**"
  contains "$section" "- **Deployment**"
  contains "$section" "owner-verified once on import and is deliberately not a"
  contains "$section" "CI gate here"
}

@test "the reference page names the loki plugin id and the LogQL dialect" {
  run cat "$REF_PAGE"
  [ "$status" -eq 0 ]
  contains "$output" "LogQL"
  contains "$output" "loki"
  # …and the id it names is the one every panel actually uses
  run jq -e '[.panels[].datasource.type] | unique == ["loki"]' "$DASH"
  [ "$status" -eq 0 ]
}

@test "the reference page carries exactly the two tables this suite assumes" {
  # page_table_keys() splits flag rows from envelope rows on a leading `--`.
  # A third table would silently pollute one of those sets.
  run grep -cE '^\| --- \|' "$REF_PAGE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "the envelope table lists exactly the keys the enforcer prints" {
  local documented enforced
  documented="$(page_table_keys | grep -v '^--' | sort)"
  enforced="$(envelope_keys | sort)"
  [ -n "$enforced" ]
  [ "$documented" = "$enforced" ]
  [ "$(envelope_keys | grep -c '')" -eq 14 ]
}

@test "the page's pasted key array matches the enforcer byte for byte, order included" {
  # The page shows the flag's output verbatim in a console block — the exact spot
  # a consumer repo copy-pastes from, and a second source of truth the sorted
  # table comparison above would never catch drifting. This also pins key ORDER,
  # which that comparison deliberately does not.
  local pasted
  pasted="$(grep -m1 '^\["schema"' "$REF_PAGE")"
  [ -n "$pasted" ]
  [ "$pasted" = "$(zsh "$VALIDATE" --print-envelope-keys)" ]
}

@test "every envelope-table row carries a type cell and a nullability cell" {
  local keys key row
  keys="$(envelope_keys)"
  [ -n "$keys" ]
  while IFS= read -r key; do
    row="$(grep -F "| \`$key\` |" "$REF_PAGE")"
    [ -n "$row" ]
    # 4 pipes = 3 cells: key | type | nullability
    [ "$(printf '%s' "$row" | tr -cd '|' | wc -c | tr -d ' ')" -eq 4 ]
    # neither trailing cell may be blank
    run bash -c "printf '%s' \"\$1\" | grep -qE '^\| \`[^\`]+\` \| +[^ |][^|]* \| +[^ |][^|]* \|\$'" _ "$row"
    [ "$status" -eq 0 ]
  done <<< "$keys"
}

@test "every flag the page documents really exists in that script's --help" {
  # The guard that stops the page documenting a flag before it ships.
  local rows row flag script help
  rows="$(grep -E '^\| `--' "$REF_PAGE")"
  [ -n "$rows" ]
  while IFS= read -r row; do
    flag="$(printf '%s' "$row" | sed -E 's/^\| `([^`]+)`.*/\1/')"
    script="$(printf '%s' "$row" | sed -E 's/^\| `[^`]+` \| `([^`]+)`.*/\1/')"
    # Shape assertions, not `[ -n … ]`: `sed -E` echoes a non-matching line
    # UNCHANGED, so both variables are non-empty whether the extraction worked or
    # not. Worse, a failed flag extraction would splice the whole markdown row
    # into the ERE below, where its `|` characters become alternation and the
    # first branch matches almost any help text — silently undoing the
    # whole-token match this test depends on.
    starts_with "$flag" "--"
    ends_with "$script" ".zsh"
    [ -f "$TELEMETRY_DIR/$script" ]
    help="$(zsh "$TELEMETRY_DIR/$script" --help 2>&1)"
    # WHOLE-FLAG match. A substring check defeats this test's entire purpose: a
    # page row for a non-existent `--repo` or `--telemetry` would pass, because
    # `--repo-dir` and `--telemetry-dir` are in the help text.
    run grep -qE -- "(^|[^-A-Za-z0-9_])${flag}([^-A-Za-z0-9_]|$)" <<< "$help"
    [ "$status" -eq 0 ]
  done <<< "$rows"
}

@test "the flag table is not empty — the --help cross-check must not pass vacuously" {
  run bash -c "grep -cE '^\| \`--' '$REF_PAGE'"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "the page states the time-axis dependency the queries cannot express" {
  # count_over_time buckets by the Loki entry timestamp, not by the record's
  # `ts`. Leaving that unsaid would promise record time and silently deliver
  # ingest time on any backfill or re-scrape.
  run cat "$REF_PAGE"
  [ "$status" -eq 0 ]
  contains "$output" "must promote the record's \`ts\` onto the"
  contains "$output" "entry timestamp"
}

@test "the page does not present the shared sink as already wired into pipelines" {
  # No pipeline forwards --telemetry-dir yet (ARCHITECTURE.md says so); an
  # unqualified page would send a reader debugging the emitter or the reporting
  # repo instead of reading the open caller-wiring gap.
  run cat "$REF_PAGE"
  [ "$status" -eq 0 ]
  contains "$output" "No pipeline forwards \`--telemetry-dir\` yet"
}

# ------------------------------------------------------------- registration

@test "both new pages are registered in the nav, the MOC and their section index" {
  local page
  for page in reference/telemetry-grafana-handoff.md explanation/telemetry-grafana-handoff.md; do
    run grep -qF "$page" "$REPO_ROOT/mkdocs.yml"
    [ "$status" -eq 0 ]
    run grep -qF "$page" "$REPO_ROOT/docs/index.md"
    [ "$status" -eq 0 ]
  done
  run grep -qF "telemetry-grafana-handoff.md" "$REPO_ROOT/docs/reference/index.md"
  [ "$status" -eq 0 ]
  run grep -qF "telemetry-grafana-handoff.md" "$REPO_ROOT/docs/explanation/index.md"
  [ "$status" -eq 0 ]
}

@test "the prose this suite asserts on is inside the script-tests path filter" {
  # The suite gates docs/reference, the MOC and the nav. If the workflow did not
  # trigger on them, a docs-only PR could delete an envelope row or a nav entry
  # and land red on main instead of red on the PR.
  local wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  local path
  for path in "docs/reference/**" "docs/index.md" "mkdocs.yml" "docs/explanation/**"; do
    run grep -qF "'$path'" "$wf"
    [ "$status" -eq 0 ]
  done
}

@test "the page's panel list names exactly the dashboard's panels" {
  # The envelope table and the flag table are both cross-checked against their
  # source; the panel bullets were not, so a renamed panel would leave the page
  # describing one that no longer exists.
  local section titles t
  section="$(page_subsection '### The four panels')"
  [ -n "$section" ]
  titles="$(jq -r '.panels[].title' "$DASH")"
  [ -n "$titles" ]
  while IFS= read -r t; do
    contains "$section" "- **$t**"
  done <<< "$titles"
  # …and the converse the title promises: no bullet for a panel that no longer
  # exists. One direction alone would leave a deleted panel described forever.
  local bullets
  bullets="$(printf '%s' "$section" | grep -oE '^- \*\*[^*]+\*\*' | sed -E 's/^- \*\*//; s/\*\*$//' | LC_ALL=C sort)"
  [ -n "$bullets" ]
  [ "$bullets" = "$(printf '%s' "$titles" | LC_ALL=C sort)" ]
}

@test "the explanation page exists and answers its three why questions" {
  run cat "$EXP_PAGE"
  [ "$status" -eq 0 ]
  contains "$output" "## Why the Grafana stack lives in another repo"
  contains "$output" "## Why the envelope is closed"
  contains "$output" "## Why the hand-off is a committed artifact"
}

@test "the explanation page scopes its coverage claim to instrumented pipelines" {
  # "Every pipeline appends one line" was false: only review-loop and
  # refine-issue are retrofitted.
  run cat "$EXP_PAGE"
  [ "$status" -eq 0 ]
  contains "$output" "Every **instrumented** pipeline"
  lacks "$output" "Every pipeline in this family appends"
}
