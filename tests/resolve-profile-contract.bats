#!/usr/bin/env bats
#
# The resolve-profile contract (#1504).
#
# `/development:resolve-issue` is one conductor read by every repo type, so a
# rule true of ONE type is a tax on all the others — and a magnet for collisions,
# since every plugin-side edit and every loop-side edit land in the same file.
# #1504 introduces the seam: a `resolve-profile` skill in
# `development-<repo_type>`, loaded by name at the conductor's §1b step, holding
# exactly the rules that are true of that type.
#
# A seam whose shape is not pinned is a seam that drifts, so this file gates
# three things:
#
#   - the CONTRACT — six `##` headings, in one declared order, each with a body
#     (a heading with nothing to say says **none**; it is never dropped), plus
#     the `name:` and the "not for direct use" description prefix — swept over
#     every profile the repo ships, from a DERIVED roster (`git ls-files`), never
#     a hand-written list that rots the moment a second profile lands (#936);
#   - the MOVE — one positive needle per moved rule against the profile and one
#     matching NEGATIVE needle against the conductor, so "moved" is provably
#     distinguished from "copied". The conductor is the #1503 CORPUS — `SKILL.md`
#     **plus** `reference/*.md` — because a rule pasted back into a reference
#     file is back in the shared conductor just as surely as one left in
#     `SKILL.md`. The byte-frozen `<!-- moved: … -->` spans are excluded, since
#     #1504 deliberately did not touch them and one moved needle has a live
#     in-span duplicate; that exemption is asserted below rather than implied;
#   - the LOAD POINT — that §1b exists, sits between §1 and §2, states all four
#     of `detect`'s exit arms, and states the missing-profile fallback and the
#     `unsupported_repo_type` non-reuse.
#
# Every assertion is anchored by CONTENT, never by line number (#1189).

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_DIR="$REPO_ROOT/development/skills/resolve-issue"
  CONDUCTOR="$SKILL_DIR/SKILL.md"
  REF_DIR="$SKILL_DIR/reference"
  DISPATCH="$SKILL_DIR/scripts/review-dispatch.zsh"
  PROFILE="$REPO_ROOT/development-claude-plugin/skills/resolve-profile/SKILL.md"
  ARCH="$REPO_ROOT/ARCHITECTURE.md"

  # THE contract, written once here and compared against both sides.
  HEADINGS=("Gate" "Version bump" "Panel" "Fix-pass rules" \
            "Documentation expectations" "Residue")
  PREFIX="Loaded by /development:resolve-issue — not for direct use"
  POINTER='profile: `development-<repo_type>:resolve-profile` § '
}

# --- helpers ----------------------------------------------------------------

# The profile roster, DERIVED from the index. `git ls-files` and not a glob, so
# a profile that exists on disk but was never `git add`ed fails here rather than
# passing locally and reding in CI (#1189/PR#1263).
_profiles() {
  git -C "$REPO_ROOT" ls-files 'development-*/skills/resolve-profile/SKILL.md'
}

# Every `## ` heading of $1, in file order, one per line.
_profile_headings() {
  grep '^## ' "$1" | sed 's/^## //'
}

# Print nothing when $1 carries EXACTLY the six contract headings in the
# declared order; otherwise print what it actually carries. The real assertion
# and its non-vacuity control both go through this, so the control proves this
# detector rather than a paraphrase of it.
_order_violation() {
  local got want
  got="$(_profile_headings "$1")"
  want="$(printf '%s\n' "${HEADINGS[@]}")"
  [ "$got" = "$want" ] || printf '%s\n' "$got"
}

# Print any `## ` heading of $1 with no non-blank line before the next one. The
# other half of "it is never dropped": the order check above cannot see a
# heading that is present but empty, and an empty heading in the REFERENCE
# implementation is what #1505's copy-this-one authors would inherit.
_empty_headings() {
  awk '
    /^## / { if (h != "" && n == 0) print h; h = substr($0, 4); n = 0; next }
    h != "" && NF { n++ }
    END { if (h != "" && n == 0) print h }
  ' "$1"
}

# The first content line of $1's frontmatter `description:`, whether it is
# written inline or as a folded (`>`) block. Both spellings are used across this
# repo's skills, and a check that understood only one would silently pass the
# other by finding nothing to test.
_description_of() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { exit }
    fm && folded { sub(/^[[:space:]]+/, ""); print; exit }
    fm && /^description:/ {
      sub(/^description:[[:space:]]*/, "")
      if ($0 == ">" || $0 == "|" || $0 == ">-" || $0 == "|-") { folded = 1; next }
      print; exit
    }
  ' "$1"
}

# The frontmatter `name:` of $1.
_name_of() {
  awk '
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { exit }
    fm && /^name:[[:space:]]/ { sub(/^name:[[:space:]]*/, ""); print; exit }
  ' "$1"
}

