#!/usr/bin/env bats
#
# The development-side persona readers find the registry through the lookup
# (#3352, a child of #3198): `story-readiness` and `issue-refiner` run
# development/scripts/reference-docs/resolve-reference-doc.zsh with
# docs/personas.md and read the `path` it prints, so a product whose registry
# lives in a linked docs repository no longer looks as if it had none.
#
# The two agents are models, so most pins here are prose pins: the suite holds
# each outcome's stated behaviour in place. The fixture tests run the lookup
# the way both agents spell the call, against invented throwaway repos built in
# setup() — no network, nothing taken from a real registry.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  # a git hook or `rebase --exec` exports these, and `git -C` does not override
  # them: the fixture repo's init/add would land in the REAL index
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  # scripts that annotate under Actions would change stderr on CI only
  unset GITHUB_ACTIONS
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GATE="$REPO_ROOT/development/agents/story-readiness.md"
  REFINER="$REPO_ROOT/development/agents/issue-refiner.md"
  LOOKUP_REL="development/scripts/reference-docs/resolve-reference-doc.zsh"
  CALL='zsh <resolved path> --repo-dir <target repo root> docs/personas.md'
}

# flat <file> — the file with hard wraps joined, so a sentence is pinned whole
flat() {
  tr -s '[:space:]' ' ' < "$1"
}

# outcome_bullet <file> <bullet head> — the one lookup-outcome bullet whose
# line starts with "  - **<bullet head>", up to the next bullet or blank line,
# joined onto one line
outcome_bullet() {
  awk -v head="  - **$2" '
    index($0, head) == 1 { on = 1; print; next }
    on && (/^  - / || /^$/) { exit }
    on { print }' "$1" | tr -s '[:space:]' ' '
}

# product_path_hits <dir> — tracked lines under <dir>/development that name a
# path into product/; prints them, exits non-zero only when git itself fails
product_path_hits() {
  local out rc
  out="$(git -C "$1" grep -nE -e '(^|[^A-Za-z0-9_.-])(\.\./)*product/((\*|[0-9][0-9A-Za-z.+-]*)/)?(scripts|skills|agents|templates|\.claude-plugin)/' -- development)"
  rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  printf '%s' "$out"
}

g() {
  git -c user.name="Fixture Author" -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null -c init.defaultBranch=main "$@"
}

# --- the call ----------------------------------------------------------------

@test "both agents run the lookup with docs/personas.md and read the printed path" {
  local f t
  for f in "$GATE" "$REFINER"; do
    t="$(flat "$f")"
    contains "$t" "$CALL"
    contains "$t" '**Find the registry with the lookup, never by a path of your own (#3352).**'
    contains "$t" 'On exit 0 it prints one JSON object, and the registry is the file at its `path`.'
    contains "$t" "plugins/cache/*/development/*/scripts/reference-docs/resolve-reference-doc.zsh(N.nOn[1])"
    contains "$t" "An empty result means no installed copy; when the target repo is this plugin's own repo, its working-tree copy at \`$LOOKUP_REL\`"
  done
}

@test "both agents say the lookup ships in the plugin and when persona validation runs" {
  local gate refiner
  gate="$(flat "$GATE")"
  refiner="$(flat "$REFINER")"
  contains "$gate" 'It ships in this plugin, not in the target repo, so resolve its path with one `Bash` call that takes the highest installed version:'
  contains "$refiner" 'It ships in this plugin, not in the target repo, so resolve its path with one `Bash` call that takes the highest installed version:'
  contains "$gate" 'If the story-spec block references persona ids (a non-empty `personas` array), find the target repo'"'"'s `personas/v1` registry with the lookup below, validate the ids against it and record any problem as an **advisory** (the `advisories` output field), **never** as a check failure.'
  contains "$gate" 'A persona-less story (empty or absent `personas`) is **silent** — no lookup, no advisory.'
  contains "$refiner" '**Reference personas** from the target repo'"'"'s `personas/v1` registry (#665), found with the lookup below, when one fits, and **draw the drafted payloads from the referenced persona'"'"'s `data_traits`** (#668)'
}

@test "neither agent names docs/personas.md anywhere but in the lookup call" {
  local f all calls
  for f in "$GATE" "$REFINER"; do
    all="$(grep -oF 'docs/personas.md' "$f" | wc -l | tr -d ' ')"
    calls="$(grep -oF -- "$CALL" "$f" | wc -l | tr -d ' ')"
    [ "$calls" -eq 1 ]
    [ "$all" -eq "$calls" ]
  done
}

@test "the cache glob and the working-tree path name the script that ships" {
  [ -x "$REPO_ROOT/$LOOKUP_REL" ]
  # the glob's tail after development/*/ is the script's path inside the plugin
  [ -f "$REPO_ROOT/development/${LOOKUP_REL#development/}" ]
}

# --- one behaviour per outcome ----------------------------------------------

