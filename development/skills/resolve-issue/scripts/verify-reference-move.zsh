#!/usr/bin/env zsh
# verify-reference-move.zsh — prove the review-loop carve-out (#1503) is
# byte-preserving.
#
# Why: `resolve-issue/SKILL.md` was ~3 900 lines, of which ~2 250 described
# branches a given run never takes, loaded on every run of every repo type. The
# fix is a MOVE into on-demand `reference/*.md`, not a rewrite — and a move is
# the one restructuring a reviewer can check mechanically instead of re-reading
# as new prose. This script is that check.
#
# What it asserts, per moved chunk: the bytes between the chunk's
# `<!-- moved: NAME -->` / `<!-- /moved: NAME -->` sentinels in the reference
# file are IDENTICAL to the lines the chunk was carved from in the pre-move
# SKILL.md at `--base` (default: the pinned pre-move commit). On a mismatch it
# prints the
# first differing line, with both sides, and exits 1.
#
# WHAT IT DOES NOT PROVE, stated because the header used to overclaim: this is a
# per-chunk check. For each DECLARED chunk it proves the moved bytes are
# unchanged. It does NOT prove conservation — text deleted from the pre-move
# SKILL.md that landed in no reference file, or landed but was never added to the
# manifest, is invisible to every path here. Read the claim as "each declared
# chunk moved verbatim", never as "nothing was lost". (Conservation is tracked
# separately; see #1548.) Nor does it prove anything about text sitting BETWEEN
# two chunks of a SPLIT span — the #1582 gap inside `round-protocol`, which since
# #3168 runs on through the whole of round step 1, and the #3169 gap holding
# step 3's narration paragraph, and the two #3044 gaps in review-loop/core.md
# holding round step 4 and the *How to wait* paragraph — which is verified by
# nothing; see the manifest comment below.
#
# Normalisation, stated so the claim is honest: leading and trailing BLANK or
# WHITESPACE-ONLY lines are stripped from BOTH sides before comparison (they are
# section separators, not content). Nothing else is normalised — no whitespace
# collapsing, no case folding, no reflowing.
#
# The source ranges are pinned by CONTENT anchors, never by line number (#1189):
# each is `first line` .. `last line`, both matched in full against the pre-move
# file. A moved chunk whose first or last line was edited fails loudly here
# rather than silently re-anchoring onto neighbouring text.
#
# Usage:
#   verify-reference-move.zsh [--base <git-ref>] [--repo <dir>] [--quiet]
#
# `--base` defaults to the PINNED pre-move commit, never to a moving ref: once
# #1503 merges, `origin/main` holds the POST-move conductor and contains none of
# the moved chunks, so an `origin/main` default would fail its own documented
# invocation forever and read as the very defect this script disproves.
#
# Exit codes:
#   0  every chunk is byte-identical (or, for -h/--help, the usage string — the
#      one exit-0 stdout that is NOT a verdict)
#   1  at least one chunk differs, an input could not be read, a MANIFEST row is
#      malformed (fewer than four tab-separated fields — #1588, counted as a
#      chunk failure so the sweeps below it still run), OR a sentinel
#      sweep failed: an undeclared/duplicated sentinel, the sweep could not be
#      RUN at all (#1588 — grep or its normalisation failed, so the invariant is
#      vacuous rather than satisfied), the round-protocol head closer not
#      appearing exactly once, in core.md, or the head's last anchor or
#      round-protocol-step-2's first anchor no longer adjacent to round step 1 in
#      the pinned commit (#1582, #3168), a re-cut span's seam leaving an
#      original line uncovered or out of order (#2055), or a gapped seam whose
#      gap is no longer exactly the paragraph it was opened for (#3169, #3044).
#      Chunk differences and sweep failures are counted and reported separately
#      — they are different defects — but both land here.
#   2  usage error

emulate -L zsh
# AFTER emulate, never before: `emulate` resets the emulation-sensitive options
# to their zsh defaults, and UNSET is one of them (default ON), so a `set -u`
# placed above this line would be silently switched back off — leaving the
# script running without the unset-parameter net it declares. Note that the `-L`
# above DOES set `local_options` (and `local_traps`/`local_patterns`) — it is the
# local-options flag. Both are inert here, because a script's top level never
# returns from a function, and harmless if this file is ever sourced from inside
# one; they are not what the ordering rule above is about.
setopt no_unset pipefail

# Same scrub as review-dispatch.zsh and git-tree-id.zsh (#1582). These override
# `git -C "$repo"`, so an inherited one — git hooks, filter drivers, some CI
# wrappers, any invocation nested inside a git subprocess — would make the two
# git calls below read the pinned commit and SKILL.md out of a DIFFERENT
# repository. That fails in the worst direction: if the other repo also contains
# the pinned commit (a clone or worktree of this one does), the gate prints
# `all N declared chunks are byte-identical` at exit 0 having verified nothing
# about the tree the caller named with `--repo`.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# The pre-move conductor. Pinned, and single-sourced here — the bats gate reads
# this value out of the script rather than restating it.
typeset -r PRE_MOVE_DEFAULT=a45c6b1c1e38e1c56614be6cb9282d83072969e1

typeset base="$PRE_MOVE_DEFAULT"
typeset repo=""
typeset quiet=0

