#!/usr/bin/env bats
#
# #1492 — two families of cross-reference that #1434 minted or extended, each
# swept by a DERIVED roster so neither can rot silently.
#
#   1. `§N.M` SECTION POINTERS. `resolve-story-loop.zsh` tells its caller "see
#      §3.5 step 2", and the review panels, the resolve profiles, ARCHITECTURE.md
#      and resolve-issue's own reference files route to `/development:resolve-issue`
#      §3.5. A pointer resolves when development/skills/resolve-issue/SKILL.md has a
#      line beginning `### N.M `. A pointer whose own line names another document
#      (`design doc`, `design spec`, `SETUP.md`) is FOREIGN and exempt — counted,
#      and the count asserted exactly, so a new foreign pointer is a deliberate
#      edit. Every step-2 spelling additionally resolves to the review-loop.md
#      item titled `2. **One loop invocation.**` (found by that title, never by
#      position), whose span must still carry the arms the pointers name. Other
#      `step N` pointers index a different numbered list and are out of scope.
#
#   2. WORK-DIR ARTIFACT NAMES. The script is the source of truth: every
#      `$work_dir/…` stem resolve-story-loop.zsh names. Every `<work-dir>/…`
#      spelling in the swept markdown must normalise to one of those stems, or be
#      a recorded session-written exception, of which there may be none. Bare
#      mentions without the `<work-dir>/` prefix are out of scope: the prefix is
#      what makes a match an artifact reference rather than unrelated prose.
#
# SWEPT FILES: `git ls-files '*.md' '*.zsh' '*.sh' '*.json'` minus
# `docs/superpowers/**` (historical, never edited) and `tests/**` (fixtures are
# historical; the bats suites quote pointers as needles). Bootstrap `*.tmpl`
# templates fall outside the extensions on purpose — their `§N.M` point at the
# generated repo's own SETUP.md.
#
# TRIPWIRES. Every figure is read back OUT of the sweep's own row in
# MAINTAINING.md's *Invariants in force*, so a pointer or an artifact site
# appearing or vanishing reds this suite until that row is updated in the same PR.
#
# MUTATION CONTROLS (MAINTAINING.md, *Carry a non-vacuity control*), each run
# over a throwaway copy of the real sites through the SAME functions:
#   pointer sweep  — prose site: ARCHITECTURE.md §3.5 → §3.9
#                  — code site:  resolve-story-loop.zsh §3.5 → §3.9
#                  — renumbered heading: SKILL.md `### 3.5 ` → `### 3.6 `
#                  — removed arm: review-loop.md's NOT-APPLICABLE-on-a-full-round line,
#                    and the STALE_FINDINGS arm's title
#                  — renamed `## The round protocol`, the far end of SKILL.md's route
#   artifact sweep — prose site: review-loop.md `<work-dir>/tree-` renamed
#                  — code site:  the script's `$work_dir/.closing-sweep` renamed

bats_require_minimum_version 1.5.0

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export LC_ALL=C
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SKILL_REL='development/skills/resolve-issue/SKILL.md'
  LOOP_DIR_REL='development/skills/resolve-issue/reference/review-loop'
  # Since #2055 the round protocol is sharded: the step-2 item opens in
  # STEP2_SHARD and its recovery arms continue in RECOVER_SHARD, step 3 opens in
  # STEP3_SHARD, and `## The round protocol` heads CORE_SHARD.
  CORE_SHARD="$LOOP_DIR_REL/core.md"
  STEP2_SHARD="$LOOP_DIR_REL/step-2-invocation.md"
  RECOVER_SHARD="$LOOP_DIR_REL/exit-2-stale-findings.md"
  STEP3_SHARD="$LOOP_DIR_REL/exit-20-awaiting-fix.md"
  ARTIFACT_SHARD="$LOOP_DIR_REL/step-1-panel.md"
  SCRIPT_REL='development/skills/resolve-issue/scripts/resolve-story-loop.zsh'
  STEP2_TITLE='2. **One loop invocation.**'
  STEP3_TITLE='3. **On `AWAITING_FIX`'
  ROUTE='see `reference/review-loop/core.md` § The round protocol'
  POINTER_ROW='**resolve-issue section pointers**'
  ARTIFACT_ROW='**Work-dir artifact names**'
  REFPTR_ROW='**resolve-issue reference pointers**'
}

