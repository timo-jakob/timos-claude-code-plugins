#!/usr/bin/env zsh
# test-case-spinout.zsh — reconcile a story's linked `test-case` issues against
# its story-spec/v1 `test_cases[]` (#671, epic #573).
#
# The hybrid test-case model: outside-in test cases live BOTH structured in the
# story's `story-spec/v1` block (the single gate-validatable source of truth) AND
# as separate linked `test-case` issues, so each case is independently visible in
# the backlog and its existence is checkable by the gate — while staying
# implemented in the SAME PR as the story (#577/#696), so tests and feature can
# never drift apart. This script is the spin-out/reconcile primitive
# `/development:refine-issue` runs after the human approves a rewrite, before it
# writes the story-spec block back.
#
# Reconciliation is idempotent, keyed on the stable `test_cases[].id`:
#   - new case with no prior linked issue          → create a `test-case` issue
#   - new case whose id matches a prior link        → edit that issue (regenerate)
#   - prior linked id absent from the new case set  → close the orphan + comment
#   - story with zero test cases (no surface)       → close every prior link
#
# The prior links come from `--old-spec` (the story-spec block currently in the
# issue body, before write-back): each `test_cases[].id → .issue`. A case whose
# NEW entry already carries a numeric `.issue` is also treated as linked, so a
# no-op re-run reconciles cleanly even without an --old-spec.
#
# On success it prints the reconciled `test_cases` JSON array (each entry's
# `issue` now populated) to STDOUT — the caller merges it back into the block
# before write-back. All diagnostics go to STDERR.
#
# Usage:
#   test-case-spinout.zsh --repo <owner/name> --story <N> --spec <new-spec.json> \
#     [--old-spec <old-spec.json>]
#
#   --repo:     owner/name of the target repo (passed to every `gh` call)
#   --story:    parent story issue number
#   --spec:     path to the NEW proposed story-spec/v1 JSON object
#   --old-spec: path to the story's CURRENT story-spec/v1 JSON (optional; supplies
#               the prior id→issue links for reconciliation + orphan detection)
#
# Exit codes: 0 ok · 1 runtime error (unreadable file, no jq/gh, gh failure) ·
#             2 usage error.

emulate -L zsh
set -euo pipefail

readonly LABEL="test-case"
readonly LABEL_COLOR="0e8a16"
readonly LABEL_DESC="An outside-in acceptance test case spun out from a story's story-spec/v1 block (#671)"
# A stable, machine-findable marker stamped into every managed test-case body.
readonly MANAGED_MARKER="<!-- managed by /development:refine-issue test-case spin-out (#671) — body regenerated on reconcile; do not hand-edit -->"

repo=""
story=""
spec=""
old_spec=""

