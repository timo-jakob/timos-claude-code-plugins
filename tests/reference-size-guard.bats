#!/usr/bin/env bats
#
# #2055 — the resolve-issue reference layout's two guards. The conductor re-read
# its whole reference docs on later rounds; the fix splits each oversized file
# into a directory of shards with a short index at the old path. These guards
# keep that true:
#
#   1. SIZE — every covered file is at most 20,000 bytes, and every index at the
#      old path of a split file is at most 3,000.
#   2. SINGLE HOME — every H2–H4 heading of a split file, as it stood at the
#      split's base commit, appears exactly once across reference/**: no heading
#      dropped by the split, none duplicated into two shards.
#
# The covered set was an extendable list while the split was under way: #2055
# review-loop.md, #2056 residue.md and #2057 promotion.md each appended their
# index and directory. #2058 split interactive.md, the last file over the limit,
# so the list became the whole tree: every file under reference/, searched
# recursively, with no exemption list — a file added later is covered without
# editing this guard. SPLIT still names each split file and its base commit, for
# the single-home guard and the index limit.
#
# MUTATION CONTROLS run the same functions over a throwaway copy: a planted
# 20,001-byte shard or new file, an over-long index, a dropped heading, a
# duplicated one.

bats_require_minimum_version 1.5.0

setup() {
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  export LC_ALL=C
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  REF_REL='development/skills/resolve-issue/reference'
  MAX_BYTES=20000
  MAX_INDEX_BYTES=3000
  # Split files: NAME:BASE — the former file and the commit its headings are read at.
  SPLIT=(
    review-loop.md:98e51ea59858a3cf247d10cc841ca5f31239f985
    residue.md:98e51ea59858a3cf247d10cc841ca5f31239f985
    promotion.md:98e51ea59858a3cf247d10cc841ca5f31239f985
    interactive.md:98e51ea59858a3cf247d10cc841ca5f31239f985
  )
}

# Every covered file under reference root $1, one absolute path per line: the
# whole tree, every file, recursively (#2058).
covered_files_in() {
  find "$1" -type f | sort
}

# One problem per line for reference root $1; nothing when every limit holds.
size_problems_in() {
  local root="$1" f n s name
  while IFS= read -r f; do
    n="$(wc -c < "$f" | tr -d ' ')"
    [ "$n" -le "$MAX_BYTES" ] || printf '%s is %s bytes (max %s)\n' "${f#"$root"/}" "$n" "$MAX_BYTES"
  done < <(covered_files_in "$root")
  for s in "${SPLIT[@]}"; do
    name="${s%%:*}"
    f="$root/$name"
    [ -f "$f" ] || { printf 'the index of %s is missing\n' "$name"; continue; }
    n="$(wc -c < "$f" | tr -d ' ')"
    [ "$n" -le "$MAX_INDEX_BYTES" ] || printf 'index %s is %s bytes (max %s)\n' "$name" "$n" "$MAX_INDEX_BYTES"
  done
  return 0
}

# The H2–H4 heading lines of a split file at its base commit.
base_headings() {
  git -C "$REPO_ROOT" show "$2:$REF_REL/$1" | grep -E '^#{2,4} ' || true
}

# Every base heading that does not appear exactly once across reference root $1.
home_problems_in() {
  local root="$1" s name base h n
  for s in "${SPLIT[@]}"; do
    name="${s%%:*}" base="${s#*:}"
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      n="$(find "$root" -type f -name '*.md' -exec grep -hxF -- "$h" {} + | wc -l | tr -d ' ')"
      [ "$n" -eq 1 ] || printf '%s heading appears %s times across reference/ (want 1): %s\n' "$name" "$n" "$h"
    done < <(base_headings "$name" "$base")
  done
  return 0
}