# Every swept file in the git work tree $1, repo-relative, one per line.
swept_files_in() {
  git -C "$1" ls-files -z -- '*.md' '*.zsh' '*.sh' '*.json' \
    ':!:docs/superpowers/**' ':!:tests/**' | tr '\0' '\n' | sort
}

# ---------------------------------------------------------------------------
# 1. §N.M pointers
# ---------------------------------------------------------------------------

# One row per pointer OCCURRENCE: file TAB line TAB N.M TAB foreign(0|1).
# Foreignness is judged on the pointer's own line.
pointers_in() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    awk -v f="$f" '
      {
        foreign = (index($0, "design doc") || index($0, "design spec") || index($0, "SETUP.md")) ? 1 : 0
        rest = $0
        while (match(rest, "§[0-9]+[.][0-9]+")) {
          p = substr(rest, RSTART, RLENGTH); gsub(/[^0-9.]/, "", p)
          printf "%s\t%d\t%s\t%d\n", f, NR, p, foreign
          rest = substr(rest, RSTART + RLENGTH)
        }
      }' "$root/$f"
  done < <(swept_files_in "$root")
}

# The `### N.M ` section numbers SKILL.md declares, one per line.
skill_sections_in() {
  awk '/^### [0-9]+[.][0-9]+ / { print $2 }' "$1/$SKILL_REL"
}

# Every non-foreign pointer whose target section SKILL.md does not declare.
unresolved_pointers_in() {
  local root="$1" sections
  sections="$(skill_sections_in "$root")"
  pointers_in "$root" | awk -F'\t' -v s="$sections" '
    BEGIN { n = split(s, a, "\n"); for (i = 1; i <= n; i++) have[a[i]] = 1 }
    $4 == 0 && !($3 in have) { printf "%s:%s: §%s has no `### %s ` heading\n", $1, $2, $3, $3 }'
}

# A file flattened to one line: leading indentation and one comment/quote marker
# stripped per line, so a pointer wrapped across two lines (`§3.5` / `step 2`),
# in prose or in a `#` comment, still reads as one phrase.
flatten_file() {
  awk '{ sub(/^[ \t]*[#>]*[ \t]*/, ""); printf "%s ", $0 }' "$1" | tr -s ' '
}

# The step-2 spellings: `§3.5 step 2`, `§3.5's *Each round* step 2` and
# `§3.5 *Each round* step-2`. Other step numbers are a different list.
STEP2_RE="§3[.]5('s)? ([*]Each round[*] )?step[- ]2([^0-9]|\$)"

# One row per file carrying step-2 pointers: file TAB count.
step2_pointers_in() {
  local root="$1" f n
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n="$(flatten_file "$root/$f" | grep -oE -- "$STEP2_RE" | wc -l | tr -d ' ')"
    [ "$n" -gt 0 ] && printf '%s\t%s\n' "$f" "$n"
  done < <(swept_files_in "$root")
  return 0
}

# Every file of the review-loop shard tree in work tree $1, repo-relative.
loop_shards_in() {
  (cd "$1" && find "$LOOP_DIR_REL" -type f -name '*.md' | sort)
}

# Every shard of $1 whose lines BEGIN with $2, one per line, once per occurrence.
title_sites_in() {
  local root="$1" title="$2" f
  while IFS= read -r f; do
    awk -v a="$title" -v f="$f" 'index($0, a) == 1 { print f }' "$root/$f"
  done < <(loop_shards_in "$root")
}

# The step-2 item's span across the cut (#2055): STEP2_SHARD from the line
# beginning with its title to that file's end, then the whole of RECOVER_SHARD,
# where step 2's recovery arms continue.
step2_span_in() {
  awk -v a="$STEP2_TITLE" 'index($0, a) == 1 { on = 1 } on { print }' "$1/$STEP2_SHARD"
  cat -- "$1/$RECOVER_SHARD"
}

