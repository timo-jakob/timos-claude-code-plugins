#!/usr/bin/env bats
#
# This repo's own C4 diagrams (issue #795, epic #746) — the dogfood. This repo is
# the first real consumer of the c4/v1 contract (#790), so these tests assert the
# hand-authored pages conform to that contract mechanically: the two required
# levels exist, the Container diagram's declared set is recoverable by the SAME
# parser the maintenance pipeline (#793) uses, the Context diagram names the whole
# landscape the story requires, and the old placeholder framing is gone from both
# the landing page and the MOC. (No test asserts Mermaid renders — the contract is
# explicit that nothing validates the diagram body; the declared-container parse is
# the only mechanical diagram-validity signal.)

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CTX="$REPO_ROOT/docs/architecture/c4-context.md"
  CONT="$REPO_ROOT/docs/architecture/c4-container.md"
  INDEX="$REPO_ROOT/docs/architecture/index.md"
  MOC="$REPO_ROOT/docs/index.md"
  MKDOCS="$REPO_ROOT/mkdocs.yml"
  PARSER="$REPO_ROOT/development/skills/bootstrap/scripts/extract-declared-containers.zsh"
}

@test "both required C4 pages exist (#795)" {
  [ -f "$CTX" ]
  [ -f "$CONT" ]
}

@test "the Context page is a C4Context mermaid block (#795)" {
  grep -Fq '```mermaid' "$CTX"
  grep -Eq '^[[:space:]]*C4Context([[:space:]]|$)' "$CTX"
}

@test "the Container page is a C4Container mermaid block (#795)" {
  grep -Fq '```mermaid' "$CONT"
  grep -Eq '^[[:space:]]*C4Container([[:space:]]|$)' "$CONT"
}

@test "the Container page's declared set is recoverable by the c4/v1 parser with the full c4/v1 shape (#795)" {
  # the real diagram-validity signal: the same parse #793 performs
  run zsh "$PARSER" --repo "$REPO_ROOT"
  [ "$status" -eq 0 ]
  # a non-empty JSON array with the FULL c4/v1 per-entry shape (incl. description)
  echo "$output" | jq -e 'type == "array" and length > 0' >/dev/null
  echo "$output" | jq -e 'all(.[]; has("alias") and has("label") and has("technology") and has("description"))' >/dev/null
  # the declared set is the real one — every marketplace plugin plus the detected
  # tests image — so a mass-deletion of Container entries fails rather than
  # passing on a single survivor. DERIVED, not a hardcoded floor: a floor goes
  # stale the moment a plugin is added (it did, at #1151) and then tolerates
  # exactly one silently deleted entry.
  # DERIVE THE WHOLE SET, not just its size: a count plus a few literals still
  # passes when an alias is misspelled or a renamed plugin keeps its old alias,
  # which is the identity half of the same rot the length floor had.
  local declared expected
  declared="$(echo "$output" | jq -r '.[].alias' | sort)"
  expected="$( { jq -r '.plugins[].name' "$REPO_ROOT/.claude-plugin/marketplace.json"; echo tests; } | sort)"
  [ -n "$declared" ]
  [ "$declared" = "$expected" ]
}

# the page states its own totals in words ("the twelve Container(...) entries
# above — the eleven installed plugins plus the tests runner image"). Those were
# hand-bumped at #1151 and nothing derived them, so the NEXT plugin would leave
# them silently wrong — which is exactly how the length >= 11 floor above rotted.
# Split across two tests so a stale COUNT and a stale SPELLING are reported by
# distinct names: errexit aborts a test at its first failure, so bundling both
# would hide the second behind the first.
_count_words() {
  # sets n_plugins / n_containers / w_plugins / w_containers, or returns nonzero
  n_plugins=$(jq '.plugins | length' "$REPO_ROOT/.claude-plugin/marketplace.json")
  n_containers=$(( n_plugins + 1 ))
  word_for() {
    case "$1" in
      9) echo nine ;; 10) echo ten ;; 11) echo eleven ;; 12) echo twelve ;;
      13) echo thirteen ;; 14) echo fourteen ;; 15) echo fifteen ;;
      *) echo "UNMAPPED-$1" ;;
    esac
  }
  w_plugins="$(word_for "$n_plugins")"
  w_containers="$(word_for "$n_containers")"
  # plain [ ] — errexit catches it on every bash, unlike an inert [[ ]] (#1011).
  # Reds loudly when the family outgrows word_for rather than asserting nothing.
  [ "${w_plugins#UNMAPPED-}" = "$w_plugins" ]
  [ "${w_containers#UNMAPPED-}" = "$w_containers" ]
}

@test "the Container page's prose states the counts derived from the marketplace (#1151)" {
  local n_plugins n_containers w_plugins w_containers flat
  _count_words
  # whitespace-normalized: the page wraps at ~80 cols, so a needle that spans a
  # line break must be matched against flattened text, not line by line
  flat="$(tr -s '[:space:]' ' ' < "$CONT")"
  # rostered helpers, so a stale count prints needle + haystack rather than a
  # bare `return 1` at a line number (#1067)
  contains "$flat" "the $w_containers \`Container(...)\` entries"
  contains "$flat" "$w_plugins installed plugins"
  contains "$flat" "$w_plugins **plugins**, by contrast"
}

