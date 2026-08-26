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

# The repo types review-dispatch.zsh DOCUMENTS in its header line, one per line
# ($1 overrides the file, for the non-vacuity controls). The same expression both
# directions of the set-equality use, so they cannot disagree about what the
# documented set is (#1505).
_dispatch_types() {
  sed -n 's/^#  *repo_type ∈ {\(.*\)};.*/\1/p' "${1:-$DISPATCH}" | tr -d ' ' | tr ',' '\n'
}

# The repo types review-dispatch.zsh ACTUALLY EMITS, derived from the code that
# assigns them: the supported-language loop plus every literal `repo_type="…"`
# assignment (the fallbacks). Sorted and de-duplicated.
#
# Why both this and `_dispatch_types`: the header line is a COMMENT, and a
# comment cannot gate anything. Adding a third fallback arm — an `is_terraform`
# marker assigning `repo_type="terraform"` — while leaving the header untouched
# would keep every comment-derived check green, and the story's whole deliverable
# ("adding a repo type without shipping its profile reds the suite") would be
# false. The pairing test below is what forbids that: the documented set and the
# emitted set must be equal, and the profile roster is then gated against BOTH.
_emitted_types() {
  local f="${1:-$DISPATCH}"
  {
    sed -n 's/^  for l in \(.*\); do$/\1/p' "$f" | tr ' ' '\n'
    # Optional quoting on purpose: `repo_type=terraform` and
    # `repo_type='terraform'` are both valid zsh, and a derivation that saw only
    # the double-quoted spelling would let a new arm ship with no profile while
    # every check here stayed green — falsifying the guarantee this file exists
    # to enforce. No regex closes the set, which is why the assignment-site
    # tripwire below counts the sites as well.
    sed -n 's/.*repo_type=["'"'"']\{0,1\}\([a-z][a-z0-9_-]*\)["'"'"']\{0,1\}.*/\1/p' "$f"
  } | grep -v '^$' | sort -u
}

# Every `repo_type=` assignment site in the dispatcher, however spelled. Counted
# rather than parsed: `_emitted_types` can only recognise the shapes it was
# taught, so a NEW shape has to red here and send its author to that helper.
_repo_type_assignment_sites() {
  grep -o 'repo_type=' "${1:-$DISPATCH}" | grep -c . || true
}

# The review dimensions this repo's panels declare, one per line, DERIVED from
# each review skill's own table rather than transcribed. Two table shapes ship —
# `| Agent | Model | Dimension |` and kubernetes' `| Dimension | Agent |` — so
# the column is located by its HEADER rather than by a fixed index, and a panel
# that reorders its columns cannot silently drop out of the roster.
_review_dimensions() {
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _review_dimensions_of "$REPO_ROOT/$f"
  done < <(git -C "$REPO_ROOT" ls-files 'development-*/skills/review/SKILL.md') | sort -u
}