# What is wrong with the step-2 target, one problem per line; nothing when sound.
step2_target_problems_in() {
  local root="$1" sites span
  sites="$(title_sites_in "$root" "$STEP2_TITLE")"
  [ "$sites" = "$STEP2_SHARD" ] || {
    printf 'step-2 title must appear exactly once across %s, in %s (found: %s)\n' \
      "$LOOP_DIR_REL" "$STEP2_SHARD" "$(printf '%s' "$sites" | tr '\n' ' ')"; return 0; }
  sites="$(title_sites_in "$root" "$STEP3_TITLE")"
  [ "$sites" = "$STEP3_SHARD" ] || {
    printf 'step-3 title must appear exactly once across %s, in %s (found: %s)\n' \
      "$LOOP_DIR_REL" "$STEP3_SHARD" "$(printf '%s' "$sites" | tr '\n' ' ')"; return 0; }
  # the far end of SKILL.md's route: `## The round protocol` heads the core shard
  sites="$(title_sites_in "$root" '## The round protocol')"
  [ "$sites" = "$CORE_SHARD" ] \
    || printf '## The round protocol does not sit in %s (found: %s)\n' "$CORE_SHARD" "$(printf '%s' "$sites" | tr '\n' ' ')"
  span="$(step2_span_in "$root" | tr '\n' ' ' | tr -s ' ')"
  local needle
  # each needle is the arm's own title, unique in the span — a bare
  # `STALE_FINDINGS` would be satisfied by the span's passing mentions
  for needle in 'NOT APPLICABLE on a full round' '**`STALE_FINDINGS` (exit 2'; do
    grep -qF -- "$needle" <<< "$span" \
      || printf 'step-2 span lacks the arm: %s\n' "$needle"
  done
}

# Empty when SKILL.md's `### 3.5 ` section still routes to the round protocol.
route_problem_in() {
  local section
  section="$(awk '
    /^### 3[.]5 / { on = 1; print; next }
    on && (/^### / || /^## /) { exit }
    on { print }' "$1/$SKILL_REL")"
  [ -n "$section" ] || { printf 'SKILL.md has no `### 3.5 ` section\n'; return 0; }
  grep -qF -- "$ROUTE" <<< "$section" \
    || printf 'SKILL.md `### 3.5` no longer carries the route: %s\n' "$ROUTE"
}

# ---------------------------------------------------------------------------
# 2. work-dir artifact names
# ---------------------------------------------------------------------------

# A stem: filename characters plus the round tokens the normaliser rewrites.
STEM_RE='([A-Za-z0-9._-]|\$\(\([^)]*\)\)|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|<[^>]*>|\*)+'

# Normalise stdin, one reference per line: drop the `<work-dir>/` / `$work_dir/`
# prefix (quoted or braced), rewrite every round token — `<…>`, `$((…))`,
# `$name`, a glob `*` — to `<N>`, and drop a trailing sentence period.
normalise_stems() {
  sed -E \
    -e 's#^(<work-dir>|"?\$\{?work_dir\}?"?)/##' \
    -e 's#\$\(\([^)]*\)\)#<N>#g' \
    -e 's#\$\{?[A-Za-z_][A-Za-z0-9_]*\}?#<N>#g' \
    -e 's#<[^>]*>#<N>#g' \
    -e 's#\*#<N>#g' \
    -e 's#\.+$##'
}

# The distinct stems the script names (the source of truth).
script_stems_in() {
  grep -oE -- "\"?\\\$\\{?work_dir\\}?\"?/$STEM_RE" "$1/$SCRIPT_REL" \
    | normalise_stems | sort -u
}

# One row per prose instruction site: file TAB normalised stem.
prose_stems_in() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in *.md) ;; *) continue ;; esac
    grep -oE -- "<work-dir>/$STEM_RE" "$root/$f" | normalise_stems \
      | awk -v f="$f" '{ printf "%s\t%s\n", f, $0 }'
  done < <(swept_files_in "$root")
  return 0
}

# The session-written exceptions, read out of the artifact row.
recorded_exceptions_in() {
  grep -F -- "$ARTIFACT_ROW" "$1/MAINTAINING.md" \
    | grep -oE 'session-written exceptions?: (`[^`]+`(, )?)+' \
    | grep -oE '`[^`]+`' | tr -d '`' | sort -u || true
}

