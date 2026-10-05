# Plugin Approver ENV Override Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With `CLAUDE_PLUGIN_APPROVER=1` set, the Claude Approver approves bot PRs on a claude-plugin repo, so
`/development:resolve-issue` epics and `/development:maintenance` runs advance without a human merge per PR. Without an
installed Approver App, every flow quietly stays human-only.

**Architecture:** One decision helper (`plugin-approver-override.zsh`) answers on/off per repo and session. It uses the
owner-registry probe plus a new quiet installation probe (`mint-approver-token.zsh --check-installed`). A new
`claude-plugin-approver` agent and `/development-claude-plugin:approve` skill mirror the language approvers. They add a
plugin-specific never-approve bar, enforced by a testable script. resolve-issue and maintenance call the helper and
reuse their existing Approver-repo cadence when it says `on`.

**Tech Stack:** zsh scripts, bats (with `tests/assertions.bash` and `tests/claude-apps-stubs.bash`), Markdown
skills/agents, `gh`, `jq`.

**Spec:** `docs/superpowers/specs/2026-10-05-plugin-approver-env-override-design.md`

## Global Constraints

- Opt-in variable: `CLAUDE_PLUGIN_APPROVER`; only the exact value `1` enables it. Nothing is written to the repo.
- The default stays human-only. `resolve-approval.zsh`, the recorded `approval:` key and its refusal of `approver` on
  plugin repos are unchanged.
- **No Approver App** (not registered for the owner, or not installed on the repo) is a supported configuration. It
  produces no error, no warning, empty stderr and exit 0 from the helper, with or without the ENV variable.
- Exit 1 from the helper only for a broken setup: `approver: key missing`, unusable registry or owner
  (`claude-apps-owner.zsh` exit 1/4), or an installation lookup that failed other than `Not Found`.
- The Approver reviews only PRs authored by the Maintenance App (`^(app/)?claude-maintenance`).
- Never-approve bar: residue (`open > 0` in any dossier dimension), any `.github/workflows/*` path, or approval/identity
  machinery. When hit, the verdict is `COMMENT`, never `APPROVE`.
- New shell scripts are zsh (`#!/usr/bin/env zsh`), shellcheck- and `zsh -n`-clean, with 120-column lines.
- Every content PR bumps the touched plugin's `plugin.json` and `.claude-plugin/marketplace.json` entry (minor bump: new
  capability). Re-bump right before committing.
- Run the full suite before each PR: `LC_ALL=C bats tests`. Report counts as passed/total.
- Out of scope: bootstrap Step 4f, `/development:sync-prs`, CI-side Approver workflows, and language repos'
  approver-mode detection.

## Review Focus

1. **ENV set, App registered but not installed:** a human-only stop with one informational line, and no "not installed"
   error leaking from the mint script. Pinned in Task 2 (helper stderr empty) and Task 4 (prose names the info line).
2. **ENV set to `true`, `yes`, or `1` with a leading space:** treated as off. Pinned in Task 2's truth table.
3. **Network down while the ENV is set:** exit 1 with a diagnostic, while the human path still runs and is never
   mistaken for "not installed". Pinned in Task 1 (`CURL_OFFLINE` → 2) and Task 2 (→ exit 1).
4. **A PR that edits the approve skill itself:** a renamed or new file under `skills/approve/` must still hit the bar.
   Pinned in Task 3 (path cases).
5. **Dossier absent, or with no `open` keys:** treated as `open = 0`, so it doesn't hit the bar and doesn't crash.
   Pinned in Task 3.

---

### Task 1: Quiet installation probe — `mint-approver-token.zsh --check-installed`

**Files:**

- Modify: `development/skills/maintenance/scripts/mint-approver-token.zsh` (argument parsing near `emit_stdout=false`;
  the "discover installation" block)
- Test: `tests/mint-approver-check-installed.bats` (new)
- Modify: `development/.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json` (minor bump)

**Interfaces:**

- Produces: `mint-approver-token.zsh --check-installed`. Exit `0` installed; `3` not installed (GitHub `Not Found`),
  with **no stdout and no stderr**; `2` any other lookup failure, with today's diagnostics; `1` prerequisites
  (unchanged). It mints no token, and makes no `access_tokens` request.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
#
# mint-approver-token.zsh --check-installed: the quiet installation probe the
# plugin-Approver override reads. "Not installed" is a supported setup (no AI
# approvals), so it is a silent exit 3; every other failure keeps exit 2.

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
  write_registry
  in_personal_repo "timo-jakob"
}

@test "check-installed: an installed App exits 0 and mints no token" {
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q '/repos/timo-jakob/widget/installation' "$STUB_DIR/curl.log"
  run grep -c 'access_tokens' "$STUB_DIR/curl.log"
  [ "$output" = "0" ]
}

@test "check-installed: Not Found exits 3 silently" {
  export CURL_NO_INSTALL=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 3 ]
  [ -z "$output" ]
  [ -z "$stderr" ]
}

@test "check-installed: a rejected lookup exits 2 with the key diagnostic" {
  export CURL_INSTALL_REJECTED=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 2 ]
  contains "$stderr" "GitHub rejected the claude-approver installation lookup"
}

@test "check-installed: an unreachable GitHub exits 2, never reads as not installed" {
  export CURL_OFFLINE=1
  run --separate-stderr zsh "$MINT_APPROVER" --check-installed
  [ "$status" -eq 2 ]
  contains "$stderr" "Could not reach GitHub"
  lacks "$stderr" "is not installed"
}

