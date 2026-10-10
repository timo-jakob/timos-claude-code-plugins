#!/usr/bin/env bats
#
# resolve-issue honours the CLAUDE_PLUGIN_APPROVER override (#2133, epic #2129)
# through plugin-approver-override.zsh, never by reading the variable itself:
#   * SKILL.md §6 "Outcomes": the claude-plugin bullet asks the helper; on
#     override=on it approves and advances on open-pr's bot path, acting on
#     every merge-pr-cycle.zsh exit, approving on exit 4, and treating the PR
#     as merged only once one of at most 30 paced foreground reads shows
#     MERGED; any other verdict is the human-only stop naming it; on
#     override=off it is unchanged, with one informational line for a missing
#     Approver App and a relayed diagnostic on a helper failure;
#   * the Epic flow advances in the same invocation under override=on, branches
#     each next child only after its predecessor reads MERGED, and parks the
#     dependents of a child that ends on the human-only stop;
#   * the frontmatter description, sequential.md and open-pr name the exception;
#   * remediation.md carries the exception in an unfrozen note AFTER its
#     interactive-remediation frozen block, and interactive.md lists that note
#     among the text outside the byte proof;
#   * no file under resolve-issue/ reads the variable.
# Each file's needles live in one list, used both by its check and by its
# MUTATION test, which runs the same check on a copy with that needle cut.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RI="$REPO_ROOT/development/skills/resolve-issue"
  SKILL="$RI/SKILL.md"
  REMEDIATION="$RI/reference/interactive/remediation.md"
  INTERACTIVE="$RI/reference/interactive.md"
  SEQUENTIAL="$RI/reference/sequential.md"
  OPENPR="$REPO_ROOT/development/skills/open-pr/SKILL.md"
}

# flat <file>: the file with every run of whitespace squeezed to one space, so
# a needle can span a line break.
flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# holds <file> <needle...>: every needle is in the flattened file.
holds() {
  local file="$1" text n; shift
  text="$(flat "$file")"
  for n in "$@"; do
    [[ "$text" == *"$n"* ]] || { echo "missing in ${file##*/}: $n"; return 1; }
  done
}

# mutation <file> <needle...>: cutting any one needle from a copy of the file
# makes holds() fail on the copy.
mutation() {
  local file="$1" cut="$BATS_TEST_TMPDIR/cut.md" n; shift
  for n in "$@"; do
    flat "$file" | NEEDLE="$n" perl -pe 's/\Q$ENV{NEEDLE}\E//g' > "$cut"
    run holds "$cut" "$@"
    [ "$status" -ne 0 ] || { echo "holds() still passed with this needle cut: $n"; return 1; }
  done
}