# Every prose stem that is neither a script stem nor a recorded exception,
# plus every exception that is stale (no prose site, or the script now writes it).
artifact_problems_in() {
  local root="$1" script prose exc s
  script="$(script_stems_in "$root")"
  prose="$(prose_stems_in "$root")"
  exc="$(recorded_exceptions_in "$root")"
  while IFS=$'\t' read -r f s; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" <<< "$script" && continue
    grep -qxF -- "$s" <<< "$exc" && continue
    printf '%s: <work-dir>/%s is not a stem resolve-story-loop.zsh writes\n' "$f" "$s"
  done <<< "$prose"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    grep -qxF -- "$s" <<< "$(cut -f2 <<< "$prose")" \
      || printf 'recorded exception %s has no prose site\n' "$s"
    grep -qxF -- "$s" <<< "$script" \
      && printf 'recorded exception %s is a script stem, not session-written\n' "$s"
  done <<< "$exc"
  return 0
}

# ---------------------------------------------------------------------------
# 3. reference/<path>.md pointers (#2055)
# ---------------------------------------------------------------------------

# The files whose `reference/<path>.md` mentions name resolve-issue's own
# reference tree: SKILL.md, every file under reference/, the resolve-issue
# scripts, the round subagents, every resolve profile, ARCHITECTURE.md and
# MAINTAINING.md. Other skills' docs name `docs/reference/…`, which the mention
# pattern below already excludes by its left boundary.
refptr_files_in() {
  git -C "$1" ls-files -- \
    'development/skills/resolve-issue/SKILL.md' \
    'development/skills/resolve-issue/reference/**' \
    'development/skills/resolve-issue/scripts/*' \
    'development/agents/round-*.md' \
    '*/skills/resolve-profile/SKILL.md' \
    ARCHITECTURE.md MAINTAINING.md | sort
}

