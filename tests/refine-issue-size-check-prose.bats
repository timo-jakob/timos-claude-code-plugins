#!/usr/bin/env bats
#
# The prose half of sizing a story while a human is present (#2589). The two
# scripts have their own suites (size-check.bats, file-split-children.bats);
# these needles pin the rules that make the agents and skills run them:
#
#   - story-readiness runs size-check.zsh, fails check 2 on a stop, and reports
#     an additive top-level `size` object while `checks` keeps its five keys;
#   - refine-issue never writes back a draft that stops, offers a split instead,
#     and files an accepted split only through file-split-children.zsh;
#   - refine-issue's Step 7 carries the optional size_preflight key;
#   - resolve-issue §2(b) says refine-issue files the accepted split's children.
#
# Each needle is anchored by content, never by line (#1189).

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/development/agents/story-readiness.md"
  REFINE="$REPO_ROOT/development/skills/refine-issue/SKILL.md"
  RESOLVE="$REPO_ROOT/development/skills/resolve-issue/SKILL.md"
}

# The lines of the section headed exactly $1 in $2, up to the next heading of
# the same or a higher level; fenced lines are never read as headings.
section() {
  awk -v h="$1" '
    /^```/ { fence = !fence }
    !fence && $0 == h { f = 1; match(h, /^#+/); lvl = RLENGTH; next }
    f && !fence && /^#+ / { match($0, /^#+/); if (RLENGTH <= lvl) exit }
    f' "$2"
}

# --- story-readiness ---------------------------------------------------------

@test "story-readiness runs size-check.zsh on a declared inventory" {
  grep -qF -- '- **Size the story'"'"'s declared inventory** (#2589).' "$GATE"
  grep -qF 'zsh <resolved path> --file <inventory.json>' "$GATE"
  grep -qF 'skills/refine-issue/scripts/size-check.zsh(N.nOn[1])' "$GATE"
}

@test "story-readiness fails check 2 on a size stop and never on a skip" {
  local c2
  c2="$(sed -n '/^2\. \*\*Scope is bounded\.\*\*/,/^3\. /p' "$GATE")"
  [ -n "$c2" ]
  contains "$c2" "A declared inventory that"
  contains "$c2" "stops also fails this check"
  contains "$c2" 'set `scope_bounded:'
  contains "$c2" "names the trigger and its count"
  contains "$c2" 'A
   `skipped` size never fails this check.'
  contains "$c2" "This stop has no override"
}

@test "story-readiness treats an unjudged inventory as skipped, never as a stop" {
  grep -qF 'Record `size.verdict` as `skipped`: an unjudged inventory never' "$GATE"
}

@test "story-readiness branches on every size-check exit, and builds the inventory as a judgement" {
  grep -qF -- '- **`0`** — `pass`, or `skipped` (an empty inventory). Size does not fail the' "$GATE"
  grep -qF -- '- **`1`** — `stop`. Check 2 fails (below).' "$GATE"
  grep -qF -- '- **`2`** — your own malformed call: fix it and re-run once.' "$GATE"
  grep -qF -- '- **`3`**, a second `2`, or no copy anywhere — the inventory could not be' "$GATE"
  grep -qF '`{"files": [ … ]}` to a temporary file outside the repository, and an empty' "$GATE"
  grep -qF 'you never judge size yourself, and you never restate a' "$GATE"
  grep -qF 'the size check reported (`0` and `0` when `skipped`). Copy them from' "$GATE"
}

@test "story-readiness reports an additive size object and keeps checks at five keys" {
  grep -qF -- '- `size` (#2589) is always present, and **additive**: `checks` keeps exactly' "$GATE"
  grep -qF '"size": { "verdict": "pass", "triggers": [], "files": 6, "plugins": 1,' "$GATE"
  grep -qF '"inventory": ["src/jobs/api.py",' "$GATE"
  # the example's checks object still holds exactly the five keys
  local checks
  checks="$(sed -n '/^```json$/,/^```$/p' "$GATE" | sed -n '/"checks": {/,/}/p')"
  [ "$(printf '%s\n' "$checks" | grep -cE '^ +"[a-z_]+": (true|false),?$')" -eq 5 ]
}

# --- refine-issue ------------------------------------------------------------

