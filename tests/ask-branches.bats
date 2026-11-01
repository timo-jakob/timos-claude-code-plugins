#!/usr/bin/env bats
#
# #2903: the ask-branch inventories of resolve-issue and refine-issue. Each
# skill's reference/ask-branches.md lists every branch that can put a question
# to a human, with a verbatim content anchor per file and a #2899 kind. Guarded
# both ways: every ask-pattern line in the skill's SKILL.md and reference/**/*.md
# (the inventory itself excluded) carries one of its file's anchors, and every
# anchor still occurs in its file. Then the four implementation defaults: each
# new sentence is pinned, and the question wording it replaced is gone.

bats_require_minimum_version 1.5.0
load assertions

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVE="$REPO_ROOT/development/skills/resolve-issue"
  REFINE="$REPO_ROOT/development/skills/refine-issue"
  ASK_RE='AskUserQuestion|ask the human|ask once|halt and ask|ask for native sub-issues|ask whether|warn and confirm|offer to|offer another loop|offer the parked exit|put the choice to the human'
}

flat() { tr '\n' ' ' < "$1" | tr -s ' '; }

# num:window per line: that line joined with the next, emphasis stripped, so a
# phrase wrapped across a line break or split by ** still matches.
windows() {
  awk '{ gsub(/\*/, ""); sub(/^[ \t]+/, "") } NR > 1 { print NR - 1 ":" prev " " $0 } { prev = $0 } END { if (NR) print NR ":" prev }' "$1"
}

# One TSV line per anchor: id, file, anchor, kind, outcome. A row is a table
# line starting `| RS-` or `| RF-`; its anchors cell holds code spans joined by
# " · ", a span with a backtick inside written with double backticks.
rows() {
  awk -F ' [|] ' '
    /^\| R[SF]-[0-9]+ \|/ {
      id = $1; sub(/^\| /, "", id)
      out = $5; sub(/ \|$/, "", out)
      n = split($3, a, " · ")
      for (i = 1; i <= n; i++) {
        s = a[i]
        if (s ~ /^`` .* ``$/) s = substr(s, 4, length(s) - 6)
        else if (s ~ /^`.*`$/) s = substr(s, 2, length(s) - 2)
        else s = "UNQUOTED:" s
        printf "%s\t%s\t%s\t%s\t%s\n", id, $2, s, $4, out
      }
    }' "$1"
}

# The skill's scanned files: SKILL.md plus every tracked reference/**/*.md,
# the inventory excluded. Paths relative to the skill directory.
scanned() {
  printf '%s\n' SKILL.md
  git -C "$1" ls-files -- 'reference/*.md' 'reference/**/*.md' | sort -u | grep -v '^reference/ask-branches\.md$' || true
}

# Prints every ask-pattern line no anchor of its file covers, as file:line:text.
unanchored() {
  local dir="$1" inv="$2" f line num text found anchor
  local tsv; tsv="$(rows "$inv")"
  while IFS= read -r f; do
    while IFS= read -r line; do
      num="${line%%:*}"; text="${line#*:}"; found=0
      while IFS=$'\t' read -r _ af anchor _ _; do
        [ "$af" = "$f" ] || continue
        case "$text" in *"${anchor//\*/}"*) found=1; break ;; esac
      done <<< "$tsv"
      [ "$found" -eq 1 ] || printf '%s:%s:%s\n' "$f" "$num" "$text"
    done < <(windows "$dir/$f" | grep -i -E "$ASK_RE" || true)
  done < <(scanned "$dir")
}

# Prints every anchor that no longer occurs in its file, as id file anchor.
stale() {
  local dir="$1" inv="$2" id f anchor
  while IFS=$'\t' read -r id f anchor _ _; do
    if [ ! -f "$dir/$f" ] || ! grep -qF -- "$anchor" "$dir/$f"; then
      printf '%s %s %s\n' "$id" "$f" "$anchor"
    fi
  done < <(rows "$inv")
}

# --- the inventories are well formed -------------------------------------------