# One row per mention: file TAB path TAB title (empty when no `§` follows).
# A mention is `reference/<path>.md`, optionally prefixed by
# `development/skills/resolve-issue/`, `resolve-issue/` or `<skill-base-dir>/`,
# and otherwise never preceded by a path character — so `docs/reference/x.md` is
# not one. A title is the `§` that follows (after an
# optional closing backtick and comma, across a line break): an italic
# `*…*` title, whitespace-flattened, or else the rest of that line.
refptr_mentions_in() {
  local root="$1" f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # The name rides in the environment: under `-n`, a second ARGV entry would
    # be opened as an input file rather than read as the name.
    REFPTR_FILE="$f" perl -0777 -ne '
      my $f = $ENV{REFPTR_FILE};
      while (/(?:(?<![\w.\/-])(?:development\/skills\/)?resolve-issue\/|<skill-base-dir>\/|(?<![\w.\/-]))reference\/([\w\/.-]+?\.md)(`?,?[ \t]*\n?[ \t]*(?:[#>][ \t]*)?§[ \t]*(?:\*([^*]+)\*|([^\n]*)))?/g) {
        my ($p, $t) = ($1, defined $3 ? $3 : (defined $4 ? $4 : ""));
        $t =~ s/\s+/ /g; $t =~ s/^ | $//g;
        print "$f\treference/$p\t$t\n";
      }' "$root/$f" </dev/null
  done < <(refptr_files_in "$root")
}

# The headings of a reference file, `#`s and surrounding `*` stripped.
headings_of() {
  awk '/^#{1,6} / { sub(/^#+ +/, ""); gsub(/^[*]|[*]$/, ""); print }' "$1"
}

# Every mention whose file does not exist under resolve-issue/, and every title
# that names no heading of that file. A title matches a heading it equals, or
# shares a word-bounded prefix with: the title begins with the heading — so
# `§ The round protocol, step 3` resolves to `## The round protocol` — or the
# heading begins with the title — so the short form `§ *The risk pass*` resolves
# to `### The risk pass — assess every blocking finding …`. In both directions
# the character after the shorter one must not be a word character, so a title
# never matches a heading that merely shares its first letters.
refptr_problems_in() {
  local root="$1" f p t target heads
  while IFS=$'\t' read -r f p t; do
    [ -n "$p" ] || continue
    target="$root/development/skills/resolve-issue/$p"
    [ -f "$target" ] || { printf '%s: %s does not exist\n' "$f" "$p"; continue; }
    [ -n "$t" ] || continue
    heads="$(headings_of "$target")"
    T="$t" H="$heads" perl -e '
      my $t = $ENV{T};
      for my $h (split /\n/, $ENV{H}) {
        exit 0 if $t eq $h;
        exit 0 if index($t, $h) == 0 && substr($t, length $h, 1) !~ /\w/;
        exit 0 if index($h, $t) == 0 && substr($h, length $t, 1) !~ /\w/;
      }
      exit 1' || printf '%s: %s § %s names no heading in that file\n' "$f" "$p" "$t"
  done < <(refptr_mentions_in "$root")
  return 0
}

# ---------------------------------------------------------------------------
# helpers shared by the tripwires and the mutation controls
# ---------------------------------------------------------------------------

# The figure preceding $3 in the MAINTAINING.md row labelled $2 of work tree $1.
row_figure() {
  grep -F -- "$2" "$1/MAINTAINING.md" | grep -oE "[0-9]+ $3" | sed -n 1p | grep -oE '^[0-9]+' || true
}

# Build a throwaway git work tree under $1 holding every swept file that carries
# a pointer or an artifact reference, plus the targets and MAINTAINING.md, at
# their real repo-relative paths. Files carrying neither contribute nothing to
# any derivation, so every derived figure is the real one. The `|| true` on the
# filtering loop is load-bearing: under errexit a LAST file with no match ends
# that pipeline at 1 and aborts the whole group, silently dropping every listing
# after it — which went unseen while every target also carried a pointer (#2055).
make_fixture_repo() {
  local dest="$1" f
  mkdir -p "$dest"
  git -C "$dest" init -q
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$dest/$(dirname "$f")"
    cp -- "$REPO_ROOT/$f" "$dest/$f"
  done < <({
    swept_files_in "$REPO_ROOT" | while IFS= read -r f; do
      grep -qE -e '§[0-9]' -e '<work-dir>/' "$REPO_ROOT/$f" && printf '%s\n' "$f"
    done || true
    printf '%s\n' "$SKILL_REL" "$SCRIPT_REL" MAINTAINING.md
    loop_shards_in "$REPO_ROOT"
    refptr_files_in "$REPO_ROOT"
  } | sort -u)
  git -C "$dest" add -A
}

# Replace the FIRST literal occurrence of $2 with $3 in file $1.
replace_first() {
  awk -v a="$2" -v b="$3" '
    !done && (i = index($0, a)) { $0 = substr($0, 1, i - 1) b substr($0, i + length(a)); done = 1 }
    { print }' "$1" > "$1.tmp" && mv -- "$1.tmp" "$1"
}

# ---------------------------------------------------------------------------
# tests — pointer sweep
# ---------------------------------------------------------------------------

@test "#1492 every resolve-issue §N.M pointer resolves to a ### N.M heading in SKILL.md" {
  [ -n "$(pointers_in "$REPO_ROOT")" ]   # non-vacuity: the roster is not empty
  run unresolved_pointers_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1492 TRIPWIRE: the pointer, foreign and step-2 counts equal the pointer row's figures" {
  local ptrs foreign step2 s_ptrs s_foreign s_step2
  ptrs="$(pointers_in "$REPO_ROOT" | awk -F'\t' '$4 == 0' | wc -l | tr -d ' ')"
  foreign="$(pointers_in "$REPO_ROOT" | awk -F'\t' '$4 == 1' | wc -l | tr -d ' ')"
  step2="$(step2_pointers_in "$REPO_ROOT" | awk -F'\t' '{ n += $2 } END { print n + 0 }')"
  s_ptrs="$(row_figure "$REPO_ROOT" "$POINTER_ROW" 'resolve-issue pointers')"
  s_foreign="$(row_figure "$REPO_ROOT" "$POINTER_ROW" 'foreign pointers')"
  s_step2="$(row_figure "$REPO_ROOT" "$POINTER_ROW" 'step-2 pointers')"
  [ -n "$s_ptrs" ] && [ -n "$s_foreign" ] && [ -n "$s_step2" ] || {
    echo "MAINTAINING.md's pointer row is missing or states no figures" >&2; return 1; }
  [ "$ptrs" = "$s_ptrs" ] || { echo "row says $s_ptrs resolve-issue pointers, derived $ptrs" >&2; return 1; }
  [ "$foreign" = "$s_foreign" ] || { echo "row says $s_foreign foreign pointers, derived $foreign" >&2; return 1; }
  [ "$step2" = "$s_step2" ] || { echo "row says $s_step2 step-2 pointers, derived $step2" >&2; return 1; }
}

@test "#1492 every step-2 spelling is recognised, including one wrapped across a comment line" {
  local fx="$BATS_TEST_TMPDIR/spellings.md"
  printf '%s\n' \
    'see §3.5 step 2 here' \
    "per §3.5's *Each round* step 2 before" \
    'the §3.5 *Each round* step-2 arm' \
    '  # wrapped §3.5' \
    '  # step 2 in a comment' \
    'but not §3.5 step 1, nor §3.5 step 20, nor §3.5 step 3' > "$fx"
  [ "$(flatten_file "$fx" | grep -oE -- "$STEP2_RE" | wc -l | tr -d ' ')" -eq 4 ]
}

@test "#1492 the step-2 item carries its NOT-APPLICABLE and STALE_FINDINGS arms, and ### 3.5 routes to it" {
  [ "$(step2_pointers_in "$REPO_ROOT" | wc -l | tr -d ' ')" -gt 0 ]
  run step2_target_problems_in "$REPO_ROOT"
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
  run route_problem_in "$REPO_ROOT"
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1492 MUTATION: the pointer sweep reds on a prose site, a code site, a renumbered heading and a removed arm" {
  local fx="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fx"
  # the untouched copy must be clean and carry the real figures, or the control proves nothing
  [ -z "$(unresolved_pointers_in "$fx")" ]
  [ -z "$(step2_target_problems_in "$fx")" ]
  [ -z "$(route_problem_in "$fx")" ]
  [ "$(pointers_in "$fx" | wc -l | tr -d ' ')" -eq "$(pointers_in "$REPO_ROOT" | wc -l | tr -d ' ')" ]

  # (a) prose site
  replace_first "$fx/ARCHITECTURE.md" '§3.5' '§3.9'
  run unresolved_pointers_in "$fx"
  [ "$(printf '%s\n' "$output" | grep -c '^ARCHITECTURE.md:.*§3.9')" -eq 1 ]
  git -C "$fx" checkout -q -- ARCHITECTURE.md

  # (b) code site
  replace_first "$fx/$SCRIPT_REL" '§3.5' '§3.9'
  run unresolved_pointers_in "$fx"
  [ "$(printf '%s\n' "$output" | grep -c "^$SCRIPT_REL:.*§3.9")" -eq 1 ]
  git -C "$fx" checkout -q -- "$SCRIPT_REL"

  # (c) renumbered heading: every pointer to §3.5 goes stale, and the route is lost
  replace_first "$fx/$SKILL_REL" '### 3.5 ' '### 3.6 '
  run unresolved_pointers_in "$fx"
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq "$(pointers_in "$REPO_ROOT" | awk -F'\t' '$4 == 0 && $3 == "3.5"' | wc -l | tr -d ' ')" ]
  run route_problem_in "$fx"
  [ -n "$output" ]
  git -C "$fx" checkout -q -- "$SKILL_REL"

  # (d) removed arm — it sits past the cut, in the recover shard
  grep -vF 'NOT APPLICABLE on a full round' "$fx/$RECOVER_SHARD" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/$RECOVER_SHARD"
  run step2_target_problems_in "$fx"
  [ "$output" = 'step-2 span lacks the arm: NOT APPLICABLE on a full round' ]
  git -C "$fx" checkout -q -- "$RECOVER_SHARD"

  # (e) removed STALE_FINDINGS arm: its title goes, the span's passing mentions stay
  grep -vF '**`STALE_FINDINGS` (exit 2' "$fx/$STEP2_SHARD" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/$STEP2_SHARD"
  run step2_target_problems_in "$fx"
  [ "$output" = 'step-2 span lacks the arm: **`STALE_FINDINGS` (exit 2' ]
  git -C "$fx" checkout -q -- "$STEP2_SHARD"

  # (f) renamed round-protocol heading: SKILL.md's route now points at nothing
  replace_first "$fx/$CORE_SHARD" '## The round protocol' '## The round procedure'
  run step2_target_problems_in "$fx"
  [ "$output" = "## The round protocol does not sit in $CORE_SHARD (found: )" ]
  git -C "$fx" checkout -q -- "$CORE_SHARD"

  # (g) the step-2 item moved into the wrong shard: its title now opens a second file
  printf '%s\n' "$STEP2_TITLE" >> "$fx/$CORE_SHARD"
  run step2_target_problems_in "$fx"
  [ "${output#step-2 title must appear exactly once}" != "$output" ]
}

# ---------------------------------------------------------------------------
# tests — artifact sweep
# ---------------------------------------------------------------------------

@test "#1492 normalisation: every round-token spelling of one artifact compares equal" {
  run normalise_stems <<'EOF'
$work_dir/tree-$(( round - 1 )).txt
<work-dir>/tree-$((R-1)).txt
<work-dir>/tree-<R-1>.txt
"$work_dir"/tree-*.txt
${work_dir}/tree-$round.txt
<work-dir>/tree-<N>.txt.
EOF
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sort -u)" = 'tree-<N>.txt' ]
}

@test "#1492 every <work-dir>/ artifact named in prose is one the loop script writes, or a recorded exception" {
  [ -n "$(script_stems_in "$REPO_ROOT")" ]
  [ -n "$(prose_stems_in "$REPO_ROOT")" ]
  run artifact_problems_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#1492 TRIPWIRE: instruction-site files, distinct stems and exceptions equal the artifact row's" {
  local files stems s_files s_stems exc derived_exc
  files="$(prose_stems_in "$REPO_ROOT" | cut -f1 | sort -u | wc -l | tr -d ' ')"
  stems="$(prose_stems_in "$REPO_ROOT" | cut -f2 | sort -u | wc -l | tr -d ' ')"
  s_files="$(row_figure "$REPO_ROOT" "$ARTIFACT_ROW" 'instruction-site files')"
  s_stems="$(row_figure "$REPO_ROOT" "$ARTIFACT_ROW" 'distinct stems')"
  [ -n "$s_files" ] && [ -n "$s_stems" ] || {
    echo "MAINTAINING.md's artifact row is missing or states no figures" >&2; return 1; }
  [ "$files" = "$s_files" ] || { echo "row says $s_files instruction-site files, derived $files" >&2; return 1; }
  [ "$stems" = "$s_stems" ] || { echo "row says $s_stems distinct stems, derived $stems" >&2; return 1; }
  # the exception list is exactly the prose stems the script does not write
  exc="$(recorded_exceptions_in "$REPO_ROOT")"
  derived_exc="$(comm -23 <(prose_stems_in "$REPO_ROOT" | cut -f2 | sort -u) <(script_stems_in "$REPO_ROOT"))"
  [ "$exc" = "$derived_exc" ] || { printf 'row exceptions:\n%s\nderived:\n%s\n' "$exc" "$derived_exc" >&2; return 1; }
}

@test "#1492 MUTATION: the artifact sweep reds on a renamed prose site and a renamed script site" {
  local fx="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fx"
  [ -z "$(artifact_problems_in "$fx")" ]
  [ "$(prose_stems_in "$fx")" = "$(prose_stems_in "$REPO_ROOT")" ]

  # (a) prose site: a review-loop shard names a tree file the script never writes
  replace_first "$fx/$ARTIFACT_SHARD" '<work-dir>/tree-' '<work-dir>/trees-'
  run artifact_problems_in "$fx"
  [ "$output" = "$ARTIFACT_SHARD: <work-dir>/trees-<N>.txt is not a stem resolve-story-loop.zsh writes" ]
  git -C "$fx" checkout -q -- "$ARTIFACT_SHARD"

  # (b) code site: the script stops writing .closing-sweep, so every prose site naming it reds
  replace_first "$fx/$SCRIPT_REL" '$work_dir/.closing-sweep' '$work_dir/.closing-sweep-flag'
  run artifact_problems_in "$fx"
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | grep -vc '/.closing-sweep is not a stem')" -eq 0 ]
}