# The conductor as a session actually reads it — `SKILL.md` plus every
# `reference/*.md` — MINUS the byte-frozen `<!-- moved: … -->` spans, which
# #1504 deliberately did not touch and #1506 will. Writes to $1.
#
# Stripping the spans is what makes the negative sweep BOTH honest and
# achievable: one moved needle (`run-gate.zsh --tests-dir tests`) has a live
# duplicate inside `review-loop.md`'s frozen span, so an unstripped corpus would
# red on day one for text this story is contractually forbidden to edit — while
# a sweep scoped to `SKILL.md` alone would miss a rule pasted into a reference
# file OUTSIDE a span, which is the regression that matters.
_conductor_outside_frozen() {
  local out="$1" f
  : > "$out"
  cat "$CONDUCTOR" >> "$out"
  printf '\n' >> "$out"
  for f in "$REF_DIR"/*.md; do
    [ -e "$f" ] || continue
    awk '
      /^<!-- moved: /    { skip = 1; next }
      /^<!-- \/moved: /  { skip = 0; next }
      !skip              { print }
    ' "$f" >> "$out"
    printf '\n' >> "$out"
  done
}

# The body of ARCHITECTURE.md's profile-contract section, flattened to one line.
_arch_contract_flat() {
  awk '
    /^## Resolve profile contract/ { inside = 1; next }
    inside && /^## /               { exit }
    inside                         { print }
  ' "$1" | tr '\n' ' '
}

# Print nothing when the six headings appear, emphasised and in order, in the
# flattened contract section $1; otherwise print what went wrong. Shared by the
# real assertion and its control.
_arch_order_violation() {
  local flat="$1" h pos prev=0
  for h in "${HEADINGS[@]}"; do
    pos="$(awk -v s="$flat" -v n="**$h**" 'BEGIN { print index(s, n) }')"
    if [ "$pos" -eq 0 ]; then
      printf 'not named in the contract section: %s\n' "$h"
      return 0
    fi
    if [ "$pos" -le "$prev" ]; then
      printf 'out of order in the contract section: %s\n' "$h"
      return 0
    fi
    prev="$pos"
  done
}

# --- the roster is real -----------------------------------------------------

@test "#1504 the profile sweep finds the exact number of profiles recorded" {
  # A COUNT, not a floor — the sibling budget test's own lesson ("`-ge 5` moved
  # WITH a deletion rather than against it"). Every check below iterates this
  # roster, so an empty one would make all of them pass having examined nothing;
  # and a profile ADDED without updating MAINTAINING.md's registry reds here, in
  # the same PR, which is what a derived sweep alone can never see.
  local n
  n="$(_profiles | grep -c .)"
  [ "$n" -eq 1 ] || {
    printf 'the repo ships %s profile(s), expected 1.\n' "$n" >&2
    printf 'Adding one? THREE figures move together, in the same PR: this count,\n' >&2
    printf "the Resolve profile contract row in MAINTAINING.md's Invariants in force,\n" >&2
    printf "and ARCHITECTURE.md's 'Profiles populated today: **N**' sentence.\n" >&2
    _profiles >&2
    return 1
  }
}

@test "#1504 the claude-plugin profile is in the swept roster" {
  # ...and it is the one this story ships, named explicitly so a sweep that
  # somehow found a different file cannot stand in for it.
  _profiles | grep -qxF 'development-claude-plugin/skills/resolve-profile/SKILL.md'
}

@test "#1504 every swept profile names a repo type review-dispatch.zsh can emit" {
  # The roster glob is `development-*`, but §1b loads
  # `development-<repo_type>:resolve-profile` where repo_type is one of six. A
  # profile at `development-spring/` or `development-react/` would satisfy every
  # contract check here and could never be loaded. The valid set is DERIVED from
  # the script's own header line, so the two cannot drift.
  local types p seg bad=""
  types="$(sed -n 's/^#  *repo_type ∈ {\(.*\)};.*/\1/p' "$DISPATCH" | tr -d ' ')"
  [ -n "$types" ] || { echo "could not read the repo_type set out of $DISPATCH" >&2; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    seg="${p%%/*}"
    seg="${seg#development-}"
    printf '%s\n' "$types" | tr ',' '\n' | grep -qxF -- "$seg" \
      || bad+="$p (repo type '$seg')"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'profile(s) naming a repo type review-dispatch.zsh never emits (%s):\n%s\n' \
      "$types" "$bad" >&2
    return 1
  }
}

# --- the contract -----------------------------------------------------------

@test "#1504 every profile carries the six contract headings in order" {
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local got
    got="$(_order_violation "$REPO_ROOT/$p")"
    [ -z "$got" ] || bad+="$p carries:"$'\n'"$got"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'profile heading contract violated. Expected, in order:\n%s\n\n%s\n' \
      "$(printf '%s\n' "${HEADINGS[@]}")" "$bad" >&2
    return 1
  }
}

@test "#1504 non-vacuity: an out-of-order heading reds the order check" {
  # Proves the detector does work — without it the check could be passing
  # because `_profile_headings` returns nothing, or because the comparison never
  # discriminates.
  local planted="$BATS_TEST_TMPDIR/out-of-order.md"
  # Swap the last two headings in a throwaway copy. A SWAP, not an insertion:
  # it keeps the heading SET identical, so only an order-sensitive check reds —
  # which is exactly the property being claimed.
  sed -e "s/^## ${HEADINGS[4]}\$/## __TMP__/" \
      -e "s/^## ${HEADINGS[5]}\$/## ${HEADINGS[4]}/" \
      -e "s/^## __TMP__\$/## ${HEADINGS[5]}/" \
      "$PROFILE" > "$planted"
  # the swap really happened (guard against a sed that matched nothing)
  [ "$(_profile_headings "$planted" | tail -2 | head -1)" = "${HEADINGS[5]}" ]
  local got
  got="$(_order_violation "$planted")"
  [ -n "$got" ]
  # ...and the real profile still passes the same detector
  [ -z "$(_order_violation "$PROFILE")" ]
}

@test "#1504 no profile heading is present-but-empty — one that has nothing says none" {
  # The half the order check cannot see. The contract's readers key on the
  # ROSTER, not on presence, so a heading kept as a bare label is a heading that
  # silently stopped carrying its rule.
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local empty
    empty="$(_empty_headings "$REPO_ROOT/$p")"
    [ -z "$empty" ] || bad+="$p: $empty"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || { printf 'heading(s) with no body:\n%s\n' "$bad" >&2; return 1; }
  # ...and the three that have nothing to say actually say so, rather than
  # carrying prose that merely looks like a rule
  local h
  for h in "Fix-pass rules" "Documentation expectations" "Residue"; do
    awk -v want="$h" '
      /^## / { cur = substr($0, 4); next }
      cur == want && NF { print; exit }
    ' "$PROFILE" | grep -q '^\*\*none\*\*' || {
      printf 'the claude-plugin profile heading %s no longer opens with **none**\n' "$h" >&2
      return 1
    }
  done
}