@test "each inventory row has a kind in {intent, gap, implementation}, and only implementation rows name a default" {
  local inv bad=""
  for inv in "$RESOLVE/reference/ask-branches.md" "$REFINE/reference/ask-branches.md"; do
    [ "$(rows "$inv" | wc -l)" -gt 0 ]
    bad+="$(rows "$inv" | awk -F '\t' '
      { n = split($4, k, " / "); ok = (n > 0); impl = 0
        for (i = 1; i <= n; i++) { if (k[i] !~ /^(intent|gap|implementation)$/) ok = 0; if (k[i] == "implementation") impl = 1 }
        if (!ok) print "bad kind: " $0
        else if (impl && n != 1) print "implementation shares a row: " $0
        else if (impl && $5 !~ /^\*\*default:\*\* /) print "implementation without a default: " $0
        else if (!impl && $5 !~ /^human-owned: /) print "non-implementation not human-owned: " $0
        if ($3 ~ /^UNQUOTED:/) print "anchor not a code span: " $0 }')"
  done
  [ -z "$bad" ] || { printf '%s\n' "$bad" >&2; return 1; }
}

@test "exactly RS-09, RF-02, RF-03 and RF-09 are implementation rows" {
  local ids
  ids="$( { rows "$RESOLVE/reference/ask-branches.md"; rows "$REFINE/reference/ask-branches.md"; } \
    | awk -F '\t' '$4 == "implementation" { print $1 }' | sort -u | tr '\n' ' ')"
  [ "$ids" = "RF-02 RF-03 RF-09 RS-09 " ]
}

# --- both directions of the anchor guard ----------------------------------------

@test "every ask-pattern line in resolve-issue carries an inventory anchor of its file" {
  local out; out="$(unanchored "$RESOLVE" "$RESOLVE/reference/ask-branches.md")"
  [ -z "$out" ] || { printf 'unanchored: %s\n' "$out" >&2; return 1; }
}

@test "every ask-pattern line in refine-issue carries an inventory anchor of its file" {
  local out; out="$(unanchored "$REFINE" "$REFINE/reference/ask-branches.md")"
  [ -z "$out" ] || { printf 'unanchored: %s\n' "$out" >&2; return 1; }
}

@test "every inventory anchor still occurs in its file" {
  local out
  out="$(stale "$RESOLVE" "$RESOLVE/reference/ask-branches.md")$(stale "$REFINE" "$REFINE/reference/ask-branches.md")"
  [ -z "$out" ] || { printf 'stale anchor: %s\n' "$out" >&2; return 1; }
}

@test "the scan covers SKILL.md and the reference tree, and never the inventory itself" {
  local list; list="$(scanned "$RESOLVE")"
  grep -qx 'SKILL.md' <<< "$list"
  grep -qx 'reference/interactive/remediation.md' <<< "$list"
  grep -qx 'reference/checkpoint.md' <<< "$list"
  run -1 grep -qx 'reference/ask-branches.md' <<< "$list"
}

@test "the guard fires on an unanchored ask line, a stale anchor and an unquoted anchor (mutation)" {
  local d="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$d/reference"
  printf '%s\n' 'Interactive: ask the human to attach them.' 'Then ask once (`AskUserQuestion`) which.' > "$d/SKILL.md"
  printf '%s\n' '| id | file | anchors | kind | outcome |' '|---|---|---|---|---|' \
    '| RS-01 | SKILL.md | `ask the human to attach` · `gone from the file` | gap | human-owned: x |' > "$d/reference/ask-branches.md"
  git -C "$d" init -q
  git -C "$d" add -A
  run unanchored "$d" "$d/reference/ask-branches.md"
  [ "$output" = 'SKILL.md:2:Then ask once (`AskUserQuestion`) which.' ]
  run stale "$d" "$d/reference/ask-branches.md"
  [ "$output" = 'RS-01 SKILL.md gone from the file' ]
  printf '%s\n' '| RS-02 | SKILL.md | then ask once | intent | human-owned: x |' >> "$d/reference/ask-branches.md"
  run rows "$d/reference/ask-branches.md"
  contains "$output" $'RS-02\tSKILL.md\tUNQUOTED:then ask once'
  printf '%s\n' 'Then **halt** and ask.' '' 'Then ask for native' 'sub-issues.' > "$d/SKILL.md"
  run unanchored "$d" "$d/reference/ask-branches.md"
  contains "$output" 'SKILL.md:1:Then halt and ask.'
  contains "$output" 'SKILL.md:3:Then ask for native sub-issues.'
}