SKILL_NEEDLES=(
  # §6: the claude-plugin bullet asks the helper
  "**Claude-plugin repo (human-only)** → a human approves → it auto-merges — **unless** \`development/scripts/approval/plugin-approver-override.zsh\` reports \`override=on\`, the \`CLAUDE_PLUGIN_APPROVER=1\` exception."
  "Ask the helper; never read the variable yourself."
  # §6: override=on
  "**\`override=on\`** → approve and advance, on open-pr's bot path only: a user-authored fallback PR has no armed auto-merge, so once approved it ends on the human-only stop, \`approved; a human admin-merges\`."
  "Wait with \`development/skills/maintenance/scripts/merge-pr-cycle.zsh <pr>\` and act on its exit:"
  "**4** AWAITING-APPROVAL is the cue — run \`/development-claude-plugin:approve <pr>\`, then re-read \`reviewDecision\`;"
  "**0** READY means the PR is already approved;"
  "**6** NOT-GREEN means fix CI first, push the fix and re-trigger CI as open-pr's *Re-pushing to an already-open PR?* paragraph says (#605), then wait again on the new head"
  "a third NOT-GREEN is the human-only stop, naming the failing check;"
  "**5** CHANGES-REQUESTED, **3** TIMED-OUT or **1** is the human-only stop, naming that result line;"
  "**2** is your own malformed call — fix it and re-run, never a verdict."
  "\`reviewDecision\` \`APPROVED\` (exit 0, or after the approve run) → armed auto-merge merges it:"
  "wait for its checks with \`development/skills/maintenance/scripts/await-pr-checks.zsh <pr>\`,"
  "then re-read \`gh pr view <pr> --json state,autoMergeRequest\` until it reads \`MERGED\` — a green PR is not yet a merged one"
  "Each re-read is its own foreground Bash call, \`gh pr view <pr> --json state,autoMergeRequest; sleep 60\`, judged by the JSON it prints, never by its exit status — at most 30 of them, one a minute, and never a hand-rolled \`while [ … ]\` loop (#412), a \`Monitor\` or a background poll."
  "A read showing \`MERGED\` ends the wait merged, even when that same read shows \`autoMergeRequest\` \`null\`."
  "Otherwise the wait ends unmerged, on the human-only stop naming why, when \`await-pr-checks.zsh\` exits non-zero or settles \`NOT-GREEN\`, \`state\` reads \`CLOSED\`, \`autoMergeRequest\` reads \`null\` (auto-merge disarmed), or the 30th re-read shows no \`MERGED\`."
  "Any other \`reviewDecision\` → the human-only stop, naming the Approver's verdict, or that it posted none."
  "In strictly sequential mode every one of these waits is that mode's foreground call."
  # §6: override=off and helper failures
  "**\`override=off\`** → the human-only flow, unchanged. For \`env-unset\` or \`not-plugin-repo\` the report adds nothing;"
  "for \`approver-not-registered\` or \`approver-not-installed\` it adds exactly one informational line, never a warning:"
  "AI approval: off (Approver App not installed) — a human approves."
  "**Helper exit 1** (a broken Approver setup), or any other non-zero exit → relay the helper's diagnostic — its \`reason=\` slug and its stderr — as one line, and take the human path."
  # the Epic flow
  "E3 asks \`development/scripts/approval/plugin-approver-override.zsh\` once per run. On \`override=on\` each child's PR takes §6's approve-and-advance path,"
  "so the chain advances in the same invocation as on an Approver repo — each next child branches only once §6 reads its predecessor \`MERGED\`."
  "A child that ends on §6's human-only stop (any ending short of \`MERGED\`) stops there, and the children that depend on it are parked."
  "On \`override=off\` (or a helper exit 1) the per-merge stop above is unchanged."
  # the frontmatter description
  "a human approves on claude-plugin repos, except under CLAUDE_PLUGIN_APPROVER=1, where the claude-plugin Approver approves each PR and an epic advances in one invocation."
)

REMEDIATION_NEEDLES=(
  "**A rung's PR under the \`CLAUDE_PLUGIN_APPROVER=1\` exception.**"
  "reports \`override=on\` there is a third: the rung's PR follows the approve-and-advance cadence exactly as SKILL.md §6 states it"
  "its \`merge-pr-cycle.zsh <pr>\` wait, \`/development-claude-plugin:approve <pr>\` on that wait's exit 4 only, and \`await-pr-checks.zsh <pr>\` once \`reviewDecision\` reads \`APPROVED\`, each exit acted on as §6 lists it"
  "the remediation continues once the PR reads \`MERGED\`, not merely green."
  "Wherever §6 ends on its human-only stop, that is the span's human-only wait, and the report names the verdict §6 named."
  "On \`override=off\`, or a helper failure (its diagnostic relayed), the span's human-only wait is unchanged."
)

INTERACTIVE_NEEDLES=(
  "the #1226 note after \`remediation.md\`'s block, the \`CLAUDE_PLUGIN_APPROVER=1\` note that follows it (#2133)"
)