while (( $# )); do
  case "$1" in
    # Both flags reject an EMPTY value, not merely a missing one. An empty
    # `--repo` used to fall through to the script-relative default and verify
    # the real tree while the caller believed it verified the one it named; an
    # empty `--base` made `git show ":<path>"` read the INDEX — git's staged-blob
    # syntax — and report success against whatever happened to be staged.
    --base)
      shift
      [[ ${1-} == ?* ]] || { print -u2 -- "verify-reference-move: --base needs a non-empty value"; exit 2 }
      base="$1" ;;
    --repo)
      shift
      [[ ${1-} == ?* ]] || { print -u2 -- "verify-reference-move: --repo needs a non-empty value"; exit 2 }
      repo="$1" ;;
    --quiet) quiet=1 ;;
    -h|--help)
      print -r -- "usage: verify-reference-move.zsh [--base <git-ref>] [--repo <dir>] [--quiet]"
      exit 0 ;;
    *) print -u2 -- "verify-reference-move: unknown argument: $1"; exit 2 ;;
  esac
  shift
done

if [[ -z "$repo" ]]; then
  repo="${0:A:h}/../../../.."
fi
repo="${repo:A}"
[[ -d "$repo" ]] || { print -u2 -- "verify-reference-move: not a directory: $repo"; exit 2 }

typeset SKILL_REL="development/skills/resolve-issue/SKILL.md"
typeset REF_DIR="$repo/development/skills/resolve-issue/reference"

# Resolve the base to a commit before reading through it, so a ref that is not a
# commit (or an accidental index/tree spelling) is a named failure rather than a
# silent read of something else.
if ! git -C "$repo" rev-parse --verify --quiet "${base}^{commit}" >/dev/null 2>&1; then
  print -u2 -- "verify-reference-move: '$base' does not resolve to a commit in $repo — is it fetched?"
  exit 1
fi

# git's own stderr is NOT discarded here. The check above has already proved
# `$base` resolves to a commit, so "is it fetched?" is the one cause that cannot
# be true by this point; the realistic ones are a path that did not exist at that
# commit (a pin predating the file, or a rename) and an object-store read error,
# which git distinguishes precisely. Swallowing that to print a hint we know is
# wrong is the confidently-wrong-cause pattern `_detect_json`'s stderr relay
# exists to avoid.
typeset pre
if ! pre=$(git -C "$repo" show "${base}:${SKILL_REL}"); then
  print -u2 -- "verify-reference-move: could not read ${base}:${SKILL_REL} — does that path exist at ${base}?"
  exit 1
fi