@test "#2055 every covered reference file is at most 20,000 bytes, and every index at most 3,000" {
  [ -n "$(covered_files_in "$REPO_ROOT/$REF_REL")" ]   # non-vacuity
  # the whole tree (#2058): every tracked file under reference/ is covered
  [ "$(covered_files_in "$REPO_ROOT/$REF_REL" | wc -l | tr -d ' ')" -ge \
    "$(git -C "$REPO_ROOT" ls-files -- "$REF_REL" | wc -l | tr -d ' ')" ]
  run size_problems_in "$REPO_ROOT/$REF_REL"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#2055 every H2-H4 heading of a split file at its base commit appears exactly once across reference/" {
  local s
  for s in "${SPLIT[@]}"; do
    [ -n "$(base_headings "${s%%:*}" "${s#*:}")" ] || { echo "no base headings for $s" >&2; return 1; }
  done
  run home_problems_in "$REPO_ROOT/$REF_REL"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "#2055 MUTATION: the size guard reds on a 20,001-byte shard and an over-long index" {
  local fx="$BATS_TEST_TMPDIR/ref"
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(size_problems_in "$fx")" ]

  head -c 20001 /dev/zero | tr '\0' 'x' > "$fx/review-loop/planted.md"
  run size_problems_in "$fx"
  [ "$output" = 'review-loop/planted.md is 20001 bytes (max 20000)' ]
  rm -- "$fx/review-loop/planted.md"

  head -c 3001 /dev/zero | tr '\0' 'x' > "$fx/review-loop.md"
  run size_problems_in "$fx"
  [ "$output" = 'index review-loop.md is 3001 bytes (max 3000)' ]
}

@test "#2056 MUTATION: the guards cover reference/residue/ — an oversized shard, an over-long index, a dropped heading" {
  local fx="$BATS_TEST_TMPDIR/ref" h
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(size_problems_in "$fx")" ]
  [ -z "$(home_problems_in "$fx")" ]

  head -c 20001 /dev/zero | tr '\0' 'x' > "$fx/residue/planted.md"
  run size_problems_in "$fx"
  [ "$output" = 'residue/planted.md is 20001 bytes (max 20000)' ]
  rm -- "$fx/residue/planted.md"

  cp -- "$fx/residue.md" "$fx/residue.md.orig"
  head -c 3001 /dev/zero | tr '\0' 'x' > "$fx/residue.md"
  run size_problems_in "$fx"
  [ "$output" = 'index residue.md is 3001 bytes (max 3000)' ]
  mv -- "$fx/residue.md.orig" "$fx/residue.md"

  h='## Condition 2 — removed; the story-diff rail is upstream (#1571)'
  grep -vxF -- "$h" "$fx/residue/condition-2-removed.md" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/residue/condition-2-removed.md"
  run home_problems_in "$fx"
  [ "$output" = "residue.md heading appears 0 times across reference/ (want 1): $h" ]
}

@test "#2057 MUTATION: the guards cover reference/promotion/ — an oversized shard, an over-long index, a dropped heading" {
  local fx="$BATS_TEST_TMPDIR/ref" h
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(size_problems_in "$fx")" ]
  [ -z "$(home_problems_in "$fx")" ]

  head -c 20001 /dev/zero | tr '\0' 'x' > "$fx/promotion/planted.md"
  run size_problems_in "$fx"
  [ "$output" = 'promotion/planted.md is 20001 bytes (max 20000)' ]
  rm -- "$fx/promotion/planted.md"

  cp -- "$fx/promotion.md" "$fx/promotion.md.orig"
  head -c 3001 /dev/zero | tr '\0' 'x' > "$fx/promotion.md"
  run size_problems_in "$fx"
  [ "$output" = 'index promotion.md is 3001 bytes (max 3000)' ]
  mv -- "$fx/promotion.md.orig" "$fx/promotion.md"

  h='## Suggestion promotion on convergence — human-curated, opt-in (#994)'
  grep -vxF -- "$h" "$fx/promotion/gate.md" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/promotion/gate.md"
  run home_problems_in "$fx"
  [ "$output" = "promotion.md heading appears 0 times across reference/ (want 1): $h" ]
}

@test "#2058 MUTATION: the guards cover reference/interactive/ — an oversized shard, an over-long index, a dropped heading" {
  local fx="$BATS_TEST_TMPDIR/ref" h
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(size_problems_in "$fx")" ]
  [ -z "$(home_problems_in "$fx")" ]

  head -c 20001 /dev/zero | tr '\0' 'x' > "$fx/interactive/planted.md"
  run size_problems_in "$fx"
  [ "$output" = 'interactive/planted.md is 20001 bytes (max 20000)' ]
  rm -- "$fx/interactive/planted.md"

  cp -- "$fx/interactive.md" "$fx/interactive.md.orig"
  head -c 3001 /dev/zero | tr '\0' 'x' > "$fx/interactive.md"
  run size_problems_in "$fx"
  [ "$output" = 'index interactive.md is 3001 bytes (max 3000)' ]
  mv -- "$fx/interactive.md.orig" "$fx/interactive.md"

  h='## Interactive extension (#562-resume)'
  grep -vxF -- "$h" "$fx/interactive/extension.md" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/interactive/extension.md"
  run home_problems_in "$fx"
  [ "$output" = "interactive.md heading appears 0 times across reference/ (want 1): $h" ]
}

@test "#2058 MUTATION: the size guard covers a file at a NEW path under reference/, with no list to extend" {
  # The covered set is the whole tree, so a file nobody listed is judged too: a
  # new top-level file, a new directory, and a file that is not markdown at all.
  local fx="$BATS_TEST_TMPDIR/ref" p
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(size_problems_in "$fx")" ]
  for p in planted.md new-dir/planted.md new-dir/deeper/planted.txt; do
    mkdir -p "$(dirname "$fx/$p")"
    head -c 20001 /dev/zero | tr '\0' 'x' > "$fx/$p"
    run size_problems_in "$fx"
    [ "$output" = "$p is 20001 bytes (max 20000)" ]
    rm -- "$fx/$p"
  done
  [ -z "$(size_problems_in "$fx")" ]
}

@test "#2055 MUTATION: the single-home guard reds on a dropped heading and a duplicated one" {
  local fx="$BATS_TEST_TMPDIR/ref" h
  cp -R "$REPO_ROOT/$REF_REL" "$fx"
  [ -z "$(home_problems_in "$fx")" ]
  h='### The risk pass — assess every blocking finding before consolidating (#1921)'
  [ "$(grep -cxF -- "$h" "$fx/review-loop/risk-pass.md")" -eq 1 ]

  grep -vxF -- "$h" "$fx/review-loop/risk-pass.md" > "$fx/tmp" && mv -- "$fx/tmp" "$fx/review-loop/risk-pass.md"
  run home_problems_in "$fx"
  [ "$output" = "review-loop.md heading appears 0 times across reference/ (want 1): $h" ]

  printf '%s\n' "$h" "$h" >> "$fx/review-loop/carry.md"
  run home_problems_in "$fx"
  [ "$output" = "review-loop.md heading appears 2 times across reference/ (want 1): $h" ]
}