# The dimensions ONE review skill declares. Split out so the roster check can
# assert per-file that every panel contributes — an aggregate count cannot tell
# "this panel declares none" from "the awk stopped parsing this table".
_review_dimensions_of() {
    awk -F'|' '
      # the header row: remember which field is the Dimension column
      !col && /\|/ {
        for (i = 1; i <= NF; i++) {
          v = $i; gsub(/^[ \t]+|[ \t]+$/, "", v)
          if (tolower(v) == "dimension") { col = i }
        }
        if (col) next
      }
      col && /^\|/ {
        v = $col; gsub(/^[ \t]+|[ \t]+$/, "", v)
        gsub(/`/, "", v)
        if (v ~ /^-+$/ || v == "") next
        print v
      }
    ' "$1"
}

# Every Panel restatement violation, one per line. $1 overrides the repo root so
# the non-vacuity control can drive THIS function over a planted tree.
# NOTE the `if`s rather than `cmd && printf`. A trailing `&&` whose left side
# does not match returns non-zero, and "does not match" is the GOOD case here —
# as the last statement of a loop body it makes the whole function exit 1, which
# under bats' errexit aborts the caller on a CLEAN tree. Every violation
# accumulator in this file has to stay status-clean for the same reason.
_panel_restatements() {
  local root="${1:-$REPO_ROOT}" p d sec
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -r "$root/$p" ] || continue
    sec="$(_profile_section "$root/$p" "Panel")"
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      if printf '%s' "$sec" | grep -qiwF -- "$d"; then
        printf "%s: Panel names the dimension '%s'\n" "$p" "$d"
      fi
    done < <(_review_dimensions)
    # the other half of what every profile promises: no severity bar either
    if printf '%s' "$sec" | grep -qwE -- 'CRITICAL|WARNING|SUGGESTION'; then
      printf '%s: Panel restates a severity bar\n' "$p"
    fi
  done < <(_profiles)
  return 0
}

# The Gate clauses whose REVERSION would put a run back on an action a review
# round raised as wrong — whether or not that round blocked on it, the bar
# ARCHITECTURE.md states. `type|needle`, one row per clause, matched inside
# that profile's `## Gate` section.
#
# Deliberately NOT one row per sentence: these profiles are contracted to be
# short, and pinning every clause would both freeze prose that should stay
# editable and mint review surface of its own. The bar is the one the #1505
# guidance sets — a clause earns a row when losing it puts a model back on an
# action a review round raised as wrong, whether or not it blocked on it.
#
# A needle must be both UNIQUE and DISCRIMINATING, which are different tests and
# both were failed here once:
#
#   - UNIQUE — it occurs exactly once in that profile's Gate. `kustomize` did
#     not: it also appears in the render bullet and in "component
#     kustomizations", so reverting the absent-tool enumeration left the row
#     matching an untouched line. The sweep below now enforces this
#     mechanically, so the rule is not review-only.
#   - DISCRIMINATING — it appears in the CORRECTED text and not in the defective
#     text it replaced. `Epic verification (§E4)` was a substring of the
#     defective round-2 sentence, and `coverage-floor-go`/`-swift` sit in their
#     bullet's premise sentence, which the defective version also carried. A
#     unique needle in a paragraph the mutation does not touch pins nothing.
#     No sweep can check this one — it is a claim about text that no longer
#     exists — so it is the reviewer's job, and the reason each row below names
#     the corrective clause rather than the surrounding explanation.
#
# The #1558 rows meet the same bar by a slightly different route: #1505's
# closing round raised each seam as a finding and recorded it rather than
# blocking on it, so the action a reader was left on was wrong in each case even
# though no round called it wrong loudly enough to hold the PR — and #1558's own
# rounds then raised the same shapes as blocking. Reverting any one of them puts
# a model back on it: a vacuously green kubernetes gate over zero rendered
# documents (or over documents the change never touched), a halt on a tool that
# repo never selects, an E4 verdict resting on the inference its go/swift
# siblings reject, a go E4 arm that reads two ways on a `cmd/` binary, and a §6
# halt that fires where the coverage guard itself owes nothing. #1558's own
# rounds then added further seams to that list — a docs-only story held up by a
# renderer it never needed, a delivered docs-only epic left permanently open at
# E4, a green criterion whose subject narrows back to render output on a repo
# that renders nothing, and the deleted-path relation read from the panel's
# bolded headline rather than from the rule that closes it. That list is open,
# not closed: every row below is pinned by the sentence carrying its own
# corrective instruction, so a seam pinned later belongs in the table whether or
# not this paragraph names it.
#
# Each seam is pinned by the sentence that CARRIES the corrective instruction,
# not by the premise that motivates it — the DISCRIMINATING half above, applied.
# A row on the premise alone survives a rewrite that keeps the premise and drops
# the directive, which is the whole failure mode this table exists to catch.
_gate_clauses() {
  printf '%s\n' \
    'python|git rev-parse --git-common-dir' \
    'python|Epic verification (§E4)' \
    'python|end-to-end exercise of the affected behaviour' \
    'java|Epic verification (§E4)' \
    'java|end-to-end exercise of the affected behaviour' \
    'go|unconditionally' \
    'go|abandon-and-report' \
    'go|Do not produce it here' \
    'go|Epic verification (§E4)' \
    'go|end-to-end exercise of the affected behaviour' \
    'swift|report the unresolved scheme/destination and stop' \
    'swift|do not run it here' \
    'swift|-enableCodeCoverage YES build test' \
    'swift|Epic verification (§E4)' \
    'swift|end-to-end exercise of the affected behaviour' \
    'kubernetes|read the set there' \
    'kubernetes|Attribute a finding' \
    'kubernetes|the renderers as much as the validators' \
    'kubernetes|Epic verification (§E4)' \
    'kubernetes|An EMPTY set of gateable documents is not green' \
    'kubernetes|The population is the panel' \
    'kubernetes|Repo-wide — the tree is empty' \
    'kubernetes|with **no commit and no PR**' \
    'kubernetes|Take that halt, never an arm' \
    'kubernetes|neither arm applies:** a README' \
    'kubernetes|declared policy tree is in the population too' \
    'kubernetes|own result stands** — this Gate is not claiming a red' \
    'kubernetes|Change-relative — the tree is non-empty' \
    'kubernetes|NOT-APPLICABLE-on-a-full-round** arm and take the' \
    'kubernetes|not map-value equality' \
    'kubernetes|and **proceed** — the panel will report its own' \
    'kubernetes|zero applicable tools over an **empty tree**' \
    'kubernetes|standalone manifests validated directly' \
    'kubernetes|when the diff carried a deploy-relevant path' \
    'kubernetes|qualifier is the **deploy-relevant-path precondition' \
    'kubernetes|every diff-shaped test in this heading asks' \
    'kubernetes|For the ARMS specifically' \
    'kubernetes|does not halt it' \
    'kubernetes|not held up by a renderer it never needed' \
    'kubernetes|found something deployable in the diff' \
    'kubernetes|Once it is read against the union' \
    'kubernetes|let E5 close the epic' \
    'kubernetes|Neither arm is cleared by re-running' \
    'kubernetes|is not a missing tool' \
    'kubernetes|A chart or root inside the skip set never selects its' \
    'kubernetes|never against the repo' \
    'kubernetes|unless the renderer' \
    'kubernetes|The reason is positive, not an inference from E4' \
    'kubernetes|for #1206 here** — that gate reads an *application* repo' \
    'kubernetes|which those types do not share' \
    'kubernetes|union of the epic' \
    'kubernetes|never against `origin/main`, which by E4 already carries' \
    'kubernetes|**finding-attribution** bullet' \
    'kubernetes|halt E4, file an issue for it, and do NOT close the epic' \
    'kubernetes|Attribution has three outcomes here, not two' \
    'kubernetes|absent from the pre-epic baseline' \
    'kubernetes|So at E4 **either arm** means' \
    'kubernetes|halt E4, report which arm fired, and do NOT close the epic' \
    'kubernetes|halt E4, report the absent tool(s) by name' \
    'kubernetes|from the panel'"'"'s rule, not from its headline' \
    'kubernetes|belongs to no rendered document' \
    'kubernetes|lived under one — is always in scope' \
    'kubernetes|paths are policies belongs by the same' \
    'go|decides only what to exercise through it' \
    'go|still on the deployable arm' \
    'go|being importable exempts nothing' \
    'go|left on disk for E4 to' \
    'go|Close the enumeration rather than assuming the common case' \
    'go|name them in the' \
    'go|the exercise was **partial**' \
    'go|is a usage error,' \
    'go|**not a licence**' \
    'swift|**not a licence**' \
    'java|0 — nothing owed' \
    'java|read all **three** of its exits' \
    'java|only exit that halts WITHOUT further checking' \
    'java|never read *not 1* as *push*' \
    'java|came from THIS tree' \
    'java|its **own entry guard**' \
    'python|only one of them is *nothing owed*' \
    'python|read all **three** of its exits' \
    'python|only exit that halts WITHOUT further checking' \
    'python|never read *not 1* as *push*' \
    'python|its **own entry guard**' \
    'python|from **this** tree'
}

# Every missing Gate clause, one per line. $1 overrides the repo root so the
# control can drive THIS accumulator over a planted tree.
_gate_clause_violations() {
  local root="${1:-$REPO_ROOT}" rows="${2:-_gate_clauses}" row type needle profile
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    type="${row%%|*}"
    # `${row#*|}` is a NO-OP on a row with no separator, so a row mistyped as
    # `go` would yield needle=go and grep the go Gate for "go" — always a match,
    # asserting nothing while still counting toward the tripwire. The sibling
    # `_gate_pair_violations` names this degeneration; so does this one.
    case "$row" in
      *'|'*) needle="${row#*|}" ;;
      *) printf '%s: row names no needle\n' "$row"; continue ;;
    esac
    [ -n "$needle" ] || { printf '%s: empty needle in its _gate_clauses row\n' "$type"; continue; }
    profile="$root/development-$type/skills/resolve-profile/SKILL.md"
    [ -f "$profile" ] || { printf '%s: no profile at %s\n' "$type" "$profile"; continue; }
    _profile_section "$profile" "Gate" | grep -qF -- "$needle" \
      || printf '%s: Gate lost <<%s>>\n' "$type" "$needle"
  done < <("$rows")
  return 0   # status-clean on a clean tree — see _panel_restatements
}

# Every Version-bump violation, one per line. $1 overrides the repo root so the
# non-vacuity control can drive THIS accumulator over a planted tree.
#
# The RULE is taken as the first **bold** line, not merely the first line
# matching `**none` anywhere. Every section opens with the same two-line plain
# preamble (which is why "first non-blank line" is the wrong test here), and a
# section that PREPENDS a contradictory bold directive above a surviving
# conditional paragraph would satisfy a bare presence test — while §4's reader,
# going top-down, meets the bump first.
_version_bump_violations() {
  local root="${1:-$REPO_ROOT}" p sec first
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -r "$root/$p" ] || continue
    sec="$(_profile_section "$root/$p" "Version bump")"
    first="$(printf '%s\n' "$sec" | grep -m1 -- '^\*\*' || true)"
    case "$first" in
      '**none'*) : ;;
      *) printf '%s: Version bump does not OPEN with **none (got: %s)\n' \
           "$p" "${first:-<no bold rule at all>}"; continue ;;
    esac
    # The bold test alone sees only a BOLD prepend. The mutation the carried
    # blocker literally named is plain prose — an unbolded "Bump plugin.json …"
    # line above the rule — which leaves the first bold line untouched while
    # §4's top-down reader meets the bump first. Every section's preamble is the
    # same two plain lines, so anything directive-shaped above the rule is the
    # mutation.
    # `/^\*\*/q` stops BEFORE the rule line; a `1,/^\*\*/p` range would include
    # it, and the rule's own words ("nothing to bump") would trip this arm.
    # `([^[:alnum:]]|$)` rather than `\b`: the boundary escape is a GNU
    # extension, a stock BSD grep reads it as a literal `b`, and this repo is
    # macOS-only — so `bump\b` would quietly match nothing on the likely host
    # and let a plain-prose prepend ship green. The same substitution, for the
    # same reason, is why tests/go-docs-parity.bats spells its own needle this
    # way.
    if printf '%s\n' "$sec" | sed -n '/^\*\*/q;p' \
         | grep -qiE -- '^[[:space:]]*bump([^[:alnum:]]|$)|plugin\.json|marketplace\.json'; then
      printf '%s: Version bump states a directive ABOVE its **none rule\n' "$p"
      continue
    fi
    case "$p" in
      development-kubernetes/*)
        printf '%s' "$sec" | grep -qF -- 'cluster-definition repo' \
          || printf '%s: Version bump does not say WHY none holds here\n' "$p" ;;
      *)
        printf '%s' "$sec" | grep -qF -- 'unless this repo also ships installable plugin content' \
          || printf '%s: Version bump is not the CONDITIONAL none\n' "$p"
        printf '%s' "$sec" | grep -qF -- '.claude-plugin/marketplace.json' \
          || printf "%s: Version bump does not name the floor's marketplace half\n" "$p"
        printf '%s' "$sec" | grep -qF -- 'supersede' \
          || printf '%s: Version bump does not say it must not supersede the floor\n' "$p" ;;
    esac
  done < <(_profiles_without_runner)
  return 0   # status-clean on a clean tree — see _panel_restatements
}

# The profile at repo-relative path $1 with its whole Version bump body replaced
# by $2. Replacing the BODY rather than deleting a line is what keeps each
# planted mutation surgical: the conditional clause, the marketplace half and
# the `supersede` rule all live on the same line as the `**none` opener, so a
# `grep -v` of any one of them removes the opener too and the accumulator then
# reports "does not OPEN with **none" — a true statement about the plant, but
# not the branch the control meant to exercise.
_plant_vb() {
  awk -v body="$2" '
    /^## Version bump$/ { print; print ""; print body; skip = 1; next }
    /^## / { skip = 0 }
    !skip { print }
  ' "$REPO_ROOT/$1"
}

# Every emitted repo type with no profile in the roster, one per line, annotated
# with the path that is missing. $1 overrides the dispatch script, so the
# non-vacuity control can drive THIS function over a planted one rather than
# re-implementing its loop — the shape `_order_violation` and `_roster_sites`
# already use.
_types_without_profile() {
  local t have
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # `|| true`: a count of ZERO is the very condition this loop exists to
    # detect, and `grep -c` exits 1 on no match — under bats' errexit the bare
    # form aborts the caller before it can report the missing profile.
    have="$(_profiles | grep -cxF -- "development-$t/skills/resolve-profile/SKILL.md" || true)"
    [ "$have" -eq 1 ] \
      || printf '%s (no development-%s/skills/resolve-profile/SKILL.md)\n' "$t" "$t"
  done < <(_emitted_types "${1:-$DISPATCH}")
  return 0   # status-clean on a clean tree — see _panel_restatements
}

# The body of profile $1's `## `-heading $2, exclusive of the heading lines.
_profile_section() {
  awk -v want="$2" '
    /^## / { inside = (substr($0, 4) == want); next }
    inside { print }
  ' "$1"
}

# The profiles with NO attestable single-run runner — derived from the Gate's
# own content, never a hand-written list. That is the real reason the rule
# splits: `--gate-attest` (#981) carries a tree identity a runner produced, so a
# type with no such runner has nothing to attest and must say so. A type that
# later grows one drops out of this set by editing its own Gate, which is
# exactly when its `not applicable` line should stop being required.
#
# The needle is the runner INVOKED — `run-gate.zsh --tests-dir` — not the bare
# script name. Every profile without a runner names `run-gate.zsh` in prose, to
# say which shape it lacks, so a bare-name test matches all six and the set
# comes back EMPTY. That is not a harmless miss: the callers below then iterate
# nothing and report clean, which is the vacuity this file's header warns about
# — and the partition tripwire is what turns it back into a red.
_profiles_without_runner() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _profile_section "$REPO_ROOT/$p" "Gate" | grep -qF -- 'run-gate.zsh --tests-dir' \
      || printf '%s\n' "$p"
  done < <(_profiles)
  return 0   # status-clean on a clean tree — see _panel_restatements
}

# Print nothing when $1 carries EXACTLY the six contract headings in the
# declared order; otherwise print what it actually carries. The real assertion
# and its non-vacuity control both go through this, so the control proves this
# detector rather than a paraphrase of it.
_order_violation() {
  local got want
  # An unreadable path is a violation, not a clean sweep: `_profiles` derives
  # from `git ls-files`, so a profile deleted from the worktree without being
  # staged is still in the roster.
  [ -r "$1" ] || { printf '<unreadable: %s>\n' "$1"; return 0; }
  got="$(_profile_headings "$1")"
  want="$(printf '%s\n' "${HEADINGS[@]}")"
  # `${got:-<…>}` because the pipeline in `_profile_headings` swallows grep's
  # no-match status, so a file with NO `## ` heading at all — the loudest
  # mutation this detector exists to catch, and the one a heading demoted to
  # `###` produces — yields an empty `got`, and printing that emits a lone
  # newline the caller's command substitution strips back to "" (i.e. clean).
  [ "$got" = "$want" ] || printf '%s\n' "${got:-<no \`## \` headings at all>}"
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
  n="$(_profiles | grep -c . || true)"
  [ "$n" -eq 6 ] || {
    printf 'the repo ships %s profile(s), expected 6.\n' "$n" >&2
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
  # Both directions go through `_emitted_types` (#1505), so neither can be
  # dodged by editing the header comment alone — the pairing test below holds
  # the comment and the code equal.
  local types p seg bad=""
  types="$(_emitted_types)"
  [ -n "$types" ] || { echo "could not read the repo_type set out of $DISPATCH" >&2; return 1; }
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    seg="${p%%/*}"
    seg="${seg#development-}"
    printf '%s\n' "$types" | grep -qxF -- "$seg" \
      || bad+="$p (repo type '$seg')"$'\n'
  done < <(_profiles)
  [ -z "$bad" ] || {
    printf 'profile(s) naming a repo type review-dispatch.zsh never emits (%s):\n%s\n' \
      "$types" "$bad" >&2
    return 1
  }
}

@test "#1505 the header line documents exactly the repo types the code emits" {
  # The set-equality below is only as good as the set it reads, and one side of
  # it comes from a COMMENT. Pair the comment against the code that assigns
  # `repo_type` — the supported-language loop plus the fallback assignments — so
  # a new arm added without touching the header cannot slip past every
  # comment-derived check while the story's guarantee ("adding a repo type
  # without shipping its profile reds the suite") quietly becomes false.
  local documented emitted
  documented="$(_dispatch_types | sort -u)"
  emitted="$(_emitted_types)"
  [ -n "$documented" ] || { echo "could not read the repo_type set out of $DISPATCH" >&2; return 1; }
  [ -n "$emitted" ] || { echo "could not derive the emitted repo_type set from $DISPATCH" >&2; return 1; }
  [ "$documented" = "$emitted" ] || {
    printf 'the header line and the code disagree about repo_type.\n' >&2
    printf 'documented:\n%s\n\nemitted by the code:\n%s\n' "$documented" "$emitted" >&2
    return 1
  }
}

@test "#1505 the repo_type assignment sites are the ones _emitted_types was taught" {
  # `_emitted_types` recognises the shapes it was written for. No regex closes
  # the set, so a NEW assignment shape would slip past it silently — and the
  # story's whole guarantee ("adding a repo_type without shipping its profile
  # reds the suite") would quietly become false. A count is what turns that into
  # a red that names its own remedy.
  local n
  n="$(_repo_type_assignment_sites)"
  [ "$n" -eq 6 ] || {
    printf 'review-dispatch.zsh has %s `repo_type=` site(s), expected 6.\n' "$n" >&2
    printf 'Today: the `local repo_type=""` declaration, the two fallback\n' >&2
    printf 'literals, ${supported[1]}, $primary, and `local repo_type="$_RD_REPO_TYPE"`.\n' >&2
    printf 'A NEW site must be taught to _emitted_types in the same PR, or the\n' >&2
    printf 'set-equality below stops seeing the type it emits.\n' >&2
    return 1
  }
}

@test "#1505 non-vacuity: an UNQUOTED repo_type arm is still derived" {
  # The spelling that defeated the first cut of this derivation. Drives the real
  # helper over a planted script, and plants with awk — BSD sed emits a literal
  # `n` for `\n` in a replacement, which would collapse the plant onto one line
  # and silently drop `kubernetes` from the derived set.
  local planted="$BATS_TEST_TMPDIR/dispatch-unquoted.zsh" emitted
  awk '
    { print }
    /^      repo_type="kubernetes"$/ {
      print "    elif [[ \"$is_tf\" == true ]]; then"
      print "      repo_type=terraform"
    }
  ' "$DISPATCH" > "$planted"
  emitted="$(_emitted_types "$planted")"
  printf '%s\n' "$emitted" | grep -qxF terraform || {
    echo "an unquoted repo_type= arm was not derived" >&2; return 1; }
  # ...and the plant ADDED an arm rather than replacing one
  printf '%s\n' "$emitted" | grep -qxF kubernetes || {
    echo "the plant dropped kubernetes — the fixture is not an ADDED arm" >&2; return 1; }
}

@test "#1505 non-vacuity: an emitted type missing from the header reds the pairing" {
  # Drives the REAL derivations over a planted script, so a narrowed sed is
  # caught rather than re-implemented — this file's own control convention.
  local planted="$BATS_TEST_TMPDIR/dispatch-extra-arm.zsh" documented emitted
  # Add a fallback arm WITHOUT touching the header comment: the exact drift.
  # awk, not sed: BSD sed emits a literal `n` for `\n` in a replacement, which
  # collapses the plant onto one line — and `_emitted_types`' greedy match then
  # yields ONLY terraform, silently dropping kubernetes, so the control would
  # pass over a fixture that is not the shape this comment describes.
  awk '
    { print }
    /^      repo_type="kubernetes"$/ {
      print "    elif [[ \"$is_tf\" == true ]]; then"
      print "      repo_type=\"terraform\""
    }
  ' "$DISPATCH" > "$planted"
  emitted="$(_emitted_types "$planted")"
  printf '%s\n' "$emitted" | grep -qxF terraform || {
    echo "the plant did not take — _emitted_types found no terraform arm" >&2
    return 1
  }
  printf '%s\n' "$emitted" | grep -qxF kubernetes || {
    echo "the plant dropped kubernetes — the fixture is not an ADDED arm" >&2
    return 1
  }
  documented="$(_dispatch_types "$planted" | sort -u)"
  [ "$documented" != "$emitted" ]
  # ...and the real script still pairs cleanly through the same helpers
  [ "$(_dispatch_types | sort -u)" = "$(_emitted_types)" ]
}

@test "#1505 every repo type review-dispatch.zsh can emit HAS a profile" {
  # The converse of the check above, and the half #1504 deliberately left out
  # while only one type had a profile. Together the two are a SET EQUALITY.
  #
  # This is a BUILD-TIME requirement, adopted on purpose: from #1505 on, adding
  # a repo_type to review-dispatch.zsh without shipping its profile reds the
  # suite. It changes no RUNTIME behaviour — §1b's missing-profile arm is still
  # notice-and-continue, and nothing here licenses turning that into a refusal.
  #
  # Driven from the set the CODE emits, not the header comment — the pairing
  # test above holds the two equal, so this gate cannot be dodged by adding an
  # arm and leaving the comment alone.
  [ "$(_emitted_types | grep -c . || true)" -ge 1 ] \
    || { echo "could not derive the emitted repo_type set from $DISPATCH" >&2; return 1; }
  local bad
  bad="$(_types_without_profile)"
  [ -z "$bad" ] || {
    printf 'repo type(s) review-dispatch.zsh can emit with no profile:\n%s\n' "$bad" >&2
    printf 'Ship development-<type>/skills/resolve-profile/SKILL.md in the same PR,\n' >&2
    printf 'or the run silently takes the conductor generic floor for that type.\n' >&2
    return 1
  }
}

@test "#1505 non-vacuity: a seventh repo type with no profile reds the converse" {
  # Drives the REAL detector over a planted script rather than re-implementing
  # its loop — this file's own control convention, and the only shape that can
  # see the detector being narrowed.
  local planted="$BATS_TEST_TMPDIR/dispatch-seventh.zsh"
  # awk, not sed — see the sibling control above for why.
  awk '
    { print }
    /^      repo_type="kubernetes"$/ {
      print "    elif [[ \"$is_rust\" == true ]]; then"
      print "      repo_type=\"rust\""
    }
  ' "$DISPATCH" > "$planted"
  # the plant really took, measured through the same helper the detector uses
  _emitted_types "$planted" | grep -qxF rust || {
    echo "the plant did not take — _emitted_types found no rust arm" >&2
    return 1
  }
  _emitted_types "$planted" | grep -qxF kubernetes || {
    echo "the plant dropped kubernetes — the fixture is not an ADDED arm" >&2
    return 1
  }
  _types_without_profile "$planted" | grep -qxF -- 'rust (no development-rust/skills/resolve-profile/SKILL.md)'
  # ...and the REAL script still passes the same detector
  [ -z "$(_types_without_profile)" ]
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

@test "#1505 non-vacuity: a profile stripped of every heading reds the order check" {
  # The SWAP control below keeps the heading set non-empty by construction, so
  # it cannot see the emptiness case — which is the one that used to read clean.
  local planted="$BATS_TEST_TMPDIR/no-headings.md"
  grep -v '^## ' "$PROFILE" > "$planted"
  [ "$(_profile_headings "$planted" | grep -c . || true)" -eq 0 ]
  _order_violation "$planted" | grep -qF -- 'no `## ` headings at all'
  # ...and an unreadable path is a violation too, not a clean sweep
  _order_violation "$BATS_TEST_TMPDIR/definitely-absent.md" | grep -qF -- '<unreadable:'
  # ...while the real profile still passes the same detector
  [ -z "$(_order_violation "$PROFILE")" ]
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
  [ "$(_profile_headings "$planted" | grep -c . || true)" -eq 6 ]
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

@test "#1505 the contract section states every clause the sweep gates" {
  # MAINTAINING.md sends a new profile's author here, and this file gates five
  # clauses the "A profile is:" list did not originally carry. Unpinned, the
  # block can be deleted while every clause stays gated — and the author of the
  # seventh profile then writes to the documented contract and reds tests whose
  # requirements the contract never stated.
  local flat n needle bad="" needles
  flat="$(_arch_contract_flat "$ARCH")"
  [ -n "$flat" ] || { echo "no Resolve profile contract section in $ARCH" >&2; return 1; }
  # One needle per gated clause, INCLUDING the `none`-carries-a-reason clause
  # (gated by the trailing-headings sweep) and the Panel ban (gated by
  # `_panel_restatements`) — both of which the list once stated without any
  # needle holding them there.
  needles="$(printf '%s\n' \
    'disable-model-invocation: false' \
    'carries a **reason**' \
    '#1502' \
    '--gate-attest: not applicable' \
    '_gate_pairs' \
    '_gate_clauses' \
    'no dimension list and' \
    'narrows' \
    'whether or not that round blocked on it' \
    'carries the corrective instruction' \
    'per-type row split')"
  [ "$(printf '%s\n' "$needles" | grep -c . || true)" -eq 11 ] || {
    echo "the arch-clause needle list changed size. It covers the six clause bullets, the frontmatter disable-model-invocation clause above them, and clause 4's SECOND table (_gate_clauses) — which is why it is larger than the bullet count. #1558 added three more, all gated by the same sweep: the widened admission bar, the corrective-clause rule, and the per-type row split the tripwire now records." >&2
    return 1
  }
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    case "$flat" in *"$needle"*) : ;; *) bad+="$needle"$'\n' ;; esac
  done <<< "$needles"
  [ -z "$bad" ] || {
    printf 'clause(s) the sweep gates but the contract section no longer states:\n%s\n' \
      "$bad" >&2
    return 1
  }
  # ...and the spelled count tracks the BULLETS, derived rather than trusted, so
  # deleting a clause cannot leave the sentence claiming one more than it lists.
  local bullets
  bullets="$(awk '
    /further clauses became normative with #1505/ { inside = 1; next }
    inside && /^## / { exit }   # never leave the contract section
    inside && /^\*\*/ { exit }
    inside && /^- / { n++ }
    END { print n + 0 }
  ' "$ARCH")"
  [ "$bullets" -eq 6 ] || {
    printf 'the clause list holds %s bullet(s), expected 6.\n' "$bullets" >&2
    return 1
  }
  n="$(sed -n 's/^\*\*\([A-Za-z]*\) further clauses became normative with #1505\*\*.*/\1/p' "$ARCH")"
  [ "$n" = "Six" ] || {
    printf 'the contract section says "%s further clauses" over %s bullets.\n' \
      "$n" "$bullets" >&2
    return 1
  }
}