@test "without the flag, Not Found still exits 2 with the install hint (open-pr's fallback key)" {
  export CURL_NO_INSTALL=1
  run --separate-stderr zsh "$MINT_APPROVER"
  [ "$status" -eq 2 ]
  contains "$stderr" "claude-approver App is not installed on timo-jakob/widget."
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `LC_ALL=C bats tests/mint-approver-check-installed.bats`
Expected: the first four tests FAIL. The flag is ignored today, so a token gets minted, exit is 0, or Not Found exits 2.
The fifth test passes.

- [ ] **Step 3: Implement**

Replace the argument parsing:

```zsh
# --- argument parsing --------------------------------------------------------
emit_stdout=false
check_installed=false
case "${1:-}" in
  --stdout)          emit_stdout=true ;;
  # Probe only: is the Approver App installed on this repo? No token is minted.
  # Not installed is a supported setup (no AI approvals), so it is a SILENT
  # exit 3; the plugin-Approver override reads it (plugin-approver-override.zsh).
  --check-installed) check_installed=true ;;
esac
```

Document the flag in the header's usage/exit-code comment: `3 — --check-installed only: not installed (silent)`. Then,
directly after `install_id=$(… jq -r '.id // empty' …)` and before the existing `if [[ -z "$install_id" …` block,
insert:

```zsh
if [[ "$check_installed" == true ]]; then
  [[ -n "$install_id" && "$install_id" != "null" ]] && exit 0
  if [[ -n "$install_resp" \
        && "$(printf '%s' "$install_resp" | jq -r '.message // empty' 2>/dev/null || true)" == "Not Found" ]]; then
    exit 3
  fi
  # Anything else falls through to the diagnostics below (exit 2).
fi
```

- [ ] **Step 4: Run the tests and see them pass**

Run: `LC_ALL=C bats tests/mint-approver-check-installed.bats tests/claude-apps-owner.bats`
Expected: all pass (the existing owner suite proves the default path is unchanged).

- [ ] **Step 5: Lint, bump, commit**

```bash
zsh -n development/skills/maintenance/scripts/mint-approver-token.zsh
pre-commit run --files development/skills/maintenance/scripts/mint-approver-token.zsh tests/mint-approver-check-installed.bats
# bump development minor in development/.claude-plugin/plugin.json and .claude-plugin/marketplace.json
RTK_DISABLED=1 git add tests/mint-approver-check-installed.bats development/skills/maintenance/scripts/mint-approver-token.zsh \
  development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
RTK_DISABLED=1 git commit -m "feat(approver): quiet --check-installed probe for mint-approver-token"
```

---

### Task 2: Decision helper — `plugin-approver-override.zsh`, plus the ARCHITECTURE.md sentence

**Files:**

- Create: `development/scripts/approval/plugin-approver-override.zsh` (executable)
- Test: `tests/plugin-approver-override.bats` (new)
- Modify: `ARCHITECTURE.md`, the approval-model paragraph starting `**So is the approval model (#1684).**`
- Modify: plugin manifests (development minor bump)

**Interfaces:**

- Consumes: `claude-apps-owner.zsh status claude-approver` (exit 0/3/4/1; report lines `approver: registered|not
  registered|key missing`, `fix: …`); `mint-approver-token.zsh --check-installed` (Task 1).
- Produces: `development/scripts/approval/plugin-approver-override.zsh`, no arguments, run from inside the repo. Stdout
  is `override=on`, or `override=off` followed by `reason=<slug>`, where slug ∈ `env-unset`, `not-plugin-repo`,
  `approver-not-registered`, `approver-not-installed`, `approver-key-missing`, `approver-registry-unusable`,
  `approver-lookup-failed`. Exit 0 for `on` and for the first four off-reasons (with empty stderr). Exit 1 for the last
  three, with the diagnostic relayed on stderr.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
#
# plugin-approver-override.zsh: may the Claude Approver approve PRs on this
# claude-plugin repo in this session? Off unless CLAUDE_PLUGIN_APPROVER is
# exactly 1. "No Approver App" (not registered / not installed) is a supported
# way to forbid AI approvals: exit 0 and EMPTY stderr, with or without the ENV.

bats_require_minimum_version 1.5.0
load assertions
load claude-apps-stubs

setup() {
  claude_apps_stubs
  write_registry
  in_personal_repo "timo-jakob"
  mkdir -p .claude-plugin && printf '{}' > .claude-plugin/marketplace.json
  export OVERRIDE="$REPO_ROOT/development/scripts/approval/plugin-approver-override.zsh"
  unset CLAUDE_PLUGIN_APPROVER
}

@test "env unset: off/env-unset, silent, and nothing is probed" {
  run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=env-unset' ]
  [ -z "$stderr" ]
  [ ! -e "$STUB_DIR/curl.log" ]
  [ ! -e "$STUB_DIR/security.log" ]
}

@test "only the exact value 1 enables it" {
  for v in 0 true yes " 1" "1 " ""; do
    CLAUDE_PLUGIN_APPROVER="$v" run --separate-stderr zsh "$OVERRIDE"
    [ "$status" -eq 0 ]
    [ "$output" = $'override=off\nreason=env-unset' ]
  done
}

@test "a repo without the claude-plugin marker is off/not-plugin-repo" {
  rm -rf .claude-plugin
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=not-plugin-repo' ]
  [ -z "$stderr" ]
}

@test "an individual plugin (plugin.json) counts as a plugin repo" {
  rm .claude-plugin/marketplace.json && printf '{}' > .claude-plugin/plugin.json
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$output" = "override=on" ]
}

@test "all checks pass: on" {
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = "override=on" ]
  [ -z "$stderr" ]
}

@test "company setup — Approver not registered: off, exit 0, empty stderr" {
  in_org_repo "acme-corp"   # writer-only organisation
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=approver-not-registered' ]
  [ -z "$stderr" ]
}

@test "company setup — Approver registered but not installed: off, exit 0, empty stderr" {
  export CURL_NO_INSTALL=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 0 ]
  [ "$output" = $'override=off\nreason=approver-not-installed' ]
  [ -z "$stderr" ]
}

@test "broken setup — key missing: exit 1, fix line relayed" {
  rm "$KC_DIR/claude-plugins.timo-jakob.claude-approver"
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-key-missing' ]
  contains "$stderr" "install-claude-apps.zsh --verify --fix"
}

@test "broken setup — owner unresolvable: exit 1, registry-unusable" {
  export GH_REPO_FAIL=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-registry-unusable' ]
  [ -n "$stderr" ]
}

@test "broken setup — GitHub unreachable: exit 1, lookup-failed, never not-installed" {
  export CURL_OFFLINE=1
  CLAUDE_PLUGIN_APPROVER=1 run --separate-stderr zsh "$OVERRIDE"
  [ "$status" -eq 1 ]
  [ "$output" = $'override=off\nreason=approver-lookup-failed' ]
  contains "$stderr" "Could not reach GitHub"
}

