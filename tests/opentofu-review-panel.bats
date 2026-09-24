#!/usr/bin/env bats
#
# development-opentofu's four agents and its review panel (issue #1161, child 3
# of epic #1158).
#
# The agents and the review skill ship no executable behaviour beyond the gate
# script (tests/opentofu-review-gate.bats), so their PROSE is the contract, and
# the clauses pinned here are the ones a later edit could drop with the rest of
# the suite green: the frontmatter each agent is dispatched by, the two routing
# names #1160's dispatcher already spells, the two-member panel, the three gate
# outcomes, and the whole-tree-read / changed-file-report split.
#
# Conventions inherited from tests/opentofu-dispatcher.bats: every haystack is
# SCOPED to the section that must carry the clause and asserted non-empty
# first, and needles are chosen so a negated clause cannot satisfy them.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLUGIN_DIR="$REPO_ROOT/development-opentofu"
  AGENTS="$PLUGIN_DIR/agents"
  SKILL="$PLUGIN_DIR/skills/review/SKILL.md"
  DISPATCHER="$PLUGIN_DIR/skills/maintenance/SKILL.md"
  [ -d "$AGENTS" ]
  [ -f "$SKILL" ]
  [ -f "$DISPATCHER" ]
}

# frontmatter value of key $2 in file $1 (first frontmatter block only)
fm() {
  awk -v k="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside && index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }
  ' "$1"
}

# the SKILL.md section under the H2 whose title starts with $1, flattened
section() {
  sed -n "/^## $1/,/^## /p" "$SKILL" | tr -s '[:space:]' ' '
}

# an agent's section under the H2 $2, flattened
agent_section() {
  sed -n "/^## $2/,/^## /p" "$AGENTS/$1.md" | tr -s '[:space:]' ' '
}

@test "the agent set is exactly the four named files (#1161)" {
  local names
  names="$(cd "$AGENTS" && LC_ALL=C ls -A | LC_ALL=C sort | tr '\n' ' ')"
  [ "$names" = "opentofu-format-fixer.md opentofu-module-advisor.md opentofu-policy-triage.md opentofu-security-reviewer.md " ]
}