@test "#1504 non-vacuity: a heading emptied of its body reds the none check" {
  local planted="$BATS_TEST_TMPDIR/emptied.md"
  # Drop everything under `## Fix-pass rules` up to the next heading, leaving the
  # heading itself — the exact mutation the order check waves through.
  awk '
    /^## Fix-pass rules$/ { print; drop = 1; next }
    /^## / { drop = 0 }
    !drop { print }
  ' "$PROFILE" > "$planted"
  # the mutation really happened
  [ "$(_profile_headings "$planted" | grep -c .)" -eq 6 ]
  local empty
  empty="$(_empty_headings "$planted")"
  printf '%s\n' "$empty" | grep -qxF 'Fix-pass rules'
  # ...and the real profile still passes the same detector
  [ -z "$(_empty_headings "$PROFILE")" ]
}

@test "#1504 every profile's frontmatter name matches its skill directory" {
  # §1b invokes the profile BY NAME, so a `name:` typo makes the load silently
  # take the missing-profile fallback. Caught elsewhere only indirectly, by the
  # generated command reference drifting on a different CI leg.
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$(_name_of "$REPO_ROOT/$p")" = "resolve-profile" ] \
      || bad+="$p: $(_name_of "$REPO_ROOT/$p")"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'profile(s) whose name: is not resolve-profile:\n%s\n' "$bad" >&2
    return 1
  }
}

@test "#1504 every profile's Panel records ITS OWN plugin's review skill" {
  # ARCHITECTURE.md: a profile's Panel heading RECORDS the review_skill
  # review-dispatch.zsh plan computes and never overrides it. Nothing read the
  # body, so a profile could name another type's panel — and #1505 would copy
  # the un-gated shape into five more.
  local p plug sec bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    plug="${p%%/*}"
    sec="$(awk '
      /^## Panel$/ { inside = 1; next }
      inside && /^## / { exit }
      inside { print }
    ' "$REPO_ROOT/$p")"
    printf '%s' "$sec" | grep -qF -- "$plug:review" \
      || bad+="$p: its Panel does not name $plug:review"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || { printf 'Panel drift:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1504 every profile stays model-invocable, so the by-name load resolves" {
  # The sibling of the name: check, with the identical failure mode: flipping
  # this key makes §1b's Skill-tool load stop resolving, and every run of that
  # repo type silently degrades to the conductor's generic rules behind a
  # one-line notice. The generated command reference reproduces only
  # name/description, so no other gate sees it.
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    awk '
      NR == 1 && $0 == "---" { fm = 1; next }
      fm && $0 == "---" { exit }
      fm && /^disable-model-invocation:[[:space:]]*false[[:space:]]*$/ { found = 1 }
      END { exit(found ? 0 : 1) }
    ' "$REPO_ROOT/$p" || bad+="$p"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'profile(s) without `disable-model-invocation: false`:\n%s\n' "$bad" >&2
    printf 'A profile is loaded BY NAME at §1b; disabling that silently takes the\n' >&2
    printf 'missing-profile fallback on every run of that repo type.\n' >&2
    return 1
  }
}

@test "#1504 every profile's description begins with the not-for-direct-use prefix" {
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    local d
    d="$(_description_of "$REPO_ROOT/$p")"
    case "$d" in
      "$PREFIX"*) : ;;
      *) bad+="$p: ${d:-<no description found>}"$'\n' ;;
    esac
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'description(s) not beginning with %s:\n%s\n' "$PREFIX" "$bad" >&2
    return 1
  }
}

@test "#1504 ARCHITECTURE.md's contract SECTION names the six headings, in order" {
  # Both sides of one contract, pinned against the same list (#1011/#1067's
  # pairing idiom). Scoped to the section, NOT to the whole file: `Gate` and
  # `Residue` each occur elsewhere in ARCHITECTURE.md, so a whole-file substring
  # check would stay green with the heading deleted from the contract itself.
  local flat bad
  flat="$(_arch_contract_flat "$ARCH")"
  [ -n "$flat" ] || { echo "no Resolve profile contract section in $ARCH" >&2; return 1; }
  bad="$(_arch_order_violation "$flat")"
  [ -z "$bad" ] || { printf '%s\n' "$bad" >&2; return 1; }
  # ...and the profile carries the same six as `##` headings
  local h
  for h in "${HEADINGS[@]}"; do
    _profile_headings "$PROFILE" | grep -qxF -- "$h" || {
      printf 'the profile no longer carries the heading: %s\n' "$h" >&2
      return 1
    }
  done
}

@test "#1504 non-vacuity: a heading dropped from the contract section reds the pairing" {
  # The mutation a whole-file `grep -qF Gate` waves through, because `Gate`
  # also appears in ARCHITECTURE.md's quality-gate and gate-attestation prose.
  local planted="$BATS_TEST_TMPDIR/arch-no-gate.md" flat bad
  sed 's/\*\*Gate\*\*, //' "$ARCH" > "$planted"
  flat="$(_arch_contract_flat "$planted")"
  bad="$(_arch_order_violation "$flat")"
  [ -n "$bad" ] || { echo "dropping **Gate** from the contract section did not red" >&2; return 1; }
  # ...and the word is still in the file, which is why a whole-file check fails
  grep -qF 'Gate' "$planted"
}

# --- the move: present in the profile, ABSENT from the conductor CORPUS ------
#
# The five needles are the five moved items. Each is asserted twice — once
# positively against the profile, once negatively against the conductor corpus
# outside its frozen spans — so a COPY (which would leave both green on a
# presence-only check) reds.

_moved_needles() {
  printf '%s\n' \
    'run-gate.zsh --tests-dir tests' \
    'Capture the gate attestation (#981).' \
    'DEGRADED gate to the user, up front (#980).' \
    'otherwise installs never see the' \
    'driving the affected skills/agents'
}

