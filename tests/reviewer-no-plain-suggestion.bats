#!/usr/bin/env bats
#
# #3171 — the closing guard of epic #3122: no read-only reviewer offers a plain
# SUGGESTION, and no panel review skill or review-loop shard mentions the
# removed suggestion carry. Two sweeps, both derived with `git ls-files`, so a
# reviewer, a panel or a shard added later is in them the moment it is tracked.
#
#   1. Every read-only reviewer — derived exactly as
#      tests/reviewer-evidence-rule.bats derives it: tracked `*/agents/*.md`
#      outside `tests/`, frontmatter tool set normalised to `Read, Grep, Glob`,
#      minus the entries of tests/reviewer-evidence-rule.exemptions — offers no
#      SUGGESTION severity rung. SUGGESTION stays only in the lanes
#      ARCHITECTURE.md *Terminating severity bars* states: the evidence-capped
#      tool claim (the evidence-rule section and its Reporting Format slot) and
#      the scope-bounded `follow-up:` lane. The rung this guard refuses is the
#      shape the #3158-#3167 children removed: a line that DEFINES SUGGESTION as
#      a severity — a list item, a heading, a table cell or a bare line opening
#      on the word and followed by `:`, `(`, `=`, a dash or a cell separator,
#      such as `- **SUGGESTION:** Defensive improvement that prevents future
#      bugs`. The evidence-rule section is never swept: it is the lane itself.
#   2. No panel review skill (`*/skills/review/SKILL.md`) and no tracked `.md`
#      under development/skills/resolve-issue/reference/review-loop/ (briefs/
#      included) mentions `adjudicated_path`, `REVIEW_ADJUDICATED` or waived
#      suggestions. The phrase is matched case-insensitively as `waived`, then
#      a hyphen or whitespace, then `suggestion`, on each file's text with its
#      line wraps collapsed, so a wrapped reintroduction is still a hit. A bare
#      `waived` is never a hit.
#
# Each guard is mutation-checked in a throwaway fixture repo built from the
# tracked files, never against the working tree.

bats_require_minimum_version 1.5.0

setup() {
  # git exports these inside hooks and `git rebase --exec`; `-C` does not
  # override them, so the fixture repo's init/add would hit the REAL index.
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # repo-relative, so the fixture repo resolves it inside its own tree
  EXEMPTIONS_REL='tests/reviewer-evidence-rule.exemptions'
  HEADING="## The evidence rule (a tool's verdict needs the tool run)"
  SHARDS_REL='development/skills/resolve-issue/reference/review-loop/'
  PLAIN_RUNG='- **SUGGESTION:** Defensive improvement that prevents future bugs.'
}

# --- guard 1: the reviewer roster -------------------------------------------
# The four roster functions are the ones tests/reviewer-evidence-rule.bats
# defines, so both files sweep the same set; the carrier-set test below ties
# them together by content as well.

agent_files_in() {
  git -C "$1" ls-files -- '*/agents/*.md' ':(exclude)tests/' | LC_ALL=C sort
}

tool_set_of() {
  awk -F': *' '
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && /^tools:/ { print $2; exit }
  ' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -v '^$' | LC_ALL=C sort | tr '\n' ' '
}

read_only_agents_in() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(tool_set_of "$root/$f")" = "Glob Grep Read " ] || continue
    printf '%s\n' "$f"
  done < <(agent_files_in "$root")
}

exempt_agents_in() {
  local file="$1/$EXEMPTIONS_REL"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" \
    | sed 's/[[:space:]]*|.*$//; s/^[[:space:]]*//' | LC_ALL=C sort
}

# The swept reviewers: the read-only roster minus the exemptions.
reviewers_in() {
  local root="$1" a exempt
  exempt="$(exempt_agents_in "$root")"
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qxF -- "$a" <<< "$exempt" && continue
    printf '%s\n' "$a"
  done < <(read_only_agents_in "$root")
}

# Print every read-only agent in $1 that carries the evidence-rule heading.
rule_carriers_in() {
  local root="$1" a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    grep -qxF -- "$HEADING" "$root/$a" || continue
    printf '%s\n' "$a"
  done < <(read_only_agents_in "$root")
}

# Print `<line number>:<line>` for every line of the agent file $1 outside its
# evidence-rule section. The section runs from its heading to the next `## `.
outside_evidence_rule() {
  awk -v h="$HEADING" '
    $0 == h { inside = 1; next }
    inside && /^## / { inside = 0 }
    !inside { printf "%d:%s\n", NR, $0 }
  ' "$1"
}

# The SUGGESTION rung shape, as one ERE over a `<n>:<line>` record: the line
# opens (after an optional list marker, heading marks or table pipe) on the
# word, wrapped in at most emphasis or code marks, and then defines it.
RUNG_ERE='^[0-9]+:[[:space:]]*(([-*+]|[0-9]+[.)]|#+|[|])[[:space:]]*)?[*_`]*SUGGESTION[*_`]*[[:space:]]*(:|\(|=|[|]|-[[:space:]]|—|–)'