# --- the four implementation defaults --------------------------------------------

@test "RS-09: an attended run refines the parked follow-ups without asking, and records the decision" {
  local t r; t="$(flat "$RESOLVE/SKILL.md")"; r="$(flat "$RESOLVE/reference/ask-branches.md")"
  contains "$t" 'invoke `/development:refine-issue <issue> --follow-up` for each issue it prints. Do it without asking, in every session mode (`resolve-session.zsh`, #2575), and record it: see `reference/ask-branches.md` § RS-09 — the parked follow-up default (#2903)'
  contains "$t" '**Before open-pr (#2903):** see `reference/ask-branches.md` § RS-09 — the parked follow-up default (#2903)'
  contains "$r" '**Print one line** when §7 starts the refinements: `Decision taken (not asked): auto-refining the parked follow-ups #A, #B`.'
  contains "$r" '**Record the follow-up default in the body (#2903).** In §6, run §7'"'"'s `follow-up-origin.zsh parked-issues` read before open-pr opens the PR.'
  contains "$r" 'how to overrule: restore a follow-up'
  contains "$r" 'there is no PR body, so the same entry goes in the run'"'"'s report, as it does whenever §7 refines follow-ups an open PR'"'"'s body does not hold.'
  run -1 grep -qF 'Decision taken (not asked)' <<< "$t"
  run -1 grep -qF 'attended run ask once' <<< "$t"
  run -1 grep -qF 'asks once, listing the follow-ups' "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md"
  run -1 grep -qF 'after one question on an attended run' "$REPO_ROOT/ARCHITECTURE.md"
  run -1 grep -qF 'auto-refinement recommended' <<< "$t"
}

@test "RF-02: refine-issue proceeds on a missing needs-refinement label, with a notice" {
  local t; t="$(flat "$REFINE/SKILL.md")"
  contains "$t" 'Otherwise, if the label is **absent**, **proceed without asking**, and take the default with its notice (*Defaults taken instead of asking*, above)'
  run -1 grep -qF 'refine it anyway?' <<< "$t"
  run -1 grep -qiF 'warn and confirm' <<< "$t"
  contains "$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")" 'If the `needs-refinement` label is missing it refines anyway, and says so.'
}

@test "RF-03: refine-issue clears the label of an already-READY story without asking" {
  local t; t="$(flat "$REFINE/SKILL.md")"
  contains "$t" 'If it already returns `READY`, the story now passes: **clear the label through Step 5 without asking** — no loop needed — and take the default with its notice'
  run -1 grep -qF 're-run' <<< "$(grep -F '| Step 1 |' "$REFINE/SKILL.md")"
  contains "$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")" 'If the story is already READY, the skill clears the label and says so.'
  run -1 grep -qF 'offer to just clear the label' <<< "$t"
  run -1 grep -qF 'ask whether they want to refine anyway' <<< "$t"
  # Scoped to Step 1, the READY shortcut this guards: #2904's batch skip ends a
  # child as *skipped (human declined)* in the Epic walk, which is not this ask.
  run -1 grep -qF 'human declined' <<< "$(sed -n '/^## Step 1 /,/^## Step 2 /p' "$REFINE/SKILL.md")"
}