@test "both agents state a behaviour for own, linked, exit 3, exit 4 or 6, and every other exit" {
  local f h b
  for f in "$GATE" "$REFINER"; do
    for h in 'exit 0, `origin` `own`**' 'exit 0, `origin` `linked`**' 'exit 3**' 'exit 4 or 6**' \
             'exit 1, 2, 5 or any other non-zero exit**'; do
      b="$(outcome_bullet "$f" "$h")"
      [ -n "$b" ] || { printf 'no %s bullet in %s\n' "$h" "$f" >&2; return 1; }
    done
  done
}

@test "own and linked read the printed path; linked is read-only and routes to define-personas in the docs repo" {
  local f own linked
  for f in "$GATE" "$REFINER"; do
    own="$(outcome_bullet "$f" 'exit 0, `origin` `own`**')"
    linked="$(outcome_bullet "$f" 'exit 0, `origin` `linked`**')"
    contains "$own" 'the file at `path`'
    contains "$linked" 'the file at `path`'
    contains "$linked" 'It is read-only here'
    contains "$linked" '`/product:define-personas` run in that docs repository; it ships in the `product` plugin.'
  done
}

@test "exit 3 keeps today's no-registry behaviour" {
  local gate refiner
  gate="$(outcome_bullet "$GATE" 'exit 3**')"
  refiner="$(outcome_bullet "$REFINER" 'exit 3**')"
  contains "$gate" 'the repo has no registry: the `persona-registry-missing` advisory below, unchanged.'
  contains "$refiner" 'the repo has no registry: leave `personas: []` and route a story that needs a persona to `/product:define-personas`, as above, unchanged.'
  contains "$(flat "$GATE")" 'the story references personas but the lookup exited 3 → advisory that the ids can'"'"'t be validated.'
}

@test "exit 4 or 6 carries the fix line; every other exit carries stderr" {
  local f four other
  for f in "$GATE" "$REFINER"; do
    four="$(outcome_bullet "$f" 'exit 4 or 6**')"
    other="$(outcome_bullet "$f" 'exit 1, 2, 5 or any other non-zero exit**')"
    contains "$four" 'carries the fix line the script printed on stderr'
    contains "$other" "the script's stderr"
    contains "$other" 'or no copy of the lookup anywhere'
    contains "$other" 'says the lookup was not found'
    contains "$other" 'Only exit 3 means there is no registry.'
  done
  contains "$(outcome_bullet "$GATE" 'exit 4 or 6**')" 'a `persona-registry-unreadable` advisory'
  contains "$(outcome_bullet "$GATE" 'exit 1, 2, 5 or any other non-zero exit**')" 'a `persona-registry-unreadable` advisory'
}

@test "no outcome other than exit 3 says the registry is absent" {
  local f h b rest
  for f in "$GATE" "$REFINER"; do
    for h in 'exit 4 or 6**' 'exit 1, 2, 5 or any other non-zero exit**'; do
      b="$(outcome_bullet "$f" "$h")"
      contains "$b" 'It never says the registry is absent.'
      # with the two sentences that NAME absence to deny it removed, nothing
      # in the bullet may assert it
      rest="${b//It never says the registry is absent./}"
      rest="${rest//It never says the registry is absent. Only exit 3 means there is no registry./}"
      rest="${rest//Only exit 3 means there is no registry./}"
      lacks "$rest" 'absent'
      lacks "$rest" 'no registry'
      lacks "$rest" 'persona-registry-missing'
    done
  done
}

@test "the refiner's outcome bullets are pinned sentence by sentence, with the unchecked-id rule after them" {
  local own linked four other t
  own="$(outcome_bullet "$REFINER" 'exit 0, `origin` `own`**')"
  linked="$(outcome_bullet "$REFINER" 'exit 0, `origin` `linked`**')"
  four="$(outcome_bullet "$REFINER" 'exit 4 or 6**')"
  other="$(outcome_bullet "$REFINER" 'exit 1, 2, 5 or any other non-zero exit**')"
  t="$(flat "$REFINER")"
  contains "$own" 'the repo'"'"'s own registry: read the file at `path` and reference personas from it, as above.'
  contains "$linked" 'the registry lives in the linked docs repository named by `submodule`: read the file at `path` and reference personas from it, as above.'
  contains "$linked" 'It is read-only here — never propose an edit to it in this repo.'
  contains "$linked" 'A missing or ill-fitting persona is routed, in a `recommendations` entry, to `/product:define-personas` run in that docs repository; it ships in the `product` plugin.'
  contains "$four" 'the registry could not be read at its pinned version: a `recommendations` entry that carries the fix line the script printed on stderr, and no new persona reference this turn.'
  contains "$other" 'or no copy of the lookup anywhere — a `recommendations` entry that carries the script'"'"'s stderr (or says the lookup was not found), and no new persona reference this turn.'
  contains "$t" 'On those last two outcomes the registry was not read, so nothing was checked.'
  contains "$t" 'Carry every persona id already in `issue.body`'"'"'s story-spec block, or named by the human, unchanged, together with its accepted `persona_derivations` records, and derive nothing from it this turn.'
  contains "$t" 'Such an id is unchecked, not an id that does not resolve: wherever this file routes a non-resolving id to `/product:define-personas`, that routing does not apply to it, and the `recommendations` entry above is the whole response.'
}