@test "#1504 the moved-needle list is the full set, not a survivor of a red round" {
  # The roster tripwire's twin, for the hand-written half. Both move tests
  # iterate this list and report clean on an empty one, so a session resolving a
  # red "still in the conductor" failure could delete the offending needle and
  # both go green with no other signal.
  [ "$(_moved_needles | grep -c .)" -eq 5 ]
}

@test "#1504 every moved rule is present in the claude-plugin profile" {
  local n missing=""
  while IFS= read -r n; do
    grep -qF -- "$n" "$PROFILE" || missing+="$n"$'\n'
  done < <(_moved_needles)
  [ -z "$missing" ] || { printf 'not moved INTO the profile:\n%s\n' "$missing" >&2; return 1; }
}

@test "#1504 every moved rule is absent from the conductor corpus outside its frozen spans" {
  # The conductor is SKILL.md PLUS reference/*.md (#1503). A rule pasted back
  # into a reference file is back in the shared conductor just as surely as one
  # left in SKILL.md, and a sweep scoped to SKILL.md alone cannot see it.
  local corpus="$BATS_TEST_TMPDIR/conductor-outside-frozen.md" n left=""
  _conductor_outside_frozen "$corpus"
  while IFS= read -r n; do
    if grep -qF -- "$n" "$corpus"; then left+="$n"$'\n'; fi
  done < <(_moved_needles)
  [ -z "$left" ] || {
    printf 'still in the conductor — copied rather than moved:\n%s\n' "$left" >&2
    return 1
  }
}

@test "#1504 the frozen-span exemption is asserted, not assumed" {
  # One moved needle has a LIVE duplicate inside review-loop.md's byte-frozen
  # `<!-- moved: round-protocol -->` span, which #1504 is contractually
  # forbidden to edit and #1506 will extract. Pin it: the sweep above is honest
  # only if the text it skips is exactly that, and this reds if the span ever
  # stops holding it (the exemption became unnecessary) or if the stripper stops
  # stripping (the sweep silently narrowed).
  local corpus="$BATS_TEST_TMPDIR/exemption-corpus.md"
  _conductor_outside_frozen "$corpus"
  # present in the raw reference file...
  grep -qF -- 'run-gate.zsh --tests-dir tests' "$REF_DIR/review-loop.md"
  # ...and gone once the frozen span is stripped, which is the stripper working
  run grep -qF -- 'run-gate.zsh --tests-dir tests' "$corpus"
  [ "$status" -ne 0 ]
}

@test "#1504 the frozen-span stripper is bounded — every span is closed" {
  # `_conductor_outside_frozen` skips from an opening sentinel to a closing one.
  # A reference file that lost (or mis-spelled) a closer would make awk skip to
  # EOF, and the negative sweep above would then examine a smaller corpus and
  # report clean over text it never read. The exemption test proves the stripper
  # strips; this bounds how much.
  local f opens closes bad=""
  for f in "$REF_DIR"/*.md; do
    [ -e "$f" ] || continue
    opens="$(grep -c '^<!-- moved: ' "$f" || true)"
    closes="$(grep -c '^<!-- /moved: ' "$f" || true)"
    [ "$opens" -eq "$closes" ] || bad+="${f##*/}: $opens open, $closes closed"$'\n'
  done
  [ -z "$bad" ] || { printf 'unbalanced sentinel span(s):\n%s\n' "$bad" >&2; return 1; }
  # ...and the stripped corpus still holds the connective prose that lives
  # OUTSIDE every span, so the stripper is not silently eating whole files.
  local corpus="$BATS_TEST_TMPDIR/bounded-corpus.md"
  _conductor_outside_frozen "$corpus"
  grep -qF -- 'The round protocol' "$corpus"
  grep -qF -- 'Residue branch' "$corpus"
}

@test "#1504 the two deliberate non-moves are still in the conductor" {
  # The move is narrow as well as complete. The §E2 passage is epic ORDERING and
  # the §6 line is an open-pr OUTCOME — neither fits any of the six headings, so
  # taking them would have been over-reach, and nothing else would have said so.
  grep -qF -- 'The version manifest is the dominant serialiser' "$CONDUCTOR"
  grep -qF -- '**Claude-plugin repo (human-only)**' "$CONDUCTOR"
}

# --- the vacated sites carry a pointer --------------------------------------