@test "RF-09: refine-issue loops back to Step 2 on a still-rejected re-gate without asking" {
  local t; t="$(flat "$REFINE/SKILL.md")"
  contains "$t" '**Loop back to Step 2 without asking**, with the gate'
  contains "$t" 'The unattended follow-up mode never loops back: it takes the stop below, its deferred route.'
  contains "$t" '**A stop the human takes in that loop before its next Step 3 write-back is a recorded ending, but NOT Step 2'
  run -1 grep -qF 'Offer another loop (back to Step 2) or to stop here' <<< "$t"
  contains "$(flat "$REPO_ROOT/docs/explanation/workflow-refine-issue.md")" 'On NEEDS_REFINEMENT it keeps the label and loops back to step 2; you can still stop there as `deferred`.'
}

@test "refine-issue's defaults print one line and record one Decisions-taken entry, in the body or a comment" {
  local t; t="$(flat "$REFINE/SKILL.md")"
  contains "$t" '1. **Prints one line** in your terminal output: `Decision taken (not asked): <choice>`.'
  contains "$t" 'When Step 2 renders the Decisions taken section before the approval, that file counts as one of this issue'
  contains "$t" 'but it is never part of a parked state'
  contains "$t" 'post each pending entry as a one-line issue comment instead'
  contains "$t" 'The body is never edited only to record a default.'
  contains "$t" 'drop it from the file, so nothing records it twice.'
  contains "$t" '| Step 5 | Loop again after a re-gate that still rejects? |'
  contains "$t" 'Append it as `{"kind": "implementation", "question": …, "answer": <choice>, "rationale": <evidence>, "overrule": <how to overrule>}` to the `auto` array of `/tmp/conductor-defaults.json`, created as `{"auto": []}`; Step 0 deletes it with the parked state.'
  contains "$t" 'rm -f /tmp/parked-state.json /tmp/parked-comment.md /tmp/parked.json /tmp/conductor-defaults.json'
  contains "$(flat "$REPO_ROOT/docs/how-to/let-refine-issue-answer-confident-questions.md")" 'Three questions are no longer asked at all, whatever the threshold: whether to refine an issue that is not marked `needs-refinement`, whether to clear the label of a story that already passes, and whether to loop again after a failed re-gate. The skill takes the safe answer to each, prints one line, and records it under **Decisions taken**: in the body when it writes one, else as a one-line comment.'
}

@test "refine-issue's defaults table, its READY shortcut and its guardrail say the threshold decides none of them" {
  local t; t="$(flat "$REFINE/SKILL.md")"
  contains "$t" '| Step 1 | Clear `needs-refinement` on a story the gate now passes? | Cleared it through Step 5'"'"'s `READY` branch. | Step 5 removes the label only on a `READY` verdict. |'
  contains "$t" 'That shortcut is still a run: set `PARK_TYPE=""; ROUNDS=0; RAISED=0; RESOLVED=0`'
  contains "$t" 'An attended run asks none of the three either: they are the conductor'"'"'s defaults (*Defaults taken instead of asking*), which the threshold never decides.'
}

@test "resolve-issue reads the parked follow-ups before open-pr, so the PR body carries the decision" {
  local r; r="$(flat "$RESOLVE/reference/ask-branches.md")"
  contains "$r" 'read before open-pr opens the PR. When it prints any issue, the body carries a `## Decisions taken` section'
  contains "$r" 'An exit 1 or 2 adds no section.'
  contains "$(flat "$RESOLVE/SKILL.md")" '**Before open-pr (#2903):** see `reference/ask-branches.md` §'
}

@test "both inventories state their contract: the kinds, the anchor format and the two-way guard" {
  local inv t
  for inv in "$RESOLVE/reference/ask-branches.md" "$REFINE/reference/ask-branches.md"; do
    t="$(flat "$inv")"
    contains "$t" 'An `intent` or `gap` branch stays with the human'
    contains "$t" '**anchors** are verbatim text from that file, one code span each, joined by ` · `.'
    contains "$t" '`tests/ask-branches.bats` holds the two directions: every line of the skill that matches its ask pattern carries one of its file'"'"'s anchors, and every anchor still occurs in its file.'
  done
  contains "$(flat "$RESOLVE/reference/ask-branches.md")" 'An `intent` or `gap` branch stays with the human, and its autonomous / interactive split is the one its own file states, and `scripts/resolve-session.zsh` decides which arm a run takes.'
}