@test "story-readiness pins that persona checks stay advisory in every outcome" {
  local t
  t="$(flat "$GATE")"
  contains "$t" '**Persona checks stay advisory in every outcome of the lookup: no outcome turns a `READY` verdict into `NEEDS_REFINEMENT`.**'
  contains "$t" '"persona-registry-missing" | "persona-registry-unreadable" |'
  contains "$(flat "$REFINER")" 'Persona checks stay advisory in every outcome of the lookup: none of them blocks the turn.'
}

# --- the lookup, called as the agents spell it ------------------------------

@test "the call as spelled finds an own registry, and exits 3 when there is none" {
  local R="$BATS_TEST_TMPDIR/depot product"
  mkdir -p "$R/docs"
  g -C "$R" init -q
  printf '# Personas\n\nDana, the field dispatcher.\n' > "$R/docs/personas.md"
  g -C "$R" add -- docs/personas.md
  g -C "$R" commit -q -m "registry"
  run --separate-stderr zsh "$REPO_ROOT/$LOOKUP_REL" --repo-dir "$R" docs/personas.md
  [ "$status" -eq 0 ]
  [ "$(jq -r .origin <<<"$output")" = "own" ]
  [ "$(jq -r .path <<<"$output")" = "$(cd "$R" && pwd -P)/docs/personas.md" ]
  g -C "$R" rm -q -- docs/personas.md
  g -C "$R" commit -q -m "no registry"
  run --separate-stderr zsh "$REPO_ROOT/$LOOKUP_REL" --repo-dir "$R" docs/personas.md
  [ "$status" -eq 3 ]
  [ -z "$output" ]
}

# --- the contract's statement -----------------------------------------------

@test "ARCHITECTURE.md's persona registry contract records the lookup and the exit rule" {
  local section
  section="$(sed -n '/^## Persona registry contract (`personas\/v1`, #665)$/,/^### /p' "$REPO_ROOT/ARCHITECTURE.md" | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  contains "$section" '**How the development-side readers find it (#3352).**'
  contains "$section" 'the development copy of the lookup, `development/scripts/reference-docs/resolve-reference-doc.zsh`'
  contains "$section" 'When the lookup for `docs/personas.md` exits 1, 2, 5 or with any other non-zero code that is not 3, 4 or 6, the development-side persona readers raise an advisory that carries the script'"'"'s stderr and never say the registry is absent. Only exit 3 means there is no registry.'
}

@test "ARCHITECTURE.md's product plugin section says the development readers use the development copy" {
  local section
  section="$(sed -n '/^### The `product` plugin — outside the language\/topic model$/,/^### /p' "$REPO_ROOT/ARCHITECTURE.md" | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  contains "$section" '**The development-side persona readers use the development copy (#3352).**'
  contains "$section" 'no file under `development/` names a path into `product/`.'
}

@test "the persona-consumption validation note describes the lookup" {
  local t
  t="$(flat "$REPO_ROOT/development/skills/refine-issue/docs/PERSONA-CONSUMPTION-VALIDATION.md")"
  contains "$t" '## 2a. Where the registry is found (#3352)'
  contains "$t" 'Neither consumer opens the registry by a fixed path.'
  contains "$t" "\`$LOOKUP_REL --repo-dir <repo> docs/personas.md\`"
}

# --- no development file names a path into product/ ------------------------

@test "no tracked file under development/ names a path into product/" {
  run product_path_hits "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the product-path sweep finds each planted path form and spares what is not one" {
  local d="$BATS_TEST_TMPDIR/sweep"
  mkdir -p "$d/development/agents"
  printf 'see https://example.invalid/docs/product/migration-guide/\n' > "$d/development/agents/a.md"
  printf 'run xproduct/scripts/resolve-product-doc.zsh\n' > "$d/development/agents/x.md"
  g -C "$d" init -q
  g -C "$d" add -A
  run product_path_hits "$d"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'run ../../product/scripts/resolve-product-doc.zsh\n' > "$d/development/agents/b.md"
  printf 'read product/skills/define-personas/SKILL.md\n' > "$d/development/agents/c.md"
  printf 'glob plugins/cache/*/product/*/scripts/resolve-product-doc.zsh\n' > "$d/development/agents/d.md"
  printf 'glob plugins/cache/shelf/product/1.4.0/scripts/resolve-product-doc.zsh\n' > "$d/development/agents/e.md"
  printf 'read product/agents/persona-writer.md\n' > "$d/development/agents/f.md"
  printf 'read product/.claude-plugin/plugin.json\n' > "$d/development/agents/h.md"
  g -C "$d" add -A
  run product_path_hits "$d"
  [ "$status" -eq 0 ]
  contains "$output" 'development/agents/b.md:1:'
  contains "$output" 'development/agents/c.md:1:'
  contains "$output" 'development/agents/d.md:1:'
  contains "$output" 'development/agents/e.md:1:'
  contains "$output" 'development/agents/f.md:1:'
  contains "$output" 'development/agents/h.md:1:'
  lacks "$output" 'development/agents/a.md'
  lacks "$output" 'development/agents/x.md'
}