@test "#1504 each of the three vacated sites carries a profile pointer" {
  local n
  n="$(grep -oF -- "$POINTER" "$CONDUCTOR" | grep -c .)"
  [ "$n" -eq 3 ] || {
    printf 'the conductor carries %s profile pointer(s), expected 3 (§3, §4, §E4).\n' "$n" >&2
    return 1
  }
  # ...and they name headings the profile actually has, so a renamed heading
  # cannot leave a step pointing into nothing.
  local h bad=""
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    _profile_headings "$PROFILE" | grep -qxF -- "$h" || bad+="$h"$'\n'
  done < <(grep -o 'profile: `development-<repo_type>:resolve-profile` § .*$' "$CONDUCTOR" \
             | sed 's/^profile: `development-<repo_type>:resolve-profile` § //')
  [ -z "$bad" ] || { printf 'pointer(s) naming no such profile heading:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1504 the conductor keeps the §4 heading the frozen references resolve to" {
  # `promotion.md` (2 occurrences) and `interactive.md` (1) cross-reference
  # `§4 (Version bump)` from INSIDE byte-frozen sentinel spans that cannot be
  # edited. Only §4's body moved; its heading is the anchor. A COUNT, not a
  # floor — with `-ge 1` two of the three could vanish silently.
  grep -qF -- '### 4. Version bump (plugin content only)' "$CONDUCTOR"
  local r files=0 hits n
  for r in "$REF_DIR"/*.md; do
    n="$(grep -cF -- '§4 (Version bump)' "$r" || true)"
    [ "$n" -eq 0 ] || files=$(( files + 1 ))
  done
  hits="$(cat "$REF_DIR"/*.md | grep -cF -- '§4 (Version bump)' || true)"
  [ "$files" -eq 2 ] || {
    printf '%s reference file(s) cross-reference §4 (Version bump), expected 2\n' "$files" >&2
    printf '(promotion.md and interactive.md). The heading is their anchor — if the\n' >&2
    printf 'set really changed, update this count in the same PR.\n' >&2
    return 1
  }
  [ "$hits" -eq 3 ] || {
    printf '%s cross-reference(s) to §4 (Version bump), expected 3\n' "$hits" >&2
    return 1
  }
}

@test "#1504 the conductor's steps 2 through 6 are not renumbered" {
  local s
  for s in '### 2. Implement' \
           '### 3. Validate' \
           '### 4. Version bump (plugin content only)' \
           '### 5. Commit' \
           '### 6. Open the bot-authored PR'; do
    grep -qF -- "$s" "$CONDUCTOR" || { printf 'missing step heading: %s\n' "$s" >&2; return 1; }
  done
}

@test "#1504 §4 keeps a generic floor for the no-profile fallback" {
  # §1b promises the fallback continues "with the conductor's generic rules". §3
  # and E4 keep generic content; §4 must too, or a run with no profile installed
  # edits plugin content and opens a PR with no version bump at all — a change
  # installs never see.
  grep -qF -- '**With no profile loaded**, however you got here' "$CONDUCTOR"
  grep -qF -- 'This is a **floor, not a second' "$CONDUCTOR"
  # ...and the floor defers the SIZING to the profile rather than restating it,
  # which is what keeps the version-bump rule to one live statement per fact.
  grep -qF -- 'which this floor deliberately does not state' "$CONDUCTOR"
}

@test "#1504 §3's no-profile floor names a command too" {
  # The sibling floor, unpinned until round 2. Deleting it leaves a run with no
  # profile at §3 with no gate command at all, and every other check green.
  # Scoped to §3's own bullet: `pytest` also occurs in an unrelated paragraph
  # further down, so a whole-file needle could not fail while that paragraph
  # exists — the test would pass with the floor naming no command at all.
  local bullet="$BATS_TEST_TMPDIR/step-3-floor.md" flat
  # The window starts at the BULLET, not at the floor sentence: the round-4
  # remedy ("run its detect + load NOW") sits above the floor, and a window
  # opened at the floor could not see it — so deleting the remedy would leave a
  # session that skipped §1b dropping into the generic fallback on a repo whose
  # profile names a different gate entirely.
  awk '
    /^- tests for the stack/ { inside = 1 }
    inside && /^- / && !/^- tests for the stack/ { exit }
    inside { print }
  ' "$CONDUCTOR" > "$bullet"
  [ -s "$bullet" ] || { echo "§3's no-profile floor is gone" >&2; return 1; }
  flat="$(tr '\n' ' ' < "$bullet" | tr -s ' ')"
  case "$flat" in *"use the stack's usual whole-suite command"*) : ;;
    *) echo "§3's floor no longer names what to run" >&2; return 1 ;; esac
  case "$flat" in *pytest*) : ;;
    *) echo "§3's floor names no concrete command" >&2; return 1 ;; esac
  case "$flat" in *"./gradlew test"*) : ;;
    *) echo "§3's floor lost its Gradle arm" >&2; return 1 ;; esac
  # ...and it covers the exit-3 arm, not only a missing skill
  case "$flat" in *"or its exit-3"*) : ;;
    *) echo "§3's floor does not cover detect's exit-3 arm" >&2; return 1 ;; esac
  # ...and the remedy above the floor, for a session that never ran §1b
  case "$flat" in *"run its \`detect\` + load NOW"*) : ;;
    *) echo "§3 lost the never-ran-§1b remedy" >&2; return 1 ;; esac
  case "$flat" in *"a LOADED profile's command is never substituted for"*) : ;;
    *) echo "§3 lost the no-substitution guard on its remedy" >&2; return 1 ;; esac
}

@test "#1504 §4's floor covers the exit-3 arm too" {
  # The sibling instance. §1b now says the exit-3 state is explicitly NOT the
  # missing-profile fallback, so a floor keyed only to that fallback leaves an
  # exit-3 run editing plugin content with no version bump at all.
  grep -qF -- 'fallback and **its exit-3 arm** are the two ordinary ways' "$CONDUCTOR"
}

@test "#1504 E4 reads detect's non-zero arms the Epic flow's way" {
  # §1b argues both non-zero arms from §3.5 ("the same detector runs again
  # there"). The Epic flow never reaches §3.5, so importing that table wholesale
  # would have a model continue past exit 3 and close the epic on verification
  # that never ran.
  grep -qF -- "Read \`detect\`'s two non-zero arms the Epic flow's way" "$CONDUCTOR"
  grep -qF -- '**halt E4 without closing the epic**' "$CONDUCTOR"
  grep -qF -- "report it as the epic's own" "$CONDUCTOR"
  grep -qF -- 'post the typed object as a comment **on the epic** with' "$CONDUCTOR"
  # ...and the LABEL, which lives on the next source line: without its own
  # needle the clause can be deleted while every needle here still matches, and
  # an epic escalation then posts unlabelled — never entering the human-decision
  # queue E4 forbids the escalation terminal from reaching on its behalf.
  grep -qF -- 'the `needs-human-decision` label, and stop' "$CONDUCTOR"
  # ...and it does NOT delegate to a terminal whose steps cannot run at E4
  grep -qF -- "Do **not** run the escalation" "$CONDUCTOR"
  # exits 0 and 2 are explicitly NOT overridden, so the enumeration is closed
  grep -qF -- '**Exits 0 and 2, and a merely missing profile, are unchanged**' "$CONDUCTOR"
}

@test "#1504 E4's no-profile floor names what to run and what to disclose" {
  # The third floor. Its ban must be scoped to a LOADED profile, or it forbids
  # the very fallback the sentence beside it licenses.
  grep -qF -- '**Never substitute your own command for a LOADED profile' "$CONDUCTOR"
  grep -qF -- "run the repo's whole suite as §3's fallback directs" "$CONDUCTOR"
  grep -qF -- 'no profile-blessed gate was available' "$CONDUCTOR"
}

@test "#1504 the profile's shipped-slice version exception is pinned on both sides" {
  # Round 1's blocker. Nothing asserted it, so deleting the clause left the
  # suite green and a resolve run on development-kubernetes cutting a minor —
  # breaking the `0.3.` prefix tests/kubernetes-plugin-skeleton.bats asserts.
  grep -qF -- 'shipped-slice label' "$PROFILE"
  grep -qF -- 'development-kubernetes' "$PROFILE"
  # ...and the MAINTAINING.md rule it defers to still exists under that name,
  # so the citation cannot rot into a pointer at nothing.
  grep -qF -- 'One plugin-local override' "$REPO_ROOT/MAINTAINING.md"
  grep -qF -- 'One plugin-local override' "$PROFILE"
  # ...and by the DIGIT it moves, which is the whole behaviour. Pinned by its
  # exact wording, both sides: flipping `patch` to `minor` in either file
  # otherwise leaves every needle above matching while a resolve run on
  # development-kubernetes is told to break the prefix its own bats asserts.
  grep -qF -- 'moves only its **patch** digit' "$PROFILE"
  grep -qF -- 'moves only its patch digit' "$REPO_ROOT/MAINTAINING.md"
  # ...and the major tier MAINTAINING.md mandates is not silently missing from
  # what is now the sole statement of the sizing rule for this repo type.
  grep -qF -- 'a **major** for a breaking' "$PROFILE"
}

@test "#1504 E4 tells an epic-only session to detect and load the profile itself" {
  # §1b lives under ## Single-issue flow; the Epic flow never runs it, and E3's
  # zero-open-children re-run arrives at E4 having run no child at all. Without
  # this the session has an unbound <repo_type> and improvises the holistic gate.
  grep -qF -- 'the Epic flow never ran §1b' "$CONDUCTOR"
  grep -qF -- 'the bullets are chosen *by* repo type' "$CONDUCTOR"
  # ...and it sits ABOVE the bullet list, because the bullets are chosen BY the
  # repo type detect reports. Inside one bullet it would need repeating once per
  # type when #1505 populates the other five profiles.
  local hoist java
  hoist="$(grep -n 'First, before choosing a bullet below' "$CONDUCTOR" | cut -d: -f1)"
  java="$(grep -n '^- \*\*Java / Python app\*\*' "$CONDUCTOR" | cut -d: -f1)"
  [ -n "$hoist" ] || { echo "E4's detect-and-load paragraph is gone" >&2; return 1; }
  [ -n "$java" ] || { echo "E4's first bullet is gone" >&2; return 1; }
  [ "$hoist" -lt "$java" ] || { echo "E4's detect-and-load is not above the bullets" >&2; return 1; }
}

# --- the load point ---------------------------------------------------------

@test "#1504 §1b sits between §1 and §2 and runs detect" {
  local one bee two
  one="$(grep -n '^### 1\. Branch off fresh main$' "$CONDUCTOR" | cut -d: -f1)"
  bee="$(grep -n '^### 1b\. Detect the repo type and load the profile$' "$CONDUCTOR" | cut -d: -f1)"
  two="$(grep -n '^### 2\. Implement$' "$CONDUCTOR" | cut -d: -f1)"
  # One assertion per line: in an `&&`-joined list every member but the last is
  # exempt from errexit, so a chained form would swallow the first two.
  [ -n "$one" ] || { echo "no §1 heading" >&2; return 1; }
  [ -n "$bee" ] || { echo "no §1b heading" >&2; return 1; }
  [ -n "$two" ] || { echo "no §2 heading" >&2; return 1; }
  [ "$one" -lt "$bee" ] || { echo "§1b is not after §1" >&2; return 1; }
  [ "$bee" -lt "$two" ] || { echo "§1b is not before §2" >&2; return 1; }
  grep -qF -- 'review-dispatch.zsh" detect --repo .' "$CONDUCTOR"
  grep -qF -- '`development-<repo_type>:resolve-profile`' "$CONDUCTOR"
}

@test "#1504 §1b states ALL FOUR of detect's exit arms, and the script documents the same four" {
  # The pointer sweep says a step cites the contract; it says nothing about what
  # the step CLAIMS. Rewriting the exit-3 arm to "no profile exists; continue"
  # teaches the session to swallow a typed escalation, and every other test here
  # stays green — the regression this file's header calls the most likely one.
  grep -qF -- '#   0 → use .repo_type below' "$CONDUCTOR"
  grep -qF -- '#   2 → your OWN malformed invocation: fix the command and re-run' "$CONDUCTOR"
  grep -qF -- "#   1 → internal failure: report the script's stderr and stop" "$CONDUCTOR"
  grep -qF -- '#   3 → a repo whose TYPE could not be determined' "$CONDUCTOR"
  # exit 3 must keep an ACTION, not just a cross-reference: this story adds no
  # typed refusal, so the arm continues rather than stopping.
  grep -qF -- 'repo type could not be determined' "$CONDUCTOR"
  grep -qF -- 'That line is NOT the missing-profile notice below' "$CONDUCTOR"
  # ...and the same four codes are what the script's own contract documents, so
  # a change to either side reds rather than drifting.
  local c
  for c in '#   0  success' '#   2  usage error' '#   3  typed escalation' '#   1  internal error'; do
    grep -qF -- "$c" "$DISPATCH" || {
      printf 'the script no longer documents: %s\n' "$c" >&2
      return 1
    }
  done
}

# Every tracked markdown file that names the WHOLE contract roster. Derived,
# never transcribed — a closed list of governed sites rots the moment a fifth
# copy lands, which is this repo's own position-guard rule (#936/#1188).
# `docs/superpowers/` is vendored and restates nothing of ours, the same
# exclusion the sibling sweeps use.
_roster_sites() {
  local root="${1:-$REPO_ROOT}" f h all
  while IFS= read -r f; do
    case "$f" in docs/superpowers/*) continue ;; esac
    all=1
    for h in "${HEADINGS[@]}"; do
      grep -qF -- "$h" "$root/$f" || { all=0; break; }
    done
    [ "$all" -eq 0 ] || printf '%s\n' "$f"
  done < <(git -C "$root" ls-files '*.md')
}

@test "#1504 the whole-roster sites are exactly ARCHITECTURE.md plus every shipped profile" {
  # MAINTAINING.md's registry row claims the heading strings live in the
  # authoritative site and in the test, and §1b says naming them again would be
  # "a third copy to drift". Round 2 checked only §1b, and only for the WHOLE
  # roster, so a rename there — the mutation that finding was filed against —
  # still passed, and a fourth copy on a hand-written docs page passed too.
  # This is the derived form: whatever names all six is a governed site, and the
  # governed set is exactly ARCHITECTURE.md plus the profiles.
  local expected got
  expected="$( { printf 'ARCHITECTURE.md\n'; _profiles; } | sort )"
  got="$(_roster_sites | sort)"
  [ "$got" = "$expected" ] || {
    printf 'the contract roster is named at:\n%s\n\nexpected exactly:\n%s\n' \
      "$got" "$expected" >&2
    printf '\nA new site is a new copy to drift. Point at ARCHITECTURE.md instead,\n' >&2
    printf 'or add it here AND to MAINTAINING.md'"'"'s registry row in the same PR.\n' >&2
    return 1
  }
}

@test "#1504 non-vacuity: a fifth site naming the roster reds the sweep" {
  # Drives the SAME derivation over a synthetic tree, so the sweep really is
  # what is measured rather than a restatement of the number two.
  local D="$BATS_TEST_TMPDIR/roster-probe" h got
  mkdir -p "$D/docs/superpowers"
  git -C "$D" init -q
  git -C "$D" config user.email t@example.com
  git -C "$D" config user.name tester
  : > "$D/all-six.md"
  for h in "${HEADINGS[@]}"; do printf '## %s\n' "$h" >> "$D/all-six.md"; done
  # ...one that names five of six, the shape that slipped past round 2's check
  head -5 "$D/all-six.md" > "$D/five-of-six.md"
  # ...and a VENDORED copy, so the exclusion clause is measured rather than
  # assumed — without it the sweep would red on every vendored doc that happens
  # to carry the same words.
  cp "$D/all-six.md" "$D/docs/superpowers/vendored.md"
  git -C "$D" add -A
  # Drives the REAL helper, not a hand-copy of its loop: a control that
  # re-implements the derivation cannot see the derivation being narrowed, which
  # is the whole reason this file routes its other controls through the detector
  # they guard.
  got="$(_roster_sites "$D")"
  [ "$got" = "all-six.md" ] || {
    printf 'the sweep returned [%s], expected exactly all-six.md\n' "$got" >&2
    return 1
  }
}

@test "#1504 §1b points at the contract rather than restating the roster" {
  # The site-scoped half. The sweep above bounds the governed SET; this asserts
  # §1b is not in it and does send the reader somewhere that is.
  local sec="$BATS_TEST_TMPDIR/step-1b.md" flat
  awk '
    /^### 1b\. / { inside = 1; next }
    inside && /^### / { exit }
    inside { print }
  ' "$CONDUCTOR" > "$sec"
  [ -s "$sec" ] || { echo "no §1b section found" >&2; return 1; }
  # Flattened, because the pointer wraps: a line-oriented needle would be one
  # reflow away from silently not matching.
  flat="$(tr '\n' ' ' < "$sec" | tr -s ' ')"
  case "$flat" in *"ARCHITECTURE.md's *Resolve profile contract*"*) : ;;
    *) echo "§1b does not point at ARCHITECTURE.md's contract section" >&2; return 1 ;;
  esac
  # ...and it refers to the headings by POSITION, so a rename cannot leave it
  # advertising a heading no profile carries.
  case "$flat" in *"referred to here by POSITION rather than by name"*) : ;;
    *) echo "§1b no longer states why it names no heading" >&2; return 1 ;;
  esac
  # ...and the round-4 remedy itself: the LITERAL `none` test and the filing
  # duty. Unpinned, "BEGINS with" could be weakened to "IS", at which point the
  # shipped profile's three `none`-prefixed headings all read as non-`none` and
  # every run of a plugin repo files spurious issues.
  case "$flat" in *"BEGINS with \`none\`"*) : ;;
    *) echo "§1b no longer defines \`none\` literally" >&2; return 1 ;; esac
  case "$flat" in *"does **not** make it non-\`none\`"*) : ;;
    *) echo "§1b no longer says qualifying prose leaves a heading none" >&2; return 1 ;; esac
  case "$flat" in *"file an issue against #1506"*) : ;;
    *) echo "§1b no longer states the filing duty" >&2; return 1 ;; esac
  case "$flat" in *"never add the dereference to this conductor yourself"*) : ;;
    *) echo "§1b no longer forbids editing the conductor instead of filing" >&2; return 1 ;; esac
  # ...and the rule is SCOPED: without this it also selects the dereferenced
  # positions, licensing a run to skip the profile's blessed gate.
  case "$flat" in *"The first three positions are never filed against #1506"*) : ;;
    *) echo "§1b's none rule is not scoped away from the dereferenced positions" >&2; return 1 ;; esac
  # ...and it names NONE of them. The derived sweep above only reds on a file
  # carrying the WHOLE roster, so a five-of-six restatement here — the exact
  # shape rounds 2 and 3 both blocked on — would otherwise ship green.
  local h
  for h in "${HEADINGS[@]}"; do
    if grep -qF -- "$h" "$sec"; then
      printf '§1b names the heading "%s" — that is the extra copy it says not to make.\n' "$h" >&2
      printf 'Refer to it by position, or move the sentence to ARCHITECTURE.md.\n' >&2
      return 1
    fi
  done
}

@test "#1504 non-vacuity: a heading name planted in §1b reds the absence loop" {
  # Proves the loop above discriminates rather than passing because `$sec` is
  # empty or `HEADINGS` is unset.
  local sec="$BATS_TEST_TMPDIR/step-1b-planted.md" h hit=0
  awk '
    /^### 1b\. / { inside = 1; next }
    inside && /^### / { exit }
    inside { print }
  ' "$CONDUCTOR" > "$sec"
  [ -s "$sec" ] || { echo "no §1b section found" >&2; return 1; }
  printf '\nthe roster is %s and friends.\n' "${HEADINGS[3]}" >> "$sec"
  for h in "${HEADINGS[@]}"; do
    grep -qF -- "$h" "$sec" && hit=1
  done
  [ "$hit" -eq 1 ]
}

@test "#1504 every shipped profile has a row in the hand-written plugin reference" {
  # docs/reference/plugins.md is hand-written — no generator covers it — so the
  # only skill this story ships can be deleted from the user-facing inventory
  # with the whole suite green. Derived from the profile roster, so #1505's
  # further profiles red until their rows land too.
  local page="$REPO_ROOT/docs/reference/plugins.md" p plug bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    plug="${p%%/*}"
    # the row exists...
    grep -qF -- '| Resolve profile |' "$page" || { bad+="$plug: no Resolve profile row"$'\n'; continue; }
    # ...inside that plugin's own section, not some other plugin's
    awk -v want="## $plug" '
      $0 == want { inside = 1; next }
      inside && /^## / { exit }
      inside { print }
    ' "$page" | grep -qF -- '| Resolve profile |' \
      || bad+="$plug: the Resolve profile row is not in its own section"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || { printf 'plugin reference row(s) missing:\n%s\n' "$bad" >&2; return 1; }
  # ...and the row points at the contract rather than restating the roster
  grep -qF -- 'not restated here' "$page"
}

@test "#1504 MAINTAINING.md's registry row records the derived roster count" {
  # The roster tripwire above tells the reader to update this row, but until now
  # nothing read it — so #1505's author could edit the test count to 6, see
  # green, and leave the registry recording 1. Both sibling invariants
  # (tests/iac-selection-rule.bats, tests/no-cluster-deploy.bats) tie their
  # figure to the table exactly this way.
  local table row recorded derived
  table="$(sed -n '/^| Invariant | Authoritative site |/,/^$/p' "$REPO_ROOT/MAINTAINING.md")"
  [ -n "$table" ] || { echo "no Invariants in force table in MAINTAINING.md" >&2; return 1; }
  # awk, not grep: grep exits 1 on no match and would abort before the emptiness
  # check below could report the DELETED row, which is the mutation that matters.
  row="$(awk '/\*\*Resolve profile contract\*\*/' <<< "$table")"
  [ -n "$row" ] || {
    echo "MAINTAINING.md's Invariants in force has no Resolve profile contract row" >&2
    return 1
  }
  # it names its own sweep and its authoritative site, so the row cannot point
  # the reader at the wrong file
  case "$row" in *"tests/resolve-profile-contract.bats"*) : ;;
    *) echo "the row does not name its sweep" >&2; return 1 ;; esac
  case "$row" in *"ARCHITECTURE.md"*) : ;;
    *) echo "the row does not name its authoritative site" >&2; return 1 ;; esac
  recorded="$(sed -n 's/.*gated == roster == \([0-9][0-9]*\).*/\1/p' <<< "$row")"
  [ -n "$recorded" ] || { echo "the row records no gated == roster == N figure" >&2; return 1; }
  derived="$(_profiles | grep -c .)"
  [ "$recorded" -eq "$derived" ] || {
    printf 'MAINTAINING.md records %s profile(s); the derived roster holds %s.\n' \
      "$recorded" "$derived" >&2
    printf 'Update the Resolve profile contract row in the same PR.\n' >&2
    return 1
  }
}