@test "ARCHITECTURE.md states the ENV exception and the no-App way to forbid AI approvals" {
  run grep -c 'CLAUDE_PLUGIN_APPROVER=1' "$REPO_ROOT/ARCHITECTURE.md"
  [ "$output" -ge 1 ]
  grep -q 'not installing the Approver App is the supported way to forbid AI approvals' "$REPO_ROOT/ARCHITECTURE.md"
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `LC_ALL=C bats tests/plugin-approver-override.bats`
Expected: all FAIL (the script doesn't exist yet; the ARCHITECTURE.md needle is missing).

- [ ] **Step 3: Implement the helper**

```zsh
#!/usr/bin/env zsh
# plugin-approver-override.zsh — may the Claude Approver approve PRs on this
# claude-plugin repo in THIS session? A claude-plugin repo is human-only
# (#1684); CLAUDE_PLUGIN_APPROVER=1 is a per-session, ENV-only opt-in that
# nothing records in the repo. Every flow asks this script instead of reading
# the variable itself (resolve-issue §6/E3, maintenance's approver mode,
# /development-claude-plugin:approve).
#
# "No Approver App" — not registered for the repo's owner, or not installed on
# the repo — is the SUPPORTED way to forbid AI approvals (an organisation that
# wants none simply does not install it). It is a decision, not a failure:
# exit 0, nothing on stderr, whether or not the variable is set.
#
# Usage: plugin-approver-override.zsh        (run inside the repository)
#
# Stdout: `override=on`, or `override=off` then `reason=<slug>`:
#   env-unset | not-plugin-repo | approver-not-registered | approver-not-installed
#     → exit 0, stderr empty
#   approver-key-missing | approver-registry-unusable | approver-lookup-failed
#     → exit 1, the probe's diagnostic relayed on stderr (a setup someone
#       intended is broken; callers still take the human path)

setopt err_exit nounset pipefail

script_dir="${0:A:h}"
owner_helper="$script_dir/../../skills/bootstrap/scripts/claude-apps-owner.zsh"
mint="$script_dir/../../skills/maintenance/scripts/mint-approver-token.zsh"

off() {
  print -r -- "override=off"
  print -r -- "reason=$1"
  exit "${2:-0}"
}

[[ "${CLAUDE_PLUGIN_APPROVER:-}" == "1" ]] || off env-unset
[[ -f .claude-plugin/plugin.json || -f .claude-plugin/marketplace.json ]] || off not-plugin-repo

rc=0
report=$(zsh "$owner_helper" status claude-approver 2>"${TMPDIR:-/tmp}/pao.$$") || rc=$?
diag=$(<"${TMPDIR:-/tmp}/pao.$$"); rm -f "${TMPDIR:-/tmp}/pao.$$"
case $rc in
  0) ;;
  3)
    if grep -q '^approver: key missing' <<<"$report"; then
      print -u2 -r -- "Approver key missing — fix: $(sed -n 's/^fix: //p' <<<"$report")"
      off approver-key-missing 1
    fi
    off approver-not-registered
    ;;
  *)
    [[ -n "$diag" ]] && print -u2 -r -- "$diag"
    off approver-registry-unusable 1
    ;;
esac

rc=0
diag=$(zsh "$mint" --check-installed 2>&1 >/dev/null) || rc=$?
case $rc in
  0) print -r -- "override=on" ;;
  3) off approver-not-installed ;;
  *) [[ -n "$diag" ]] && print -u2 -r -- "$diag"; off approver-lookup-failed 1 ;;
esac
```

`chmod +x` it. Check that the stub for `GH_REPO_FAIL` makes `claude-apps-owner.zsh status` exit 4 (it does; see
`tests/claude-apps-stubs.bash`).

- [ ] **Step 4: Add the ARCHITECTURE.md sentence**

At the end of the paragraph that starts `**So is the approval model (#1684).**` (after `` `/development:maintenance`
does not read `approval:` yet. ``), append:

```markdown
One per-session exception exists, and it records nothing: with
`CLAUDE_PLUGIN_APPROVER=1` in the environment, a claude-plugin repo's bot PRs
may be approved by `claude-plugin-approver`, decided by
`development/scripts/approval/plugin-approver-override.zsh` (registered and
installed Approver App required; residue, workflow and approval-machinery
changes still go to a human); not registering or not installing the Approver App is the supported way to forbid AI approvals —
every flow then takes the human path without an error or a warning.
```

Keep `not installing the Approver App is the supported way to forbid AI approvals` on one source line, because the bats
needle greps it. Wrap the rest at 120 columns.

- [ ] **Step 5: Run the tests and see them pass**

Run: `LC_ALL=C bats tests/plugin-approver-override.bats`
Expected: 11/11 pass.

- [ ] **Step 6: Mutation-check the silence guarantee**

Temporarily change the `3) off approver-not-installed ;;` line to also `print -u2 "x"`, re-run, and confirm the
not-installed test goes red. Then revert.

- [ ] **Step 7: Full suite, bump, commit**

```bash
LC_ALL=C bats tests   # expect all green; report passed/total
RTK_DISABLED=1 git add development/scripts/approval/plugin-approver-override.zsh tests/plugin-approver-override.bats ARCHITECTURE.md \
  development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
RTK_DISABLED=1 git commit -m "feat(approver): CLAUDE_PLUGIN_APPROVER override decision helper"
```

---

### Task 3: The plugin approver — bar script, policy overlay, agent, approve skill, APPROVER.md

**Files:**

- Create: `development-claude-plugin/skills/approve/scripts/never-approve-bar.zsh` (executable)
- Create: `development-claude-plugin/skills/approve/approver-policy-overlay.md.tmpl`
- Create: `development-claude-plugin/skills/approve/SKILL.md`
- Create: `development-claude-plugin/agents/claude-plugin-approver.md`
- Modify: `development/skills/bootstrap/docs/APPROVER.md` (new section after "Multi-language status")
- Test: `tests/plugin-approver.bats` (new)
- Modify: `development-claude-plugin/.claude-plugin/plugin.json` and its marketplace entry (minor bump); `development`
  too, for APPROVER.md

**Interfaces:**

- Consumes: `plugin-approver-override.zsh` (Task 2); `mint-approver-token.zsh` (prints the token file path);
  `development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl` (only placeholder: `{{APPROVER_LANG}}`).
- Produces:
  - `never-approve-bar.zsh --body <pr-body-file> --paths <changed-paths-file>`. Exit 0 = clear; 3 = bar hit, with one
    stdout line per hit (`hit=residue open=<n>`, `hit=workflow path=<p>`, `hit=approval-machinery path=<p>`); 2 = usage
    error.
  - Skill `/development-claude-plugin:approve [<pr>]`.
  - Agent `development-claude-plugin:claude-plugin-approver`, taking `PR_NUMBER`, `REPO`, `DRY_RUN`, `POLICY_FILE`,
    `BAR_FILE` and the token file path in its prompt.

- [ ] **Step 1: Write the failing tests**

```bash
#!/usr/bin/env bats
#
# The claude-plugin Approver (opt-in via CLAUDE_PLUGIN_APPROVER=1): its
# never-approve bar, its skill's override gate, and its plugin layout.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  BAR="$REPO_ROOT/development-claude-plugin/skills/approve/scripts/never-approve-bar.zsh"
  SKILL="$REPO_ROOT/development-claude-plugin/skills/approve/SKILL.md"
  AGENT="$REPO_ROOT/development-claude-plugin/agents/claude-plugin-approver.md"
  OVERLAY="$REPO_ROOT/development-claude-plugin/skills/approve/approver-policy-overlay.md.tmpl"
  cd "$BATS_TEST_TMPDIR"
  printf 'Summary\n' > body
  : > paths
}

dossier() { printf 'x\n<!-- review-dossier: %s -->\n' "$1" > body; }

@test "bar: clean docs-only change with a clean dossier passes" {
  dossier '{"dimensions":{"bugs":{"clean":true,"open":0},"tests":{"clean":false,"open":0}}}'
  printf 'docs/how-to/x.md\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "bar: no dossier and no open keys mean open=0" {
  printf 'README.md\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
  dossier '{"dimensions":{"bugs":{"clean":true}}}'
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 0 ]
}

@test "bar: residue in any dimension hits, summing open" {
  dossier '{"dimensions":{"bugs":{"open":1},"tests":{"open":2}}}'
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  contains "$output" "hit=residue open=3"
}

@test "bar: workflow paths hit" {
  printf '.github/workflows/script-tests.yml\n' > paths
  run zsh "$BAR" --body body --paths paths
  [ "$status" -eq 3 ]
  contains "$output" "hit=workflow path=.github/workflows/script-tests.yml"
}

@test "bar: approval and identity machinery hits" {
  for p in development-python/agents/python-approver.md \
           development/skills/maintenance/scripts/mint-approver-token.zsh \
           development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl \
           development/skills/bootstrap/scripts/resolve-approval.zsh \
           development/skills/bootstrap/scripts/claude-apps-owner.zsh \
           development/skills/bootstrap/scripts/install-claude-apps.zsh \
           development/skills/bootstrap/scripts/register-claude-apps.zsh \
           development/scripts/approval/plugin-approver-override.zsh \
           development-claude-plugin/skills/approve/SKILL.md \
           development-claude-plugin/skills/approve/scripts/new-helper.zsh; do
    printf '%s\n' "$p" > paths
    run zsh "$BAR" --body body --paths paths
    [ "$status" -eq 3 ] || { echo "not caught: $p"; false; }
    contains "$output" "hit=approval-machinery path=$p"
  done
}

@test "bar: usage error on missing args" {
  run zsh "$BAR" --body body
  [ "$status" -eq 2 ]
}

@test "skill: gates on the override helper and refuses non-bot authors" {
  grep -q 'plugin-approver-override.zsh' "$SKILL"
  grep -q 'AI approval: off (' "$SKILL"
  grep -q '\^(app/)?claude-maintenance' "$SKILL"
  grep -q 'never-approve-bar.zsh' "$SKILL"
  grep -q 'subagent_type="development-claude-plugin:claude-plugin-approver"' "$SKILL"
}

@test "agent: frontmatter and the never-approve rule" {
  head -6 "$AGENT" | grep -qx 'name: claude-plugin-approver'
  head -6 "$AGENT" | grep -qx 'model: fable'
  head -6 "$AGENT" | grep -qx 'tools: Bash, Read, Grep'
  grep -q 'never post `APPROVE`' "$AGENT"
  grep -q 'BAR_FILE' "$AGENT"
}

@test "policy: the core's only placeholder is APPROVER_LANG, so sed renders it" {
  run grep -oE '\{\{[A-Z_]+\}\}' "$REPO_ROOT/development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl"
  [ "$(printf '%s\n' "$output" | sort -u)" = "{{APPROVER_LANG}}" ]
  grep -q '^# Overlay — Claude plugin' "$OVERLAY"
}

@test "APPROVER.md documents the plugin opt-in and the no-App company setup" {
  grep -q '^## Plugin repos: opt-in per session' "$REPO_ROOT/development/skills/bootstrap/docs/APPROVER.md"
  grep -q 'Forbidding AI approvals' "$REPO_ROOT/development/skills/bootstrap/docs/APPROVER.md"
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `LC_ALL=C bats tests/plugin-approver.bats`
Expected: all FAIL except the placeholder-shape half of the policy test (files missing).

- [ ] **Step 3: Implement `never-approve-bar.zsh`**

```zsh
#!/usr/bin/env zsh
# never-approve-bar.zsh — the claude-plugin Approver's hard bar. A claude-plugin
# repo is the origin of every other repo, so even with CLAUDE_PLUGIN_APPROVER=1
# these changes always go to a human: the agent posts COMMENT, never APPROVE.
#
# Usage: never-approve-bar.zsh --body <pr-body-file> --paths <changed-paths-file>
# Stdout: one line per hit — hit=residue open=<n> | hit=workflow path=<p> |
#         hit=approval-machinery path=<p>
# Exit: 0 clear, 3 bar hit, 2 usage.

setopt err_exit nounset pipefail

body="" paths=""
while (( $# )); do
  case "$1" in
    --body)  body="${2:-}"; shift 2 ;;
    --paths) paths="${2:-}"; shift 2 ;;
    *) print -u2 -- "usage: never-approve-bar.zsh --body <file> --paths <file>"; exit 2 ;;
  esac
done
[[ -r "$body" && -r "$paths" ]] || { print -u2 -- "usage: never-approve-bar.zsh --body <file> --paths <file>"; exit 2; }

hits=0
# Residue: sum dimensions.<lens>.open over the (single) hidden dossier block; absent = 0.
dossier=$(sed -n 's/.*<!-- review-dossier: \(.*\) -->.*/\1/p' "$body" | head -1)
open=0
if [[ -n "$dossier" ]]; then
  open=$(jq -r '[.dimensions // {} | .[] | (.open // 0)] | add // 0' <<<"$dossier" 2>/dev/null || print 0)
fi
if (( open > 0 )); then print -r -- "hit=residue open=$open"; hits=1; fi

while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  case "$p" in
    .github/workflows/*) print -r -- "hit=workflow path=$p"; hits=1 ;;
    *approver*|*/skills/approve/*|*/resolve-approval.zsh|*/claude-apps-owner.zsh|\
    */install-claude-apps.zsh|*/register-claude-apps.zsh)
      print -r -- "hit=approval-machinery path=$p"; hits=1 ;;
  esac
