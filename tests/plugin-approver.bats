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
  grep -qxF 'export GH_TOKEN=$(cat <the token file path>) && [ -n "$GH_TOKEN" ] || exit 1' "$AGENT"
  pin_each "$AGENT" \
    '`GH_TOKEN` (re-exported from its token file), `PR_NUMBER`, `REPO`,' \
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
    'head or body change, a failed re-read, unsettled CI or a conflicting PR), say' \
    '`/development-claude-plugin:approve` — never report its derived verdict as posted.' \
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

# ── the bar is tied to the head and body it judged (#2223) ────────────────────

# The first ```bash block after the line containing $2, verbatim.
extract_block() {
  awk -v m="$2" 'index($0, m) { f = 1 } f && /^```bash$/ { b = 1; next } b && /^```$/ { exit } b { print }' "$1"
}

# A gh stub: logs every call to $GH_LOG, answers `pr view` from $STUB_HEAD /
# $STUB_BODY (printed newline-terminated, as gh prints a body), fails the head
# read when $STUB_FAIL is set, and lists $STUB_PATHS for `api …/files`.
stub_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >> "$GH_LOG"' \
    'case "$*" in' \
    '  *headRefOid*) [ -z "${STUB_FAIL:-}" ] || exit 1; printf "%s\n" "$STUB_HEAD" ;;' \
    '  *"--json body"*) printf "%s\n" "$STUB_BODY" ;;' \
    '  *nameWithOwner*) printf "o/r\n" ;;' \
    '  *"--json author"*) exit 1 ;;' \
    '  *"/files"*) printf "%s\n" "${STUB_PATHS:-README.md}" ;;' \
    '  "api --method POST"*) printf "https://github.com/o/r/pull/42#pullrequestreview-1\n" ;;' \
    '  *) exit 99 ;;' \
    'esac' > "$BATS_TEST_TMPDIR/bin/gh"
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
}

sha_of_body() { printf '%s\n' "$1" | shasum -a 256 | cut -d' ' -f1; }

# Agent Step 12's block with its placeholders filled in: judged head abc123,
# judged body "Summary", the given verdict and DRY_RUN, and the per-run
# heredoc delimiter built from the work directory's name.
step12_script() {
  local verdict="$1" dry="$2" work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work"; printf 'tok\n' > "$BATS_TEST_TMPDIR/token"
  extract_block "$AGENT" 'The guard and the `case` stay in this one call' | sed \
    -e "s|<the review delimiter>|REVIEW_work|g" \
    -e "s|<the token file path>|$BATS_TEST_TMPDIR/token|" \
    -e 's|<the PR number>|42|' -e 's|<owner>/<repo>|o/r|' -e "s|<true or false>|$dry|" \
    -e 's|<HEAD_SHA from the prompt>|abc123|' \
    -e "s|<BODY_SHA256 from the prompt>|$(sha_of_body Summary)|" \
    -e "s|<the path Step 2 printed>|$work|" \
    -e "s|<APPROVE, REQUEST_CHANGES or COMMENT>|$verdict|" \
    -e 's|<the rendered review body>|RENDERED REVIEW|' > "$BATS_TEST_TMPDIR/step12.sh"
}

@test "skill Step 3: HEAD_SHA is read first and BODY_SHA256 hashes the body file, both inside the fail-closed group" {
  local block
  block=$(extract_block "$SKILL" '## Step 3 — Policy and never-approve bar')
  [ "$(printf '%s\n' "$block" | sed -n 4p)" = \
    '{ HEAD_SHA=$(gh pr view "$PR_NUMBER" --json headRefOid -q .headRefOid) && [ -n "$HEAD_SHA" ] &&' ]
  local body_line hash_line group_end
  body_line=$(printf '%s\n' "$block" | grep -nF 'gh pr view "$PR_NUMBER" --json body -q .body > "$SCRATCH/body" &&' | cut -d: -f1)
  hash_line=$(printf '%s\n' "$block" | grep -nxF \
    '  BODY_SHA256=$(shasum -a 256 < "$SCRATCH/body" | cut -d'"' '"' -f1) && [ -n "$BODY_SHA256" ] &&' | cut -d: -f1)
  group_end=$(printf '%s\n' "$block" | grep -nF '} || { echo "::error::Policy render or PR fetch failed' | cut -d: -f1)
  [ -n "$body_line" ]
  [ -n "$hash_line" ]
  [ -n "$group_end" ]
  [ "$body_line" -lt "$hash_line" ]
  [ "$hash_line" -lt "$group_end" ]
}