# ---------------------------------------------------------------------------
# tests — reference/<path>.md pointer sweep (#2055)
# ---------------------------------------------------------------------------

@test "#2055 every reference/<path>.md mention resolves to a file, and every § title to a heading in it" {
  [ -n "$(refptr_mentions_in "$REPO_ROOT")" ]   # non-vacuity
  run refptr_problems_in "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#2055 the mention pattern: a wrapped italic title, a bare title, a <skill-base-dir>/ prefix, and docs/reference/ excluded" {
  local fx="$BATS_TEST_TMPDIR/m"
  mkdir -p "$fx" && git -C "$fx" init -q
  printf '%s\n' \
    'see `reference/review-loop/core.md` § The round protocol' \
    'and `reference/review-loop/carry.md` § *Carry accounting — confirmed,' \
    're-raised, unconfirmed (#1583)* governs; `docs/reference/commands.md` is not one' \
    'read `<skill-base-dir>/reference/review-loop/briefs/fix.md`' > "$fx/ARCHITECTURE.md"
  git -C "$fx" add -A
  run refptr_mentions_in "$fx"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 3 ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "$(printf 'ARCHITECTURE.md\treference/review-loop/briefs/fix.md\t')" ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "$(printf 'ARCHITECTURE.md\treference/review-loop/core.md\tThe round protocol')" ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "$(printf 'ARCHITECTURE.md\treference/review-loop/carry.md\tCarry accounting — confirmed, re-raised, unconfirmed (#1583)')" ]
}

