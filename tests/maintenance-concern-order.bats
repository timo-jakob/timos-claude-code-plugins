#!/usr/bin/env bats
#
# #3211: a full /development:maintenance run works its plan in one documented
# order between concerns — security, dependencies, bugs, codequality, then the
# topic plugins' checks. concern-of.zsh is the one place the tool -> concern
# mapping lives; order-groups.zsh applies the order to the merged plan. The
# prose that wires them in (SKILL.md Phase 0 and Phase 8), the rationale
# (reference/pr-cycle.md) and the two documents that state the order
# (docs/explanation/workflow-maintenance.md, ARCHITECTURE.md) are pinned too.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/development/skills/maintenance/scripts"
  CONCERN="$SCRIPTS/concern-of.zsh"
  ORDER="$SCRIPTS/order-groups.zsh"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  [ -x "$CONCERN" ]
  [ -x "$ORDER" ]
}

# The raw lines of the SKILL.md section headed exactly "$1", up to the next
# heading of the same or a higher level; headings inside fences do not count.
raw_section() {
  awk -v h="$1" '
    /^[[:space:]]*```/ { fence = !fence }
    !fence && /^#+ / {
      lvl = index($0, " ") - 1
      if (on && lvl <= level) exit
      if ($0 == h) { on = 1; level = lvl }
    }
    on { print }
  ' "${2:-$SKILL}"
}

# The same section, whitespace-collapsed so a needle may span a line break.
section() {
  raw_section "$@" | tr -s '[:space:]' ' '
}

# Phase 0's `--tool` list: the backticked names between "must be one of:" and
# the bullet's next sentence, one per line, sorted.
tool_flag_list() {
  section '## Phase 0 — parse flags' \
    | sed -n 's/.*`--tool=<name>` — scope dispatch to a single tool (testing aid)\. `<name>` must be one of: \([^.]*\)\. The gather phase.*/\1/p' \
    | grep -o '`[a-z_]*`' | tr -d '`' | sort
}

# ---- concern-of.zsh -------------------------------------------------------

@test "concern-of: every --tool tool maps to the concern the epic's design gives it" {
  local pair tool want
  for pair in snyk_prs:security code_scanning:security semgrep:security container_scan:security \
      govulncheck:security dependabot:dependencies renovate:dependencies sonarcloud:codequality \
      ruff:codequality; do
    tool="${pair%%:*}"
    want="${pair#*:}"
    run "$CONCERN" "$tool"
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ] || {
      printf '%s maps to %s, want %s\n' "$tool" "$output" "$want" >&2
      return 1
    }
  done
}

@test "concern-of: a planner-only language tool is code quality" {
  local tool
  for tool in format_lint grpc api_contract openapi versioning; do
    run "$CONCERN" "$tool"
    [ "$status" -eq 0 ]
    [ "$output" = codequality ]
  done
}

@test "concern-of: a topic tool maps to topic" {
  local tool
  for tool in skill_validation c4_drift manifest_validation; do
    run "$CONCERN" "$tool"
    [ "$status" -eq 0 ]
    [ "$output" = topic ]
  done
}

@test "concern-of: an unknown tool exits 2 and names it on stderr" {
  run --separate-stderr "$CONCERN" no_such_tool
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown tool 'no_such_tool'"
}

@test "concern-of: no argument, an empty tool or two tools exit 2 with the usage" {
  run --separate-stderr "$CONCERN"
  [ "$status" -eq 2 ]
  contains "$stderr" 'usage: concern-of.zsh'
  run --separate-stderr "$CONCERN" ''
  [ "$status" -eq 2 ]
  contains "$stderr" 'usage: concern-of.zsh'
  run --separate-stderr "$CONCERN" ruff semgrep
  [ "$status" -eq 2 ]
  contains "$stderr" 'usage: concern-of.zsh'
}

@test "concern-of --tools: each concern lists its --tool tools in Phase 0's order, then its planner-only ones" {
  run "$CONCERN" --tools security
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = 'snyk_prs code_scanning semgrep container_scan govulncheck' ]
  run "$CONCERN" --tools dependencies
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = 'dependabot renovate' ]
  run "$CONCERN" --tools codequality
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = 'sonarcloud ruff format_lint grpc api_contract openapi versioning' ]
}