@test "skill Step 3 runs: it prints the judged head and body hash, and an empty head stops before the bar" {
  stub_gh
  local block
  block=$(extract_block "$SKILL" '## Step 3 — Policy and never-approve bar' \
    | sed -e "s|<skill-base-dir>|$REPO_ROOT/development-claude-plugin/skills/approve|" \
      -e 's|<the PR_NUMBER Step 1 printed>|42|' -e 's|<the REPO Step 1 printed>|o/r|')
  printf '%s\n' "$block" > step3.sh
  cd "$REPO_ROOT"
  TMPDIR="$BATS_TEST_TMPDIR" STUB_HEAD=abc123 STUB_BODY=Summary run bash "$BATS_TEST_TMPDIR/step3.sh"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "${lines[@]:1}")" = "$(printf 'HEAD_SHA=abc123\nBODY_SHA256=%s\nBAR_RC=0' "$(sha_of_body Summary)")" ]
  [ -d "${lines[0]#SCRATCH=}" ]
  starts_with "${lines[0]#SCRATCH=}" "$BATS_TEST_TMPDIR/plugin-approver."
  : > "$GH_LOG"
  TMPDIR="$BATS_TEST_TMPDIR" STUB_HEAD='' STUB_BODY=Summary run bash "$BATS_TEST_TMPDIR/step3.sh"
  [ "$status" -eq 1 ]
  contains "$output" "Policy render or PR fetch failed — posting nothing."
  lacks "$output" "BAR_RC="
  [ "$(cat "$GH_LOG")" = "pr view 42 --json headRefOid -q .headRefOid" ]
}

@test "skill Step 1 runs: a failed author lookup is an error with exit 1, never the off state (#2300)" {
  stub_gh
  extract_block "$SKILL" '## Step 1 — Resolve the PR and check its author' \
    | sed 's|<the PR number resolved above>|42|' > step1.sh
  run bash "$BATS_TEST_TMPDIR/step1.sh"
  [ "$status" -eq 1 ]
  contains "$output" "::error::Could not read PR #42's author — posting nothing."
  lacks "$output" "AI approval: off"
}

@test "skill Step 5: the prompt passes HEAD_SHA and BODY_SHA256 and names the pinned reviews endpoint" {
  pin_each "$SKILL" \
    '    HEAD_SHA=<$HEAD_SHA>' \
    '    BODY_SHA256=<$BODY_SHA256>' \
    'Post the verdict through `gh api repos/<owner>/<repo>/pulls/<n>/reviews` with' \
    'commit_id=<HEAD_SHA>, and only after your Step 12 has re-checked the live head' \
    'So is an empty `HEAD_SHA` or `BODY_SHA256`: a review with nothing to pin it to' \
    'holds only for the head SHA and body it judged: a push or a body edit before' \
    'verbatim from that output, never from a fresh `gh` read.'
  run grep -n 'gh pr review' "$SKILL"
  [ "$status" -eq 1 ]
}

@test "agent: takes HEAD_SHA and BODY_SHA256 and hard-fails without them" {
  grep -qF '| `HEAD_SHA` | The PR'"'"'s head commit (`headRefOid`) when the bar was run.' "$AGENT"
  grep -qF '| `BODY_SHA256` | The SHA-256 of the PR body the bar read.' "$AGENT"
  pin_each "$AGENT" \
    '- `HEAD_SHA` or `BODY_SHA256` is not present in the prompt. Without them' \
    'there is no telling whether the bar'"'"'s result still applies.'
}

@test "agent Step 12: the head/body guard precedes the dry-run print and the case, and every arm posts pinned to HEAD_SHA" {
  local block
  block=$(extract_block "$AGENT" 'The guard and the `case` stay in this one call')
  local guard dry kase
  guard=$(printf '%s\n' "$block" | grep -nF '[ "$live_head" = "$HEAD_SHA" ] ||' | cut -d: -f1)
  dry=$(printf '%s\n' "$block" | grep -nxF 'if [ "$DRY_RUN" = "true" ]; then' | cut -d: -f1)
  kase=$(printf '%s\n' "$block" | grep -nxF '  APPROVE)' | cut -d: -f1)
  [ -n "$guard" ]
  [ -n "$dry" ]
  [ -n "$kase" ]
  [ "$guard" -lt "$dry" ]
  [ "$dry" -lt "$kase" ]
  local ev
  for ev in APPROVE REQUEST_CHANGES COMMENT; do
    printf '%s\n' "$block" | grep -A2 -xF "  $ev)" | grep -qxF -- \
      "      -f commit_id=\"\$HEAD_SHA\" -f event=$ev -F body=@\"\$review_body_file\" --jq .html_url" \
      || { echo "arm not pinned to HEAD_SHA: $ev"; false; }
  done
  [ "$(printf '%s\n' "$block" | grep -cxF '    gh api --method POST "repos/$REPO/pulls/$PR_NUMBER/reviews" \')" -eq 3 ]
  run grep -n 'gh pr review' "$AGENT"
  [ "$status" -eq 1 ]
  pin_each "$AGENT" \
    'posted or printed. If the head is not `HEAD_SHA`, or the body no longer' \
    'hashes to `BODY_SHA256`, it posts **no** review of **any** verdict —' \
    'The check covers `DRY_RUN=true` too: a mismatch prints the report, never'
}