@test "#1505 non-vacuity: a clause stripped from the contract section reds the sweep" {
  local planted="$BATS_TEST_TMPDIR/arch-no-clause.md" flat
  grep -vF -- 'disable-model-invocation: false' "$ARCH" > "$planted"
  flat="$(_arch_contract_flat "$planted")"
  [ -n "$flat" ] || { echo "the planted contract section is empty" >&2; return 1; }
  case "$flat" in *'disable-model-invocation: false'*)
    echo "the strip did not take" >&2; return 1 ;; esac
  # ...and the real file still carries it, through the same extractor
  case "$(_arch_contract_flat "$ARCH")" in *'disable-model-invocation: false'*) : ;;
    *) echo "ARCHITECTURE.md no longer states the clause" >&2; return 1 ;; esac
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

# --- #1505: each Gate is pinned to the file that already runs the command ----
#
# A profile's Gate is only worth having if it names what the plugin's own tooling
# actually runs. Each pair below is asserted on BOTH sides — in the profile and
# in its anchor file — so the two cannot drift apart: change the agent's command
# without the profile (or the reverse) and this reds.
#
# The needles are TOKENS, not whole command strings. The anchor lines are
# reproduction invocations carrying shell noise the profile must not repeat
# (`2>&1 | tail -80`, `> /tmp/go-test.log`), so a whole-string needle would
# either force that noise into the profile or rot on the first cosmetic edit.