@test "concern-of --tools: bugs and topic are known concerns with no language tool" {
  run "$CONCERN" --tools bugs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run "$CONCERN" --tools topic
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "concern-of --tools: an unknown concern or a missing one exits 2" {
  run --separate-stderr "$CONCERN" --tools quality
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown concern 'quality'"
  run --separate-stderr "$CONCERN" --tools
  [ "$status" -eq 2 ]
  contains "$stderr" 'usage: concern-of.zsh'
}

# ---- sweeps: the mapping knows every tool a plan can carry -----------------

@test "sweep: every tool of Phase 0's --tool list is known to concern-of.zsh" {
  local tools tool n=0
  tools="$(tool_flag_list)"
  [ -n "$tools" ]
  for tool in $tools; do
    run "$CONCERN" "$tool"
    [ "$status" -eq 0 ] || {
      printf 'Phase 0 --tool accepts %s, concern-of.zsh does not know it\n' "$tool" >&2
      return 1
    }
    n=$((n + 1))
  done
  [ "$n" -eq 9 ]
}

@test "sweep: the three --concern sets together are exactly Phase 0's --tool list plus the planner-only tools" {
  local want got
  want="$({ tool_flag_list; printf '%s\n' format_lint grpc api_contract openapi versioning; } | sort | tr '\n' ' ')"
  got="$({ "$CONCERN" --tools security; "$CONCERN" --tools dependencies; "$CONCERN" --tools codequality; } \
    | sort | tr '\n' ' ')"
  [ "$got" = "$want" ]
  # ...and no tool sits in two of them
  [ "$({ "$CONCERN" --tools security; "$CONCERN" --tools dependencies; "$CONCERN" --tools codequality; } \
    | sort | uniq -d)" = '' ]
}

@test "sweep: every language dispatcher's supported tool is known and is not topic" {
  local lang skill tools tool n
  for lang in go java javascript python swift; do
    skill="$REPO_ROOT/development-$lang/skills/maintenance/SKILL.md"
    tools="$(tr -s '[:space:]' ' ' <"$skill" \
      | grep -o 'dispatch_filter.only_tools; [^"]*\."' \
      | sed 's/^dispatch_filter.only_tools; //; s/^development-[a-z]* //; s/^supp[a-z]*: //; s/\."$//' \
      | tr ',' '\n' | tr -d ' ')"
    n=0
    for tool in $tools; do
      run "$CONCERN" "$tool"
      [ "$status" -eq 0 ] || {
        printf 'development-%s supports %s, concern-of.zsh does not know it\n' "$lang" "$tool" >&2
        return 1
      }
      [ "$output" != topic ]
      n=$((n + 1))
    done
    [ "$n" -ge 1 ] || {
      printf 'no supported tools read from %s\n' "$skill" >&2
      return 1
    }
  done
}

@test "sweep: every topic dispatcher's routing-table tool maps to topic" {
  local topic skill tools tool n
  for topic in claude-plugin composition docs kubernetes opentofu react spring; do
    skill="$REPO_ROOT/development-$topic/skills/maintenance/SKILL.md"
    tools="$(grep -o '^| *`[a-z_0-9]*` *|' "$skill" | grep -o '`[a-z_0-9]*`' | tr -d '`' | sort -u)"
    n=0
    for tool in $tools; do
      run "$CONCERN" "$tool"
      [ "$status" -eq 0 ] || {
        printf 'development-%s routes %s, concern-of.zsh does not know it\n' "$topic" "$tool" >&2
        return 1
      }
      [ "$output" = topic ]
      n=$((n + 1))
    done
    [ "$n" -ge 1 ] || {
      printf 'no routing-table tools read from %s\n' "$skill" >&2
      return 1
    }
  done
}

# ---- order-groups.zsh -----------------------------------------------------

@test "order-groups: a shuffled five-concern array comes out in rank order, each with its concern" {
  run --separate-stderr "$ORDER" <<'EOF'
[{"group_id":1,"tool":"c4_drift"},{"group_id":2,"tool":"ruff"},{"group_id":3,"tool":"dependabot"},
 {"group_id":4,"tool":"semgrep"},{"group_id":5,"tool":"format_lint"}]
EOF
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.group_id)' <<<"$output")" = '[4,3,2,5,1]' ]
  [ "$(jq -c 'map(.concern)' <<<"$output")" = '["security","dependencies","codequality","codequality","topic"]' ]
}

@test "order-groups: two groups of one concern keep their planner order" {
  run "$ORDER" <<'EOF'
[{"group_id":7,"tool":"sonarcloud"},{"group_id":8,"tool":"snyk_prs"},{"group_id":9,"tool":"ruff"},
 {"group_id":10,"tool":"code_scanning"}]
EOF
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.group_id)' <<<"$output")" = '[8,10,7,9]' ]
}

@test "order-groups: every other field of a group is kept" {
  run "$ORDER" <<'EOF'
[{"group_id":1,"tool":"ruff","target":"python","isolation":true,"priority_score":0.4,"findings":["a"]}]
EOF
  [ "$status" -eq 0 ]
  [ "$(jq -c '.[0]' <<<"$output")" = \
    '{"group_id":1,"tool":"ruff","target":"python","isolation":true,"priority_score":0.4,"findings":["a"],"concern":"codequality"}' ]
}