@test "agent Step 12 runs: on the judged head and body each verdict posts once, pinned with commit_id" {
  stub_gh
  local ev
  for ev in APPROVE REQUEST_CHANGES COMMENT; do
    step12_script "$ev" false
    : > "$GH_LOG"
    STUB_HEAD=abc123 STUB_BODY=Summary run bash "$BATS_TEST_TMPDIR/step12.sh"
    [ "$status" -eq 0 ] || { echo "$ev: $output"; false; }
    [ "$output" = "https://github.com/o/r/pull/42#pullrequestreview-1" ]
    [ "$(grep -c '^api --method POST' "$GH_LOG")" -eq 1 ]
    grep -qxF "api --method POST repos/o/r/pulls/42/reviews -f commit_id=abc123 -f event=$ev -F body=@$BATS_TEST_TMPDIR/work/review.md --jq .html_url" "$GH_LOG" \
      || { echo "$ev posted as: $(cat "$GH_LOG")"; false; }
  done
}

@test "agent Step 12 runs: a moved head, an edited body or a failed re-read posts no verdict at all" {
  stub_gh
  local ev
  for ev in APPROVE REQUEST_CHANGES COMMENT; do
    step12_script "$ev" false
    : > "$GH_LOG"
    STUB_HEAD=def456 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
    [ "$status" -eq 1 ]
    contains "$stderr" "PR #42 changed since the never-approve bar judged it (head abc123 -> def456) — posting nothing"
    [ "$(grep -c '^api' "$GH_LOG")" -eq 0 ] || { echo "$ev posted on a moved head"; false; }

    STUB_HEAD=abc123 STUB_BODY=$'Summary\n<!-- review-dossier: {"dimensions":{"bugs":{"open":1}}} -->' \
      run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
    [ "$status" -eq 1 ]
    contains "$stderr" "(body changed) — posting nothing"
    [ "$(grep -c '^api' "$GH_LOG")" -eq 0 ] || { echo "$ev posted on an edited body"; false; }
  done
  STUB_HEAD=def456 STUB_BODY=Other run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  contains "$stderr" "(head abc123 -> def456; body changed)"
  STUB_FAIL=1 STUB_HEAD=abc123 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  contains "$stderr" "could not re-read PR #42's head and body — posting nothing"
  [ "$(grep -c '^api' "$GH_LOG")" -eq 0 ]
}

@test "agent Step 12 runs: DRY_RUN prints the body only on the judged head, and posts nothing either way" {
  stub_gh
  step12_script APPROVE true
  STUB_HEAD=abc123 STUB_BODY=Summary run bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "RENDERED REVIEW" ]
  STUB_HEAD=def456 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "(head abc123 -> def456) — posting nothing"
  STUB_HEAD=abc123 STUB_BODY='Summary plus residue' run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "(body changed) — posting nothing"
  STUB_FAIL=1 STUB_HEAD=abc123 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "could not re-read PR #42's head and body — posting nothing"
  [ "$(grep -c '^api' "$GH_LOG")" -eq 0 ]
}

@test "agent Step 12 runs: a DRY_RUN other than exactly true or false, or an unknown verdict, stops before any read, print or post (#2299)" {
  stub_gh
  local v
  for v in TRUE 1 ''; do
    step12_script APPROVE "$v"
    : > "$GH_LOG"
    STUB_HEAD=abc123 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
    [ "$status" -eq 1 ] || { echo "DRY_RUN='$v' exited $status"; false; }
    [ -z "$output" ]
    contains "$stderr" "::error::unknown DRY_RUN '$v' — posting nothing"
    [ ! -s "$GH_LOG" ] || { echo "DRY_RUN='$v' called gh: $(cat "$GH_LOG")"; false; }
  done
  step12_script BOGUS true
  : > "$GH_LOG"
  STUB_HEAD=abc123 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "::error::unknown verdict 'BOGUS' — posting nothing"
  [ ! -s "$GH_LOG" ]
}