# --- the manifest ----------------------------------------------------------
# One row per moved chunk: NAME<TAB>REF_FILE<TAB>FIRST_LINE<TAB>LAST_LINE
# FIRST_LINE / LAST_LINE are matched in full (fixed-string, whole line) against
# the pre-move SKILL.md. Keep this list in sync with the reference files'
# sentinels — a chunk present in one and not the other is reported below.
#
# `round-protocol` is SPLIT into head + tail (#1582). The reviewer path rule had
# to land in the round protocol, and the whole span was byte-frozen, so the span
# was re-cut to open a gap for it. Until #3168 the gap held ONLY new prose: the
# head ends at `Each round:` and the tail resumed at step 1's own first line, so
# the only original line in the gap was the blank separator between them.
#
# The cost is still real and is recorded rather than hidden: text sitting in that
# gap is verified by NOTHING, so an edit to the new rule passes this gate in
# silence. It was bounded to the rule itself until #3168.
#
# #3168 retired the TAIL (`round-protocol-tail`, round step 1 in
# review-loop/step-1-panel.md). Dropping the waived-suggestion hand-off edited
# step 1 from its plan flags near the top to its last sub-bullet, and step 1 is
# ONE numbered list item, so no column-0 sentinel can sit inside it (see the
# markdown note below). No part of it could stay byte-frozen, so its row and
# sentinels are gone and the whole of step 1 is verified by NOTHING. With no
# tail anchor to pair with, two adjacency assertions below guard the gap's two
# edges in the pinned commit: the head's last anchor must sit next to step 1's
# first line, and round-protocol-step-2's first anchor next to step 1's last
# line, so no original prose leaves either neighbour's verified region unnoticed.
#
# The cut is where it is because of MARKDOWN, not preference. `extract_chunk`
# matches a sentinel as a whole line at column 0, and a column-0 HTML comment
# INSIDE a numbered list item destroys the list continuation — putting the tail's
# opener mid-step produced 16 markdownlint findings on a file that lints clean.
# The only column-0 positions that are structurally safe are outside the list, so
# the gap sits between `Each round:` and the list's first item.
#
# Three spans were re-cut by #3121, which removed the suggestion-promotion phase
# from their text, so the lines it edited could no longer stay byte-frozen. Each
# re-cut keeps every unchanged line it can verify at a markdown-safe cut:
#   - `escalation-terminal` now starts at its step 1. Its opening paragraph,
#     which offered the promotion phase on `CONVERGED`, is verified by nothing.
#   - `interactive-extension` is cut into its intro (`interactive-extension`)
#     and its steps 2-4 (`interactive-extension-steps-2-4`). The `grants`
#     paragraph between them named the promotion sub-loop's own counter, and
#     step 1 the progress table's Promoted column; both are verified by nothing.
#   - `interactive-extension-steps-5-7` is now `interactive-extension-steps-6-7`.
#     Step 5 passed the promotion flag and offered the phase throughout, and
#     a column-0 sentinel inside its list item would break the list, so the
#     whole step is verified by nothing.
# The steps-2-4 / steps-6-7 seam is no longer checked: step 5 sits between them,
# so the two are not adjacent in the pinned commit, and no CUT_GROUPS entry names
# them any more.
#
# #3169 cut `round-protocol-steps-3-4` around ONE paragraph of round step 3, the
# narration paragraph that begins `Otherwise blockers remain and budget is
# left:`. Dropping the waived-suggestion carry edited it, and step 3 is one list
# item of some 240 lines, so retiring the whole step (as #3168 did for step 1)
# would have left all of it verified by nothing. The cut instead puts an
# INDENTED sentinel pair at the paragraph boundaries inside the list item: an
# HTML comment indented to the item's content column is part of the item, so
# the list is unbroken, which a column-0 one is not (see the markdown note
# above). `extract_chunk` and the stray-sentinel sweep therefore accept leading
# blanks before a sentinel. The chunk before the paragraph is
# `round-protocol-step-3-head`, and the one after it keeps the name
# `round-protocol-steps-3-4`, so its column-0 closer, which other suites anchor
# on, stays where it was. The paragraph between them is verified by nothing, and
# the gapped-seam check below pins that gap to exactly that paragraph.
#
# #3044 cut the old `round-protocol-head` span twice, because it replaced the
# marker-file wait in two places inside it: round step 4, and the *How to wait*
# paragraph just above `Each round:`. The span is now three chunks:
#   - `round-protocol-boundary`, from the boundary's banner through round step
#     3, closed by an INDENTED sentinel inside step 3's list item (#3169's
#     form, so the list is unbroken);
#   - `round-protocol-boundary-steps-5-7`, from step 5 through the attestation
#     invariant's paragraph, opened by an indented sentinel at the end of step 4;
#   - `round-protocol-head`, now the single line `Each round:`. It keeps the old
#     name and its column-0 closer, which the adjacency check below and other
#     suites anchor on. `Each round:` occurs once in the pinned commit, so a
#     one-line range whose two anchors are equal extracts exactly it.
# Step 4 and the *How to wait* paragraph sit in the two gaps, verified by
# nothing; the gapped-seam check below pins each gap to exactly that text.
#
# One anchor that looks obvious is UNUSABLE, recorded so nobody re-derives it:
# `   **How to wait** (this section) governs the wait — it is not restated here.`
# occurs TWICE in the pinned pre-move SKILL.md, and `extract_range` starts at the
# FIRST match of a first-anchor — so using it as the tail's opener would extract
# from the wrong place and never match.
typeset -a MANIFEST
MANIFEST=(
"interactive-remediation	interactive/remediation.md	Applies **only** with a human present, and only to a **shape (i)**	  what the gate exists to prevent.
"
"round-protocol-boundary	review-loop/core.md	**The round boundary is concurrent — one minted tree, two readers (#1497).**	   held \`--gate-attest\`, which is the self-attestation the invariant forbids.
"
"round-protocol-boundary-steps-5-7	review-loop/core.md	5. **Green** → consolidate (the *Each round* loop-invocation step below),	That is the one recovery the *no fix pass ran* case above excludes.
"
"round-protocol-head	review-loop/core.md	Each round:	Each round:
"
"round-protocol-step-2	review-loop/step-2-invocation.md	2. **One loop invocation.**	     actually read. The stderr names both identities and the files that moved.
"
"round-protocol-recover	review-loop/exit-2-stale-findings.md	   **Recover by cause, then re-invoke** — the round is not lost. One arm below	   dispatch \`findings_path\`) needs no digest tool and always applies.
"
"round-protocol-step-3-head	review-loop/exit-20-awaiting-fix.md	3. **On \`AWAITING_FIX\` (exit 20)** — the round is over and the run continues.	   claim true rather than merely well-formed.
"
"round-protocol-steps-3-4	review-loop/exit-20-awaiting-fix.md	   **That row is this round's fix-pass trigger (#1496).** Sum the last two	   is how the two statements of it came to disagree once already.
"
"escalation-head	escalation.md	A bad escalation costs a human an afternoon; a good one costs two minutes. On	tell the human the opposite of what happened.
"
"interactive-extension	interactive/extension.md	**Interactive extension (human present, \`BUDGET_EXHAUSTED\` /	run** skip this branch entirely and go straight to the typed comment below.)
"
"interactive-extension-steps-2-4	interactive/extension.md	2. **Offer the choice** with \`AskUserQuestion\` (one question), tailored to the	   side-channel).
"
"interactive-extension-steps-6-7	interactive/extension-grant.md	6. **Soft cap.** Before re-offering, if \`grants >= 5\` **or** the **last round	   later with \`/development:resolve-issue <N>\`.
"
"escalation-terminal	escalation.md	1. **Push the branch as the bot** (so the diff-so-far is linkable) but **create	   the next run can converge. No PR exists until it does.
"
)

# Extract the inclusive range [first .. last] from a file's text, by full-line
# match. Prints nothing and returns non-zero when either anchor is missing or
# the pair is out of order.
# A HERE-STRING, not `print -r -- "$text" | awk`: awk `exit`s the moment it sees
# the closing anchor, which SIGPIPEs the feeding `print`, and under `pipefail`
# that makes the whole pipeline non-zero — reported as "could not locate the
# source range" for every chunk that ends early in the file, while the extraction
# in fact succeeded. (It was invisible until the `emulate` ordering above was
# fixed, because `emulate` had been silently switching `pipefail` back off.)
extract_range() {
  local text="$1" first="$2" last="$3"
  awk -v f="$first" -v l="$last" '
    !started && $0 == f { started = 1 }
    started            { buf = buf $0 "\n" }
    started && $0 == l { printf "%s", buf; found = 1; exit }
    END { if (!found) exit 3 }
  ' <<< "$text"
}

# Extract the body between the sentinels of one chunk in a reference file. A
# sentinel may be indented with blanks (#3169, see the manifest comment): the
# whole line, minus its leading blanks, must be the sentinel.
extract_chunk() {
  local file="$1" name="$2"
  awk -v n="$name" '
    { t = $0; sub(/^ +/, "", t) }
    t == "<!-- moved: " n " -->"  { inside = 1; next }
    t == "<!-- /moved: " n " -->" { inside = 0; found = 1; exit }
    inside                        { print }
    END { if (!found) exit 3 }
  ' "$file"
}