# type | anchor file | token…  — one row per repo type with an app-style gate.
_gate_pairs() {
  printf '%s\n' \
    'python|development-python/agents/python-ci-fixer.md|pytest --cov|.venv/bin/python -m pytest' \
    'java|development-java/agents/java-ci-fixer.md|./gradlew build test jacocoTestReport' \
    'go|development-go/agents/go-ci-fixer.md|go test ./...|-race' \
    'swift|development-swift/agents/swift-ci-fixer.md|swift test|--enable-code-coverage' \
    'kubernetes|development-kubernetes/skills/maintenance/SKILL.md|kubeconform|kube-linter|kyverno test'
}

# Planted row sets for the non-vacuity control below. Each is a `_gate_pairs`
# stand-in carrying exactly one malformed row, so the control drives the real
# parser instead of a paraphrase of it.
_planted_missing_token_row() {
  # a token present in the anchor's neighbourhood but NOT in the profile
  printf '%s\n' \
    'python|development-python/agents/python-ci-fixer.md|--tb=short --cov-fail-under=101'
}
_planted_empty_token_row() {
  printf '%s\n' 'python|development-python/agents/python-ci-fixer.md||pytest --cov'
}
_planted_tokenless_row() {
  printf '%s\n' 'python|development-python/agents/python-ci-fixer.md'
}

# Every gate/anchor violation, one per line. $1 overrides the row source so the
# control can drive THIS parser over a planted set.
#
# The `|`-walk has two silent-degeneration modes, and both are named rather than
# tolerated: an EMPTY token would make `grep -qF -- ""` match any non-empty file
# (so the row asserts nothing while still counting), and a row with no token
# fields would leave `${row#*|}` a no-op, turning the anchor PATH into the sole
# needle — which several profiles contain verbatim, making the check a tautology.
_gate_pair_violations() {
  local rows="${1:-_gate_pairs}" row type anchor tok profile
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    type="${row%%|*}"; row="${row#*|}"
    anchor="${row%%|*}"
    case "$row" in
      *'|'*) row="${row#*|}" ;;
      *) printf '%s: row names no token\n' "$type"; continue ;;
    esac
    profile="$REPO_ROOT/development-$type/skills/resolve-profile/SKILL.md"
    [ -r "$profile" ] || { printf '%s: no profile at %s\n' "$type" "$profile"; continue; }
    [ -r "$REPO_ROOT/$anchor" ] || { printf '%s: no anchor at %s\n' "$type" "$anchor"; continue; }
    while :; do
      tok="${row%%|*}"
      if [ -z "$tok" ]; then
        printf '%s: empty token in its _gate_pairs row\n' "$type"
      else
        grep -qF -- "$tok" "$profile" || printf '%s: profile lacks <<%s>>\n' "$type" "$tok"
        grep -qF -- "$tok" "$REPO_ROOT/$anchor" \
          || printf '%s: %s lacks <<%s>>\n' "$type" "$anchor" "$tok"
      fi
      [ "$row" = "$tok" ] && break
      row="${row#*|}"
    done
  done < <("$rows")
  return 0   # status-clean on a clean tree — see _panel_restatements
}