@test "#2055 TRIPWIRE: the mention and titled-pointer counts equal the reference-pointer row's figures" {
  local mentions titled s_mentions s_titled
  mentions="$(refptr_mentions_in "$REPO_ROOT" | wc -l | tr -d ' ')"
  titled="$(refptr_mentions_in "$REPO_ROOT" | awk -F'\t' '$3 != ""' | wc -l | tr -d ' ')"
  s_mentions="$(row_figure "$REPO_ROOT" "$REFPTR_ROW" 'reference mentions')"
  s_titled="$(row_figure "$REPO_ROOT" "$REFPTR_ROW" 'titled pointers')"
  [ -n "$s_mentions" ] && [ -n "$s_titled" ] || {
    echo "MAINTAINING.md's reference-pointer row is missing or states no figures" >&2; return 1; }
  [ "$mentions" = "$s_mentions" ] || { echo "row says $s_mentions reference mentions, derived $mentions" >&2; return 1; }
  [ "$titled" = "$s_titled" ] || { echo "row says $s_titled titled pointers, derived $titled" >&2; return 1; }
}

@test "#2055 MUTATION: the reference-pointer sweep reds on a missing file and a renamed heading" {
  local fx="$BATS_TEST_TMPDIR/repo"
  make_fixture_repo "$fx"
  run refptr_problems_in "$fx"
  [ -z "$output" ] || { printf 'the untouched copy is not clean:\n%s\n' "$output" >&2; return 1; }
  [ "$(refptr_mentions_in "$fx")" = "$(refptr_mentions_in "$REPO_ROOT")" ]

  # (a) a mention whose file is gone
  replace_first "$fx/$SKILL_REL" 'reference/review-loop/core.md' 'reference/review-loop/kore.md'
  run refptr_problems_in "$fx"
  [ "$output" = "$SKILL_REL: reference/review-loop/kore.md does not exist" ]
  git -C "$fx" checkout -q -- "$SKILL_REL"

  # (b) the heading a § title names is renamed: every pointer at it reds
  replace_first "$fx/$CORE_SHARD" '## The round protocol' '## The round procedure'
  run refptr_problems_in "$fx"
  [ -n "$output" ]
  [ "$(printf '%s\n' "$output" | grep -vc 'core.md § The round protocol.* names no heading in that file')" -eq 0 ]
}
