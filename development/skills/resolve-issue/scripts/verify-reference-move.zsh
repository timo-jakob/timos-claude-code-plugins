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
# two chunks of a SPLIT span — the #1582 gap inside `round-protocol` — which is
# verified by nothing; see the manifest comment below.
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
#   1  at least one chunk differs, an input could not be read, OR a sentinel
#      sweep failed: an undeclared/duplicated sentinel, or the #1582 split-span
#      checks (a split sentinel not appearing exactly once, the halves out of
#      order, or the split anchors no longer adjacent in the pre-move file).
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
# was re-cut to open a gap for it. The gap holds ONLY new prose: the head ends at
# `Each round:` and the tail resumes at step 1's own first line, so 224 + 788 of
# the original 1 013 lines stay verified and the only original line in the gap is
# the blank separator between them (which `strip_blanks` would discard anyway).
#
# The cost is still real and is recorded rather than hidden: text sitting in that
# gap is verified by NOTHING, so an edit to the new rule passes this gate in
# silence. It is bounded to the rule itself.
#
# The cut is where it is because of MARKDOWN, not preference. `extract_chunk`
# matches a sentinel as a whole line at column 0, and a column-0 HTML comment
# INSIDE a numbered list item destroys the list continuation — putting the tail's
# opener mid-step produced 16 markdownlint findings on a file that lints clean.
# The only column-0 positions that are structurally safe are outside the list, so
# the gap sits between `Each round:` and the list's first item.
#
# One anchor that looks obvious is UNUSABLE, recorded so nobody re-derives it:
# `   **How to wait** (this section) governs the wait — it is not restated here.`
# occurs TWICE in the pinned pre-move SKILL.md, and `extract_range` starts at the
# FIRST match of a first-anchor — so using it as the tail's opener would extract
# from the wrong place and never match.
typeset -a MANIFEST
MANIFEST=(
"interactive-remediation	interactive.md	Applies **only** with a human present, and only to a **shape (i)**	  what the gate exists to prevent.
"
"round-protocol-head	review-loop.md	**The round boundary is concurrent — one minted tree, two readers (#1497).**	Each round:
"
"round-protocol-tail	review-loop.md	1. **Review panel, in-session.** Get the dispatch plan (\`review-dispatch.zsh	   is how the two statements of it came to disagree once already.
"
"residue-branch	residue.md	Runs **only** on \`CONVERGED_WITH_RESIDUE\` (exit 14). The loop has already	  them, and do not read the story's own work as unstartable.
"
"suggestion-promotion	promotion.md	Low suggestions never block, so every one the panel raises is **waived** the	   exactly the history it exists to attest.
"
"escalation-head	escalation.md	A bad escalation costs a human an afternoon; a good one costs two minutes. On	tell the human the opposite of what happened.
"
"interactive-extension	interactive.md	**Interactive extension (human present, \`BUDGET_EXHAUSTED\` /	   later with \`/development:resolve-issue <N>\`.
"
"escalation-terminal	escalation.md	If the interactive extension ended in \`CONVERGED\`, skip the terminal below,	   the next run can converge. No PR exists until it does.
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

# Extract the body between the sentinels of one chunk in a reference file.
extract_chunk() {
  local file="$1" name="$2"
  awk -v n="$name" '
    $0 == "<!-- moved: " n " -->"  { inside = 1; next }
    $0 == "<!-- /moved: " n " -->" { inside = 0; found = 1; exit }
    inside                         { print }
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

  src=$(print -r -- "$src_raw" | strip_blanks)
  dst=$(print -r -- "$dst" | strip_blanks)

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
sentinels=("${(@f)$(grep -rhoE '^<!-- moved: .+ -->$' "$REF_DIR" | sed -E 's/^<!-- moved: (.*) -->$/\1/' | sort)}")
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

# --- the SPLIT-span invariant the manifest cannot express (#1582) ------------
# head and tail are located independently, so per-chunk byte-identity proves
# nothing about their RELATIONSHIP: swap the two blocks and every check above
# still passes.
#
# What is asserted, and why it is EXACT rather than a size cap. The split cost
# exactly ONE original line — the blank separator between `Each round:` and step
# 1 — so head keeps 224 pre-move lines and tail 788, and 1 012 of 1 013 stay
# byte-verified however much NEW prose the gap holds. The hazard is therefore
# never the gap being large; it is ORIGINAL conductor prose migrating into it,
# which happens by moving a chunk anchor inward and would shrink the verified
# region while every byte-identity check above stayed green.
#
# A gap-SIZE cap only approximates that, and badly: it cannot fire until more
# original lines migrate than the headroom the new prose happens to be leaving,
# and any number it names can be raised in the same edit that violates it. The
# exact statement is available instead — in the PRE-MOVE file, the head's LAST
# anchor and the tail's FIRST anchor must be ADJACENT modulo blank lines, since
# nothing sits between them there. Assert that, and no original line can enter
# the gap undetected regardless of how the new prose grows.
typeset rp_file="$REF_DIR/review-loop.md"
typeset -a hc_hits to_hits
# Captured as ARRAYS and required to be exactly one: `grep -n … | cut` emits one
# line per match, so a DUPLICATED sentinel would assign a multi-line string to an
# integer-attributed parameter — a bad-math abort, or a silently wrong line
# number compared against the wrong pair. The stray sweep above cannot catch it
# either: it greps only the OPENING form, so a duplicated `/moved:` closer is
# seen by nothing else in this script.
# stderr is NOT discarded, the same rule the sentinel sweep above states: an
# unreadable `review-loop.md` (mode 000, an ACL, a bad checkout) would otherwise
# be reported as "head-close: 0, tail-open: 0" — a verdict about the file's
# CONTENT derived from a read that never happened. `-f` is true for an
# unreadable regular file, so the guard above does not cover it.
hc_hits=("${(@f)$(grep -nxF -- '<!-- /moved: round-protocol-head -->' "$rp_file")}")
to_hits=("${(@f)$(grep -nxF -- '<!-- moved: round-protocol-tail -->'  "$rp_file")}")
hc_hits=(${hc_hits:#}); to_hits=(${to_hits:#})
if (( ${#hc_hits} != 1 || ${#to_hits} != 1 )); then
  print -u2 -- "FAIL: the round-protocol split sentinels must appear exactly once each in review-loop.md (head-close: ${#hc_hits}, tail-open: ${#to_hits})"
  (( sweep_failures++ ))
else
  typeset -i hc="${hc_hits[1]%%:*}" to="${to_hits[1]%%:*}"
  if (( to <= hc )); then
    print -u2 -- "FAIL: round-protocol-tail opens at line $to, at or before head closes at $hc — the split halves are out of order"
    (( sweep_failures++ ))
  else
    # The EXACT invariant: in the pre-move conductor, nothing but blank lines
    # separated the head's LAST anchor from the tail's FIRST anchor, so nothing
    # original belongs in the gap now.
    #
    # Both anchors are READ OUT OF THE MANIFEST, never restated here. That is the
    # whole point: `$pre` is a pinned, immutable commit, so an assertion built
    # from literals is a CONSTANT — it would return the same verdict forever and
    # could not fire on the one edit it exists to catch. The hazard is a manifest
    # anchor moved inward (which migrates original lines into the gap while every
    # per-chunk byte comparison still passes), and the manifest is the only thing
    # such an edit touches.
    typeset head_last="" tail_first="" mrow
    for mrow in "${MANIFEST[@]}"; do
      mrow="${mrow%$'\n'}"
      case "${mrow%%$'\t'*}" in
        round-protocol-head) head_last="${mrow##*$'\t'}" ;;
        round-protocol-tail) tail_first="${${mrow#*$'\t'}#*$'\t'}"; tail_first="${tail_first%%$'\t'*}" ;;
      esac
    done
    if [[ -z "$head_last" || -z "$tail_first" ]]; then
      print -u2 -- "FAIL: the manifest no longer declares both round-protocol split rows, so their adjacency cannot be checked"
      (( sweep_failures++ ))
    else
      # A here-string, not `print … | awk`: awk `exit`s at the tail anchor and
      # would SIGPIPE the producer, which `pipefail` promotes to 141 — the very
      # pattern this file documents for `extract_range` and that #1582 swept out
      # of `_primary`. It matters here because the status IS read.
      typeset between
      typeset -i awk_rc=0
      between=$(awk -v h="$head_last" -v t="$tail_first" '
        $0 == h        { seen = 1; next }
        seen && $0 == t { done = 1; exit }
        seen && $0 ~ /[^[:space:]]/ { print }
        END { if (!seen || !done) exit 3 }
      ' <<< "$pre") || awk_rc=$?
      if (( awk_rc )); then
        print -u2 -- "FAIL: the split anchors named by the manifest are not both present in ${base}:${SKILL_REL} — head-last <<${head_last}>>, tail-first <<${tail_first}>>"
        (( sweep_failures++ ))
      elif [[ -n "$between" ]]; then
        print -u2 -- "FAIL: the round-protocol split anchors are no longer adjacent in ${base}:${SKILL_REL} — original prose now sits between them, so the gap in review-loop.md is not new text alone:"
        print -u2 -- "$between"
        (( sweep_failures++ ))
      fi
    fi
  fi
fi

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
  print -u2 -- "$sweep_failures sentinel problem(s) in reference/ (undeclared or duplicated)."
fi
if (( chunk_failures || sweep_failures )); then
  exit 1
fi

(( quiet )) || print -r -- ""
(( quiet )) || print -r -- "all $verified declared chunks are byte-identical to ${base}:${SKILL_REL}"
exit 0