@test "#1505 the gate-pair list covers every profile that has no attestable runner" {
  # The tripwire the roster count is to the sweep. Both needle tests below
  # iterate this list and report clean on a short one, so a session resolving a
  # red pair could delete the row and go green with no other signal.
  local n_pairs n_app
  # `|| true` on both: an empty set is exactly what this tripwire must REPORT
  # (a discriminator that matches nothing makes every caller vacuous), and the
  # bare `grep -c` would abort under errexit before the message could print.
  n_pairs="$(_gate_pairs | grep -c . || true)"
  n_app="$(_profiles_without_runner | grep -c . || true)"
  [ "$n_pairs" -eq "$n_app" ] || {
    printf '%s gate pair(s) for %s profile(s) with no attestable runner.\n' \
      "$n_pairs" "$n_app" >&2
    printf 'Every such profile needs a row in _gate_pairs, or its Gate is unpinned.\n' >&2
    _profiles_without_runner >&2
    return 1
  }
  # ...and the split is real: the exemplar HAS a runner, so it is not in the set
  _profiles_without_runner \
    | grep -qxF 'development-claude-plugin/skills/resolve-profile/SKILL.md' && {
      echo "the claude-plugin profile's Gate no longer names run-gate.zsh" >&2
      return 1
    }
  return 0
}