@test "agent Step 12 runs: a review body holding a line that is just REVIEW lands verbatim and runs nothing (#2299)" {
  stub_gh
  step12_script APPROVE false
  local canary="$BATS_TEST_TMPDIR/ran"
  awk -v c="$canary" '$0 == "RENDERED REVIEW" { print "Looks fine."; print "REVIEW"; print "touch " c; next } { print }' \
    "$BATS_TEST_TMPDIR/step12.sh" > "$BATS_TEST_TMPDIR/step12-canary.sh"
  : > "$GH_LOG"
  STUB_HEAD=abc123 STUB_BODY=Summary run bash "$BATS_TEST_TMPDIR/step12-canary.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$canary" ]
  [ "$(cat "$BATS_TEST_TMPDIR/work/review.md")" = "$(printf 'Looks fine.\nREVIEW\ntouch %s' "$canary")" ]
  [ "$(grep -c '^api --method POST' "$GH_LOG")" -eq 1 ]
}

@test "agent Step 12: the delimiter is REVIEW_ plus the work directory's name, checked before the heredoc, and a wrong one posts nothing (#2299)" {
  local block guard heredoc
  block=$(extract_block "$AGENT" 'The guard and the `case` stay in this one call')
  [ "$(printf '%s\n' "$block" | grep -cF '<the review delimiter>')" -eq 3 ]
  heredoc=$(printf '%s\n' "$block" | grep -nxF "cat > \"\$review_body_file\" <<'<the review delimiter>'" | cut -d: -f1)
  guard=$(printf '%s\n' "$block" | grep -nxF '[ "<the review delimiter>" = "REVIEW_${work##*/}" ] ||' | cut -d: -f1)
  [ -n "$heredoc" ]
  [ -n "$guard" ]
  [ "$guard" -lt "$heredoc" ]
  run grep -n "<<'REVIEW'" "$AGENT"
  [ "$status" -eq 1 ]
  stub_gh
  step12_script APPROVE false
  sed -i.bak 's/REVIEW_work/REVIEW_fixed/g' "$BATS_TEST_TMPDIR/step12.sh"
  : > "$GH_LOG"
  STUB_HEAD=abc123 STUB_BODY=Summary run --separate-stderr bash "$BATS_TEST_TMPDIR/step12.sh"
  [ "$status" -eq 1 ]
  contains "$stderr" "the review delimiter is not REVIEW_ plus the work directory's name — posting nothing"
  [ ! -s "$GH_LOG" ]
  pin_each "$AGENT" \
    '`DRY_RUN` is exactly `true` (print the body, post nothing) or exactly' \
    '`false` (post). Any other value — `TRUE`, `1`, empty — stops before' \
    'one of the three tokens, dry run included (#2299).' \
    'The review body goes through a quoted heredoc whose delimiter is unique' \
    'shell. `<the review delimiter>` is `REVIEW_` followed by the basename of' \
    'a variable inside a heredoc delimiter, and the block refuses a delimiter'
}

@test "the stop and no-review messages are pinned through their re-run instructions, and APPROVER.md states the stale-approval rule (#2299)" {
  pin_each "$AGENT" \
    "{ echo \"::error::could not re-read PR #\$PR_NUMBER's head and body — posting nothing; re-run the review\" >&2; exit 1; }" \
    '($changed) — posting nothing; re-run /development-claude-plugin:approve" >&2'
  pin_each "$SKILL" \
    'say "Needs a human" and list every `hit=` line. If the agent posted nothing (a' \
    'head or body change, a failed re-read, unsettled CI or a conflicting PR), say' \
    'that no review was posted, give the reason, and say to re-run' \
    '`/development-claude-plugin:approve` — never report its derived verdict as posted.'
  pin_each "$APPROVER_DOC" \
    'The review is posted pinned to the head the never-approve bar judged, with' \
    '`commit_id`, and nothing is posted when the head or the body changed in the' \
    'meantime. An `APPROVE` stops counting after a later push only when branch' \
    "protection's *Dismiss stale pull request approvals when new commits are" \
    "pushed* is on; bootstrap's \`branch-protection.sh\` turns it on."
}
