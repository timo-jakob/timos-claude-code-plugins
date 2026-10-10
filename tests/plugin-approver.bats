#!/usr/bin/env bats
#
# The claude-plugin Approver (#2132), opt-in per session via
# CLAUDE_PLUGIN_APPROVER=1: its never-approve bar, its skill's override gate,
# its agent, its policy overlay and the APPROVER.md sections that document it.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BAR="$REPO_ROOT/development-claude-plugin/skills/approve/scripts/never-approve-bar.zsh"
  SKILL="$REPO_ROOT/development-claude-plugin/skills/approve/SKILL.md"
  AGENT="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-approver.md"
  OVERLAY="$REPO_ROOT/development-claude-plugin/skills/approve/approver-policy-overlay.md.tmpl"
  CORE="$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  APPROVER_DOC="$REPO_ROOT/development/skills/bootstrap/docs/APPROVER.md"
  cd "$BATS_TEST_TMPDIR"
  printf 'Summary\n' > body
  printf 'README.md\n' > paths
}

dossier() { printf 'x\n<!-- review-dossier: %s -->\n' "$1" > body; }

# ── the bar: clear ────────────────────────────────────────────────────────────

@test "bar: a clean docs-only change with a clean dossier is clear, silently" {
  dossier '{"dimensions":{"bugs":{"clean":true,"open":0},"tests":{"clean":false,"open":0}}}'
  printf 'docs/how-to/x.md\n' > paths
  run --separate-stderr zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "bar: no dossier block counts as open=0" {
  printf 'README.md\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bar: a dossier with no open keys, or no dimensions, counts as open=0" {
  for d in '{"dimensions":{"bugs":{"clean":true}}}' '{"terminal":"CONVERGED"}' '{"dimensions":{}}'; do
    dossier "$d"
    run zsh "$BAR" --body body --paths paths
    [ "$status" -eq 0 ] || { echo "not clear: $d"; false; }
    [ -z "$output" ]
  done
}

@test "bar: blank lines in the paths file are ignored" {
  printf '\n\ndocs/x.md\n\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── the bar: residue ──────────────────────────────────────────────────────────

@test "bar: residue in any dimension hits, summing open across dimensions" {
  dossier '{"dimensions":{"bugs":{"open":1},"tests":{"open":2},"contract":{"open":0}}}'
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  [ "$output" = "hit=residue open=3" ]
}

@test "bar: residue in a block that is not the first dossier block still hits" {
  printf '<!-- review-dossier: {"dimensions":{"bugs":{"open":0}}} -->\nmid\n<!-- review-dossier: {"dimensions":{"tests":{"open":2}}} -->\n' > body
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  [ "$output" = "hit=residue open=2" ]
}

@test "bar: a dossier block that is not valid JSON fails closed with exit 1, never clear" {
  dossier '{"dimensions":{"bugs":{"open":1}'
  run --separate-stderr zsh "$BAR" --body body --paths paths
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "review-dossier block is not valid JSON"
}

@test "bar: a non-numeric open fails closed with exit 1, never clear" {
  dossier '{"dimensions":{"bugs":{"open":"2"}}}'
  run --separate-stderr zsh "$BAR" --body body --paths paths
  [ "$status" -eq 1 ]
  contains "$stderr" "review-dossier block is not valid JSON"
}

@test "bar: an empty or blank-only paths file fails closed with exit 1, never clear" {
  for content in '' '\n\n'; do
    printf '%b' "$content" > paths
    run --separate-stderr zsh "$BAR" --body body --paths paths
    [ "$status" -eq 1 ] || { echo "not fail-closed: '$content' -> $status"; false; }
    [ -z "$output" ]
    contains "$stderr" "never-approve-bar: no changed paths — cannot judge"
  done
}

# ── the bar: paths ────────────────────────────────────────────────────────────

@test "bar: workflow paths hit" {
  printf '.github/workflows/script-tests.yml\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  [ "$output" = "hit=workflow path=.github/workflows/script-tests.yml" ]
}

@test "bar: every approval and identity machinery path hits, case-insensitively and at any depth" {
  for p in development-python/agents/python-approver.md \
           development/skills/bootstrap/docs/APPROVER.md \
           development/skills/maintenance/scripts/mint-approver-token.zsh \
           development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl \
           development/skills/bootstrap/scripts/resolve-approval.zsh \
           development/skills/bootstrap/scripts/claude-apps-owner.zsh \
           development/skills/bootstrap/scripts/install-claude-apps.zsh \
           development/skills/bootstrap/scripts/register-claude-apps.zsh \
           resolve-approval.zsh \
           claude-apps-owner.zsh \
           install-claude-apps.zsh \
           register-claude-apps.zsh \
           development/skills/maintenance/scripts/mint-maintenance-token.zsh \
           mint-maintenance-token.zsh \
           development/scripts/approval/plugin-approver-override.zsh \
           development-claude-plugin/skills/approve/SKILL.md \
           development-claude-plugin/skills/approve/scripts/new-helper.zsh; do
    printf '%s\n' "$p" > paths
    run zsh "$BAR" --body body --paths paths
    [ "$status" -eq 3 ] || { echo "not caught: $p"; false; }
    [ "$output" = "hit=approval-machinery path=$p" ] || { echo "wrong line for $p: $output"; false; }
  done
}

@test "bar: a look-alike outside the machinery is clear" {
  printf '%s\n' development/skills/bootstrap/scripts/resolve-approval-notes.md \
                development-claude-plugin/skills/approval-docs/x.md \
                docs/my-claude-apps-owner.zsh.md > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ]
}

@test "bar: every hit is reported, one line each, residue first" {
  dossier '{"dimensions":{"bugs":{"open":1}}}'
  printf '%s\n' docs/x.md .github/workflows/a.yml development-claude-plugin/skills/approve/SKILL.md > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  [ "$output" = $'hit=residue open=1\nhit=workflow path=.github/workflows/a.yml\nhit=approval-machinery path=development-claude-plugin/skills/approve/SKILL.md' ]
}

# ── the bar: usage ────────────────────────────────────────────────────────────

@test "bar: usage error (exit 2) on a missing, unknown, valueless or unreadable argument" {
  run --separate-stderr zsh "$BAR" --body body
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: never-approve-bar.zsh --body <file> --paths <file>"
  run zsh "$BAR" --paths paths
  [ "$status" -eq 2 ]
  run zsh "$BAR" --body body --paths paths --extra
  [ "$status" -eq 2 ]
  run zsh "$BAR" --body body --paths
  [ "$status" -eq 2 ]
  run zsh "$BAR" --body nope --paths paths
  [ "$status" -eq 2 ]
  run zsh "$BAR" --body body --paths nope
  [ "$status" -eq 2 ]
}

# ── the skill ─────────────────────────────────────────────────────────────────

@test "skill: gates on the override helper first and is a clean no-op when it is off" {
  grep -q 'plugin-approver-override.zsh' "$SKILL"
  grep -qF 'echo "AI approval: off (${REASON}) — a human approves."' "$SKILL"
  grep -qF "grep -qx 'override=on'" "$SKILL"
  grep -qF 'That line is informational, not an error: report it and stop, exit 0.' "$SKILL"
}

@test "skill: refuses PRs not authored by the Maintenance App, the same way" {
  grep -qF "grep -qE '^(app/)?claude-maintenance'" "$SKILL"
  grep -qF 'AI approval: off (PR authored by ${AUTHOR}, not the Maintenance App) — a human approves.' "$SKILL"
}

@test "skill: its steps run in the issue's order — override, author, mergeability, bar, mint, agent" {
  local lines
  lines=$(grep -n '^## Step [0-9]' "$SKILL" | cut -d: -f2-)
  [ "$lines" = $'## Step 0 — Is AI approval on for this session?\n## Step 1 — Resolve the PR and check its author\n## Step 2 — Mergeability gate\n## Step 3 — Policy and never-approve bar\n## Step 4 — Mint the Approver token, just in time\n## Step 5 — Spawn the agent, then clean up\n## Step 6 — Report' ]
}

@test "skill: renders the core with APPROVER_LANG=claude-plugin then the overlay, and runs the bar on old and new paths" {
  grep -qF "sed 's/{{APPROVER_LANG}}/claude-plugin/g'" "$SKILL"
  grep -qF 'cat "<skill-base-dir>/approver-policy-overlay.md.tmpl" >> "$SCRATCH/policy.md"' "$SKILL"
  grep -qF '.previous_filename // empty' "$SKILL"
  grep -qF 'gh api --paginate "repos/$REPO/pulls/$PR_NUMBER/files"' "$SKILL"
  grep -q 'never-approve-bar.zsh' "$SKILL"
  grep -qF '> "$SCRATCH/bar" || BAR_RC=$?' "$SKILL"
  grep -qF 'Any other exit: stop. Post nothing' "$SKILL"
}

@test "skill: a failed render or fetch in Step 3 stops the block before the bar runs" {
  pin_each "$SKILL" \
    '} || { echo "::error::Policy render or PR fetch failed — posting nothing."; rm -rf "$SCRATCH"; exit 1; }' \
    '[ -n "$REPO" ] || { echo "::error::Could not resolve the repository — posting nothing."; exit 1; }' \
    'exits 1 on it: a bar run over an empty or partial paths file would read as clear.' \
    'empty paths list — the bar fails closed rather than call it clear; exit 2 is'
  local n
  for n in 'development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl > "$SCRATCH/policy.md" &&' \
           'cat "<skill-base-dir>/approver-policy-overlay.md.tmpl" >> "$SCRATCH/policy.md" &&' \
           'gh pr view "$PR_NUMBER" --json body -q .body > "$SCRATCH/body" &&'; do
    grep -qF -- "$n" "$SKILL" || { echo "unchained: $n"; false; }
  done
}

@test "skill: a conflicting PR is re-synced by sync-prs with no argument, then re-entered from Step 1" {
  pin_each "$SKILL" \
    '- `CONFLICTING` → run `/development:sync-prs` with no argument: it re-syncs' \
    'every conflicting Maintenance-App PR, this one included. Then re-check' \
    '`mergeable` with the same handful of retries: `MERGEABLE` → re-enter this' \
    'skill from Step 1 (the agent'"'"'s Step 8 waits for CI). Anything else, or a' \
    '`needs-manual-rebase` label, stays with a human: stop and report. The'
  run grep -F '/development:sync-prs <' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "skill: mints the token as a file path just in time and removes it with the scratch dir" {
  grep -qF 'TOKEN_FILE=$(development/skills/maintenance/scripts/mint-approver-token.zsh)' "$SKILL"
  grep -qF '[ -s "$TOKEN_FILE" ] || { echo "::error::Failed to mint Approver token."; rm -rf "$SCRATCH"; exit 1; }' "$SKILL"
  grep -qF 'rm -rf "$TOKEN_FILE" "$SCRATCH"' "$SKILL"
  grep -q 'subagent_type="development-claude-plugin:claude-plugin-approver"' "$SKILL"
}

# ── the agent ─────────────────────────────────────────────────────────────────

@test "agent: frontmatter names it, pins fable and its three tools" {
  [ "$(head -1 "$AGENT")" = "---" ]
  head -6 "$AGENT" | grep -qx 'name: claude-plugin-approver'
  head -6 "$AGENT" | grep -qx 'model: fable'
  head -6 "$AGENT" | grep -qx 'tools: Bash, Read, Grep'
}

@test "agent: takes POLICY_FILE and BAR_FILE and hard-fails without them" {
  grep -q '| `POLICY_FILE` |' "$AGENT"
  grep -q '| `BAR_FILE` |' "$AGENT"
  grep -qF '`POLICY_FILE` or `BAR_FILE` is unset, missing or unreadable.' "$AGENT"
}

@test "agent: Step 0 — any hit= line means it never posts APPROVE, and COMMENTs with a Needs-a-human list" {
  grep -q '^### Step 0 — The never-approve bar' "$AGENT"
  grep -qF 'If it holds any `hit=` line, you **never post `APPROVE`**' "$AGENT"
  grep -qF '`COMMENT` with a "Needs a human" section that lists every hit verbatim' "$AGENT"
  grep -qF 'This bar is not a judgment call and confidence cannot lift it.' "$AGENT"
  grep -qF 'Record each hit as a finding `{"category": "never_approve_bar", "title":' "$AGENT"
}

@test "agent: Step 8 waits for CI to settle and never reads a pending check as green" {
  pin_each "$AGENT" \
    '- CI green at head SHA — first wait for every check to settle with' \
    '`gh pr checks "$PR_NUMBER" --watch`; a pending check is never green.' \
    'Then green means zero checks in the `fail` bucket. Cancelled checks are' \
    'neutral, never failures. If it reports no checks yet, or any check is' \
    'still pending when it returns, post nothing and report that the review'
}

@test "agent: cheap local checks are syntax, shellcheck, jq and the version bump" {
  grep -qF '`zsh -n` on each changed `*.zsh`; `bash -n` on each changed `*.sh`;' "$AGENT"
  grep -qF '`shellcheck` on each changed shell script it can parse' "$AGENT"
  grep -qF '`jq empty` on each changed `*.json`;' "$AGENT"
  grep -qF "version differs from \`origin/main\`'s and equals its" "$AGENT"
}

@test "agent: PR data lives in a per-run mktemp -d directory, never a fixed /tmp path (#2222)" {
  run grep -n '/tmp/pr' "$AGENT"
  [ "$status" -eq 1 ]
  grep -qxF 'work=$(mktemp -d) && echo "work=$work"' "$AGENT"
  for f in pr.json pr.diff pr.files; do
    grep -qF "> \"\$work/$f\"" "$AGENT" || { echo "not written under \$work: $f"; false; }
  done
  grep -qF 'body=$(jq -r .body "$work/pr.json")' "$AGENT"
  grep -qF '> "$work/pr.issue.json"' "$AGENT"
  grep -qF "exit 2; grep -E '^\\+<<<<<<<' \"\$work/pr.diff\"" "$AGENT"
  grep -qF 'fallback (diff heuristic over `$work/pr.files`,' "$AGENT"
  grep -qF 'review_body_file="$work/review.md"' "$AGENT"
  [ "$(grep -cxF 'work=<the path Step 2 printed>; [ -d "$work" ] || exit 1' "$AGENT")" -eq 2 ]
  grep -qF -- '- Conflict markers — `work=<the path Step 2 printed>; [ -s "$work/pr.diff" ] ||' "$AGENT"
  grep -qxF 'verdict=<APPROVE, REQUEST_CHANGES or COMMENT>' "$AGENT"
  grep -qF "echo \"::error::unknown verdict '\$verdict' — posting nothing\" >&2; exit 1" "$AGENT"
  for arm in APPROVE:approve REQUEST_CHANGES:request-changes COMMENT:comment; do
    grep -A1 -xF "  ${arm%%:*})" "$AGENT" | grep -qxF -- \
      "    gh pr review \"\$PR_NUMBER\" --${arm#*:} --body-file \"\$review_body_file\"" \
      || { echo "arm not posting --${arm#*:}: ${arm%%:*}"; false; }
  done
  grep -qxF 'export GH_TOKEN=$(cat <the token file path>) && [ -n "$GH_TOKEN" ] || exit 1' "$AGENT"
  pin_each "$AGENT" \
    '`GH_TOKEN` (re-exported from its token file), `PR_NUMBER`, `work`,' \
    '`verdict` (exactly one of the three bare tokens) and the' \
    'rendered body in this same Bash call — none survives from an earlier' \
    '  any other non-zero status is a failed check, never a pass.'
  pin_each "$AGENT" \
    '**Make a per-run work directory first.** Two approve runs at once (two' \
    'sessions, two PRs) must never share PR data, so nothing goes to a fixed' \
    'If `mktemp -d` fails, stop and post nothing. Shell variables do not' \
    'survive between your Bash calls, so set `work` to the printed path,' \
    '`PR_NUMBER`, `GH_TOKEN` (re-exported from its token file), `wt` and' \
    'every other variable a block reads, at the top of that block — each' \
    'later block below starts with `work=<the path Step 2 printed>` and' \
    '`[ -d "$work" ] || exit 1`. **Remove it before you return, on' \
    'every path** — the early stops (a conflicting PR, CI not settled, a' \
    'refusal) and the dry-run print included — with `rm -rf "$work"`,' \
    "alongside the scratch worktree's removal." \
    "with Step 2's per-run work directory (\`rm -rf \"\$work\"\`). Never"
}

@test "agent: nothing Python-specific survives the copy" {
  run grep -n -i 'python\|ruff\|pytest\|pyproject\|griffe' "$AGENT"
  [ "$status" -eq 1 ]
}

# ── the policy ────────────────────────────────────────────────────────────────

@test "policy: the core's only placeholder is APPROVER_LANG, so the skill's sed renders it fully" {
  run grep -oE '\{\{[A-Z_]+\}\}' "$CORE"
  [ "$(printf '%s\n' "$output" | sort -u)" = "{{APPROVER_LANG}}" ]
}

@test "policy: the overlay is headed for claude-plugin and makes any bar hit a COMMENT" {
  grep -qx '# Overlay — Claude plugin' "$OVERLAY"
  grep -qF 'Any `hit=` line means the verdict is `COMMENT`' "$OVERLAY"
  grep -qF "overrides the core's leniency for disclosed residue. On a plugin repo," "$OVERLAY"
}

@test "policy: the overlay covers plugin test idioms and the plugin.json + marketplace.json bump" {
  grep -q '^## Test idioms' "$OVERLAY"
  grep -qF '`plugin.json`' "$OVERLAY"
  grep -qF '`.claude-plugin/marketplace.json` entry' "$OVERLAY"
}

@test "policy: the overlay's load-bearing sentences" {
  pin_each "$OVERLAY" \
    'identity machinery. The one exception is `REQUEST_CHANGES`, when the core'"'"'s' \
    'calibration already gives it; the verdict is never `APPROVE`. This bar' \
    'residue goes to a human.' \
    'The bar is not a judgment call, and no confidence level lifts it. An empty' \
    '`BAR_FILE` means the bar is clear; the core'"'"'s criteria then decide as usual.' \
    'bump is a REQUEST_CHANGES finding, because installs would never see the change.' \
    '- Every changed `*.zsh` must pass `zsh -n`. Every changed `*.sh` or `*.bash`' \
    'must pass `bash -n` and `shellcheck`, which cannot parse zsh.' \
    'Coverage-padding patterns to flag: a bats `@test` whose only assertion is' \
    '`[ "$status" -eq 0 ]` on a command whose output is the behaviour; `grep -q`' \
    'needles that pin a word rather than the load-bearing sentence; a stubbed' \
    'tool also present in the runner'"'"'s `/usr/bin` without hiding it; and' \
    'assertions piped through `| tail`, which reads tail'"'"'s exit, not bats'"'"'.'
}

@test "policy: the overlay carries no placeholder of its own" {
  run grep -E '\{\{[A-Z_]+\}\}' "$OVERLAY"
  [ "$status" -eq 1 ]
}

# ── APPROVER.md ───────────────────────────────────────────────────────────────

@test "APPROVER.md documents the plugin opt-in and the no-App setup, both in its table of contents" {
  grep -qx '## Plugin repos: opt-in per session' "$APPROVER_DOC"
  grep -qx '### Forbidding AI approvals' "$APPROVER_DOC"
  grep -qF '(#plugin-repos-opt-in-per-session)' "$APPROVER_DOC"
  grep -qF '(#forbidding-ai-approvals)' "$APPROVER_DOC"
  grep -qF 'without an error or a' "$APPROVER_DOC"
}

# ── load-bearing sentences the new behaviour rests on ─────────────────────────

# Each needle is a line-local piece of a load-bearing sentence in the shipped
# prose: rewording one is a behaviour change this suite must notice.
pin_each() {
  local file="$1"; shift
  local s
  for s in "$@"; do
    grep -qF -- "$s" "$file" || { echo "unpinned in $file: $s"; return 1; }
  done
}

@test "agent: the bar outranks every other verdict path" {
  pin_each "$AGENT" \
    '- `APPROVE` — confidence HIGH, the risk register has no load-bearing' \
    'entries, **and** the never-approve bar is clear.' \
    'a human"; defers to a human for the binary call. Always `COMMENT`' \
    'when the bar hit, unless a finding already makes it `REQUEST_CHANGES`.' \
    '- Bar hit → never `APPROVE`: `COMMENT`, or `REQUEST_CHANGES` when the' \
    '- Do not post `APPROVE` when `BAR_FILE` holds any `hit=` line — under' \
    'is not metadata-grounded in this sense: it was computed before you ran,' \
    'The operator-facing companion is `development/skills/bootstrap/docs/APPROVER.md`'
}

@test "skill: every off state and every failed step stops without posting" {
  pin_each "$SKILL" \
    '`env-unset`, `approver-not-registered` and `approver-not-installed` are the' \
    'as `approver-key-missing`), relay it once; the human path still applies.' \
    'Anything but an exact `override=on` line — including a helper that could not' \
    "The Approver reviews only Maintenance-App PRs. A human's PR is reviewed by a" \
    'handful of retries) before deciding. Still `UNKNOWN` → stop and report.' \
    '- `BAR_RC` 0 → clear (`$SCRATCH/bar` is empty); 3 → hit (one `hit=` line per' \
    '- Any other exit: stop. Post nothing, mint nothing, remove `$SCRATCH`, and relay' \
    'A failed `sed`, `gh pr view` or `gh api` above is the same stop, and the block' \
    'never the value (#640). Capture the path; never `cat` or `echo` the token.' \
    'say "Needs a human" and list every `hit=` line.' \
    'print `usage: /development-claude-plugin:approve [<pr-number>]` and stop.'
}

@test "skill: the security notes name the opt-in, the identity split and the scripted bar" {
  pin_each "$SKILL" \
    '- **Opt-in per session, never recorded.**' \
    'distinct from the Maintenance App that authored the PR.' \
    '- **The never-approve bar is a script, not a judgment**: residue, workflow'
}

@test "APPROVER.md: the always-human kinds, the COMMENT verdict and the exact opt-in value" {
  pin_each "$APPROVER_DOC" \
    'kinds of change always go to a human, whatever the review concludes: residue' \
    '"Needs a human" list (or `REQUEST_CHANGES` when the review already gives it),' \
    'never `APPROVE`. Nothing is recorded in the repository.' \
    '`CLAUDE_PLUGIN_APPROVER=1` (exactly `1`; any other value is off). Then run' \
    '`/development-claude-plugin:approve <pr>` by hand on each PR; on `APPROVE`,' \
    'armed auto-merge merges it. On the PRs they open, `/development:resolve-issue`' \
    '`/development:maintenance` call the skill for you: each asks' \
    '`development/scripts/approval/plugin-approver-override.zsh`, and on' \
    '`override=on` drives `/development-claude-plugin:approve` itself.'
}