@test "#1505 every gate token appears in BOTH the profile and its anchor file" {
  local bad
  bad="$(_gate_pair_violations)"
  [ -z "$bad" ] || { printf 'gate/anchor drift:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1505 non-vacuity: a token missing from the profile reds the pair check" {
  # Drives the REAL parser over a planted row set, so the failure mode this
  # control names — "the row parsing silently produced no tokens" — is actually
  # exercised. A control that only greps a stripped file proves nothing about
  # the `|`-walk that decides the verdict.
  local out
  # a token that is in the anchor but NOT in the profile
  out="$(_gate_pair_violations _planted_missing_token_row)"
  printf '%s\n' "$out" | grep -qF -- 'python: profile lacks <<--tb=short --cov-fail-under=101>>'
  # an EMPTY token must be named, not silently matched by `grep -qF -- ""`
  out="$(_gate_pair_violations _planted_empty_token_row)"
  printf '%s\n' "$out" | grep -qF -- 'python: empty token in its _gate_pairs row'
  # a row naming NO token at all must be named, not degenerate into grepping
  # the anchor path (which several profiles contain verbatim)
  out="$(_gate_pair_violations _planted_tokenless_row)"
  printf '%s\n' "$out" | grep -qF -- 'python: row names no token'
  # ...and the real rows still pass the same parser
  [ -z "$(_gate_pair_violations)" ]
}

@test "#1505 the gate-pair rows carry the exact token count recorded" {
  # The per-row twin of the row-count tripwire: without it a session resolving a
  # red pair can delete the offending TOKEN from its row and go green, since the
  # row itself survives and the row count is unchanged.
  local row n=0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    n=$(( n + $(printf '%s' "$row" | tr -cd '|' | wc -c) - 1 ))
  done < <(_gate_pairs)
  [ "$n" -eq 10 ] || {
    printf 'the gate rows carry %s token(s), expected 10.\n' "$n" >&2
    printf 'python 2, java 1, go 2, swift 2, kubernetes 3. Removing one unpins\n' >&2
    printf 'that half of its Gate from the anchor that runs the command.\n' >&2
    return 1
  }
}

@test "#1505 a profile with no attestable runner says --gate-attest is not applicable" {
  # `--gate-attest` (#981) carries a tree identity a run-gate.zsh-shaped runner
  # produced. A type with no such runner has nothing to attest — and the flag is
  # fail-closed on a MISMATCH, not on a fabricated value, so a profile that
  # stays silent here invites a caller to pass one anyway and skip a re-run it
  # never earned. Derived from the Gate's own content, so a type that later
  # grows a runner stops being required to say this by editing that Gate.
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _profile_section "$REPO_ROOT/$p" "Gate" \
      | grep -qF -- '--gate-attest' \
      || { bad+="$p: Gate never mentions --gate-attest"$'\n'; continue; }
    _profile_section "$REPO_ROOT/$p" "Gate" \
      | grep -qF -- 'not applicable' \
      || bad+="$p: Gate mentions --gate-attest but not that it is not applicable"$'\n'
  done < <(_profiles_without_runner)
  [ -z "$bad" ] || { printf 'attestation statement missing:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1505 the kubernetes profile explains why its anchor is not a ci-fixer" {
  # The one anchor that differs in KIND, and the one a later reader is most
  # likely to "fix" into line with the other four. development-kubernetes ships
  # no ci-fixer agent at all — assert that, so the explanation cannot outlive
  # the fact, and the explanation itself, so the fact cannot outlive its reason.
  local dir="$REPO_ROOT/development-kubernetes/agents"
  [ -d "$dir" ] || { echo "no development-kubernetes/agents directory" >&2; return 1; }
  run ls "$dir"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'ci-fixer' && {
    echo "development-kubernetes now ships a ci-fixer — re-anchor its Gate" >&2
    return 1
  }
  local gate
  gate="$(_profile_section "$REPO_ROOT/development-kubernetes/skills/resolve-profile/SKILL.md" "Gate")"
  printf '%s' "$gate" | grep -qF -- 'ships **no** ci-fixer agent' || {
    echo "the kubernetes Gate no longer says WHY its anchor differs" >&2
    return 1
  }
}

# --- #1505: the Panel records a pointer and nothing more --------------------

@test "#1505 the derived dimension roster is real, so the Panel ban is not vacuous" {
  # The ban below is only as strong as the needle set it derives, and the
  # derivation is silent about failure: a review skill whose Dimension column
  # the awk cannot locate contributes NOTHING and says nothing. So assert it
  # PER FILE — an aggregate floor lets a whole panel drop out unnoticed, taking
  # its dimensions off the ban with it.
  local f n bad=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(_review_dimensions_of "$REPO_ROOT/$f" | grep -c . || true)"
    [ "$n" -ge 1 ] || bad+="$f: no dimension column could be parsed"$'\n'
  done < <(git -C "$REPO_ROOT" ls-files 'development-*/skills/review/SKILL.md')
  [ -z "$bad" ] || { printf 'review panel(s) contributing no dimensions:\n%s\n' "$bad" >&2; return 1; }

  # ...and the total is a COUNT, not a floor — this file's own doctrine (a floor
  # moves WITH a deletion rather than against it).
  local dims total
  dims="$(_review_dimensions)"
  total="$(printf '%s\n' "$dims" | grep -c . || true)"
  [ "$total" -eq 13 ] || {
    printf 'the derived dimension roster holds %s entries, expected 13:\n%s\n' \
      "$total" "$dims" >&2
    printf 'A panel gaining or losing a dimension moves this figure in the same PR.\n' >&2
    return 1
  }
  # spot-check both table shapes: `| Agent | Model | Dimension |` and the
  # kubernetes `| Dimension | Agent |`
  printf '%s\n' "$dims" | grep -qxF code_quality
  printf '%s\n' "$dims" | grep -qxF argocd
}

@test "#1505 no profile's Panel enumerates a review dimension or a severity bar" {
  # ARCHITECTURE.md: the Panel RECORDS the review_skill and never overrides it,
  # and every profile states in as many words that it carries no dimension list
  # AND no bar (#1432 — each of those rules already has one home, with the agent
  # that applies it). Both halves are gated: a dimension roster here drifts from
  # the review skill's table, and a severity bar here drifts from the agents'.
  local bad
  bad="$(_panel_restatements)"
  [ -z "$bad" ] || {
    printf 'Panel restatement (the second statement that drifts, #1432):\n%s\n' "$bad" >&2
    return 1
  }
}

@test "#1505 non-vacuity: a planted dimension and a planted bar each red the ban" {
  # Drives the REAL detector over planted profiles rather than re-implementing
  # its loop, and exercises BOTH halves — a control covering only dimensions
  # would leave the bar half unproven.
  local dir="$BATS_TEST_TMPDIR/panel-probe"
  mkdir -p "$dir/development-python/skills/resolve-profile"
  local planted="$dir/development-python/skills/resolve-profile/SKILL.md"

  # Plant INSIDE the Panel section — appending at end-of-file would land under
  # `## Residue`, where the detector correctly ignores it, and the control would
  # then "fail" for a reason that says nothing about the ban.
  _plant_in_panel() {  # $1 = line to insert
    awk -v ins="$1" '
      { print }
      /^## Panel$/ { print ""; print ins }
    ' "$REPO_ROOT/development-python/skills/resolve-profile/SKILL.md" > "$planted"
  }

  _plant_in_panel 'Dimensions reviewed: bugs, security.'
  _profile_section "$planted" "Panel" | grep -qF -- 'Dimensions reviewed' \
    || { echo "the dimension plant did not land inside the Panel section" >&2; return 1; }
  _panel_restatements "$dir" | grep -qF -- "Panel names the dimension 'bugs'"

  _plant_in_panel 'Bar: a WARNING and above blocks the round.'
  _profile_section "$planted" "Panel" | grep -qF -- 'Bar:' \
    || { echo "the bar plant did not land inside the Panel section" >&2; return 1; }
  _panel_restatements "$dir" | grep -qF -- 'Panel restates a severity bar'

  # ...and the real profiles pass the same detector
  [ -z "$(_panel_restatements)" ]
}

@test "#1505 every profile's three trailing headings say none, with a reason" {
  # #1504 asserted this for the exemplar only. Swept, it is what stops #1505's
  # five copies quietly acquiring a rule in a position NO step is contracted to
  # dereference (§1b: those positions are #1506's to decide). A bare `**none**`
  # is not enough either — the reason is what tells the next author whether the
  # heading is empty by accident or by decision.
  local p h first sec bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for h in "Fix-pass rules" "Documentation expectations" "Residue"; do
      sec="$(_profile_section "$REPO_ROOT/$p" "$h")"
      # `|| true`: a DROPPED or emptied heading is exactly what this reports,
      # and `grep -m1 .` exits 1 on empty input — the bare form aborts under
      # errexit, making the `<empty>` diagnostic below unreachable.
      first="$(printf '%s\n' "$sec" | grep -m1 . || true)"
      case "$first" in
        '**none**'*) : ;;
        *) bad+="$p / $h: does not open with **none** (got: ${first:-<empty>})"$'\n'; continue ;;
      esac
      # ...and it says more than the bare word. Asserted as a SECOND non-blank
      # line rather than a character count: `**none**` is 9 characters, so a
      # length threshold is satisfied by `**none** yet.` — which tells the next
      # author nothing about whether the heading is empty by accident or by
      # decision, the very thing the reason exists to record.
      [ "$(printf '%s\n' "$sec" | grep -c . || true)" -ge 2 ] \
        || bad+="$p / $h: **none** with no reason"$'\n'
    done
  done < <(_profiles)
  [ -z "$bad" ] || { printf 'trailing-heading contract:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1505 the Gate clause table covers every runner-less profile" {
  # The tripwire the roster count is to the sweep: the accumulator below reports
  # clean on an empty table, so a session resolving a red clause could delete
  # its row and go green with no other signal.
  local n types
  n="$(_gate_clauses | grep -c . || true)"
  [ "$n" -eq 85 ] || {
    printf 'the Gate clause table holds %s row(s), expected 85.\n' "$n" >&2
    printf 'A clause earns a row when losing it puts a run back on an action a\n' >&2
    printf 'review round raised as wrong — whether or not that round blocked on\n' >&2
    printf 'it. Removing one needs that argument, in the PR.\n' >&2
    return 1
  }
  # ...and the PER-TYPE distribution, not just the total (#1558). The total
  # alone is satisfied by a SWAP: drop a row that guards a corrective clause,
  # add one naming an untouched paragraph of a DIFFERENT profile, and the count,
  # the per-type coverage loop below and the uniqueness sweep are all still
  # green — without the argument this table's header demands. Recorded the way
  # `#1505 the gate-pair rows carry the exact token count recorded` records its
  # own figure, and DERIVED from the table rather than counted by hand.
  local want row t got bad=""
  local -a expect=( 'python 9' 'java 8' 'go 14' 'swift 6' 'kubernetes 48' )
  for row in "${expect[@]}"; do
    t="${row%% *}"; want="${row##* }"
    got="$(_gate_clauses | cut -d'|' -f1 | grep -cxF -- "$t" || true)"
    [ "$got" -eq "$want" ] \
      || bad+="$t: $got row(s), expected $want"$'\n'
  done
  [ -z "$bad" ] || {
    printf 'Gate clause rows per type changed:\n%s\n' "$bad" >&2
    printf 'Moving a row between types keeps the total; record the new split.\n' >&2
    return 1
  }
  # the recorded split must ACCOUNT for every row, or a type could be added to
  # the table while this list quietly ignores it
  local summed=0
  for row in "${expect[@]}"; do summed=$(( summed + ${row##* } )); done
  [ "$summed" -eq "$n" ] || {
    printf 'the recorded per-type split sums to %s over %s rows.\n' "$summed" "$n" >&2
    return 1
  }
  # ...and every runner-less profile is represented, so a whole type cannot
  # silently fall out of the table. The required set is DERIVED, not the closed
  # hand-written list this file's header forbids (#936): a seventh runner-less
  # type must red here rather than pass on a tripwire that moved for an
  # unrelated reason.
  types="$(_gate_clauses | cut -d'|' -f1 | sort -u)"
  local p t
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    t="${p%%/*}"; t="${t#development-}"
    printf '%s\n' "$types" | grep -qxF -- "$t" \
      || { printf 'no Gate clause row for %s\n' "$t" >&2; return 1; }
  done < <(_profiles_without_runner)
}

@test "#1505 every Gate clause needle occurs exactly once in the Gate it guards" {
  # Mechanises the UNIQUE half of the rule the table's header states. A needle
  # matching twice is a needle that can go on matching an untouched neighbour
  # after the clause it guards is reverted — the `kustomize` failure, which took
  # two rounds to spot by eye. (The DISCRIMINATING half cannot be mechanised:
  # it is a claim about defective text that no longer exists.)
  local row type needle profile n bad=""
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    type="${row%%|*}"
    # Same arity guard both sibling accumulators carry: `${row#*|}` is a no-op
    # on a separator-less row, which would grep the Gate for the type's own name.
    case "$row" in
      *'|'*) needle="${row#*|}" ;;
      *) bad+="$row: row names no needle"$'\n'; continue ;;
    esac
    profile="$REPO_ROOT/development-$type/skills/resolve-profile/SKILL.md"
    [ -f "$profile" ] || continue
    # OCCURRENCES, not lines: `grep -c` counts matching LINES, so a short needle
    # recurring twice inside one wrapped markdown line — the exact shape the
    # `kustomize` failure had — would count as 1 and pass, leaving the very
    # survivable needle this sweep exists to forbid.
    n="$(_profile_section "$profile" "Gate" | grep -oF -- "$needle" | grep -c . || true)"
    [ "$n" -eq 1 ] || bad+="$type: <<$needle>> occurs $n time(s) in its Gate"$'\n'
  done < <(_gate_clauses)
  [ -z "$bad" ] || {
    printf 'non-unique Gate clause needle(s):\n%s\n' "$bad" >&2
    printf 'A needle matching more than once survives the reversion it guards.\n' >&2
    return 1
  }
}

@test "#1505 every pinned Gate clause is still in its profile" {
  local bad
  bad="$(_gate_clause_violations)"
  [ -z "$bad" ] || {
    printf 'Gate clause(s) lost — each puts a run back on an action a review\nround raised as wrong (blocking or not):\n%s\n' "$bad" >&2
    return 1
  }
}

@test "#1505 non-vacuity: a stripped Gate clause reds the sweep" {
  # Drives the REAL accumulator over a planted tree, and over a planted ROW
  # SET, so both halves — the needle check and the table walk — are shown to
  # discriminate.
  # Captured into a variable rather than piped into `grep -q`: a `-q` grep exits
  # as soon as it matches, and the still-writing accumulator upstream then takes
  # SIGPIPE and reports a write error — noise that reads like a real failure.
  local dir="$BATS_TEST_TMPDIR/clause-probe" out
  local rel="development-go/skills/resolve-profile/SKILL.md"
  mkdir -p "$dir/development-go/skills/resolve-profile"
  grep -vF -- 'unconditionally' "$REPO_ROOT/$rel" > "$dir/$rel"
  out="$(_gate_clause_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'go: Gate lost <<unconditionally>>'
  # an empty needle is named rather than matching everything
  _planted_empty_clause_row() { printf '%s\n' 'go|'; }
  out="$(_gate_clause_violations "$REPO_ROOT" _planted_empty_clause_row)"
  printf '%s\n' "$out" | grep -qF -- 'empty needle in its _gate_clauses row'
  # ...and a row that lost its separator entirely is named too, rather than
  # degenerating into grepping the Gate for the type's own name (always a match)
  _planted_tokenless_clause_row() { printf '%s\n' 'go'; }
  out="$(_gate_clause_violations "$REPO_ROOT" _planted_tokenless_clause_row)"
  printf '%s\n' "$out" | grep -qF -- 'go: row names no needle'
  # ...and the real tree passes the real table
  [ -z "$(_gate_clause_violations)" ]
}

@test "#1505 the kubernetes render delegation resolves at the file it points at" {
  # The round-1 CRITICAL's remedy is a POINTER, so it has two failure modes and
  # the clause table only covers one. This is the other: the referenced file
  # keeping the set the profile tells a model to read there.
  local review="$REPO_ROOT/development-kubernetes/skills/review/SKILL.md"
  local gate
  gate="$(_profile_section \
    "$REPO_ROOT/development-kubernetes/skills/resolve-profile/SKILL.md" "Gate")"
  printf '%s' "$gate" | grep -qF -- 'development-kubernetes/skills/review/SKILL.md' \
    || { echo "the kubernetes Gate no longer names the file it defers to" >&2; return 1; }
  [ -f "$review" ] || { echo "the referenced review skill is gone" >&2; return 1; }
  grep -qF -- 'Skip what the CI render job skips' "$review" || {
    echo "the review skill lost the skip set the kubernetes Gate defers to —" >&2
    echo "a model told to 'read the set there' now finds none and renders" >&2
    echo "everything, which is the #1505 round-1 CRITICAL verbatim." >&2
    return 1
  }
  # #1558 added a SECOND delegation to the same file, with the same two failure
  # modes: the empty-render bullet claims the panel reports both of these as not
  # applicable, and names each of its own arms after the panel's wording. Reword
  # them there and the Gate cites a reading that no longer exists — the vacuous
  # green, back by a different door. The clause table cannot see this half,
  # because every one of its rows only ever reads the profile.
  # Bare phrase presence is too weak a needle: both phrases also appear in the
  # panel's FAILED arm's neighbourhood, so moving them there would keep this
  # green while the Gate cites a verdict the panel no longer gives. Assert the
  # ATTRIBUTION — the not-applicable sentence itself, with both phrases inside
  # it — which is the only form that can drift.
  # Read the sentence FLATTENED, not line-wise: it wraps mid-parenthetical in
  # the shipped file, so a `grep` of single lines can never hold both phrases
  # and would fail on correct text. Flatten, then take the window that follows
  # the verdict marker.
  local flat na
  flat="$(tr '\n' ' ' < "$review" | tr -s ' ')"
  case "$flat" in
    *'explicitly **not applicable**'*) na="${flat#*explicitly \*\*not applicable\*\*}" ;;
    *) echo "the review skill no longer states a not-applicable verdict at all," >&2
       echo "which the kubernetes Gate's empty-set bullet cites as the panel's" >&2
       echo "own reading of the same input (#1558)." >&2
       return 1 ;;
  esac
  # the attribution is the parenthetical the marker introduces, so bound the
  # window rather than searching the rest of the file — otherwise the phrases
  # could satisfy this from the FAILED arm further down, which is the very
  # mutation this assertion exists to catch.
  #
  # ANCHORED ON THE ADJACENT PARENTHESIS, not on the first one anywhere
  # downstream. `na` is the flattened remainder of the WHOLE file, which always
  # holds another `)` further on — so a bare `*')'*` guard can never fail, and
  # `${na%%)*}` does not no-op on a reword either: it silently retargets to that
  # farther parenthesis and widens the window from one clause to a dozen lines,
  # letting the FAILED-arm-adjacency mutation back in. Both halves have to be
  # adjacency-anchored for the refusal arm to be reachable at all.
  case "$na" in
    ' ('*) na="${na#*(}"; na="${na%%)*}" ;;
    *) echo "the review skill's not-applicable verdict no longer carries an" >&2
       echo "ADJACENT parenthetical attribution, so the one-clause window this" >&2
       echo "assertion depends on cannot be bounded — re-anchor it rather than" >&2
       echo "letting the check widen silently (#1558)." >&2
       return 1 ;;
  esac
  local phrase
  for phrase in 'nothing to render at all' 'nothing in scope rendered'; do
    case "$na" in *"$phrase"*) : ;; *)
      printf 'the review skill no longer attributes <<%s>> to its\n' "$phrase" >&2
      echo "NOT-APPLICABLE verdict — the Gate cites a reading the panel has" >&2
      echo "stopped making, so the two diverge on exactly the input the" >&2
      echo "empty-set bullet is about (#1558)." >&2
      return 1 ;;
    esac
    printf '%s' "$gate" | grep -qF -- "$phrase" || {
      printf 'the kubernetes Gate no longer cites <<%s>>, so the\n' "$phrase" >&2
      echo "delegation this test guards was dropped rather than moved." >&2
      return 1
    }
  done
  # #1558 added two MORE pointers at the same file, and a pointer's second
  # failure mode is the target moving. The loop walks FOUR pairs, and they are
  # not all the same strength. The first two far sides are additionally pinned
  # by tests/kubernetes-plugin-skeleton.bats (the review skill's own suite), so
  # those assertions are co-location rather than the only guard: a break should
  # name the Gate that delegates, not leave a reader to connect a skeleton
  # assertion three files away to an arm misfiring on a values.yaml-only edit.
  # Pairs 3 and 4 are DIFFERENT. The panel's dispatch enumeration and the
  # carve-out that closes it are asserted nowhere else in this repo, so these
  # two ARE the only guard on them and must not be pruned as redundant.
  local pointer target
  for pointer in \
    'read the composition there|copied in alongside it' \
    'not map-value equality|membership plus consumption' \
    'a **deleted** path that *was* a manifest|was a manifest, a chart root, or a kustomize root' \
    'a deleted path that was **none** of those|lived under none'; do
    printf '%s' "$gate" | grep -qF -- "${pointer%%|*}" || {
      printf 'the kubernetes Gate no longer delegates via <<%s>>\n' "${pointer%%|*}" >&2
      return 1
    }
    target="${pointer#*|}"
    grep -qF -- "$target" "$review" || {
      printf 'the review skill no longer supplies <<%s>>, which the\n' "$target" >&2
      echo "kubernetes Gate defers to rather than restating. A model told to" >&2
      echo "'read it there' finds nothing, falls back on map-value equality," >&2
      echo "and the change-relative arm misfires on a values.yaml-only edit" >&2
      echo "or a deletion-only diff (#1558)." >&2
      return 1
    }
  done
}