@test "refine-issue never writes back a draft that stops the size check" {
  local s
  s="$(section '### Step 2 — size the draft before approval (#2589)' "$REFINE")"
  [ -n "$s" ]
  contains "$s" "**Never write back a draft whose declared inventory stops the size check.**"
  contains "$s" '"<skill-base-dir>/scripts/size-check.zsh" --file <inventory.json>'
  contains "$s" "- **Exit 1** — \`stop\`. Do **not** present the draft for approval."
  contains "$s" "- **Exit 2** — your own malformed call: fix it and re-run once."
  contains "$s" "- **Exit 3, or a second 2** — the inventory could not be judged."
  contains "$s" "- **2** — your own malformed call: fix it and re-run once."
  contains "$s" "in by you: show no children and ask once — **Revise the draft** or **Park as"
  contains "$s" "\`deferred\`** (the typed parked exit below), never the \`split-recommended\`"
  contains "$s" "**skip Steps 2.5–6**"
  contains "$s" 'Set `STATE_OUTCOME="parked"`, `PARK_TYPE="split-recommended"`'
  contains "$s" "still stops; **nothing was written**"
  contains "$s" "Relay its stderr and offer the parked exit."
  contains "$s" "refiner's \`proposed_split\` into a plan file as \`children\`"
  # convergence routes through the size check before approval
  grep -qF 'Then **size the draft** (*Step 2 — size' "$REFINE"
}

@test "refine-issue offers a split and files it only through file-split-children.zsh" {
  local s
  s="$(section '### Step 2 — size the draft before approval (#2589)' "$REFINE")"
  contains "$s" "propose a split into child stories, each a bounded"
  contains "$s" "**File these N child stories (Recommended)**"
  contains "$s" '"<skill-base-dir>/scripts/file-split-children.zsh" --repo "$REPO" --parent <N> --plan <plan.json>'
  contains "$s" 'and `SIZE_PREFLIGHT`'"'"'s `children_filed` to the length of its `filed` list'
  contains "$s" "Never re-run it — a re-run"
  contains "$s" "- **Exit 0** — \`pass\` or \`skipped\`: present the draft for approval as above."
  contains "$s" "an empty \`files\` array when no concrete path can be"
  contains "$s" 'Record the run as for exit 0, with
  `children_filed` the length of the report'"'"'s `filed` list'
  grep -qF -- '- **Size every draft; never write back one that stops (#2589).**' "$REFINE"
  # the split's source is a field of issue-refiner's output contract
  grep -qF -- '- **`proposed_split`** (#2589) — `null`, unless an objection says the draft'"'"'s' \
    "$REPO_ROOT/development/agents/issue-refiner.md"
}

@test "refine-issue lets the LAST readiness verdict's size win" {
  grep -qF 'Unlike `RISK`, the **last** readiness verdict'"'"'s `size` wins: Step 4'"'"'s re-gate' "$REFINE"
  grep -qF 'replaces it. A verdict with no `size` object leaves it empty.' "$REFINE"
  grep -qF 'split choice of Step 2'"'"'s size-check exit 1, converged or not.' "$REFINE"
}

@test "refine-issue records the gate's size into SIZE_PREFLIGHT and Step 7 carries it" {
  grep -qF '**Record the verdict'"'"'s `size` object too** (#2589)' "$REFINE"
  grep -qF '`SIZE_PREFLIGHT` from its `size` object (Step 1)' "$REFINE"
  # both re-assign lists name it: Step 2's rule and Step 7's
  grep -qF '`ROUNDS`, `RAISED`, `RESOLVED`, `SIZE_PREFLIGHT` and `PAUSED_S`, and its guard reads them' "$REFINE"
  grep -qF '`SIZE_PREFLIGHT` and `PAUSED_S` must all be' "$REFINE"
  local code
  code="$(section '## Step 7 — emit telemetry (every decided ending, #579)' "$REFINE" \
          | sed -n '/^```bash/,/^```$/p')"
  [ -n "$code" ]
  contains "$code" '--arg size "${SIZE_PREFLIGHT:-}"'
  contains "$code" '+ (if $size == "" then {} else {size_preflight: ($size | fromjson)} end)'
  # never guarded: the guard's condition does not name it
  lacks "$(printf '%s\n' "$code" | sed -n '/^if \[\[/,/then$/p')" "SIZE_PREFLIGHT"
}