while (( $# > 0 )); do
  # shift by 2 for value options, but only 1 when the value is missing (a
  # dangling final flag) so the required-field checks below emit the clean
  # exit-2 usage error instead of `shift` aborting under set -e.
  case "$1" in
    --repo)     repo="${2:-}";     shift $(( $# < 2 ? $# : 2 )) ;;
    --story)    story="${2:-}";    shift $(( $# < 2 ? $# : 2 )) ;;
    --spec)     spec="${2:-}";     shift $(( $# < 2 ? $# : 2 )) ;;
    --old-spec) old_spec="${2:-}"; shift $(( $# < 2 ? $# : 2 )) ;;
    -h|--help)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) print -u2 "test-case-spinout.zsh: unknown arg: $1"; exit 2 ;;
  esac
done

[[ -n "$repo"  ]] || { print -u2 "test-case-spinout.zsh: --repo is required";  exit 2; }
[[ -n "$story" ]] || { print -u2 "test-case-spinout.zsh: --story is required"; exit 2; }
[[ -n "$spec"  ]] || { print -u2 "test-case-spinout.zsh: --spec is required";  exit 2; }
[[ "$story" == <-> ]] || { print -u2 "test-case-spinout.zsh: --story must be a number, got: $story"; exit 2; }
[[ -f "$spec" ]] || { print -u2 "test-case-spinout.zsh: spec file not found: $spec"; exit 1; }
[[ -z "$old_spec" || -f "$old_spec" ]] || { print -u2 "test-case-spinout.zsh: old-spec file not found: $old_spec"; exit 1; }

command -v jq >/dev/null 2>&1 || { print -u2 "test-case-spinout.zsh: jq not found on PATH"; exit 1; }
command -v gh >/dev/null 2>&1 || { print -u2 "test-case-spinout.zsh: gh not found on PATH"; exit 1; }

jq -e . "$spec" >/dev/null 2>&1 || { print -u2 "test-case-spinout.zsh: --spec is not valid JSON: $spec"; exit 1; }
if [[ -n "$old_spec" ]]; then
  jq -e . "$old_spec" >/dev/null 2>&1 || { print -u2 "test-case-spinout.zsh: --old-spec is not valid JSON: $old_spec"; exit 1; }
fi

# Prior id→issue links: the current block's test_cases (from --old-spec), plus any
# numeric .issue already on the NEW entries (a no-op re-run without --old-spec).
typeset -A prior_link
if [[ -n "$old_spec" ]]; then
  while IFS=$'\t' read -r id num; do
    [[ -n "$id" && "$num" == <-> ]] && prior_link[$id]="$num"
  done < <(jq -r '(.test_cases // [])[] | select(.id and (.issue|type=="number")) | "\(.id)\t\(.issue)"' "$old_spec")
fi
while IFS=$'\t' read -r id num; do
  [[ -n "$id" && "$num" == <-> && -z "${prior_link[$id]:-}" ]] && prior_link[$id]="$num"
done < <(jq -r '(.test_cases // [])[] | select(.id and (.issue|type=="number")) | "\(.id)\t\(.issue)"' "$spec")

# Ensure the `test-case` label exists (idempotent — ignore "already exists").
gh label create "$LABEL" --repo "$repo" --color "$LABEL_COLOR" --description "$LABEL_DESC" \
  >/dev/null 2>&1 || true

# Render the managed body for one test case ($1=id $2=kind $3=tooling $4=shape).
render_body() {
  local id="$1" kind="$2" tooling="$3" shape="$4"
  cat <<EOF
$MANAGED_MARKER
<!-- test-case: story=$story id=$id -->

Parent story: #$story

- **Kind:** \`${kind:-unspecified}\`
- **Tooling:** \`${tooling:-unspecified}\`
- **Spec id:** \`$id\`

## Shape

${shape:-_(no shape recorded in the story-spec entry)_}

---

An outside-in **test case** spun out from the parent story's \`story-spec/v1\`
block (hybrid model, #671). It is implemented and closed in the **same PR** as
its parent story #$story — there is no \`blockedBy\` between them (same-PR closure
makes ordering moot). See ARCHITECTURE.md → *Test-case issue convention*.
EOF
}

# Extract the trailing issue number from a `gh issue create` URL.
issue_num_from_url() { print -r -- "${1##*/}"; }

count="$(jq '(.test_cases // []) | length' "$spec")"
reconciled='[]'   # accumulates the NEW test_cases with .issue filled in
typeset -A kept_id

if (( count > 0 )); then
  for (( idx = 0; idx < count; idx++ )); do
    id="$(jq -r ".test_cases[$idx].id // empty" "$spec")"
    if [[ -z "$id" ]]; then
      print -u2 "test-case-spinout.zsh: test_cases[$idx] has no id — cannot reconcile"; exit 1
    fi
    kept_id[$id]=1
    kind="$(jq -r ".test_cases[$idx].kind // empty" "$spec")"
    tooling="$(jq -r ".test_cases[$idx].tooling // empty" "$spec")"
    shape="$(jq -r ".test_cases[$idx].shape // empty" "$spec")"
    body="$(render_body "$id" "$kind" "$tooling" "$shape")"
    title="test-case: $id ($kind) — story #$story"

    linked="${prior_link[$id]:-}"
    if [[ -n "$linked" ]]; then
      gh issue edit "$linked" --repo "$repo" --title "$title" --body "$body" >/dev/null
      num="$linked"
      print -u2 "test-case-spinout.zsh: reconciled #$num ← $id"
    else
      url="$(gh issue create --repo "$repo" --title "$title" --body "$body" --label "$LABEL")"
      num="$(issue_num_from_url "$url")"
      [[ "$num" == <-> ]] || { print -u2 "test-case-spinout.zsh: could not parse issue number from: $url"; exit 1; }
      print -u2 "test-case-spinout.zsh: created #$num ← $id"
    fi

    reconciled="$(jq --argjson n "$num" ".test_cases[$idx] | .issue = \$n" "$spec" \
      | jq -s --argjson acc "$reconciled" '$acc + .')"
  done
fi

# Close orphans: prior links whose id is no longer in the new case set.
for id num in "${(@kv)prior_link}"; do
  if [[ -z "${kept_id[$id]:-}" ]]; then
    gh issue close "$num" --repo "$repo" --comment \
"Closing this test case: its parent story #$story no longer defines \`$id\` after refinement — the case was dropped from the story's \`story-spec/v1\` block (#671). Reopen only if the story re-adds it." \
      >/dev/null
    print -u2 "test-case-spinout.zsh: closed orphan #$num ($id no longer in story)"
  fi
done

print -r -- "$reconciled"