@test "#1558 the kubernetes E4 condemnation sits in the ARMS paragraph, not the exemption" {
  # Round 4's third blocker was fixed by MOVING a sentence, and _gate_clauses is
  # structurally blind to placement: every row greps the whole Gate, so the
  # sentence can be moved back to the end of the exemption paragraph with all
  # rows still matching. Moved back, a model reading the exemption top-down
  # finishes on a sentence condemning the very close it was just ordered to
  # allow, halts E4 on a fully delivered docs-only epic, and strands it open
  # with no remedy. Position is the only thing that can catch that.
  local profile arms exemption
  profile="$REPO_ROOT/development-kubernetes/skills/resolve-profile/SKILL.md"
  [ -f "$profile" ] || { echo "no kubernetes profile at $profile" >&2; return 1; }
  arms="$(grep -n -m1 -F -- 'For the ARMS specifically' "$profile" | cut -d: -f1)"
  exemption="$(grep -n -m1 -F -- 'is deliberately NOT swept into that' "$profile" | cut -d: -f1)"
  # Guard each anchor: a deleted one yields an empty string, and `-lt` on empties
  # is a syntax error rather than a named failure — the same arity discipline the
  # clause accumulators carry.
  [ -n "$arms" ] || {
    echo "the ARMS paragraph no longer carries its explicit subject, so the" >&2
    echo "vacuous-green condemnation has no stated owner (#1558)." >&2
    return 1
  }
  [ -n "$exemption" ] || {
    echo "the E4 exemption paragraph is gone — a docs-only epic has no arm" >&2
    echo "that lets E5 close it (#1558)." >&2
    return 1
  }
  [ "$arms" -lt "$exemption" ] || {
    printf 'the condemnation (line %s) now follows the exemption (line %s):\n' \
      "$arms" "$exemption" >&2
    echo "a reader finishing the exemption top-down meets a sentence calling" >&2
    echo "its own prescribed close the vacuous green the heading refuses, and" >&2
    echo "strands a delivered docs-only epic permanently open (#1558)." >&2
    return 1
  }
}

@test "#1558 the kubernetes preconditions are ordered, and both precede the arms" {
  # The profile calls this order load-bearing in as many words — "both before
  # either arm, and IN THIS ORDER" — because the two preconditions END
  # DIFFERENTLY: the deploy-relevant-path test proceeds, the tool-availability
  # test halts. Every clause row greps the whole Gate, so all of them survive a
  # swap of the two numbered items; only position can catch it.
  local profile deploy tools block arms
  profile="$REPO_ROOT/development-kubernetes/skills/resolve-profile/SKILL.md"
  [ -f "$profile" ] || { echo "no kubernetes profile at $profile" >&2; return 1; }
  deploy="$(grep -n -m1 -F -- 'Ask whether the diff carries a deploy-relevant path at all' \
    "$profile" | cut -d: -f1)"
  tools="$(grep -n -m1 -F -- 'Establish the applicable tool set and whether it is installed' \
    "$profile" | cut -d: -f1)"
  block="$(grep -n -m1 -F -- 'Two preconditions first' "$profile" | cut -d: -f1)"
  arms="$(grep -n -m1 -F -- 'Then the two arms' "$profile" | cut -d: -f1)"
  # Guard every anchor before comparing: an empty capture makes `-lt` a syntax
  # error rather than a named failure, the arity discipline the clause
  # accumulators carry. Spelled out rather than looped over variable NAMES —
  # bats runs under bash, where zsh's `${(P)name}` indirection is a hard error.
  local bad=""
  [ -n "$deploy" ] || bad+="the deploy-relevant-path precondition"$'\n'
  [ -n "$tools" ]  || bad+="the tool-availability precondition"$'\n'
  [ -n "$block" ]  || bad+="the 'Two preconditions first' block opener"$'\n'
  [ -n "$arms" ]   || bad+="the 'Then the two arms' opener"$'\n'
  [ -z "$bad" ] || {
    printf 'the kubernetes Gate lost these anchors, so the precondition order\n' >&2
    printf 'cannot be checked — re-anchor them rather than dropping the\n' >&2
    printf 'assertion (#1558):\n%s\n' "$bad" >&2
    return 1
  }
  [ "$deploy" -lt "$tools" ] || {
    printf 'the tool-availability precondition (line %s) now precedes the\n' "$tools" >&2
    printf 'deploy-relevant-path one (line %s).\n' "$deploy" >&2
    echo "A model reading the list top-down then establishes the tool set" >&2
    echo "first and takes its halt on a docs-only diff in a repo with no" >&2
    echo "helm installed — the docs-only story held up by a renderer it never" >&2
    echo "needed, which is the seam #1558 fixed." >&2
    return 1
  }
  [ "$block" -lt "$arms" ] || {
    printf 'the precondition block (line %s) no longer precedes the arms\n' "$block" >&2
    printf '(line %s), which the Gate requires with "both before either arm":\n' "$arms" >&2
    echo "an arm reached on a false premise ends a story that should ship." >&2
    return 1
  }
}