# Print `<file>:<n>: <line>` for every SUGGESTION rung in the work tree $1's
# swept reviewers. Empty output = guard 1 passes.
plain_suggestion_rungs_in() {
  local root="$1" a hit
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      printf '%s:%s: %s\n' "$a" "${hit%%:*}" "${hit#*:}"
    done < <(outside_evidence_rule "$root/$a" | LC_ALL=C grep -E -- "$RUNG_ERE")
  done < <(reviewers_in "$root")
}

# --- guard 2: the panel skills and the review-loop shards -------------------

panel_skills_in() {
  git -C "$1" ls-files -- '*/skills/review/SKILL.md' ':(exclude)tests/' | LC_ALL=C sort
}

shards_in() {
  git -C "$1" ls-files -- "$SHARDS_REL" | LC_ALL=C grep -E '\.md$' | LC_ALL=C sort
}

# Print `<file>: <needle>` once per needle a swept file in $1 mentions. Empty
# output = guard 2 passes.
carry_mentions_in() {
  local root="$1" f flat
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    LC_ALL=C grep -qF -- 'adjudicated_path' "$root/$f" \
      && printf '%s: adjudicated_path\n' "$f"
    LC_ALL=C grep -qF -- 'REVIEW_ADJUDICATED' "$root/$f" \
      && printf '%s: REVIEW_ADJUDICATED\n' "$f"
    flat="$(LC_ALL=C tr '\n' ' ' < "$root/$f")"
    LC_ALL=C grep -qiE -- 'waived[-[:space:]]+suggestion' <<< "$flat" \
      && printf '%s: waived suggestion\n' "$f"
  done < <({ panel_skills_in "$root"; shards_in "$root"; })
  return 0
}

# A throwaway git work tree under $1 holding every tracked agent, the exemption
# list, every panel skill and every shard at their repo-relative paths.
make_fixture_repo() {
  local dest="$1" f
  mkdir -p "$dest"
  git -C "$dest" init -q
  while IFS= read -r f; do
    mkdir -p "$dest/$(dirname "$f")"
    cp -- "$REPO_ROOT/$f" "$dest/$f"
  done < <({ agent_files_in "$REPO_ROOT"; panel_skills_in "$REPO_ROOT"; shards_in "$REPO_ROOT"; })
  mkdir -p "$dest/tests"
  cp -- "$REPO_ROOT/$EXEMPTIONS_REL" "$dest/$EXEMPTIONS_REL"
  git -C "$dest" add -A
}

@test "#3171 CONTROL: the rung matcher hits each rung shape and misses each lane sentence" {
  local line
  for line in \
    "$PLAIN_RUNG" \
    '**SUGGESTION**: style nit' \
    '* SUGGESTION — nice to have' \
    '1. `SUGGESTION` (optional)' \
    '| SUGGESTION | a cosmetic improvement |' \
    '### SUGGESTION: Title' \
    'SUGGESTION - defensive hardening'
  do
    run -0 bash -c 'printf "1:%s\n" "$1" | LC_ALL=C grep -cE -- "$2"' _ "$line" "$RUNG_ERE"
    [ "$output" = "1" ] || { printf 'rung shape missed: %s\n' "$line" >&2; return 1; }
  done
  for line in \
    '### [CRITICAL|WARNING|SUGGESTION] Title' \
    '  **SUGGESTION** with a Description line `follow-up: <the defect, in one line>`, and' \
    '`SUGGESTION` is reserved for the two lanes of ARCHITECTURE.md' \
    '  **Description** field above, each on its own line, with the severity set to SUGGESTION:' \
    'reported: SUGGESTION is only the evidence-capped tool-verdict claim and the scope-bounded follow-up.'
  do
    run bash -c 'printf "1:%s\n" "$1" | LC_ALL=C grep -cE -- "$2"' _ "$line" "$RUNG_ERE"
    [ "$output" = "0" ] || { printf 'lane sentence hit: %s\n' "$line" >&2; return 1; }
  done
}

@test "#3171 the swept reviewers are derived, non-empty, and are exactly the evidence-rule carriers" {
  run -0 reviewers_in "$REPO_ROOT"
  [ -n "$output" ]
  local carriers
  carriers="$(rule_carriers_in "$REPO_ROOT")"
  [ -n "$carriers" ]
  [ "$output" = "$carriers" ] || {
    diff <(printf '%s\n' "$carriers") <(printf '%s\n' "$output") >&2
    return 1
  }
  # repo-wide, not one plugin's panel
  run grep -vc '^development-claude-plugin/' <<< "$output"
  [ "$output" -gt 0 ]
}

@test "#3171 guard 1: no read-only reviewer offers a plain SUGGESTION rung" {
  run -0 plain_suggestion_rungs_in "$REPO_ROOT"
  [ -z "$output" ] || {
    printf 'a reviewer offers a plain SUGGESTION rung (report only what blocks):\n%s\n' "$output" >&2
    return 1
  }
}