done < "$paths"

(( hits )) && exit 3
exit 0
```

- [ ] **Step 4: Write the policy overlay** (`approver-policy-overlay.md.tmpl`)

```markdown
<!-- approver-policy: overlay (claude-plugin) — plugin fluency only; the
     judgment criteria live in the core above. -->

---

# Overlay — Claude plugin

Where the core policy says "per the language overlay", this part is the
reference for a repository that IS Claude Code plugins. It adds plugin
fluency to the core's criteria; it never relaxes them.

## Never approve (hard bar)

`never-approve-bar.zsh` has run before you, and its result is in `BAR_FILE`.
Any `hit=` line means the verdict is `COMMENT`, naming every hit: residue
(`open > 0`), a `.github/workflows/*` change, or a change to the approval or
identity machinery. This bar overrides the core's leniency for disclosed
residue. On a plugin repo, residue goes to a human.

## Fallback diff-heuristic paths

- **Test paths:** `tests/**/*.bats`, `tests/**/*.bash`, `tests/fixtures/**`.
- **Build-config paths (→ `ci`):** `.pre-commit-config.yaml`, `.yamllint`,
  `.markdownlint*`, `mkdocs.yml`.
- **Dependency manifests (→ `chore_deps`):** `renovate.json`, pinned
  template versions in `*.tmpl`.