@test "order-groups: an empty array stays empty" {
  run "$ORDER" <<<'[]'
  [ "$status" -eq 0 ]
  [ "$(jq -c . <<<"$output")" = '[]' ]
}

@test "order-groups: an unknown tool exits 2 and names it" {
  run --separate-stderr "$ORDER" <<<'[{"tool":"ruff"},{"tool":"mystery_tool"}]'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "unknown tool 'mystery_tool'"
}

@test "order-groups: input that is not one array of groups with a tool exits 2" {
  local bad
  for bad in '{}' '[{"group_id":1}]' '[{"tool":""}]' '[{"tool":3}]' '[1]' 'not json' '[] []'; do
    run --separate-stderr "$ORDER" <<<"$bad"
    [ "$status" -eq 2 ] || {
      printf 'input %s exited %s, want 2\n' "$bad" "$status" >&2
      return 1
    }
    contains "$stderr" 'stdin must be one JSON array of objects'
  done
}

@test "order-groups: an argument exits 2 with the usage" {
  run --separate-stderr "$ORDER" extra <<<'[]'
  [ "$status" -eq 2 ]
  contains "$stderr" 'usage: order-groups.zsh'
}

@test "order-groups: no jq on PATH is an internal failure, exit 1" {
  local bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  ln -s "$(command -v zsh)" "$bin/zsh"
  ln -s "$(command -v cat)" "$bin/cat"
  run --separate-stderr env PATH="$bin" "$bin/zsh" "$ORDER" <<<'[]'
  [ "$status" -eq 1 ]
  contains "$stderr" 'jq not found'
}

# ---- the prose that wires it in -------------------------------------------

@test "SKILL.md Phase 0: --concern points at concern-of.zsh and states the partition and the order" {
  local s
  s="$(section '## Phase 0 — parse flags')"
  contains "$s" 'Which tool belongs to which concern is stated in one place only, `<skill-base-dir>/scripts/concern-of.zsh` (#3211)'
  contains "$s" 'Expand it to its tool set with `concern-of.zsh --tools <name>`'
  contains "$s" 'The concerns rank `security`, `dependencies`, `bugs`, `codequality`, and topic-plugin checks come last'
  contains "$s" 'Every language tool belongs to exactly one of `security`, `dependencies` and `codequality`, so `--concern=security` + `--concern=dependencies` + `--concern=codequality` together cover the same language tools as an unscoped run.'
  lacks "$s" 'Every tool of the `--tool` list belongs to exactly one of'
  contains "$s" 'No tool belongs to `bugs` yet, and topic-plugin checks belong to no `--concern`: a scoped run skips them.'
  lacks "$s" 'The three concerns partition all nine tools'
  # the mapping is no longer restated inline
  lacks "$s" '`security` → `snyk_prs`'
}

@test "SKILL.md Phase 8: the queue passes through order-groups.zsh on every run before the stages walk it" {
  local s
  s="$(section '### Stages 1..N — one PR per planner group, in concern order')"
  contains "$s" 'Build the stage queue in the concern order (#3211) — on every run, attended or not.'
  contains "$s" '"<skill-base-dir>/scripts/order-groups.zsh" < <groups.json> > <ordered.json>'
  contains "$s" 'Stage 0 is never passed in: the coverage pre-flight stays ahead of everything.'
  contains "$s" 'Inside one concern the groups keep the order they came in'
  contains "$s" 'the concern order between concerns; inside one concern, worktree stages first, vendor-PR (GitHub-PR) stages last (#432, #3211).'
  contains "$s" 'in the order the ordering rule above sets:'
  lacks "$s" 'in priority order:'
  contains "$s" 'On a resume the queue is rebuilt the same way from `phase6-plan`, so it comes out identical.'
  contains "$s" '**Exit 2** names a tool `concern-of.zsh` does not know, or input that is not one array of groups each with a `tool`: a gap in the mapping or in your own call, never a reason to guess a concern.'
  contains "$s" 'otherwise walk the groups in the order they came in, and name the unknown tool in the Phase 9 summary as a defect in `concern-of.zsh`.'
  contains "$s" 'Why this order is `reference/pr-cycle.md` § *Why a full run works the concerns in a fixed order*.'
  contains "$s" 'remediate them in the **standing-PR slot** — once the queue'"'"'s last stage has run, so the rebase lands on a `main` no later stage moves.'
  contains "$s" 'concatenate the `plan` arrays — the languages in Phase 6'"'"'s dispatch order, then the topics — adding `"target": "<lang or topic>"` to each group'
  contains "$s" 'A concern'"'"'s stages all run before the next concern'"'"'s start, even when that puts the `dependencies` concern'"'"'s vendor-PR stages ahead of later worktree stages.'
  contains "$s" 'just sink the concern'"'"'s vendor-PR stage(s) to its end so they'"'"'re processed once that concern'"'"'s worktree stages have merged.'
}