SEQUENTIAL_NEEDLES=(
  "a human-only repo still stops after opening each sequential child's PR, unless \`development/scripts/approval/plugin-approver-override.zsh\` reports \`override=on\`"
  "Under the \`override=on\` exception (SKILL.md §6), \`merge-pr-cycle.zsh --timeout 540 <pr>\` waits the same way:"
  "re-issued on its exit 3 within the same 30-minute total, and only a timeout after that is §6's human-only stop."
  "§6's re-read until \`MERGED\` needs no splitting: it is already at most 30 foreground calls, one \`gh pr view\` each."
)

OPENPR_NEEDLES=(
  "so a **human** approves (no AI Approver) — the one exception is a session opted in with \`CLAUDE_PLUGIN_APPROVER=1\`,"
  "where \`development/scripts/approval/plugin-approver-override.zsh\` decides whether \`/development-claude-plugin:approve\` may approve instead."
)

@test "SKILL.md: §6, the Epic flow and the description state the override exception" {
  holds "$SKILL" "${SKILL_NEEDLES[@]}"
}

@test "MUTATION: cutting any SKILL.md needle reds its check" {
  mutation "$SKILL" "${SKILL_NEEDLES[@]}"
}

@test "SKILL.md: the description needle sits in the frontmatter" {
  local desc
  desc="$(awk 'NR==1{next} /^---$/{exit} {print}' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
  contains "$desc" "except under CLAUDE_PLUGIN_APPROVER=1, where the claude-plugin Approver approves each PR"
}

@test "SKILL.md: the override bullet sits in §6 Outcomes" {
  local out
  out="$(awk '/^Outcomes:/{f=1} f && /^Report the PR URL/{exit} f' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
  contains "$out" "Ask the helper; never read the variable yourself."
  contains "$out" "AI approval: off (Approver App not installed) — a human approves."
}

@test "remediation.md: the override note sits after the interactive-remediation frozen block" {
  local end hit
  end="$(grep -n -- '<!-- /moved: interactive-remediation -->' "$REMEDIATION" | cut -d: -f1)"
  hit="$(grep -n 'plugin-approver-override.zsh' "$REMEDIATION" | head -1 | cut -d: -f1)"
  [ -n "$end" ]
  [ -n "$hit" ]
  [ "$hit" -gt "$end" ]
}

@test "remediation.md: the note states the approve-and-advance cadence and the human-only fallback" {
  holds "$REMEDIATION" "${REMEDIATION_NEEDLES[@]}"
}

@test "MUTATION: cutting any remediation.md needle reds its check" {
  mutation "$REMEDIATION" "${REMEDIATION_NEEDLES[@]}"
}

@test "interactive.md lists the override note among the text outside the byte proof" {
  holds "$INTERACTIVE" "${INTERACTIVE_NEEDLES[@]}"
}

@test "sequential.md names the override=on exception and its foreground merge-pr-cycle wait" {
  holds "$SEQUENTIAL" "${SEQUENTIAL_NEEDLES[@]}"
}

@test "MUTATION: cutting any sequential.md needle reds its check" {
  mutation "$SEQUENTIAL" "${SEQUENTIAL_NEEDLES[@]}"
}

@test "open-pr names the CLAUDE_PLUGIN_APPROVER=1 exception and the helper that decides it" {
  holds "$OPENPR" "${OPENPR_NEEDLES[@]}"
}

@test "MUTATION: cutting any open-pr needle reds its check" {
  mutation "$OPENPR" "${OPENPR_NEEDLES[@]}"
}

@test "no file under resolve-issue reads the raw variable" {
  run grep -rnE '\$\{?CLAUDE_PLUGIN_APPROVER' "$RI"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "non-vacuity: the raw-variable sweep catches a planted read" {
  local dir="$BATS_TEST_TMPDIR/ri"
  mkdir -p "$dir"
  printf '[[ "${CLAUDE_PLUGIN_APPROVER:-}" == 1 ]]\n' > "$dir/x.zsh"
  run grep -rnE '\$\{?CLAUDE_PLUGIN_APPROVER' "$dir"
  [ "$status" -eq 0 ]
}