- **Runtime pins (→ `chore_runtime`):** none.

## Test idioms (for the core's *Test representativeness*)

Coverage-padding patterns to flag: a bats `@test` whose only assertion is
`[ "$status" -eq 0 ]` on a command whose output is the behaviour; `grep -q`
needles that pin a word rather than the load-bearing sentence; a stubbed
tool also present in the runner's `/usr/bin` without hiding it; and
assertions piped through `| tail`, which reads tail's exit, not bats'.

## Per-type additions

### `feat:` / `fix:` / `refactor:`

- Every changed `*.zsh`/`*.sh` must pass `zsh -n` (or `bash -n`) and
  shellcheck; run both on the changed files.
- A content change to a plugin needs a version bump in its `plugin.json`
  **and** the matching `.claude-plugin/marketplace.json` entry. A missing
  bump is a REQUEST_CHANGES finding, because installs would never see the change.
- Prose changes to a skill or agent are behaviour: read them as code, for
  missing failure branches and contradictions between sections.

## `suggested_agent` vocabulary

`claude-plugin-script-quality`, `claude-plugin-skill-validator`,
`claude-plugin-structure-validator`, `claude-plugin-reference-checker`,
`claude-plugin-version-sync`.
```

- [ ] **Step 5: Write the agent** (`agents/claude-plugin-approver.md`)

Build it from `development-python/agents/python-approver.md`: `cp` the file and edit it. Use this frontmatter:

```markdown
---
name: claude-plugin-approver
description: Synthesis-layer reviewer for claude-plugin PRs, opt-in per session with CLAUDE_PLUGIN_APPROVER=1 (a plugin repo is otherwise human-only). Reads the rendered policy at POLICY_FILE and the never-approve bar result at BAR_FILE, builds a risk register fed by the review dossier's five claude-plugin dimensions, calibrates confidence, and posts APPROVE / REQUEST_CHANGES / COMMENT via `gh pr review` using a locally minted Approver App token. Invoked only by `/development-claude-plugin:approve`.
model: fable
tools: Bash, Read, Grep
---
```

Exact edits to the copied body:

1. Replace "Claude Approver for Python" with "Claude Approver for Claude-plugin repos". Replace the companion-doc
   paragraph with: "The operator-facing companion is `development/skills/bootstrap/docs/APPROVER.md` § *Plugin repos:
   opt-in per session*."
2. **Inputs / Hard-fail:** replace `.claude/approver-policy.md` everywhere with `the policy at POLICY_FILE`. Add
   `BAR_FILE` to the prompt-values list. Add a hard-fail when `POLICY_FILE` or `BAR_FILE` is missing or unreadable.
3. Insert a new first procedure step, before "Step 1 — Read the policy":

   ```markdown
   ### Step 0 — The never-approve bar

   Read `BAR_FILE`. If it holds any `hit=` line, you **never post `APPROVE`**
   on this PR: finish the review as usual for its findings, then post
   `COMMENT` with a "Needs a human" section that lists every hit verbatim.
   This bar is not a judgment call and confidence cannot lift it.
   ```

4. Delete "Step 4 — Read the API-stability artifact" and the "Hotfix special case" section. A plugin repo has neither.
5. Replace "Step 5 — Cheap local checks" with:

   ```markdown
   ### Step 5 — Cheap local checks

   On the changed files only (`gh pr diff <n> --name-only`), in a fresh
   scratch worktree you remove before returning:

   - `zsh -n` on each changed `*.zsh`; `bash -n` on each changed `*.sh`;
   - `shellcheck` on each changed shell script;
   - `jq empty` on each changed `*.json`;
   - for each changed plugin directory, that its `.claude-plugin/plugin.json`
     version differs from `origin/main`'s and equals its
     `.claude-plugin/marketplace.json` entry.

   A failure is a baseline-criteria finding.
   ```

6. In "Step 7 — Test-quality detection", replace the Python idioms with "the overlay's *Test idioms*".
7. In "Step 10 — Risk register", make the dossier lenses `bugs, security, performance, code_quality, tests` plus the
   claude-plugin panel's own dimension keys (as `build-dossier.zsh` writes them).
8. Replace every `/development-python:` reference with `/development-claude-plugin:`, and every `python-*` agent name
   with the overlay's `suggested_agent` vocabulary.

Then verify nothing Python-specific survives: `grep -n -i 'python\|ruff\|pytest\|pyproject'
development-claude-plugin/agents/claude-plugin-approver.md` should print nothing.

- [ ] **Step 6: Write the skill** (`skills/approve/SKILL.md`)

````markdown
---
name: approve
description: >
  Review a claude-plugin PR and post the verdict as the Claude Approver —
  ONLY when CLAUDE_PLUGIN_APPROVER=1 opts this session in (a plugin repo is
  otherwise human-only). Without a registered + installed Approver App it is a
  clean no-op: a human approves. Pass a PR number or use the current branch's PR.
disable-model-invocation: false
---

You are running the **Claude Approver for a claude-plugin repo** and posting
its verdict as `claude-approver-<owner>[bot]`.

**User input:** `$ARGUMENTS` (PR number, optional; defaults to the current branch's PR)

## Step 0 — Is AI approval on for this session?

```bash