# Strip leading and trailing blank lines.
strip_blanks() {
  awk '
    { line[NR] = $0 }
    END {
      s = 1; e = NR
      while (s <= e && line[s] ~ /^[[:space:]]*$/) s++
      while (e >= s && line[e] ~ /^[[:space:]]*$/) e--
      for (i = s; i <= e; i++) print line[i]
    }
  '
}

typeset -i chunk_failures=0 sweep_failures=0 verified=0
typeset row name ref_name first last ref_file src_raw src dst
typeset -a a b

for row in "${MANIFEST[@]}"; do
  row="${row%$'\n'}"
  # A row must carry FOUR tab-separated fields (#1588). Field-peeling below is
  # forgiving in the wrong direction: on a three-field row `first` and `last`
  # both end up holding the same string, `extract_range` fails to bracket a
  # single line against itself, and the operator is told "could not locate the
  # source range" beneath TWO IDENTICAL ANCHORS — a message that points at the
  # anchors when the fault is the row. Never a silent pass (the empty-chunk
  # guard and the counter reconciliation close those exits), so this costs
  # diagnosis time only — which is exactly why it is worth one check.
  #
  # Counted as TABS, and `< 3` rather than `!= 3`: `last` deliberately absorbs
  # everything after the third tab, so a FOURTH tab inside an anchor line is
  # legitimate and must keep working. Only a row with too FEW fields is malformed.
  #
  # COUNTED and continued, like every other per-row failure here (missing
  # reference file, unlocatable range, missing sentinel block, empty chunk) —
  # not an `exit 1` mid-loop. The script's design is report-everything-exit-once:
  # aborting here would report only the FIRST malformed row, skip the
  # sentinel/duplicate sweeps and the head-closer and seam checks, and print
  # neither summary line. The run still ends at exit 1 via the `chunk_failures`
  # arm below, so the observable contract — exit 1, naming the offending row — is
  # unchanged, and the reconciliation `verified + chunk_failures != ${#MANIFEST}`
  # still balances.
  typeset row_tabs="${row//[^$'\t']/}"
  if (( ${#row_tabs} < 3 )); then
    print -u2 -- "FAIL: malformed manifest row — needs 4 tab-separated fields, found $(( ${#row_tabs} + 1 )):"
    print -u2 -r -- "  $row"
    (( chunk_failures++ )); continue
  fi
  name="${row%%$'\t'*}";        row="${row#*$'\t'}"
  ref_name="${row%%$'\t'*}";    row="${row#*$'\t'}"
  first="${row%%$'\t'*}"
  last="${row#*$'\t'}"

  ref_file="$REF_DIR/$ref_name"
  if [[ ! -f "$ref_file" ]]; then
    print -u2 -- "FAIL $name: reference file not found: $ref_file"
    (( chunk_failures++ )); continue
  fi

  if ! src_raw=$(extract_range "$pre" "$first" "$last"); then
    print -u2 -- "FAIL $name: could not locate the source range in ${base}:${SKILL_REL}"
    print -u2 -- "  first anchor: $first"
    print -u2 -- "  last  anchor: $last"
    (( chunk_failures++ )); continue
  fi
  if ! dst=$(extract_chunk "$ref_file" "$name"); then
    print -u2 -- "FAIL $name: no <!-- moved: $name --> block in $ref_name"
    (( chunk_failures++ )); continue
  fi

  # Both statuses are READ (#1588) — they were the only two command
  # substitutions here that were not, while `extract_range`, `extract_chunk` and
  # the adjacency `awk` all are. An unchecked `strip_blanks` failure (awk absent,
  # a locale abort) returns an empty string, and the empty-chunk refusal below
  # then fires with `empty chunk after normalisation` — a verdict about the
  # chunk's CONTENT derived from a normalisation that never ran, which is the
  # confidently-wrong cause this file's stderr-relay comments exist to avoid.
  src=$(print -r -- "$src_raw" | strip_blanks) || {
    print -u2 -- "FAIL $name: could not normalise the source chunk"
    (( chunk_failures++ )); continue
  }
  dst=$(print -r -- "$dst" | strip_blanks) || {
    print -u2 -- "FAIL $name: could not normalise the moved chunk in $ref_name"
    (( chunk_failures++ )); continue
  }

  # An empty-vs-empty comparison would pass and be counted as verified — a gate
  # whose whole job is to notice unmoved text signing off on a chunk containing
  # nothing. Reachable without any awk failure (anchors that both match a blank
  # line, against adjacent sentinels), so refuse it outright.
  if [[ -z "$src" || -z "$dst" ]]; then
    (( chunk_failures++ ))
    print -u2 -- "FAIL $name: empty chunk after normalisation (source ${#src} bytes, moved ${#dst} bytes)"
    continue
  fi
  if [[ "$src" == "$dst" ]]; then
    (( verified++ ))
    (( quiet )) || print -r -- "ok   $name — $(print -r -- "$src" | wc -l | tr -d ' ') lines byte-identical → reference/$ref_name"
    continue
  fi

  (( chunk_failures++ ))
  print -u2 -- "FAIL $name: reference/$ref_name differs from ${base}:${SKILL_REL}"
  # First differing line, with both sides.
  a=("${(@f)src}"); b=("${(@f)dst}")
  typeset -i i n
  n=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
  for (( i = 1; i <= n; i++ )); do
    if [[ "${a[$i]-$'\0MISSING'}" != "${b[$i]-$'\0MISSING'}" ]]; then
      print -u2 -- "  first difference at chunk line $i:"
      print -u2 -- "    ${base}: ${a[$i]-<end of chunk>}"
      print -u2 -- "    moved  : ${b[$i]-<end of chunk>}"
      break
    fi
  done
  print -u2 -- "  (${#a} source lines vs ${#b} moved lines)"
done

# Every sentinel present in the reference files must appear in the manifest —
# otherwise a chunk could be added to a reference file and never verified.
#
# The name pattern is `.+`, not `[a-z-]+`: extract_chunk matches ANY name, so a
# chunk called `escalation-1503` or `round_protocol` would extract and compare
# fine while this sweep skipped the line entirely, leaving it unverified with the
# script still exiting 0. And stderr is NOT discarded — a grep that fails
# outright must be distinguishable from one that found nothing.
typeset -a sentinels stray dupes
# The STATUS is read, not only the stderr (#1588). Relaying stderr makes the two
# cases distinguishable to a human; it left them identical to the SCRIPT, and
# this is the load-bearing one: on a walk that fails outright, or partially (an
# unreadable subtree under reference/), `sentinels` comes back short or empty and
# the undeclared/duplicated invariant below silently passes over whatever it
# never saw. A total failure is caught downstream anyway — every chunk then
# reports `reference file not found` — but a PARTIAL walk would leave a real
# stray sentinel unswept with nothing reported at all.
#
# Branch on grep's code, never on a bare `||`: grep exits **1 for "no matches"**
# and only **>= 2** for a real error, so a bare `||` would report a sweep failure
# for a reference tree that simply carries no sentinels — a state the
# empty-manifest comment further down discusses as legitimate-if-unlikely (and
# `tests/verify-reference-move.bats` annotates from the coverage side), and
# turning it into a fabricated error would be its own confidently-wrong cause.
#
# grep is captured ALONE, not as `grep | sed | sort`. Under `pipefail` the
# pipeline's status is the rightmost non-zero, so a `sed` that exits 1 — BSD sed
# does, on `RE error: illegal byte sequence`, which a byte-identity gate can
# plausibly meet — would be indistinguishable from grep's "no matches" and the
# duplicate/stray sweeps would then iterate over an empty list while every
# reference file is still present: a silent partial sweep, which is the exact
# failure this status read exists to catch. Splitting the two also stops a
# sed/sort failure being reported as `(grep exit N)`, naming a command that
# succeeded.
typeset sentinel_hits sentinels_raw grep_rc
# Leading blanks are allowed, as `extract_chunk` allows them (#3169): a sweep
# that saw only column-0 openers would leave an indented chunk unverified.
sentinel_hits=$(grep -rhoE '^ *<!-- moved: .+ -->$' "$REF_DIR")
grep_rc=$?
if (( grep_rc >= 2 )); then
  # COUNTED and continued, like every other sweep arm — not a mid-run `exit 1`.
  # Aborting here would discard the per-chunk work already done and print
  # neither summary, which is the same argument the malformed-row guard above
  # makes for itself. An empty `sentinel_hits` makes the sweeps below vacuous,
  # so the failure is recorded rather than hidden, and the run still ends at 1.
  print -u2 -- "FAIL: could not sweep $REF_DIR for sentinels (grep exit $grep_rc)"
  (( sweep_failures++ ))
  sentinel_hits=""
fi
sentinels_raw=$(print -r -- "$sentinel_hits" | sed -E 's/^ *<!-- moved: (.*) -->$/\1/' | sort) || {
  print -u2 -- "FAIL: could not normalise the sentinel sweep output"
  (( sweep_failures++ ))
  sentinels_raw=""
}
sentinels=("${(@f)sentinels_raw}")
sentinels=(${sentinels:#})
# Duplicates are a failure, not something to dedupe away: extract_chunk exits at
# the FIRST matching close, so a chunk copy-pasted into a second reference file
# has an unverified twin that can drift freely.
dupes=("${(@f)$(print -rl -- "${sentinels[@]}" | sort | uniq -d)}")
dupes=(${dupes:#})
typeset d
for d in "${dupes[@]}"; do
  print -u2 -- "FAIL: chunk '$d' is declared by more than one <!-- moved: --> sentinel; only the first is verified"
  (( sweep_failures++ ))
done
stray=("${(@f)$(print -rl -- "${sentinels[@]}" | sort -u)}")
stray=(${stray:#})
typeset s known
for s in "${stray[@]}"; do
  [[ -n "$s" ]] || continue
  known=0
  for row in "${MANIFEST[@]}"; do
    [[ "${row%%$'\t'*}" == "$s" ]] && { known=1; break }
  done
  (( known )) || { print -u2 -- "FAIL: reference/ declares chunk '$s' that this script does not verify"; (( sweep_failures++ )) }
done

# --- the head closer, and the head's last anchor (#1582, #3168) --------------
# #1582 split `round-protocol` into a head and a tail to open an unverified gap
# for the reviewer-path rule, and asserted here that the head's LAST anchor and
# the tail's FIRST stayed adjacent in the pinned commit, so no original line
# could migrate into the gap. #3168 retired the tail (see the manifest comment),
# so the gap now runs from the head's closer through the whole of round step 1.
#
# The hazard the adjacency check caught is still live on the head's side: move
# the head row's LAST anchor inward (with its closer) and original conductor
# prose leaves the verified region with every byte comparison green. So the
# head's last anchor is still required to sit directly above round step 1's
# first line in the pinned commit, modulo blank lines. That line is a constant
# here, and that is sound where the old literal-only form was not: the hazard is
# an edit to the MANIFEST's head row, which is read out of the manifest below,
# so the assertion moves with the edit it exists to catch.
#
# The head's closer marks where the unverified prose begins, so it must appear
# exactly once across reference/, and in core.md.
typeset -r STEP1_FIRST='1. **Review panel, in-session.** Get the dispatch plan (`review-dispatch.zsh'
typeset head_shard="$REF_DIR/review-loop/core.md"
typeset -a hc_hits
# Captured as an ARRAY and required to be exactly one: a DUPLICATED closer — in
# the right shard or in any other — must fail rather than be read as the one
# expected. The stray sweep above cannot catch it: it greps only the OPENING
# form. stderr is NOT discarded, the same rule the sentinel sweep above states:
# an unreadable shard would otherwise be reported as "head-close: 0" — a verdict
# about the file's CONTENT derived from a read that never happened.
hc_hits=("${(@f)$(grep -rxF -- '<!-- /moved: round-protocol-head -->' "$REF_DIR")}")
hc_hits=(${hc_hits:#})
if (( ${#hc_hits} != 1 )); then
  print -u2 -- "FAIL: the round-protocol head closer must appear exactly once across reference/ (head-close: ${#hc_hits})"
  (( sweep_failures++ ))
elif [[ "${hc_hits[1]%%:*}" != "$head_shard" ]]; then
  print -u2 -- "FAIL: the round-protocol head closer is in the wrong shard — ${hc_hits[1]%%:*} (want review-loop/core.md)"
  (( sweep_failures++ ))
fi
typeset head_last="" mrow
for mrow in "${MANIFEST[@]}"; do
  mrow="${mrow%$'\n'}"
  # Skip a MALFORMED row, with the same test the main loop uses (#1588), so a
  # bad row is reported once, as malformed, rather than read here as an anchor.
  typeset mrow_tabs="${mrow//[^$'\t']/}"
  (( ${#mrow_tabs} >= 3 )) || continue
  # Peeled NON-greedily, exactly as the main loop's `last="${row#*$'\t'}"` is
  # (#1588), so the two parses agree on a LAST_LINE anchor that contains a tab.
  [[ "${mrow%%$'\t'*}" == round-protocol-head ]] && head_last="${${${mrow#*$'\t'}#*$'\t'}#*$'\t'}"
done
if [[ -z "$head_last" ]]; then
  print -u2 -- "FAIL: the manifest no longer declares round-protocol-head, so its last anchor cannot be checked"
  (( sweep_failures++ ))
else
  # A here-string, not `print … | awk`: awk `exit`s at the step-1 line and would
  # SIGPIPE the producer, which `pipefail` promotes to 141. It matters here
  # because the status IS read.
  typeset between
  typeset -i awk_rc=0
  between=$(awk -v h="$head_last" -v t="$STEP1_FIRST" '
    $0 == h        { seen = 1; next }
    seen && $0 == t { done = 1; exit }
    seen && $0 ~ /[^[:space:]]/ { print }
    END { if (!seen || !done) exit 3 }
  ' <<< "$pre") || awk_rc=$?
  if (( awk_rc )); then
    print -u2 -- "FAIL: the head's last anchor and round step 1's first line are not both present, in order, in ${base}:${SKILL_REL} — head-last <<${head_last}>>"
    (( sweep_failures++ ))
  elif [[ -n "$between" ]]; then
    print -u2 -- "FAIL: the head's last anchor is no longer adjacent to round step 1 in ${base}:${SKILL_REL} — original prose now sits between them, outside every verified chunk:"
    print -u2 -- "$between"
    (( sweep_failures++ ))
  fi
fi

# The same hazard on the gap's other edge: move round-protocol-step-2's FIRST
# anchor down (with its opener) and step 2's opening lines leave the verified
# region with every comparison green. Before #3168 the tail -> step-2 seam below
# caught that; with the tail retired, step-2's first anchor is required to sit
# directly below round step 1's last line in the pinned commit (the retired tail
# row's last anchor), modulo blank lines. The step-2 anchor is read out of the
# manifest, so the assertion moves with the edit it exists to catch.
typeset -r STEP1_LAST='     Critical nobody reported.'
typeset step2_first=""
for mrow in "${MANIFEST[@]}"; do
  mrow="${mrow%$'\n'}"
  typeset mrow_tabs="${mrow//[^$'\t']/}"
  (( ${#mrow_tabs} >= 3 )) || continue
  [[ "${mrow%%$'\t'*}" == round-protocol-step-2 ]] || continue
  step2_first="${${mrow#*$'\t'}#*$'\t'}"; step2_first="${step2_first%%$'\t'*}"
done
if [[ -z "$step2_first" ]]; then
  print -u2 -- "FAIL: the manifest no longer declares round-protocol-step-2, so its first anchor cannot be checked"
  (( sweep_failures++ ))
else
  awk_rc=0
  between=$(awk -v h="$STEP1_LAST" -v t="$step2_first" '
    !seen && $0 == h { seen = 1; next }
    seen && $0 == t  { done = 1; exit }
    seen && $0 ~ /[^[:space:]]/ { print }
    END { if (!seen || !done) exit 3 }
  ' <<< "$pre") || awk_rc=$?
  if (( awk_rc )); then
    print -u2 -- "FAIL: round step 1's last line and round-protocol-step-2's first anchor are not both present, in order, in ${base}:${SKILL_REL} — step-2-first <<${step2_first}>>"
    (( sweep_failures++ ))
  elif [[ -n "$between" ]]; then
    print -u2 -- "FAIL: round-protocol-step-2's first anchor is no longer adjacent to round step 1 in ${base}:${SKILL_REL} — original prose now sits between them, outside every verified chunk:"
    print -u2 -- "$between"
    (( sweep_failures++ ))
  fi
fi

# --- each re-cut span covers its source with no gap and no overlap -----------
# A frozen span re-cut into chunks across several shards: the former
# `round-protocol-tail`, cut into four, one per step shard (#2055), of which
# #3168 retired the first (round step 1), leaving three; the retired tail ->
# step-2 seam is replaced by the step-2 adjacency check above. #3169 cut the
# last of them around a paragraph, so the group ends at
# `round-protocol-step-3-head`, and its seam to `round-protocol-steps-3-4` is
# the gapped seam checked after this loop. The former
# `suggestion-promotion`, cut into five (#2057), left the manifest when #3121
# deleted its shards. The former `interactive-extension`, cut into two across
# reference/interactive/ (#2058), was a group too until #3121 took step 5 out of
# the frozen text, leaving no adjacent pair to check (see the manifest comment).
# Each chunk is byte-checked on its own above, which proves nothing about the
# SEAMS: move one chunk's last anchor up and its neighbour's first anchor stays
# put, and the lines between them leave the verified region with every
# comparison green. So, for each consecutive pair within a group, the earlier
# chunk's LAST anchor and the later chunk's FIRST anchor must be adjacent modulo
# blank lines in the pinned commit — the exact statement the #1582 head/tail
# block made until #3168 retired the tail — and the later first anchor must come
# AFTER the earlier last one, which is what rules out overlap. Anchors are read
# out of the MANIFEST, never restated as literals: `$pre` is a pinned, immutable
# commit, so an assertion built from literals is a CONSTANT that could never
# fire on the one edit — a manifest anchor moved — it exists to catch.
#
# CUT_GROUPS is the extendable list: one space-separated group per re-cut span,
# its chunks in source order. A later split that re-cuts a span appends its
# group here.
typeset -a CUT_GROUPS=(
  "round-protocol-step-2 round-protocol-recover round-protocol-step-3-head"
)
typeset -a CUT_NAMES=(${=CUT_GROUPS})
typeset -A cut_first cut_last
typeset cname crow
for crow in "${MANIFEST[@]}"; do
  crow="${crow%$'\n'}"
  typeset crow_tabs="${crow//[^$'\t']/}"
  (( ${#crow_tabs} >= 3 )) || continue
  cname="${crow%%$'\t'*}"
  (( ${CUT_NAMES[(Ie)$cname]} )) || continue
  cut_first[$cname]="${${crow#*$'\t'}#*$'\t'}"; cut_first[$cname]="${cut_first[$cname]%%$'\t'*}"
  cut_last[$cname]="${${${crow#*$'\t'}#*$'\t'}#*$'\t'}"
done
# Declared ONCE, outside the loop: a bare `typeset seam` on a parameter that
# already exists PRINTS it, which would leak `seam=''` onto stdout every pass.
typeset -i ci seam_rc
typeset prev_c next_c seam cgroup
typeset -a group_cuts
for cgroup in "${CUT_GROUPS[@]}"; do
  group_cuts=(${=cgroup})
  for (( ci = 1; ci < ${#group_cuts}; ci++ )); do
    prev_c="${group_cuts[$ci]}" next_c="${group_cuts[$(( ci + 1 ))]}"
    if [[ -z "${cut_last[$prev_c]-}" || -z "${cut_first[$next_c]-}" ]]; then
      print -u2 -- "FAIL: the manifest no longer declares both $prev_c and $next_c, so their seam cannot be checked"
      (( sweep_failures++ ))
      continue
    fi
    seam_rc=0
    seam=$(awk -v h="${cut_last[$prev_c]}" -v t="${cut_first[$next_c]}" '
      !seen && $0 == h { seen = 1; next }
      seen && $0 == t  { done = 1; exit }
      seen && $0 ~ /[^[:space:]]/ { print }
      END { if (!seen || !done) exit 3 }
    ' <<< "$pre") || seam_rc=$?
    if (( seam_rc )); then
      print -u2 -- "FAIL: the seam $prev_c → $next_c is not in order in ${base}:${SKILL_REL} — last <<${cut_last[$prev_c]}>>, first <<${cut_first[$next_c]}>>"
      (( sweep_failures++ ))
    elif [[ -n "$seam" ]]; then
      print -u2 -- "FAIL: the seam $prev_c → $next_c leaves original lines uncovered in ${base}:${SKILL_REL}:"
      print -u2 -- "$seam"
      (( sweep_failures++ ))
    fi
  done
done

# --- a gapped seam holds exactly the paragraph it was opened for (#3169) -----
# Each gapped seam is a pair of chunks that are NOT adjacent: original text sits
# between them, verified by nothing. #3169 opened the first, around step 3's
# narration paragraph (`round-protocol-step-3-head` → `round-protocol-steps-3-4`);
# #3044 opened two more inside the old round-protocol head, around round step 4
# and around the *How to wait* paragraph. The hazard is the seam check's own:
# move the earlier chunk's LAST anchor up, or the later chunk's FIRST anchor
# down, and more original lines join the unverified gap with every comparison
# green. So the non-blank lines between the two anchors in the pinned commit
# must begin with the gap's FIRST line and end with its LAST line, the bounds of
# the text the gap was opened for. The pinned commit is immutable, so a gap
# moves only when a manifest anchor does, and the anchors are read out of the
# manifest, so the assertion moves with the edit it exists to catch. The gap
# bounds are constants here, which no manifest edit can move.
#
# GAPPED_SEAMS: one row per gap, PREV<TAB>NEXT<TAB>GAP_FIRST<TAB>GAP_LAST.
typeset -a GAPPED_SEAMS=(
  "round-protocol-boundary	round-protocol-boundary-steps-5-7	4. **Observe the gate's completion before consolidating** — wait for step 2's	   has not returned."
  "round-protocol-boundary-steps-5-7	round-protocol-head	**How to wait — end the turn (#1513).** Once the boundary has dispatched — the	boundary's own signal-never-arrived arm instead of blocking again."
  "round-protocol-step-3-head	round-protocol-steps-3-4	   Otherwise blockers remain and budget is left:	   fresh problems or re-read the last fix pass's own edits)."
)
typeset gap_row gap_prev gap_next gap_first gap_last gap_prev_last gap_next_first gap_text
for gap_row in "${GAPPED_SEAMS[@]}"; do
  gap_prev="${gap_row%%$'\t'*}";  gap_row="${gap_row#*$'\t'}"
  gap_next="${gap_row%%$'\t'*}";  gap_row="${gap_row#*$'\t'}"
  gap_first="${gap_row%%$'\t'*}"; gap_last="${gap_row#*$'\t'}"
  gap_prev_last="" gap_next_first=""
  for mrow in "${MANIFEST[@]}"; do
    mrow="${mrow%$'\n'}"
    typeset mrow_tabs="${mrow//[^$'\t']/}"
    (( ${#mrow_tabs} >= 3 )) || continue
    case "${mrow%%$'\t'*}" in
      "$gap_prev") gap_prev_last="${${${mrow#*$'\t'}#*$'\t'}#*$'\t'}" ;;
      "$gap_next") gap_next_first="${${mrow#*$'\t'}#*$'\t'}"; gap_next_first="${gap_next_first%%$'\t'*}" ;;
    esac
  done
  if [[ -z "$gap_prev_last" || -z "$gap_next_first" ]]; then
    print -u2 -- "FAIL: the manifest no longer declares both $gap_prev and $gap_next, so their gapped seam cannot be checked"
    (( sweep_failures++ ))
    continue
  fi
  awk_rc=0
  gap_text=$(awk -v h="$gap_prev_last" -v t="$gap_next_first" '
    !seen && $0 == h { seen = 1; next }
    seen && $0 == t  { done = 1; exit }
    seen && $0 ~ /[^[:space:]]/ { print }
    END { if (!seen || !done) exit 3 }
  ' <<< "$pre") || awk_rc=$?
  if (( awk_rc )); then
    print -u2 -- "FAIL: the gapped seam $gap_prev → $gap_next is not in order in ${base}:${SKILL_REL} — last <<${gap_prev_last}>>, first <<${gap_next_first}>>"
    (( sweep_failures++ ))
  elif [[ "${gap_text%%$'\n'*}" != "$gap_first" || "${gap_text##*$'\n'}" != "$gap_last" ]]; then
    print -u2 -- "FAIL: the gapped seam $gap_prev → $gap_next no longer holds exactly its paragraph in ${base}:${SKILL_REL} — original lines between the two chunks:"
    print -u2 -- "$gap_text"
    (( sweep_failures++ ))
  fi
done

# An EMPTIED MANIFEST (a bad merge, a botched edit to the multi-line array
# literal) would otherwise leave every counter at 0 and print "all 0 declared
# chunks are byte-identical" at exit 0 — a gate reporting success having verified
# nothing, which the bats caller's `status -eq 0` would accept.
#
# Be precise about when that is actually reachable, because an earlier wording
# here was wrong: against the REAL reference tree the stray-sentinel sweep above
# already fails first, finding every sentinel in reference/, none of which a manifest row declares. This
# guard is the second net for the state where BOTH were lost together — an
# emptied manifest AND a reference tree carrying no sentinels — which is the only
# one that reaches the summary line. It also fires only at exactly zero rows: a
# PARTIALLY truncated manifest never reaches it, and is caught by the sweep.
if (( ${#MANIFEST} == 0 )); then
  print -u2 -- "verify-reference-move: the manifest is empty — there is nothing to verify"
  exit 1
fi

# The real per-chunk invariant: every declared row either compared byte-identical
# or was counted as a failure. `verified` is incremented ONLY on the identical
# branch, so a row that fell out of the loop by some path nobody anticipated is
# caught here rather than held by inspection.
if (( verified + chunk_failures != ${#MANIFEST} )); then
  print -u2 -- "verify-reference-move: ${#MANIFEST} chunk(s) declared but $verified verified + $chunk_failures failed — a row was neither"
  exit 1
fi

# Reported separately, because they are different defects and the counts do not
# share a denominator: a sentinel problem is not "a declared chunk did not move".
if (( chunk_failures )); then
  print -u2 -- ""
  print -u2 -- "$chunk_failures of ${#MANIFEST} declared chunk(s) did not move verbatim."
fi
if (( sweep_failures )); then
  # NOT "(undeclared or duplicated)" any more (#1588): `sweep_failures` is
  # incremented by several arms, of which only the duplicate and stray ones are
  # that. The
  # adjacency arm — driven today — is caused by a MANIFEST edit inside this
  # script, and the old parenthetical sent the operator hunting for a stray
  # sentinel in reference/ that does not exist. The per-arm FAIL line above
  # always names the real cause, so the summary points at it instead of
  # guessing.
  print -u2 -- "$sweep_failures sentinel/split-span problem(s) — see the FAIL line(s) above."
fi
if (( chunk_failures || sweep_failures )); then
  exit 1
fi

(( quiet )) || print -r -- ""
(( quiet )) || print -r -- "all $verified declared chunks are byte-identical to ${base}:${SKILL_REL}"
exit 0
