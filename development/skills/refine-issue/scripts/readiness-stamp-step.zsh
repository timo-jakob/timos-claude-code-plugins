#!/usr/bin/env zsh
# readiness-stamp-step.zsh — refine-issue's two touch points with the
# readiness-verdict cache (#2956, epic #2953): reuse a still-valid stamp at
# Step 1, and stamp the Step 4 re-gate.
#
# Why: the gate that sent a story back stamped its verdict (#2955), so Step 1
# re-judging an unchanged story spends a gate agent to learn what the stamp
# already says. And a refined story the re-gate passed should reach the next
# resolve-issue run as a cache hit, not as a fresh gate. Both ends fail toward
# gating: a failed check is a miss, a failed write leaves no stamp, and neither
# ever stops the session. The stamp contract is ARCHITECTURE.md's "Readiness
# stamp contract (`readiness-stamp/v1`)"; this script only consumes it, through
# the resolve-issue sibling scripts.
#
# Usage (run from the repository root: `check` re-runs size-check.zsh there):
#   readiness-stamp-step.zsh diagnose --repo OWNER/NAME --issue N
#   readiness-stamp-step.zsh stamp    --repo OWNER/NAME --issue N
#                                     --verdict-file F --expect-key K
#
# diagnose runs `readiness-stamp.zsh check --issue N`, plans it with
#          `readiness-cache-plan.zsh --targets N`, and prints one object:
#            {"hit": true,  "verdict": {…}}          the cached verdict, as stamped
#            {"hit": false, "reason": R}             spawn story-readiness
#          R is the planner's miss reason (no_stamp, key_changed,
#          dependencies_recheck, …), `check_failed` when check failed, or
#          `plan_failed` when the planner did.
# stamp    runs `readiness-stamp.zsh write --expect-key K` and prints
#            {"stamped": true|false, "action": A|null, "reason": R|null}
#          where A is write's action (created, edited, skipped_stale) and R says
#          why nothing was stamped. An empty K (the caller's `key` read failed)
#          stamps nothing, since a write without the race guard could cache a
#          verdict on text the gate never read. Whenever nothing is stamped
#          other than skipped_stale, one line on stderr says so, for the
#          conductor to relay to the human as is.
#
# Seams (for tests / non-PATH installs):
#   STAMP_BIN  overrides readiness-stamp.zsh     (defaults to the resolve-issue
#   PLAN_BIN   overrides readiness-cache-plan.zsh sibling copies — no drift).
#
# Exit codes:
#   0  ok — every check, plan or write failure is reported in the output, never
#      as an exit: the caller fails toward gating
#   2  usage error
#   1  internal (jq missing)

emulate -L zsh
setopt nounset pipefail extended_glob

local stamp_bin="${STAMP_BIN:-${0:A:h}/../../resolve-issue/scripts/readiness-stamp.zsh}"
local plan_bin="${PLAN_BIN:-${0:A:h}/../../resolve-issue/scripts/readiness-cache-plan.zsh}"
local usage="usage: readiness-stamp-step.zsh diagnose --repo OWNER/NAME --issue N
       readiness-stamp-step.zsh stamp --repo OWNER/NAME --issue N --verdict-file F --expect-key K"

_fail() { print -ru2 -- "readiness-stamp-step: $1"; exit 2 }

(( $# > 0 )) || _fail "a mode is required ($usage)"
local mode="$1"; shift
case "$mode" in
  diagnose|stamp) ;;
  -h|--help) print -r -- "$usage"; exit 0 ;;
  *) _fail "unknown mode: $mode ($usage)" ;;
esac

local repo="" issue="" verdict_file="" expect_key="" have_key=0
while (( $# > 0 )); do
  case "$1" in
    --repo|--issue|--verdict-file)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || _fail "$1 requires a non-empty value"
      case "$1" in
        --repo) repo="$2" ;; --issue) issue="$2" ;; --verdict-file) verdict_file="$2" ;;
      esac
      shift 2 ;;
    --expect-key)
      [[ $# -ge 2 && "$2" != --* ]] || _fail "--expect-key requires a value (empty when key failed)"
      expect_key="$2"; have_key=1; shift 2 ;;
    *) _fail "unknown argument: $1 ($usage)" ;;
  esac
done

[[ -n "$repo" ]] || _fail "--repo is required"
[[ "$issue" == [1-9][0-9]# ]] || _fail "--issue must be an issue number: $issue"
if [[ "$mode" == stamp ]]; then
  [[ -n "$verdict_file" ]] || _fail "stamp requires --verdict-file"
  (( have_key )) || _fail "stamp requires --expect-key"
fi

command -v jq >/dev/null 2>&1 || { print -u2 "readiness-stamp-step: jq not found on PATH"; exit 1 }

local tmp
tmp="$(mktemp -d "${TMPDIR:-/tmp}/readiness-stamp-step.XXXXXX")" || { print -u2 "readiness-stamp-step: mktemp failed"; exit 1 }
trap 'rm -rf "$tmp"' EXIT

if [[ "$mode" == diagnose ]]; then
  local rc=0 prc=0
  zsh "$stamp_bin" check --repo "$repo" --issue "$issue" > "$tmp/check.json" 2>/dev/null || rc=$?
  zsh "$plan_bin" --targets "$issue" --check "$tmp/check.json" --check-exit "$rc" \
    > "$tmp/plan.json" 2>/dev/null || prc=$?
  if (( prc != 0 )) || ! jq -e 'type == "object"' "$tmp/plan.json" >/dev/null 2>&1; then
    jq -nc '{hit: false, reason: "plan_failed"}'
    exit 0
  fi
  jq -c --argjson n "$issue" '
    ([.hits[] | select(.issue == $n)] | first) as $hit
    | if $hit != null then {hit: true, verdict: $hit.verdict}
      else {hit: false, reason: ((.readiness_cache.miss_reasons // {} | keys | first) // "not_checked")}
      end' "$tmp/plan.json"
  exit 0
fi

# stamp
_not_stamped() {  # $1 = reason
  print -ru2 -- "readiness stamp not written for #$issue ($1); the next resolve-issue run gates it fresh"
  jq -nc --arg r "$1" '{stamped: false, action: null, reason: $r}'
  exit 0
}
[[ -n "$expect_key" ]] || _not_stamped "no key was read before the re-gate"
local wrc=0
zsh "$stamp_bin" write --repo "$repo" --issue "$issue" --verdict-file "$verdict_file" \
  --expect-key "$expect_key" > "$tmp/write.json" 2>/dev/null || wrc=$?
(( wrc == 0 )) || _not_stamped "write exited $wrc"
local action
action="$(jq -r '.action // empty' "$tmp/write.json" 2>/dev/null)" || action=""
case "$action" in
  created|edited) jq -nc --arg a "$action" '{stamped: true, action: $a, reason: null}' ;;
  skipped_stale)  jq -nc '{stamped: false, action: "skipped_stale", reason: "the issue changed while the re-gate ran"}' ;;
  *)              _not_stamped "write printed no action" ;;
esac
exit 0