OVR=$(development/scripts/approval/plugin-approver-override.zsh) || true
if ! grep -qx 'override=on' <<<"$OVR"; then
  REASON=$(sed -n 's/^reason=//p' <<<"$OVR")
  echo "AI approval: off (${REASON}) — a human approves."
  exit 0
fi

```

That line is informational, not an error. `approver-not-registered` and
`approver-not-installed` are the supported way to forbid AI approvals. If the
helper printed a diagnostic on stderr (a broken setup), relay it once.

## Step 1 — Resolve the PR and check its author

Positive integer → that PR. Empty → `gh pr view --json number -q .number`; with
none, stop with a clear message.

```bash

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
AUTHOR=$(gh pr view "$PR_NUMBER" --json author -q .author.login)
grep -qE '^(app/)?claude-maintenance' <<<"$AUTHOR" || {
  echo "AI approval: off (PR authored by ${AUTHOR}, not the Maintenance App) — a human approves."
  exit 0
}

```

## Step 2 — Mergeability gate

As `development-python:approve` Step 3. `CONFLICTING` → rebase the bot branch
with the rebase engine (`/development:sync-prs <pr>`), wait for green on the new
head, then continue. The Approver never resolves conflicts.

## Step 3 — Policy and never-approve bar

```bash

SCRATCH=$(mktemp -d -t plugin-approver.XXXXXX)
sed 's/{{APPROVER_LANG}}/claude-plugin/g' \
  development/skills/bootstrap/templates/common/approver-policy-core.md.tmpl > "$SCRATCH/policy.md"
cat "<skill-base-dir>/approver-policy-overlay.md.tmpl" >> "$SCRATCH/policy.md"
gh pr view "$PR_NUMBER" --json body -q .body > "$SCRATCH/body"
gh pr diff "$PR_NUMBER" --name-only > "$SCRATCH/paths"
"<skill-base-dir>/scripts/never-approve-bar.zsh" --body "$SCRATCH/body" --paths "$SCRATCH/paths" \
  > "$SCRATCH/bar" || [ $? -eq 3 ]

```

## Step 4 — Mint the Approver token, just in time

```bash

TOKEN_FILE=$(development/skills/maintenance/scripts/mint-approver-token.zsh)
[ -s "$TOKEN_FILE" ] || { echo "::error::Failed to mint Approver token."; exit 1; }

```

## Step 5 — Spawn the agent

```text

Agent(
  subagent_type="development-claude-plugin:claude-plugin-approver",
  prompt="""
    Review PR #<n> in <owner>/<repo>. Dry-run: false.
    PR_NUMBER=<n>
    REPO=<owner>/<repo>
    DRY_RUN=false
    POLICY_FILE=<$SCRATCH/policy.md>
    BAR_FILE=<$SCRATCH/bar>
    Read your token from the path below and export it before any `gh` mutation — do not print it:
      export GH_TOKEN=$(cat <TOKEN_FILE path>)
    Do NOT git checkout / switch in this worktree; use a fresh scratch worktree you remove before returning.
    Post the verdict with `gh pr review <n> --approve|--request-changes|--comment`.
  """
)

```

Afterwards: `rm -rf "$TOKEN_FILE" "$SCRATCH"`.

## Step 6 — Report

Print the posted verdict, the review URL and the agent's full output. When the
bar hit, say "Needs a human" and list the hits.
````

- [ ] **Step 7: APPROVER.md section**

Insert after the "Multi-language status" section, and add both anchors to its table of contents:

```markdown
## Plugin repos: opt-in per session

A claude-plugin repo is human-only by default and records `approval: human`.
For a session that should run end to end, such as a refined epic driven by
`/development:resolve-issue`, export `CLAUDE_PLUGIN_APPROVER=1`. Then
`/development-claude-plugin:approve` reviews each bot PR and, on `APPROVE`,
armed auto-merge merges it. Three kinds of change always go to a human:
residue, `.github/workflows/*`, and the approval/identity machinery. Nothing is
recorded in the repository. Unset the variable and the repo is human-only again.

### Forbidding AI approvals

Don't register the Approver App for the owner, or don't install it on the
repository. Every flow then takes the human path, without an error or a
warning, even with `CLAUDE_PLUGIN_APPROVER=1` set.
```

- [ ] **Step 8: Run the tests and see them pass, then run the full suite**

Run: `LC_ALL=C bats tests/plugin-approver.bats && LC_ALL=C bats tests`
Expected: all green. The plugin-skeleton and skill-validator suites must also pass with the new agent and skill.

- [ ] **Step 9: Bump and commit**

Minor-bump `development-claude-plugin` and `development` (plugin.json + marketplace.json), then:

```bash
RTK_DISABLED=1 git add development-claude-plugin development/skills/bootstrap/docs/APPROVER.md tests/plugin-approver.bats \
  development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