@test "#1558 the java/python coverage-guard claims resolve at the script itself" {
  # The §6 carry-forward paragraphs make FALSIFIABLE claims about a script no
  # _gate_pairs row covers: those rows anchor each Gate to its ci-fixer agent,
  # and this is a different file. A --lang the script does not accept, or an exit
  # code it does not return, sends a model down an arm that cannot fire — on
  # `--lang jvm` it gets exit 2, which the profile's own "only on exit 1" wording
  # then turns into a push with no coverage report.
  local guard="$REPO_ROOT/development/skills/bootstrap/scripts/ensure-coverage-precondition.zsh"
  [ -f "$guard" ] || { echo "the coverage guard the profiles cite is gone" >&2; return 1; }
  local bad="" lang sec profile
  # LOOP-INVARIANT, so it is asserted once: inside the loop a changed usage line
  # would accumulate the identical diagnostic twice and read as two defects.
  grep -qF -- '--lang <python|java|swift>' "$guard" \
    || bad+="the guard's usage line no longer spells the accepted --lang set"$'\n'
  for lang in python java; do
    profile="$REPO_ROOT/development-$lang/skills/resolve-profile/SKILL.md"
    # the same [ -f ] guard both sibling accumulators carry: without it a
    # deleted profile aborts this test under errexit instead of being NAMED.
    [ -f "$profile" ] || { bad+="$lang: no profile at $profile"$'\n'; continue; }
    sec="$(_profile_section "$profile" "Gate")"
    # The SCRIPT NAME and the flag together, not the flag alone — that is what
    # makes this a pairing. Renaming the script in the profile (to one that does
    # not exist) leaves a bare `--lang java` grep matching, and §6 then invokes
    # nothing and gets no verdict at all, which is the unconditional halt seam 5
    # removed wearing a new coat.
    printf '%s' "$sec" \
      | grep -qF -- "ensure-coverage-precondition.zsh --lang $lang" \
      || bad+="$lang: its Gate no longer names ensure-coverage-precondition.zsh --lang $lang"$'\n'
  done
  # the three exit codes the profiles now branch on are the three it documents
  grep -qF -- '#   0  no report needed' "$guard" \
    || bad+="the guard no longer documents exit 0 as no-report-needed"$'\n'
  grep -qF -- '#   1  covered-language files present' "$guard" \
    || bad+="the guard no longer documents exit 1 as report-missing"$'\n'
  grep -qF -- '#   2  usage error' "$guard" \
    || bad+="the guard no longer documents exit 2 as a usage error"$'\n'
  # exit 0's SECOND cause, which the python profile branches on explicitly
  grep -qF -- 'OR report already present' "$guard" \
    || bad+="the guard no longer documents exit 0's report-already-present cause"$'\n'
  # the go profile's claim that `--lang go` is a usage error rather than a
  # verdict, asserted from the other side: a `go)` arm added to the selector
  # would falsify it with every other check still green.
  # An alternation is the natural way to add a language sharing another's globs,
  # and a bare `^go\)` misses it — leaving the check named for the go claim
  # unable to falsify it. Match `go` in ANY position: requiring it last would
  # still miss `go|swift)`, which is just as natural a spelling.
  if grep -qE -- '^[[:space:]]*([a-z]+\|)*go(\||\))' "$guard"; then
    bad+="the guard now accepts --lang go, so the go profile's claim is false"$'\n'
  fi
  [ -z "$bad" ] || {
    printf 'coverage-guard claim drift:\n%s\n' "$bad" >&2
    return 1
  }
}

@test "#1505 every runner-less profile's Version bump opens with none, and keeps its floor" {
  # §4 DEREFERENCES this heading, and nothing read its body for any profile but
  # the exemplar — so replacing a body with "bump on every change" left the
  # suite green while every run of that type performed a §4 bump on a repo with
  # no <plugin>/ subject. The four language profiles additionally carry a
  # CONDITIONAL none, because a detected language beats the claude-plugin
  # fallback: a language repo that also ships plugin content loads this profile,
  # and an unconditional none would supersede §4's floor rather than narrow it.
  local bad
  bad="$(_version_bump_violations)"
  [ -z "$bad" ] || { printf 'Version bump contract:\n%s\n' "$bad" >&2; return 1; }
}

@test "#1505 non-vacuity: each Version bump branch reds on its own mutation" {
  # Drives the REAL accumulator over planted trees rather than re-greping a
  # copied needle — the shape `_profile_is_tracked` was extracted for, and this
  # file's stated convention. A control holding its own copy of the needle
  # cannot see the check's needle weakened, which is the mutation that matters.
  # Captured rather than piped into `grep -q` — see the sibling control for why.
  local dir="$BATS_TEST_TMPDIR/vb-probe" out
  local rel="development-python/skills/resolve-profile/SKILL.md"
  local real="$REPO_ROOT/$rel"
  mkdir -p "$dir/development-python/skills/resolve-profile"

  # Replace the body wholesale: a bold directive, not a **none rule at all.
  _plant_vb "$rel" '**Bump this plugin manifest on every change.**' > "$dir/$rel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'does not OPEN with **none'

  # PREPEND a contradictory directive, leaving the conditional paragraphs
  # below. A check that only asked whether a `**none` line EXISTS somewhere
  # passes this, while §4's reader — who reads top-down — meets the bump first.
  awk '
    /^## Version bump$/ { print; print ""; print "**Bump the plugin manifests on every change.**"; next }
    { print }
  ' "$real" > "$dir/$rel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'does not OPEN with **none'

  # A PLAIN-PROSE prepend — the shape the carried blocker literally named. It is
  # not bold, so the first-bold-line rule alone cannot see it.
  awk '
    /^## Version bump$/ { print; print ""; print "Bump plugin.json and marketplace.json on every change."; next }
    { print }
  ' "$real" > "$dir/$rel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'states a directive ABOVE its **none rule'

  # ...and one carrying NO manifest filename, so only the anchored `bump`
  # alternative can catch it. Without this the plant above satisfies all three
  # alternatives at once, and the anchored one could be deleted unnoticed.
  awk '
    /^## Version bump$/ { print; print ""; print "Bump the plugin manifests on every change."; next }
    { print }
  ' "$real" > "$dir/$rel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'states a directive ABOVE its **none rule'

  # An UNCONDITIONAL none: it opens correctly, so the opener arm passes and the
  # three conditional needles are what must fire. This is the mutation the
  # carried blocker was filed against, and the reason the check exists.
  _plant_vb "$rel" '**none** — nothing to bump in a repo of this type.' > "$dir/$rel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'is not the CONDITIONAL none'
  printf '%s\n' "$out" | grep -qF -- "the floor's marketplace half"
  printf '%s\n' "$out" | grep -qF -- 'must not supersede the floor'

  # ...and the kubernetes arm's own reason, which is a different needle
  local krel="development-kubernetes/skills/resolve-profile/SKILL.md"
  mkdir -p "$dir/development-kubernetes/skills/resolve-profile"
  _plant_vb "$krel" '**none** — nothing to bump.' > "$dir/$krel"
  out="$(_version_bump_violations "$dir")"
  printf '%s\n' "$out" | grep -qF -- 'does not say WHY none holds here'

  # ...and the real tree passes the same accumulator
  [ -z "$(_version_bump_violations)" ]
}

@test "#1505 every app-type profile names where a type-specific rule would come from" {
  # The five #1505 profiles defer their three `none` headings to #1502's
  # read-out. Pinning the pointer keeps "none" a DECISION with a named trigger
  # rather than an omission — the exemplar defers to #1506 instead, which is why
  # this is scoped to the profiles with no attestable runner.
  #
  # Scoped PER HEADING, not per file: a whole-file grep passes on one surviving
  # mention, so the pointer could be deleted from two of the three headings with
  # the check still clean.
  local p h bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    for h in "Fix-pass rules" "Documentation expectations" "Residue"; do
      _profile_section "$REPO_ROOT/$p" "$h" | grep -qF -- '#1502' \
        || bad+="$p / $h: names no evidence source"$'\n'
    done
  done < <(_profiles_without_runner)
  [ -z "$bad" ] || {
    printf 'heading(s) whose `none` names no evidence source:\n%s\n' "$bad" >&2
    return 1
  }
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
  [ "$(_moved_needles | grep -c . || true)" -eq 5 ]
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
  n="$(grep -oF -- "$POINTER" "$CONDUCTOR" | grep -c . || true)"
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
  derived="$(_profiles | grep -c . || true)"
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
  derived="$(_profiles | grep -c . || true)"
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