@test "#1504 ARCHITECTURE.md records the derived roster count too" {
  # The third recorded figure, split into its own @test so the name says it is
  # gated: #1505 moves the test constant and MAINTAINING.md's row together, and
  # this is the one that would otherwise be left behind saying "1".
  local derived arch_count
  derived="$(_profiles | grep -c .)"
  arch_count="$(sed -n 's/^Profiles populated today: \*\*\([0-9][0-9]*\)\*\*.*/\1/p' "$ARCH")"
  [ -n "$arch_count" ] || {
    echo "ARCHITECTURE.md records no 'Profiles populated today: **N**' figure" >&2
    return 1
  }
  [ "$arch_count" -eq "$derived" ] || {
    printf 'ARCHITECTURE.md records %s profile(s); the derived roster holds %s.\n' \
      "$arch_count" "$derived" >&2
    return 1
  }
}

@test "#1504 a missing profile is a one-line notice and the run CONTINUES" {
  grep -qF -- 'A missing profile is a fallback, never a refusal.' "$CONDUCTOR"
  grep -qF -- "continuing with the conductor's" "$CONDUCTOR"
}

@test "#1504 unsupported_repo_type is not reused for a missing profile" {
  # The name stays exclusively review-dispatch.zsh's exit-3 condition. Written
  # down, and pinned, so a later reader does not collapse the fallback above
  # into a typed refusal — the single most likely regression here.
  grep -qF -- '`unsupported_repo_type` is not reused here.' "$CONDUCTOR"
  grep -qF -- "exit-3 condition" "$CONDUCTOR"
}