RTK_DISABLED=1 git commit -m "feat(development-claude-plugin): opt-in claude-plugin Approver with never-approve bar"
```

---

### Task 4: resolve-issue — approve-and-advance under the override, plus the open-pr sentence

**Files:**

- Modify: `development/skills/resolve-issue/SKILL.md`: frontmatter `description`; §6 "Outcomes" list; Epic flow
  "**Waiting for each merge.**" paragraph
- Modify: `development/skills/resolve-issue/reference/interactive.md`: the "Wait for each merge before the next rung"
  paragraph
- Modify: `development/skills/resolve-issue/reference/sequential.md`: the sentence containing "a human-only repo still"
- Modify: `development/skills/open-pr/SKILL.md`: the sentence "so a **human** approves (no AI Approver)"
- Test: `tests/plugin-approver-resolve-issue.bats` (new)
- Modify: manifests (development minor bump)

**Interfaces:**

- Consumes: `plugin-approver-override.zsh` (Task 2); `/development-claude-plugin:approve` (Task 3);
  `development/skills/maintenance/scripts/merge-pr-cycle.zsh <pr>` (exit 0 READY, 4 AWAITING-APPROVAL, 5
  CHANGES-REQUESTED, 6 NOT-GREEN, 3 TIMED-OUT); `await-pr-checks.zsh <pr>`.
- Produces: the prose contract "override=on → approve-and-advance; else human-only stop".

Before editing, check `reference/*.md` for `<!-- moved: -->` frozen spans (see memory
`project-frozen-moved-spans-trap`). Edit only outside them; if a target sentence sits inside one, stop and ask.

- [ ] **Step 1: Write the failing needles**

```bash
#!/usr/bin/env bats
#
# resolve-issue honours the CLAUDE_PLUGIN_APPROVER override through the helper,
# never by reading the variable itself, and falls back to the human-only stop.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RI="$REPO_ROOT/development/skills/resolve-issue"
}

@test "SKILL.md routes the plugin outcome through the override helper" {
  grep -q 'plugin-approver-override.zsh' "$RI/SKILL.md"
  grep -q '/development-claude-plugin:approve' "$RI/SKILL.md"
  grep -q 'AI approval: off (Approver App not installed) — a human approves.' "$RI/SKILL.md"
}

@test "the epic cadence advances in the same invocation when the override is on" {
  grep -q 'override=on.*same invocation' "$RI/SKILL.md"
}

@test "no resolve-issue file reads the raw variable" {
  run grep -rn 'CLAUDE_PLUGIN_APPROVER' "$RI" --include='*.md' --include='*.zsh'
  # Only the description/outcome may NAME it for the human; never a [[ … ]] test on it.
  lacks "$output" '${CLAUDE_PLUGIN_APPROVER'
  lacks "$output" '$CLAUDE_PLUGIN_APPROVER'
}

@test "interactive.md and sequential.md name the override exception" {
  grep -q 'plugin-approver-override.zsh' "$RI/reference/interactive.md"
  grep -q 'plugin-approver-override.zsh' "$RI/reference/sequential.md"
}

@test "open-pr names the ENV exception to human-only" {
  grep -q 'CLAUDE_PLUGIN_APPROVER=1' "$REPO_ROOT/development/skills/open-pr/SKILL.md"
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `LC_ALL=C bats tests/plugin-approver-resolve-issue.bats`
Expected: FAIL (the needles are absent).

- [ ] **Step 3: Edit SKILL.md §6 Outcomes**

Replace `- **Claude-plugin repo (human-only)** → a human approves → it auto-merges.` with:

```markdown
- **Claude-plugin repo** → run
  `development/scripts/approval/plugin-approver-override.zsh` (stdout
  `override=on`, or `override=off` + `reason=`):
  - **`override=on`** (the session exported `CLAUDE_PLUGIN_APPROVER=1`, and the
    Approver App is registered and installed) → wait for green with
    `development/skills/maintenance/scripts/merge-pr-cycle.zsh <pr>` (exit 4
    AWAITING-APPROVAL is the expected cue; 6 NOT-GREEN → fix CI first), run
    `/development-claude-plugin:approve <pr>`, then re-read `reviewDecision`.
    `APPROVED` → armed auto-merge merges it; wait with `await-pr-checks.zsh <pr>`.
    Any other verdict (COMMENT for a never-approve hit, REQUEST_CHANGES) → the
    human-only stop below, naming the Approver's verdict.
  - **`override=off`** → human-only: a human approves → it auto-merges. With
    reason `env-unset` or `not-plugin-repo` add nothing. With
    `approver-not-registered` / `approver-not-installed` (the variable was set,
    but there is no App — the supported way to forbid AI approvals) add exactly
    one informational line to the report:
    `AI approval: off (Approver App not installed) — a human approves.`
    Never a warning. On helper exit 1, relay its one diagnostic line and take
    the human path.
```

Also update the frontmatter `description` clause `a human approves on claude-plugin repos` to `a human approves on
claude-plugin repos (unless the session opts in with CLAUDE_PLUGIN_APPROVER=1)`.

- [ ] **Step 4: Edit the Epic flow "Waiting for each merge" paragraph**

Replace the sentence that begins `In a **human-only** (claude-plugin) repo a human approves + merges each PR` with:

```markdown
In a **claude-plugin** repo, ask `plugin-approver-override.zsh` once per E3
run. On `override=on`, each child goes through §6's approve-and-advance path,
and the chain advances in the same invocation, exactly like an Approver repo.
A child whose Approver verdict is not `APPROVE` becomes that child's
human-only stop, and later children that depend on it park as for an
escalation. On `override=off`, a human approves and merges each PR, which is a
genuine judgement gate rather than a needless re-trigger. So a *sequential*
chain there still advances per merge: open the current child's PR and stop,
resuming on re-run once it merges.
```

The needle in Step 1 matches `override=on.*same invocation` on one line, so keep `On \`override=on\`, each child … same
invocation` on one source line. Re-wrap the paragraph if needed.

- [ ] **Step 5: interactive.md, sequential.md, open-pr**

- `interactive.md`, in "Wait for each merge before the next rung": after `in a human-only repo the human is present`,
  add `(a claude-plugin repo whose plugin-approver-override.zsh says override=on is not human-only for this run: it
  auto-merges like an Approver repo)`.
- `sequential.md`: after `a human-only repo still`, insert the same parenthetical.
- `open-pr/SKILL.md`: change `so a **human** approves (no AI Approver).` to `so a **human** approves (no AI Approver,
  unless the session opts in with \`CLAUDE_PLUGIN_APPROVER=1\` — see \`/development-claude-plugin:approve\`).`

- [ ] **Step 6: Run the tests and see them pass, then run the full suite**

Run: `LC_ALL=C bats tests/plugin-approver-resolve-issue.bats && LC_ALL=C bats tests`
Expected: all green. If a resolve-issue size or shard guard trips (reference file limits), fix it within the limits, not
by raising them.

- [ ] **Step 7: Bump and commit**

```bash
RTK_DISABLED=1 git add development/skills/resolve-issue development/skills/open-pr/SKILL.md tests/plugin-approver-resolve-issue.bats \
  development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
RTK_DISABLED=1 git commit -m "feat(resolve-issue): approve-and-advance on claude-plugin repos under CLAUDE_PLUGIN_APPROVER"
```

---

### Task 5: maintenance — plugin-primary approver mode via the helper

**Files:**

- Modify: `development/skills/maintenance/SKILL.md`, § "Approver mode — detect once per run (#642)" (prose bullets plus
  the bash block)
- Test: `tests/plugin-approver-maintenance.bats` (new)
- Modify: manifests (development minor bump)

**Interfaces:**

- Consumes: `primary` (set in Phase 1 from `.maintenance.yml`); `plugin-approver-override.zsh` (Task 2); Phase 8's
  existing `local` branch, which runs `/development-<lang>:approve`, with `<lang>` = `claude-plugin`.
- Produces: `approver_mode` ∈ `none|local` for a claude-plugin-primary repo, checkpointed exactly as today.

- [ ] **Step 1: Write the failing test**

This test extracts the bash block and runs it against stubs, so it checks behaviour, not just wording.

```bash
#!/usr/bin/env bats
#
# maintenance's approver-mode detection on a claude-plugin-primary repo is
# decided by plugin-approver-override.zsh: none unless override=on.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL="$REPO_ROOT/development/skills/maintenance/SKILL.md"
  cd "$BATS_TEST_TMPDIR"
  # The block between the "Approver mode" heading and the next heading, first ```bash fence.
  awk '/^### Approver mode — detect once per run/{s=1} s&&/^```bash$/{b=1;next} b&&/^```$/{exit} b' "$SKILL" > block.zsh
  # Stub owner probe: registered.
  printf '#!/usr/bin/env zsh\nprint "approver: registered"\nexit 0\n' > bootstrap-status.zsh
  printf '#!/usr/bin/env zsh\ncat > "$BATS_TEST_TMPDIR/checkpoint.json"\n' > checkpoint.zsh
  chmod +x bootstrap-status.zsh checkpoint.zsh
}

run_block() {  # $1 = primary, $2 = stubbed override stdout
  printf '#!/usr/bin/env zsh\nprint -r -- %q\n' "$2" > override.zsh; chmod +x override.zsh
  sed -e "s#\"<skill-base-dir>/../bootstrap/scripts/claude-apps-owner.zsh\"#$BATS_TEST_TMPDIR/bootstrap-status.zsh#" \
      -e "s#\"<skill-base-dir>/scripts/checkpoint.zsh\"#$BATS_TEST_TMPDIR/checkpoint.zsh#" \
      -e "s#\"<skill-base-dir>/../../scripts/approval/plugin-approver-override.zsh\"#$BATS_TEST_TMPDIR/override.zsh#" \
      block.zsh > b.zsh
  primary="$1" BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" zsh -c "primary=$1; source ./b.zsh"
  jq -r .approver_mode checkpoint.json
}

@test "plugin-primary, override off → none (silently)" {
  run run_block claude-plugin $'override=off\nreason=approver-not-installed'
  [ "$output" = "none" ]
}

@test "plugin-primary, override on → local" {
  run run_block claude-plugin 'override=on'
  [ "$output" = "local" ]
}

@test "language-primary is untouched → local when registered" {
  run run_block python $'override=off\nreason=not-plugin-repo'
  [ "$output" = "local" ]
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `LC_ALL=C bats tests/plugin-approver-maintenance.bats`
Expected: "plugin-primary, override off → none" FAILS. It gets `local` today.

- [ ] **Step 3: Edit the bash block**

Insert immediately before the `print -r -- "{\"approver_mode\": …` line:

```zsh
# A claude-plugin-primary repo is human-only (#1684) unless this session opted
# in with CLAUDE_PLUGIN_APPROVER=1 — decided by the shared helper, never by
# reading the variable here. Off for a "no Approver App" reason is silent: it is
# the supported way to forbid AI approvals.
if [[ "${primary:-}" == claude-plugin && "$mode" != none ]]; then
  ovr_rc=0
  ovr=$("<skill-base-dir>/../../scripts/approval/plugin-approver-override.zsh") || ovr_rc=$?
  if grep -qx 'override=on' <<<"$ovr"; then
    mode=local
  else
    mode=none
  fi
  # exit 1 = a broken setup someone intended: its stderr already named the fix; list it in Phase 9.
fi
```

- [ ] **Step 4: Edit the prose bullets**

Append to the **`none`** bullet: `A **claude-plugin-primary** repo is also \`none\` unless
\`plugin-approver-override.zsh\` prints \`override=on\` (the session exported \`CLAUDE_PLUGIN_APPROVER=1\`); then it is
\`local\`, and the gate drives \`/development-claude-plugin:approve\`. A "no Approver App" off is silent.`

- [ ] **Step 5: Run the tests and see them pass, then run the full suite**

Run: `LC_ALL=C bats tests/plugin-approver-maintenance.bats && LC_ALL=C bats tests`
Expected: all green. If the `awk` extraction picks up the wrong fence, tighten it in the test, not in the SKILL.md.

- [ ] **Step 6: Bump and commit**

```bash
RTK_DISABLED=1 git add development/skills/maintenance/SKILL.md tests/plugin-approver-maintenance.bats \
  development/.claude-plugin/plugin.json .claude-plugin/marketplace.json
RTK_DISABLED=1 git commit -m "feat(maintenance): claude-plugin approver mode via CLAUDE_PLUGIN_APPROVER override"
```

---

## Ordering

`Task 1 → Task 2 → Task 3 → Task 4 → Task 5`, each its own PR off fresh `main` (no stacking). Tasks 4 and 5 are
logically independent, but both bump `development` and would collide on its version, so they run sequentially.

## Operator follow-up (not a task)

To use the override on this repo, install the Approver App on `timo-jakob/timos-claude-code-plugins`
(`install-claude-apps.zsh`, inside the repo), then `export CLAUDE_PLUGIN_APPROVER=1` before `/development:resolve-issue
<epic>`.