@test "every agent's frontmatter is valid and its name matches its filename (#1161)" {
  local f stem
  for f in "$AGENTS"/*.md; do
    stem="$(basename "$f" .md)"
    [ "$(head -1 "$f")" = "---" ]
    # a closing delimiter exists, so the frontmatter actually ends
    [ "$(sed -n '2,$p' "$f" | grep -c '^---$')" -ge 1 ]
    [ "$(fm "$f" name)" = "$stem" ] || { echo "name != filename in $f" >&2; return 1; }
    [ -n "$(fm "$f" description)" ]
    [ "$(fm "$f" model)" = "opus" ]
    [ -n "$(fm "$f" tools)" ]
    # and a body beyond the frontmatter
    [ "$(awk 'n >= 2 && NF { c++ } /^---$/ { n++ } END { print c + 0 }' "$f")" -gt 10 ]
  done
}

@test "the two reviewers are read-only — Read, Grep, Glob, no Bash (#1161)" {
  local a
  for a in opentofu-security-reviewer opentofu-module-advisor; do
    [ "$(fm "$AGENTS/$a.md" tools)" = "Read, Grep, Glob" ]
  done
}

@test "the fixer and the triage agent hold the tools their verify step needs (#1161)" {
  local a
  for a in opentofu-format-fixer opentofu-policy-triage; do
    [ "$(fm "$AGENTS/$a.md" tools)" = "Read, Edit, Bash, Grep" ]
  done
}

@test "the routed filenames equal #1160's dispatcher routing targets verbatim (#1161)" {
  # derived from the dispatcher's table, so the two stories' names can only
  # agree — which is what the filename criterion replaced a blockedBy edge with
  local routed a
  routed="$(sed -n 's/^| `[a-z_]*` | .* | `\([a-z-]*\)` |$/\1/p' "$DISPATCHER" | LC_ALL=C sort -u | tr '\n' ' ')"
  [ "$routed" = "opentofu-format-fixer opentofu-policy-triage opentofu-security-reviewer " ]
  for a in $routed; do
    [ -f "$AGENTS/$a.md" ]
  done
}

@test "no approver agent exists, by any name (#1161)" {
  [ -z "$(find "$AGENTS" -iname '*approver*')" ]
  run -1 grep -rli 'name: .*approver' "$AGENTS"
}

# --- the review skill ---------------------------------------------------------

@test "the review skill's frontmatter declares the command (#1161)" {
  [ "$(fm "$SKILL" name)" = "review" ]
  [ "$(fm "$SKILL" disable-model-invocation)" = "false" ]
  contains "$(fm "$SKILL" description)" 'two specialized parallel agents'
}

@test "the panel is exactly two agents, dispatched in parallel (#1161)" {
  local s rows
  s="$(section 'Step 2')"
  [ -n "$s" ]
  contains "$s" 'Dispatch two agents **in parallel**'
  rows="$(sed -n '/^## Step 2/,/^## /p' "$SKILL" | sed -n 's/^| [a-z]* | `\([a-z-]*\)` |$/\1/p' | tr '\n' ' ')"
  [ "$rows" = "opentofu-security-reviewer opentofu-module-advisor " ]
}

@test "the fixer and the triage agent are named as maintenance-routed non-members (#1161)" {
  local s
  s="$(section 'Step 2')"
  [ -n "$s" ]
  contains "$s" '`opentofu-format-fixer` and `opentofu-policy-triage` are **not** panel members'
  contains "$s" 'they are maintenance-routed'
  contains "$s" 'There is no approver dimension'
}

@test "the gate's three outcomes are stated distinctly (#1161)" {
  local s
  s="$(section 'Step 1')"
  [ -n "$s" ]
  # the gate is the script, invoked before anyone is dispatched
  contains "$s" 'scripts/tofu-review-gate.zsh" --repo <repo root>'
  [ -x "$PLUGIN_DIR/skills/review/scripts/tofu-review-gate.zsh" ]
  # 1. validate fails -> the round FAILS, detail to the sibling, findings untouched
  contains "$s" '**`tofu validate` FAILS → the round FAILS**'
  contains "$s" 'write the gate'"'"'s document to the sibling `<findings-path>.failed.json`, and write **nothing** to the findings path'
  # 2. registry unreachable -> DEGRADE, the round proceeds and can succeed
  contains "$s" '**`tofu init` cannot reach the provider registry → DEGRADE**'
  contains "$s" 'the round proceeds as a **source-only review** and can succeed'
  contains "$s" 'Report the gate'"'"'s `notes` to the caller'
  # 3. both pass -> full review
  contains "$s" '**Both pass → the FULL review**'
  # tflint absent degrades with a note, never fails
  contains "$s" '**`tflint` absent degrades with a note, never fails a round**'
  # its output is handed on as observed evidence
  contains "$s" 'its output is at `tflint.output_file`: pass that path to the agents'
  # an internal failure is a failed round, never a clean gate
  contains "$s" '**Exit `1` is an internal failure**'
  contains "$s" 'report its stderr and report the round as **failed**'
  contains "$s" '**Exit `2` is your own malformed invocation** — fix the command and re-run'
  contains "$s" 'Name the failing root module and the file its diagnostics point at'
  contains "$s" '`tofu` not being installed at all degrades the same way, with its own note'
  contains "$s" 'So does a `tflint` that is installed but could not run'
  contains "$s" 'A standalone run, which has no changed-file list, always runs the gate'
  contains "$s" 'and put them in the agents'"'"' prompt'
  contains "$s" 'never read an empty stdout as a clean gate'
  # an empty repository is not applicable, not a clean review of nothing
  contains "$s" 'report the round **not applicable** (below) rather than dispatching two agents over nothing'
}

@test "the skill reads the WHOLE tree regardless of scope, and reports only changed files (#1161)" {
  local s
  s="$(section 'Step 2')"
  [ -n "$s" ]
  contains "$s" '**regardless of what `$ARGUMENTS` scopes**'
  contains "$s" 'Scope narrows what is *reviewed*, never what is *read*'
  contains "$s" 'the same prune set as #1160'"'"'s detection recipe'
  contains "$s" '**Report against the CHANGED SOURCE FILE'
  contains "$s" 'keeps only findings whose `file` **exactly matches an entry in the story'"'"'s diff**'
  # the closest-changed-file fallback and the standalone-run relaxation
  contains "$s" 'the **closest changed file in scope** with `line: null`'
  contains "$s" '**A standalone run relaxes that rule.**'
  contains "$s" '`none — standalone run`'
}

@test "the findings path is array-only; failures go to the .failed.json sibling (#1161)" {
  local s3 s4
  s3="$(section 'Step 3')"
  s4="$(section 'Step 4')"
  [ -n "$s3" ]
  [ -n "$s4" ]
  contains "$s3" 'It is array-only by contract'
  contains "$s3" '**sibling** `<findings-path>.failed.json`'
  # the retry-once rule, all three conditions
  contains "$s3" 'errors, returns no fenced `json` block, **or returns a block that is not a JSON array**'
  contains "$s3" 're-launch it once'
  contains "$s4" 'concatenate their two JSON arrays into one array'
  contains "$s4" '**per-entry union outcomes**'
  contains "$s4" 'never a sum across agents'
  contains "$s4" "reproduce each agent's per-entry lines verbatim"
  contains "$s4" 'On a **degraded** round, also report the gate'"'"'s notes beside it'
}

@test "the injected prompt carries the machine-readable findings block (#1161)" {
  local p
  # the indented prompt block only
  p="$(sed -n '/^    Review scope: {SCOPE}/,/^Without this block/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$p" ]
  contains "$p" 'emit those same findings once more as a single fenced `json` block — a JSON array of finding objects'
  contains "$p" 'severity (the CRITICAL|WARNING|SUGGESTION tag from the prose), dimension ("{DIMENSION}"), file, line'
  contains "$p" 'reviewer ("{AGENT NAME}"), round ({ROUND})'
  contains "$p" 'read the WHOLE non-pruned .tf tree'
  contains "$p" 'A re-raise of a CARRIED entry is the one exception to all of the above'
  contains "$(section 'Step 2')" 'and the tflint output path when tflint ran'
  contains "$(section 'Step 2')" '`not run: carry verification only, no root validated` on a delta round dispatched only for its carry'
  # a decides: command must not write the tree the loop minted
  contains "$p" '`tofu init`, `tofu validate` and `tofu plan` do NOT'
}

@test "the loop's delta, carry and full-round contracts are carried over (#1161)" {
  local s
  s="$(section 'Step 2')"
  [ -n "$s" ]
  contains "$s" '**On a loop-driven DELTA round that carries NOTHING, every NOT-APPLICABLE shape writes `[]`**'
  contains "$s" '**"Carries nothing" is a precondition, not a detail'
  contains "$s" '**dispatch the agents anyway** with the carry'
  contains "$s" '**On a loop-driven FULL round the not-applicable terminal stands as written'
  contains "$s" '**In hook mode, write the accounting too (#1583).**'
  contains "$s" '**A FAILED round keeps the terminal on every round, delta or full**'
}

# --- the agents' load-bearing clauses -----------------------------------------

@test "the security reviewer holds the one opinion, dialect-aware and ownership-scoped (#1161)" {
  local s
  s="$(agent_section opentofu-security-reviewer 'State encryption')"
  [ -n "$s" ]
  contains "$s" '**state must be encrypted at rest**'
  contains "$s" 'The check is **dialect-aware**'
  contains "$s" 'so when state is unencrypted in a Terraform-dialect repo'
  contains "$s" 'a `.terraform.lock.hcl` whose providers come from `registry.terraform.io`, a `cloud` block'
  contains "$s" 'on the implicit local backend, which has none, moving state to a backend that encrypts it'
  contains "$s" '**never** suggest that block'
  contains "$s" 'Suggest its backend'"'"'s own at-rest form instead'
  contains "$s" 'and where the dialect cannot be told, name both'
  contains "$s" 'it binds only where the repo **owns** state'
  contains "$s" 'owns a state file that is plaintext unless the OpenTofu `encryption` block covers it — the local backend itself clears nothing'
}

@test "the security reviewer's maintenance role describes, never edits (#1161)" {
  local s
  s="$(agent_section opentofu-security-reviewer 'When the maintenance pipeline dispatches you')"
  [ -n "$s" ]
  contains "$s" '`validate`, `misconfiguration` and `state_encryption`'
  contains "$s" 'described for a human to act on, never rewritten'
  # the field the orchestrator reads — a heading nothing reads is a finding
  # dropped on the way to the human
  contains "$s" 'report one `actions_requiring_review` entry per finding'
}

@test "no agent reports into a heading the orchestrator never reads (#1161)" {
  run -1 grep -rnE '## (Escalations|Unverified)' "$AGENTS"
}

@test "the scope check runs before the gate, and deletions survive an EMPTY verdict (#1161)" {
  local s
  s="$(section 'Step 1')"
  [ -n "$s" ]
  contains "$s" 'but only once Step 2'"'"'s scope check has found an OpenTofu source in scope'
  contains "$s" 'a tree already broken on `main` must not fail a README-only story'
  contains "$s" 'When the changed-file list holds a **deleted** OpenTofu source'
  contains "$s" 'Remove the gate'"'"'s `work_dir` whenever the round ends — failed, not applicable, or after Step 4'
}

@test "the module advisor treats version pinning as a finding, not a style note (#1161)" {
  local s
  s="$(agent_section opentofu-module-advisor 'What to look for')"
  [ -n "$s" ]
  contains "$s" '**Version pinning is a finding, not a style note**'
  contains "$s" 'no `lifecycle { prevent_destroy = true }`'
  contains "$s" 'with no `moved` block'
  # and its severity guide makes an unpinned provider blocking
  contains "$(agent_section opentofu-module-advisor 'Reporting Format')" '**WARNING** — a real defect with a bounded blast radius: an unpinned or open-ended provider or module version'
}

@test "both reviewers confirm absence claims against the whole tree (#1161)" {
  local a
  for a in opentofu-security-reviewer opentofu-module-advisor; do
    contains "$(agent_section "$a" 'Absence findings')" 'search the **entire** non-pruned `.tf` tree'
  done
}

@test "the format fixer never crosses into changing what is provisioned (#1161)" {
  local s
  s="$(agent_section opentofu-format-fixer 'Escalate')"
  [ -n "$s" ]
  contains "$s" 'A linter suggesting a different instance size is suggesting an infrastructure change, not a lint fix'
  # tflint --fix deletes unused declarations, which changes a module's interface
  contains "$s" '`terraform_unused_declarations` fix *deletes*'
  contains "$s" 'any removed declaration is **reverted** and escalated'
  contains "$s" 'a CIDR, a provider or module version, a backend, or a module'"'"'s interface'
  contains "$s" 'Report every escalation as one `actions_requiring_review` entry per finding'
  local v
  v="$(agent_section opentofu-format-fixer 'Verify')"
  contains "$v" '`tofu fmt -check -recursive` for a format finding'
  contains "$v" 'Judge the re-run per finding, not by its exit code'
  contains "$v" '**revert your edit for it**'
}

@test "the policy triage agent escalates rather than edits a wrong policy (#1161)" {
  local s
  s="$(agent_section opentofu-policy-triage '2. The policy is wrong')"
  [ -n "$s" ]
  contains "$s" '**Escalate — do not edit the policy.**'
  contains "$s" 'A policy encodes an architectural decision the consuming repo owns'
  contains "$s" 'Report every escalation as one `actions_requiring_review` entry per policy'
  local t3
  t3="$(agent_section opentofu-policy-triage '3. The policy set has no tests')"
  contains "$t3" 'Do this **before** any case-1 fix in the same group'
  contains "$t3" '**Never** adjust the test'"'"'s expectation so the suite goes green'
  contains "$(agent_section opentofu-policy-triage 'Never')" 'Do not add policies'
  # and it verifies with the command that PRODUCED the finding
  local v
  v="$(agent_section opentofu-policy-triage 'Verify')"
  contains "$v" '`conftest test --policy policies/conftest`'
  contains "$v" '`conftest verify --policy policies/conftest`'
  contains "$v" 'Do not substitute one for the other'
  contains "$v" 'or a case-3 test whose `test_` rule fails `conftest verify`'
  contains "$v" 'Judge the re-run per finding, not by its exit code'
  contains "$v" '**revert whatever you edited for it — HCL *or* test**'
}