@test "SKILL.md Phase 4: only_tools is the scope limited to each language's tools" {
  local s
  s="$(section '## Phase 4 — construct one payload per supported language')"
  contains "$s" '`only_tools` is the scoped tool set — the `--tool` name, or the lines `concern-of.zsh --tools <name>` printed for `--concern` — as a JSON list, limited to this language'"'"'s tools as the next paragraph says.'
  lacks "$s" '`["snyk_prs", "code_scanning", "semgrep", "container_scan", "govulncheck"]`'
  contains "$s" 'A dispatcher halts on an `only_tools` name it does not know, so write only the scoped tools that language supports'
  lacks "$s" 'take the full set'
  contains "$s" 'Under `--concern`, also drop each tool whose `tooling_configured.<tool>` is `false`'
  contains "$s" 'When nothing is left, build no payload for that language: record "nothing in scope for `<lang>` under `--tool=<name>`" (or `--concern=<name>`) for the Phase 9 summary and move on to the next target.'
}

@test "SKILL.md Phase 6: a language Phase 4 built no payload for is not dispatched" {
  local s
  s="$(section '## Phase 6 — dispatch per supported language to plan')"
  contains "$s" 'For each `lang` in `supported` that has a kept payload (Phase 4 builds none for a language with nothing in scope)'
}

@test "sweep: Phase 4's per-language limit matches each dispatcher's supported tools" {
  local lang s want got
  s="$(section '## Phase 4 — construct one payload per supported language' \
    | sed -n 's/.*\*\*Limit `only_tools` to the language'"'"'s tools\.\*\*\(.*\) Under `--concern`, also drop.*/\1/p')"
  [ -n "$s" ]
  for lang in java python swift go javascript; do
    want="$(tr -s '[:space:]' ' ' <"$REPO_ROOT/development-$lang/skills/maintenance/SKILL.md" \
      | grep -oE 'dispatch_filter\.only_tools; (development-[a-z]+ supports|supported): [^"]*\."' \
      | sed -E 's/^dispatch_filter\.only_tools; (development-[a-z]+ supports|supported): //; s/\."$//' \
      | tr ',' '\n' | tr -d ' ' | sort | tr '\n' ' ')"
    got="$(printf '%s\n' "$s" \
      | grep -o "\- $lang → [^-]*" \
      | sed "s/^- $lang → //" | tr ',' '\n' | tr -d ' `' | grep -v '^$' | sort | tr '\n' ' ')"
    [ -n "$want" ] && [ "$got" = "$want" ] || {
      printf '%s: Phase 4 lists [%s], dispatcher supports [%s]\n' "$lang" "$got" "$want" >&2
      return 1
    }
  done
}

@test "reference/pr-cycle.md states why the concerns run in a fixed order" {
  local s
  s="$(section '## Why a full run works the concerns in a fixed order' \
    "$REPO_ROOT/development/skills/maintenance/reference/pr-cycle.md")"
  contains "$s" 'The queue now runs `security`, `dependencies`, `bugs`, `codequality`, then the topic plugins'"'"' checks'
  contains "$s" 'The tool-to-concern mapping lives only in `scripts/concern-of.zsh`'
}

@test "workflow-maintenance.md states the concern order and its rationale" {
  local s
  s="$(section '### The concern order {#maintenance-the-concern-order}' \
    "$REPO_ROOT/docs/explanation/workflow-maintenance.md")"
  contains "$s" '1. **security**'
  contains "$s" '2. **dependencies**'
  contains "$s" '3. **bugs**'
  contains "$s" '4. **code quality**'
  contains "$s" '5. **topic-plugin checks**'
  contains "$s" 'An open vulnerability is the costliest thing to leave open'
  contains "$s" 'The order is between concerns only.'
}

@test "ARCHITECTURE.md states the concern order, the mapping's one home and the rationale" {
  local s
  s="$(section '### The concern order of a full run (#3211)' "$REPO_ROOT/ARCHITECTURE.md")"
  contains "$s" '`security` < `dependencies` < `bugs` < `codequality` < `topic`'
  contains "$s" 'is the one place the tool → concern mapping lives'
  contains "$s" '*Rationale:* an open vulnerability is the costliest thing to leave open'
}
