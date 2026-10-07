#!/usr/bin/env bats
#
# Needles for #2191: the claude-plugin profile's §E4 end-to-end half runs in
# the session only (install check, then scripts, then a foreground subagent),
# and the test harness waits on its headless child in the invoking session,
# spawning the judge only once the exit marker exists. Text is matched on a
# whitespace-flattened copy, so re-wrapping a paragraph never reds a needle.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PROFILE="$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md"
  HARNESS="$REPO_ROOT/development-claude-plugin/skills/test/SKILL.md"
  export LC_ALL=C
}

_flat() { tr '\n' ' ' | tr -s ' '; }

# The `## Gate` section of the profile, flattened.
_gate() {
  awk '/^## /{ on = ($0 == "## Gate") ; next } on' "$PROFILE" | _flat
}

# The §E4 bullet alone: from its bold lead to the next top-level bullet.
_e4() {
  awk '
    /^- \*\*Epic verification \(§E4\)/ { on = 1; print; next }
    on && /^- / { exit }
    on { print }
  ' "$PROFILE" | _flat
}

# The judge prompt: the first ```text fence under the Step 6 heading.
_judge_prompt() {
  awk '
    /^## Step 6 / { s = 1; next }
    s && /^## / { exit }
    s && /^```text$/ { f = 1; next }
    f && /^```$/ { exit }
    f { print }
  ' "$HARNESS"
}

@test "#2191 the E4 bullet runs its end-to-end half in the session, with no headless child" {
  local e4 n miss=""
  e4="$(_e4)"
  [ -n "$e4" ]
  for n in \
    'an end-to-end half driving the affected skills/agents, which runs **in the session only**' \
    'E4 is an unattended step, and no autonomous flow launches a headless `claude` child (#2191)' \
    '**Scripts first.** Run the epic'"'"'s deterministic scripts directly against a scratch target built outside the repository.' \
    '**Then a foreground subagent, only where a model-driven skill must be exercised.**' \
    'It invokes that skill through the Skill tool against the scratch target, in the foreground only: it never arms a Monitor, never ends its turn while waiting, and never starts a background task.' \
    '`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/installed_plugins.json`' \
    '`git show origin/main:<plugin>/.claude-plugin/plugin.json`' \
    'Each must look like semver and equal `main`'"'"'s.' \
    'means the end-to-end half is reported as **not run against `main`**, never as a pass: E4 is then not green, so do not proceed to E5' \
    'Never infer the installed version from the highest plugin cache directory' \
    'the full `bats` suite via that same blessed single-run gate'
  do
    case "$e4" in *"$n"*) : ;; *) miss+="$n"$'\n' ;; esac
  done
  [ -z "$miss" ] || { printf 'E4 bullet lost:\n%s\n' "$miss" >&2; return 1; }
}

@test "#2191 the E4 bullet names neither the harness nor its launcher" {
  local e4
  e4="$(_e4)"
  [ -n "$e4" ]
  case "$e4" in *development-claude-plugin:test*|*run-headless*|*'claude -p'*)
    printf 'E4 bullet still names the headless harness:\n%s\n' "$e4" >&2; return 1 ;;
  esac
}

@test "#2191 the E4 steps run in order: install check, scripts, then the subagent" {
  local e4 a b c
  e4="$(_e4)"
  a="${e4%%'**Check the install first.**'*}"
  b="${e4%%'**Scripts first.**'*}"
  c="${e4%%'**Then a foreground subagent'*}"
  # each prefix is shorter than the whole only when its marker is present
  [ "${#a}" -lt "${#e4}" ] && [ "${#b}" -lt "${#e4}" ] && [ "${#c}" -lt "${#e4}" ]
  [ "${#a}" -lt "${#b}" ]
  [ "${#b}" -lt "${#c}" ]
}

@test "#2191 the E4 bullet is still the Gate's §E4 bullet" {
  case "$(_gate)" in *'**Epic verification (§E4) uses the same command.**'*) : ;;
    *) printf 'the Gate lost its Epic verification (§E4) bullet\n' >&2; return 1 ;;
  esac
}

@test "#2191 the harness spawns its judge only once the marker exists" {
  local h n miss=""
  h="$(_flat < "$HARNESS")"
  for n in \
    'Spawn the judge only once the marker exists.' \
    'it never launches anything and never waits on anything' \
    '**Human-invoked only.**' \
    'It is **not** for autonomous pipeline steps' \
    '## Step 5 — Launch the child and wait for it yourself' \
    '**Wait on the marker file with your own Monitor until-loop**' \
    'If the Monitor expires first, re-arm the same wait, for at most 45 minutes in total. On `no_verdict`, or once the 45 minutes are used up, the run produced no verdict — report that, with `<OUT>.log`'"'"'s path and whether `<DETACHED_PID>` is still running, and stop. Never spawn the judge, and never read a verdict, without the marker.' \
    'The raw child transcript never enters this conversation.' \
    '**A headless `claude -p` child = the system under test.**' \
    'Launched by you via `scripts/run-headless.zsh`, it loads the **local** plugins from this worktree (`--plugin-dir`) and runs against an isolated clone of the target repo.' \
    '**Launch the child detached** via the wrapper' \
    'It returns immediately, printing `exit_marker=<OUT>.exit`.' \
    'Never rely on a foreground call finishing either — a real child can outlive the foreground cap.' \
    '`--detach` is the only launch mode that survives a turn boundary.' \
    'Spawn **one** subagent (Task tool, `general-purpose` type), in the foreground.' \
    '**Never** launch the wrapper as a Bash background task (`run_in_background: true`): #811 recorded that such a task is killed the instant the turn that started it ends, SIGTERM-ing the child mid-run.'
  do
    case "$h" in *"$n"*) : ;; *) miss+="$n"$'\n' ;; esac
  done
  [ -z "$miss" ] || { printf 'harness lost:\n%s\n' "$miss" >&2; return 1; }
}

@test "#2191 the parent waits before the judge is spawned" {
  local h launch judge
  h="$(_flat < "$HARNESS")"
  launch="${h%%'## Step 5 — Launch the child and wait for it yourself'*}"
  judge="${h%%'## Step 6 — Spawn the judge on the finished transcript'*}"
  [ "${#launch}" -lt "${#h}" ] && [ "${#judge}" -lt "${#h}" ]
  [ "${#launch}" -lt "${#judge}" ]
}

@test "#2191 the judge prompt carries no wait, no Monitor and no launch" {
  local p
  p="$(_judge_prompt)"
  [ -n "$p" ]
  case "$p" in *'<OUT>'*) : ;; *) echo 'judge prompt lost the transcript path' >&2; return 1 ;; esac
  case "$p" in *'<CHILD_EXIT>'*) : ;; *) echo 'judge prompt lost the exit code' >&2; return 1 ;; esac
  if printf '%s' "$p" | grep -qiE 'monitor|until|wait|run-headless|--detach'; then
    printf 'judge prompt still waits or launches:\n%s\n' "$(printf '%s' "$p" | grep -niE 'monitor|until|wait|run-headless|--detach')" >&2
    return 1
  fi
}

@test "#2191 step 2b and the 'Waiting on the judge' note are gone" {
  run grep -nE '^2b\.|Waiting on the judge' "$HARNESS"
  [ "$status" -eq 1 ]
}