@test "Step 7's state jq with a SIZE_PREFLIGHT reaches the builder as a valid state" {
  # Execute the fence's state jq, not just its text: a SIZE_PREFLIGHT the
  # documented form produces must yield a state the builder accepts.
  local expr state
  expr="$(section '## Step 7 — emit telemetry (every decided ending, #579)' "$REFINE" \
          | sed -n "/^        '{rounds:/,/> \"\$STATE\"/p" | sed -e "s/^ *'//" -e "s/' > \"\$STATE\" \\\\\$//")"
  [ -n "$expr" ]
  state="$(jq -n --arg rounds 2 --arg raised 1 --arg resolved 0 --arg outcome parked \
             --arg park_type split-recommended --arg risk normal \
             --arg size '{"verdict":"stop","triggers":["files"],"children_filed":3}' "$expr")"
  printf '%s' "$state" > "$BATS_TEST_TMPDIR/state.json"
  run zsh "$REPO_ROOT/development/skills/refine-issue/scripts/build-refine-telemetry-record.zsh" \
    --state "$BATS_TEST_TMPDIR/state.json"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -c '.size_preflight')" = '{"verdict":"stop","triggers":["files"],"children_filed":3}' ]
  # and an empty SIZE_PREFLIGHT leaves the key out
  state="$(jq -n --arg rounds 0 --arg raised 0 --arg resolved 0 --arg outcome refined-ready \
             --arg park_type "" --arg risk "" --arg size "" "$expr")"
  [ "$(printf '%s' "$state" | jq 'has("size_preflight")')" = false ]
}

# --- resolve-issue §2(b) -----------------------------------------------------

@test "resolve-issue §2(b) says refine-issue files the accepted split's children" {
  grep -qF '`/development:refine-issue`, which, once the human accepts a split there,' "$RESOLVE"
  grep -qF '**files the children as native sub-issues** of this story (#2589).' "$RESOLVE"
  # the retired claim is gone
  run -1 grep -qF 'parks — it files nothing' "$RESOLVE"
}

# --- #2602: refine-issue reads resolve-issue's size park ----------------------

@test "#2602 refine-issue Step 0 reads the size park, and a live objection satisfies the precondition" {
  local t; t="$(tr '\n' ' ' < "$REFINE" | tr -s ' ')"
  grep -qF '**Read resolve-issue' <<< "$t"
  grep -qF '"<skill-base-dir>/scripts/read-split-park.zsh" > /tmp/split-park.json' "$REFINE"
  grep -qF 'A live size objection satisfies it: resolve-issue sent the story here, so do not ask.' <<< "$t"
  grep -qF 'looks stale: tell the human so, and change no label.' <<< "$t"
  grep -qF 'An exit 2 or 3 prints nothing: report its stderr and continue without a size objection' <<< "$t"
}

@test "#2602 refine-issue Step 1 re-sizes the inventory, suppresses the READY shortcut and asks for a split" {
  local t; t="$(tr '\n' ' ' < "$REFINE" | tr -s ' ')"
  grep -qF '**A live size objection (#2602)** comes from Step 0' <<< "$t"
  grep -qF 'Exit 1: the objection carries the re-sized triggers and counts.' <<< "$t"
  grep -qF 'Exit 0: the plan now passes, so there is **no** objection' <<< "$t"
  grep -qF 'the objection carries the reader' <<< "$t"
  grep -qF '**While it is open, the `READY` shortcut below is not offered**' <<< "$t"
  grep -qF 'ask the first refiner turn for a split, each child a bounded story with its own declared inventory.' <<< "$t"
  grep -qF 'even on a `READY` verdict: go to Step 2, and ask the first refiner turn for a split' <<< "$t"
  grep -qF 'Its first non-null `proposed_split` goes to the plan file and split choice of Step 2' <<< "$t"
  grep -qF 's size-check exit 1, which with an inventory is the re-sized stop.' <<< "$t"
  grep -qF 'write it to a file and run `size-check.zsh --file <it>` from the repository root.' <<< "$t"
  grep -qF 'Append the size objection to the verdict' <<< "$t"
}

@test "#2602 refine-issue never sets or clears needs-split itself, and states each ending" {
  local t; t="$(tr '\n' ' ' < "$REFINE" | tr -s ' ')"
  grep -qF '**`needs-split` is never yours to set or clear.**' <<< "$t"
  grep -qF 'its exit 5 leaves the original' <<< "$t"
  grep -qF 'A rewrite that narrows the story instead, or any typed parked exit, leaves it on' <<< "$t"
  run grep -cE -- '--(add|remove)-label needs-split' "$REFINE"
  [ "$output" = "0" ]
}

@test "#2602 ARCHITECTURE.md and the refine-issue workflow page describe the park marker and its reader" {
  local a; a="$(tr '\n' ' ' < "$REPO_ROOT/ARCHITECTURE.md" | tr -s ' ')"
  grep -qF '**The park carries its inventory (#2602).**' <<< "$a"
  grep -qF 'the `needs-split` label is the switch, and the newest size pre-flight comment is the evidence.' <<< "$a"
  grep -qF 'It never sets or clears `needs-split` itself.' <<< "$a"
  local w; w="$(tr '\n' ' ' < "$REPO_ROOT/docs/explanation/workflow-refine-issue.md" | tr -s ' ')"
  grep -qF 'A story that resolve-issue' <<< "$w"
  grep -qF 'arrives with that objection already open' <<< "$w"
}