@test "no STALE count spelling survives anywhere on the Container page (#1151)" {
  # a correct occurrence elsewhere would otherwise hide a stale duplicate. Swept
  # for ALL THREE phrasings over a FLATTENED page, since a stale count split
  # across a line break is invisible to a line-based grep.
  local n_plugins n_containers w_plugins w_containers words
  _count_words
  words='(nine|ten|eleven|twelve|thirteen|fourteen|fifteen)'
  tr -s '[:space:]' ' ' < "$CONT" > "$BATS_TEST_TMPDIR/flat.txt"

  run bash -c "grep -oE '$words installed plugins' '$BATS_TEST_TMPDIR/flat.txt' | sort -u | grep -v '^$w_plugins installed plugins\$'"
  [ -z "$output" ]
  run bash -c "grep -oE '$words \\*\\*plugins\\*\\*' '$BATS_TEST_TMPDIR/flat.txt' | sort -u | grep -v '^$w_plugins \\*\\*plugins\\*\\*\$'"
  [ -z "$output" ]
  run bash -c "grep -oE \"$words .Container\" '$BATS_TEST_TMPDIR/flat.txt' | sort -u | grep -v \"^$w_containers .Container\\\$\""
  [ -z "$output" ]
}

@test "the Container diagram declares the one container the detector finds — no detected_not_declared drift (#795)" {
  # the dogfood must not ship a diagram the c4_drift advisor would immediately
  # "correct": every detected container (detect-stack.sh) must be declared, folded
  # on case + -/_ per the c4/v1 join
  local detect="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  local detected declared
  detected="$(cd "$REPO_ROOT" && bash "$detect" 2>/dev/null | jq -r '.containers[].name | ascii_downcase | gsub("[^a-z0-9]";"_")' | sort -u)"
  declared="$(zsh "$PARSER" --repo "$REPO_ROOT" | jq -r '.[].alias | ascii_downcase | gsub("[^a-z0-9]";"_")' | sort -u)"
  # guard against a vacuous pass: this repo genuinely has tests/Dockerfile, so the
  # detector must find at least one container — an empty set means a detector
  # regression, not a clean diagram
  [ -n "$detected" ]
  # every detected name must appear in the declared set (no detected_not_declared)
  local missing
  missing="$(comm -23 <(printf '%s\n' "$detected") <(printf '%s\n' "$declared"))"
  [ -z "$missing" ]
}

@test "the Context diagram NODES name the full landscape the story requires (#795)" {
  # anchor each required actor / system to its C4 node declaration in the diagram
  # body, NOT to any mention in the surrounding prose or a URL (a deleted node
  # must fail this test)
  grep -Eq '^[[:space:]]*System\(plugins,' "$CTX"        # the plugins (marketplace)
  grep -Eq '^[[:space:]]*System\(maint_app,' "$CTX"       # Maintenance App
  grep -Eq '^[[:space:]]*System\(approver_app,' "$CTX"    # Approver App
  grep -Eq '^[[:space:]]*System_Ext\(github,' "$CTX"      # GitHub
  grep -Eq '^[[:space:]]*System_Ext\(sonar,' "$CTX"       # SonarCloud
  grep -Eq '^[[:space:]]*System_Ext\(snyk,' "$CTX"        # Snyk
  grep -Eq '^[[:space:]]*System_Ext\(target_repos,' "$CTX"  # target repos
  grep -Eq '^[[:space:]]*System_Ext\(reporting,' "$CTX"   # planned reporting repo
  # and the reporting node is tied to #740
  grep -Eq '^[[:space:]]*System_Ext\(reporting,.*#740' "$CTX"
}

@test "the landing page dropped the placeholder framing (#795)" {
  # no self-description as a placeholder, no #746 future-work pointer, no sketch
  run -1 grep -Eqi 'placeholder' "$INDEX"
  run -1 grep -Fq '#746' "$INDEX"
  run -1 grep -Fq 'flowchart LR' "$INDEX"
}

@test "the landing page keeps ARCHITECTURE.md + MAINTAINING.md as absolute repo URLs (#795)" {
  grep -Fq 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md' "$INDEX"
  grep -Fq 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/MAINTAINING.md' "$INDEX"
}

@test "the docs MOC no longer frames architecture as a placeholder (#795)" {
  # broadened from the exact legacy string to the concept, so any reworded
  # placeholder label is caught too
  run -1 grep -Fqi 'placeholder' "$MOC"
  # and it now links both diagrams
  grep -Fq 'architecture/c4-context.md' "$MOC"
  grep -Fq 'architecture/c4-container.md' "$MOC"
}

@test "both new pages are registered in the mkdocs nav (#795)" {
  # nav<->file lockstep and internal-link resolution are enforced end-to-end by
  # the separate `mkdocs build --strict` gate (.github/workflows/docs.yml,
  # pre-commit); this asserts the nav registration the strict build depends on
  grep -Fq 'architecture/c4-context.md' "$MKDOCS"
  grep -Fq 'architecture/c4-container.md' "$MKDOCS"
}

@test "the two diagram pages' relative cross-links resolve (#795)" {
  # cheap stand-in for the strict build's link check: the pages link each other,
  # and those relative targets must exist as files in the same directory
  grep -Fq '(c4-container.md)' "$CTX"
  grep -Fq '(c4-context.md)' "$CONT"
  [ -f "$(dirname "$CTX")/c4-container.md" ]
  [ -f "$(dirname "$CONT")/c4-context.md" ]
}
