#!/usr/bin/env bats
#
# Behavioral tests for gather-claude-plugin-findings.zsh — the topic gather that
# drives the five development-claude-plugin validators. Each test starts from the
# finding-free `clean` fixture, applies ONE mutation, and asserts the matching
# validator (and only it) reports the expected finding. This is the regression
# net the coverage-misreporting incident (#258/#259) showed these scripts need.

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATHER="$REPO_ROOT/development/skills/maintenance/scripts/gather-claude-plugin-findings.zsh"
  WORK="$BATS_TEST_TMPDIR/repo"
  cp -R "$REPO_ROOT/tests/fixtures/clean" "$WORK"
}

# gather <repo> -> prints the findings JSON
gather() { zsh "$GATHER" "$1"; }
# count <repo> <tool> -> number of findings for that tool
count() { zsh "$GATHER" "$1" | jq ".findings_by_tool.$2 // [] | length"; }
# type0 <repo> <tool> -> the first finding's type for that tool
type0() { zsh "$GATHER" "$1" | jq -r ".findings_by_tool.$2[0].type"; }

@test "clean fixture: zero findings across all five validators" {
  run gather "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    (.findings_by_tool.plugin_version_check // []) == [] and
    (.findings_by_tool.skill_validation     // []) == [] and
    (.findings_by_tool.reference_checking   // []) == [] and
    (.findings_by_tool.structure_validation // []) == [] and
    (.findings_by_tool.script_quality       // []) == []'
}

@test "clean fixture: all five tools advertised as configured" {
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '.tooling_configured | .plugin_version_check and .skill_validation and .reference_checking and .structure_validation and .script_quality'"
  [ "$status" -eq 0 ]
}

@test "version drift: plugin_version_check reports version_mismatch" {
  jq '.version="2.0.0"' "$WORK/development-fixture/.claude-plugin/plugin.json" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/.claude-plugin/plugin.json"
  [ "$(count "$WORK" plugin_version_check)" -eq 1 ]
  [ "$(type0 "$WORK" plugin_version_check)" = "version_mismatch" ]
}

@test "broken SKILL frontmatter: skill_validation reports missing_field" {
  # drop the description line from the demo skill's frontmatter
  grep -v '^description:' "$WORK/development-fixture/skills/demo/SKILL.md" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/skills/demo/SKILL.md"
  [ "$(count "$WORK" skill_validation)" -ge 1 ]
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '[.findings_by_tool.skill_validation[].type] | index(\"missing_field\")'"
  [ "$status" -eq 0 ]
}

# set_effort <value> -> add an `effort:` line to the helper agent's frontmatter
set_effort() {
  awk -v e="$1" '/^effort:/{next} {print} $0=="model: haiku"{print "effort: " e}' \
    "$WORK/development-fixture/agents/helper.md" > "$WORK/t"
  mv "$WORK/t" "$WORK/development-fixture/agents/helper.md"
  grep -qx "effort: $1" "$WORK/development-fixture/agents/helper.md"
}

# add_bogus_peer -> a second agent whose effort is invalid. Paired with a
# valid or absent effort on helper.md, it proves the validator ran (the peer is
# flagged) and that it passed over helper.md, so the "no finding" cases fail
# when the effort check is reverted rather than passing vacuously.
add_bogus_peer() {
  printf -- '---\nname: peer\ndescription: A second fixture agent.\nmodel: haiku\neffort: bogus\ntools: Read\n---\n\nPeer body.\n' \
    > "$WORK/development-fixture/agents/peer.md"
}
# only_peer_flagged <repo> -> exit 0 when the sole skill_validation finding is
# the peer's invalid_effort
only_peer_flagged() {
  zsh "$GATHER" "$1" | jq -e '.findings_by_tool.skill_validation
    | length == 1 and .[0].type == "invalid_effort"
      and .[0].file == "development-fixture/agents/peer.md"'
}

@test "valid agent effort: skill_validation reports no finding (#3309)" {
  # every accepted level: low|medium|high|xhigh|max
  for level in low medium high xhigh max; do
    set_effort "$level"
    [ "$(count "$WORK" skill_validation)" -eq 0 ]
  done
  add_bogus_peer
  run only_peer_flagged "$WORK"
  [ "$status" -eq 0 ]
}

@test "invalid agent effort: skill_validation reports one invalid_effort (#3309)" {
  set_effort bogus
  run gather "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '[.findings_by_tool.skill_validation[] | select(.type == "invalid_effort")] | length == 1'
  echo "$output" | jq -e '.findings_by_tool.skill_validation | length == 1'
  echo "$output" | jq -e '.findings_by_tool.skill_validation[0] | .id == "skill:development-fixture/agents/helper.md:effort" and .field == "effort" and .kind == "agent" and .file == "development-fixture/agents/helper.md"'
}

@test "absent agent effort: skill_validation reports no finding (#3309)" {
  run grep -c '^effort:' "$WORK/development-fixture/agents/helper.md"
  [ "$output" = "0" ]
  [ "$(count "$WORK" skill_validation)" -eq 0 ]
  add_bogus_peer
  run only_peer_flagged "$WORK"
  [ "$status" -eq 0 ]
}

# effort_section -> ARCHITECTURE.md's "Reasoning effort (#3309)" section, from
# its heading to the next heading, with line breaks folded to single spaces so a
# needle may span a wrapped line.
effort_section() {
  awk '/^### Reasoning effort \(#3309\)$/{on=1; print; next} on && /^#/{exit} on{print}' \
    "$REPO_ROOT/ARCHITECTURE.md" | tr '\n' ' ' | tr -s ' '
}

@test "ARCHITECTURE.md effort section: documented level list matches the gather's case arm (#3309)" {
  run grep -Eo '^ *[a-z|]+\) ;;$' "$GATHER"
  [ "$status" -eq 0 ]
  arm="$(printf '%s\n' "$output" | grep -F 'xhigh' | tr -d ' ;)')"
  [ "$arm" = "low|medium|high|xhigh|max" ]
  run effort_section
  contains "$output" "must be one of \`low\`, \`medium\`, \`high\`, \`xhigh\` or \`max\`."
}

@test "ARCHITECTURE.md effort section: pins the invalid_effort finding contract (#3309)" {
  run effort_section
  contains "$output" "### Reasoning effort (#3309)"
  contains "$output" "reports any other value as an \`invalid_effort\` finding, shaped like \`invalid_model\`"
  contains "$output" "(id \`skill:<file>:effort\`, \`field: \"effort\"\`)"
  contains "$output" "an agent without it runs at the default effort"
}

@test "ARCHITECTURE.md effort section: pins the per-agent-class effort rules (#3309)" {
  run effort_section
  contains "$output" "**Judgement agents** — any agent whose output is a decision no deterministic check verifies: reviewers, approvers, migrations, triage (a Snyk finding, a CI failure, whether a vulnerability is exploitable) and the like — keep the model the table above gives them and run at \`high\`."
  contains "$output" "They are not raised to \`xhigh\` or \`max\` by default."
  contains "$output" "This bullet takes precedence over the next: an agent that makes any decision no deterministic check verifies is a judgement agent, even if some of its branches escalate."
  contains "$output" "**Mechanical or decision-tree agents** — any agent that makes no unverified decision of its own: every branch either applies a deterministic rule or hands the case to a human unchanged — take the cheapest model that does the job first, and then \`low\` effort."
  contains "$output" "This bullet never moves an agent's model below the row the table above gives its task."
  contains "$output" "is a decision made on a measurement of what it does to review quality (#2945), never on a guess."
}

# validator_escalate -> the skill validator agent's "### Escalate" section, from
# its heading to the next heading, with line breaks folded to single spaces.
validator_escalate() {
  awk '/^### Escalate /{on=1; print; next} on && /^#/{exit} on{print}' \
    "$REPO_ROOT/development-claude-plugin/agents/claude-plugin-skill-validator.md" | tr '\n' ' ' | tr -s ' '
}

@test "skill validator: invalid_effort is an Escalate arm beside invalid_model (#3315)" {
  run validator_escalate
  contains "$output" "- **\`invalid_model\`** —"
  contains "$output" "- **\`invalid_effort\`** — the agent's \`effort:\` is present but isn't \`low|medium|high|xhigh|max\`."
  contains "$output" "Never rewrite the line: recommend a level by the ARCHITECTURE.md *Agent model selection* effort rule (*Reasoning effort*)"
  contains "$output" "and escalate so a human confirms."
}

@test "skill validator: invalid_effort's level list matches the gather's case arm (#3315)" {
  run grep -Eo '^ *[a-z|]+\) ;;$' "$GATHER"
  arm="$(printf '%s\n' "$output" | grep -F 'xhigh' | tr -d ' ;)')"
  run validator_escalate
  contains "$output" "isn't \`$arm\`."
}

@test "skill validator: only name_mismatch is a Fix arm, so invalid_effort never auto-fixes (#3315)" {
  run awk '/^### Fix /{on=1; next} on && /^#/{exit} on && /^- \*\*`/{print}' \
    "$REPO_ROOT/development-claude-plugin/agents/claude-plugin-skill-validator.md"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
  contains "$output" "**\`name_mismatch\`**"
}

# strict_copy -> path of a copy of the gather with the exact line `emulate -L zsh`
# filtered out, so the script's own `setopt err_exit nounset pipefail` is in
# effect (#3317). The script does not resolve its own location, so the copy runs
# identically; it stays strict once #1223 reorders the two lines.
strict_copy() {
  local copy="$BATS_TEST_TMPDIR/gather-strict.zsh"
  grep -qx 'emulate -L zsh' "$GATHER" || return 1
  grep -vx 'emulate -L zsh' "$GATHER" > "$copy" || return 1
  grep -qx 'emulate -L zsh' "$copy" && return 1
  grep -qx 'setopt err_exit nounset pipefail' "$copy" || return 1
  printf '%s\n' "$copy"
}
# drop_key <file> <key> -> remove the `<key>:` line from a fixture file
drop_key() {
  grep -v "^$2:" "$WORK/$1" > "$WORK/t" || return 1
  mv "$WORK/t" "$WORK/$1" || return 1
  grep -q "^$2:" "$WORK/$1" && return 1
  return 0
}
# only_missing <field> -> exit 0 when $output is valid JSON whose sole
# skill_validation finding is missing_field for <field>, with no invalid_model
only_missing() {
  echo "$output" | jq -e --arg f "$1" '.findings_by_tool.skill_validation
    | length == 1 and .[0].type == "missing_field" and .[0].field == $f
      and all(.type != "invalid_model")'
}

@test "missing name: shipped gather reports one missing_field name (#3317)" {
  drop_key development-fixture/skills/demo/SKILL.md name
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  run only_missing name
  [ "$status" -eq 0 ]
}

@test "missing model: shipped gather reports one missing_field model, no invalid_model (#3317)" {
  drop_key development-fixture/agents/helper.md model
  run zsh "$GATHER" "$WORK"
  [ "$status" -eq 0 ]
  run only_missing model
  [ "$status" -eq 0 ]
}

@test "strict copy: clean fixture exits 0 with zero skill_validation findings (#3317)" {
  copy="$(strict_copy)"
  run zsh "$copy" "$WORK"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '(.findings_by_tool.skill_validation // []) == []'
}

@test "strict copy: missing name does not abort the gather (#3317)" {
  copy="$(strict_copy)"
  drop_key development-fixture/skills/demo/SKILL.md name
  run zsh "$copy" "$WORK"
  [ "$status" -eq 0 ]
  run only_missing name
  [ "$status" -eq 0 ]
}

@test "strict copy: missing model does not abort the gather (#3317)" {
  copy="$(strict_copy)"
  drop_key development-fixture/agents/helper.md model
  run zsh "$copy" "$WORK"
  [ "$status" -eq 0 ]
  run only_missing model
  [ "$status" -eq 0 ]
}

@test "orphaned reference: reference_checking reports orphan_command" {
  printf '\nSee /development-fixture:nonexistent for details.\n' >> "$WORK/development-fixture/skills/demo/SKILL.md"
  [ "$(count "$WORK" reference_checking)" -eq 1 ]
  [ "$(type0 "$WORK" reference_checking)" = "orphan_command" ]
}

@test "stray skill file: structure_validation reports skill_layout" {
  echo "stray" > "$WORK/development-fixture/skills/stray.md"
  [ "$(count "$WORK" structure_validation)" -ge 1 ]
  [ "$(type0 "$WORK" structure_validation)" = "skill_layout" ]
}

@test "zsh script named .sh: script_quality reports shebang_extension_mismatch" {
  printf '#!/usr/bin/env zsh\nprint hi\n' > "$WORK/development-fixture/scripts/mislabeled.sh"
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '[.findings_by_tool.script_quality[].type] | index(\"shebang_extension_mismatch\")'"
  [ "$status" -eq 0 ]
}

@test "coverage is always null for a topic gather" {
  run bash -c "zsh '$GATHER' '$WORK' | jq -e '.coverage == null'"
  [ "$status" -eq 0 ]
}

# --- bare frontmatter values through fm_value (#3347) -------------------------

SKILL_MD=development-fixture/skills/demo/SKILL.md
AGENT_MD=development-fixture/agents/helper.md

# set_line <file> <key> <rest> -> make the fixture's `<key>:` line read exactly
# `<key>:<rest>`; an `effort:` line the agent lacks is added after its model line.
set_line() {
  local f="$WORK/$1"
  KEY="$2" REST="$3" awk '
    BEGIN { k = ENVIRON["KEY"]; line = k ":" ENVIRON["REST"] }
    index($0, k ":") == 1 { print line; done = 1; next }
    { print }
    k == "effort" && !done && index($0, "model:") == 1 { print line; done = 1 }
  ' "$f" > "$WORK/t" || return 1
  mv "$WORK/t" "$f" || return 1
  grep -qxF -- "$2:$3" "$f"
}

# sv_run -> run the gather; the caller asserts exit 0 and reads $output
sv_run() { run zsh "$GATHER" "$WORK"; }

# sv_is <jq-predicate> -> exit 0 when the predicate holds on skill_validation
sv_is() { echo "$output" | jq -e --arg skill "$SKILL_MD" --arg agent "$AGENT_MD" "(.findings_by_tool.skill_validation // []) | $1" >/dev/null; }

# expect_clean <file> <key> <rest> -> exit 0 and zero skill_validation findings
expect_clean() {
  set_line "$1" "$2" "$3"
  sv_run
  [ "$status" -eq 0 ] || { echo "exit $status for $2:$3"; return 1; }
  sv_is 'length == 0' || { echo "findings for $2:$3: $output"; return 1; }
}

@test "fm_value: one shared helper, no per-key grep|head|sed value pipeline left (#3347)" {
  [ "$(grep -cE '^ *fm_value\(\) \{' "$GATHER")" -eq 1 ]
  [ "$(grep -cE "\^(name|model|effort):.*\| *head .*\| *sed" "$GATHER")" -eq 0 ]
  [ "$(grep -cE '(name|model|effort)_val=\$\(fm_value (name|model|effort)\)' "$GATHER")" -eq 3 ]
}

@test "fm_value: double-quoted valid name, model and effort give zero findings (#3347)" {
  expect_clean "$SKILL_MD" name ' "demo"'
  expect_clean "$AGENT_MD" model ' "opus"'
  expect_clean "$AGENT_MD" effort ' "high"'
}

@test "fm_value: single-quoted valid name, model and effort give zero findings (#3347)" {
  expect_clean "$SKILL_MD" name " 'demo'"
  expect_clean "$AGENT_MD" model " 'opus'"
  expect_clean "$AGENT_MD" effort " 'high'"
}

@test "fm_value: a trailing comment outside quotes is dropped (#3347)" {
  expect_clean "$SKILL_MD" name ' demo # note'
  expect_clean "$AGENT_MD" model ' opus # note'
  expect_clean "$AGENT_MD" effort ' high # note'
  expect_clean "$SKILL_MD" name ' "demo" # note'
}

@test "fm_value: trailing whitespace on an unquoted value is trimmed (#3347)" {
  expect_clean "$SKILL_MD" name ' demo   '
  expect_clean "$AGENT_MD" model ' opus  '
}

# expect_one <file> <key> <rest> <type> <needle> -> exit 0, exactly one
# skill_validation finding, of <type>, whose message contains <needle>
expect_one() {
  set_line "$1" "$2" "$3"
  sv_run
  [ "$status" -eq 0 ] || { echo "exit $status for $2:$3"; return 1; }
  sv_is "length == 1 and .[0].type == \"$4\"" || { echo "for $2:$3: $output"; return 1; }
  echo "$output" | jq -e --arg n "$5" '.findings_by_tool.skill_validation[0].message | contains($n)' >/dev/null \
    || { echo "message lacks [$5]: $output"; return 1; }
}

@test "fm_value: a # inside a quote pair is part of the value (#3347)" {
  expect_one "$SKILL_MD" name ' "de # mo"' name_mismatch 'de # mo'
}

@test "fm_value: an unmatched quote is not stripped (#3347)" {
  expect_one "$SKILL_MD" name ' "demo' name_mismatch '"demo'
}

@test "fm_value: a # with no whitespace before it starts no comment (#3347)" {
  expect_one "$SKILL_MD" name ' demo#x' name_mismatch 'demo#x'
}

@test "fm_value: a wrong quoted name with a comment is reported bare (#3347)" {
  expect_one "$SKILL_MD" name ' "other" # note' name_mismatch '“other”'
  sv_is '.[0] | .id == ("skill:" + $skill + ":name") and .severity == "high" and .field == "name"'
  sv_is '.[0].message | (contains("\"") or contains("note")) | not'
}

@test "fm_value: a wrong quoted model with a comment is reported bare (#3347)" {
  expect_one "$AGENT_MD" model ' "gpt" # note' invalid_model '“gpt”'
  sv_is '.[0] | .id == ("skill:" + $agent + ":model") and .severity == "medium" and .field == "model"'
  sv_is '.[0].message | (contains("\"") or contains("note")) | not'
}

@test "fm_value: a wrong quoted effort with a comment is reported bare (#3347)" {
  expect_one "$AGENT_MD" effort " 'bogus' # note" invalid_effort '“bogus”'
  sv_is '.[0] | .id == ("skill:" + $agent + ":effort") and .severity == "medium" and .field == "effort"'
  sv_is ".[0].message | (contains(\"'\") or contains(\"note\")) | not"
}

# expect_empty <file> <key> <rest> -> exit 0 and exactly one finding: the
# missing_field for <key>, with its id and field
expect_empty() {
  set_line "$1" "$2" "$3"
  sv_run
  [ "$status" -eq 0 ] || { echo "exit $status for $2:$3"; return 1; }
  sv_is "length == 1 and .[0].type == \"missing_field\" and .[0].field == \"$2\" and .[0].id == (\"skill:$1:$2\")" \
    || { echo "for $2:$3: $output"; return 1; }
}

@test "empty value: name in each empty form gives one missing_field (#3347)" {
  for rest in '' ' ""' " ''" ' # todo'; do expect_empty "$SKILL_MD" name "$rest"; done
}

@test "empty value: model in each empty form gives one missing_field, no invalid_model (#3347)" {
  for rest in '' ' ""' " ''" ' # todo'; do expect_empty "$AGENT_MD" model "$rest"; done
}

@test "empty value: effort in each empty form gives one missing_field, never invalid_effort (#3347)" {
  for rest in '' ' ""' " ''" ' # todo'; do expect_empty "$AGENT_MD" effort "$rest"; done
}

@test "no duplicate missing_field: absent and empty name or model each give exactly one (#3347)" {
  drop_key "$SKILL_MD" name
  drop_key "$AGENT_MD" model
  sv_run
  [ "$status" -eq 0 ]
  sv_is 'length == 2 and all(.type == "missing_field") and (group_by(.id) | all(length == 1))'
  cp -R "$REPO_ROOT/tests/fixtures/clean/development-fixture/." "$WORK/development-fixture/"
  set_line "$SKILL_MD" name ''
  set_line "$AGENT_MD" model ' # todo'
  sv_run
  [ "$status" -eq 0 ]
  sv_is 'length == 2 and all(.type == "missing_field") and (group_by(.id) | all(length == 1))'
}

@test "empty value: missing_field wording for a present-but-empty key (#3347)" {
  set_line "$SKILL_MD" name ''
  set_line "$AGENT_MD" model ' ""'
  set_line "$AGENT_MD" effort " ''"
  sv_run
  [ "$status" -eq 0 ]
  sv_is 'length == 3 and all(.severity == "high" and .type == "missing_field" and .files == [.file])'
  sv_is 'any(.field == "name" and .kind == "skill" and .message == "skill \($skill): frontmatter key “name” has no value" and .fix == "give “name:” a value")'
  sv_is 'any(.field == "model" and .kind == "agent" and .message == "agent \($agent): frontmatter key “model” has no value" and .fix == "give “model:” a value")'
  sv_is 'any(.field == "effort" and .kind == "agent" and .message == "agent \($agent): frontmatter key “effort” has no value" and .fix == "give “effort:” one of low, medium, high, xhigh or max (or remove the line)")'
}

@test "absent key: missing_field wording is unchanged (#3347)" {
  drop_key "$SKILL_MD" name
  sv_run
  [ "$status" -eq 0 ]
  sv_is 'length == 1 and .[0].message == "skill \($skill) is missing required frontmatter key “name”" and .[0].fix == "add “name:” to the frontmatter" and .[0].severity == "high"'
}

@test "empty description or tools value gives no missing_field (#3347)" {
  set_line "$SKILL_MD" description ''
  set_line "$AGENT_MD" tools ' # todo'
  sv_run
  [ "$status" -eq 0 ]
  sv_is 'length == 0'
}

@test "ARCHITECTURE.md effort section: an empty effort value is a missing_field (#3347)" {
  run effort_section
  contains "$output" "An \`effort:\` line whose value is empty after stripping one pair of quotes and a trailing comment is reported as \`missing_field\` (\`field: \"effort\"\`), never as \`invalid_effort\`."
}