@test "#3171 guard 1 MUTATION: a plain SUGGESTION rung in one reviewer reds the sweep" {
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  [ -z "$(plain_suggestion_rungs_in "$fixture")" ]
  victim='development-python/agents/python-bug-hunter.md'
  printf '%s\n' "$PLAIN_RUNG" >> "$fixture/$victim"
  n="$(wc -l < "$fixture/$victim" | tr -d ' ')"
  run -0 plain_suggestion_rungs_in "$fixture"
  [ "$output" = "$victim:$n: $PLAIN_RUNG" ]
}

@test "#3171 guard 1 scope: the evidence-rule section is the lane itself and is not swept" {
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  victim='development-go/agents/go-bug-hunter.md'
  # the rung placed right under the evidence-rule heading is inside the lane
  awk -v h="$HEADING" -v r="$PLAIN_RUNG" '{ print } $0 == h { print r }' \
    "$fixture/$victim" > "$fixture/$victim.new"
  mv -- "$fixture/$victim.new" "$fixture/$victim"
  run -0 grep -cxF -- "$PLAIN_RUNG" "$fixture/$victim"
  [ "$output" = "1" ]
  run -0 plain_suggestion_rungs_in "$fixture"
  [ -z "$output" ]
  # …and the section closes at the next `## `, so a rung in Reporting Format is swept
  awk -v r="$PLAIN_RUNG" '{ print } $0 == "## Reporting Format" { print r }' \
    "$fixture/$victim" > "$fixture/$victim.new"
  mv -- "$fixture/$victim.new" "$fixture/$victim"
  run -0 plain_suggestion_rungs_in "$fixture"
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
  case "$output" in "$victim:"*": $PLAIN_RUNG") ;; *) return 1 ;; esac
}

@test "#3171 the guard-2 sweep is derived, non-empty, and reaches briefs/" {
  run -0 panel_skills_in "$REPO_ROOT"
  [ -n "$output" ]
  run -0 shards_in "$REPO_ROOT"
  [ -n "$output" ]
  run -0 grep -c "^${SHARDS_REL}briefs/" <<< "$output"
  [ "$output" -gt 0 ]
}

@test "#3171 guard 2: no panel skill or review-loop shard mentions the removed suggestion carry" {
  run -0 carry_mentions_in "$REPO_ROOT"
  [ -z "$output" ] || {
    printf 'the removed suggestion carry is mentioned:\n%s\n' "$output" >&2
    return 1
  }
}

@test "#3171 guard 2 MUTATION: each needle, added to a swept file, reds the sweep" {
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  [ -z "$(carry_mentions_in "$fixture")" ]
  shard="${SHARDS_REL}risk-pass.md"
  panel='development-go/skills/review/SKILL.md'
  [ -f "$fixture/$shard" ]
  [ -f "$fixture/$panel" ]

  cp -- "$fixture/$shard" "$BATS_TEST_TMPDIR/shard.orig"
  cp -- "$fixture/$panel" "$BATS_TEST_TMPDIR/panel.orig"

  printf 'Pass the `adjudicated_path` to the panel.\n' >> "$fixture/$shard"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$shard: adjudicated_path" ]
  cp -- "$BATS_TEST_TMPDIR/shard.orig" "$fixture/$shard"

  printf 'Read REVIEW_ADJUDICATED before dispatching.\n' >> "$fixture/$panel"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$panel: REVIEW_ADJUDICATED" ]
  cp -- "$BATS_TEST_TMPDIR/panel.orig" "$fixture/$panel"

  printf 'The dossier lists the waived suggestions.\n' >> "$fixture/$shard"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$shard: waived suggestion" ]
  cp -- "$BATS_TEST_TMPDIR/shard.orig" "$fixture/$shard"

  # case-insensitive, hyphenated, and wrapped across a line break
  printf 'A Waived-Suggestion stays out.\n' >> "$fixture/$shard"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$shard: waived suggestion" ]
  cp -- "$BATS_TEST_TMPDIR/shard.orig" "$fixture/$shard"
  printf 'the panel carries the waived\n  suggestions forward\n' >> "$fixture/$shard"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$shard: waived suggestion" ]
  cp -- "$BATS_TEST_TMPDIR/shard.orig" "$fixture/$shard"

  # a shard under briefs/ is swept too
  brief="${SHARDS_REL}briefs/panel.md"
  printf 'adjudicated_path\n' >> "$fixture/$brief"
  run -0 carry_mentions_in "$fixture"
  [ "$output" = "$brief: adjudicated_path" ]
}

@test "#3171 guard 2: a bare 'waived' is never a hit" {
  fixture="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fixture"
  shard="${SHARDS_REL}risk-pass.md"
  printf 'the review recorded as waived\na missing dimension silently waived\nwaived. Suggestion follows\n' \
    >> "$fixture/$shard"
  run -0 carry_mentions_in "$fixture"
  [ -z "$output" ]
}
