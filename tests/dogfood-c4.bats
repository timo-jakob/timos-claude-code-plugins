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
  # the declared set is the real one — the seven plugins plus the detected tests
  # image — so a mass-deletion of Container entries fails rather than passing on a
  # single survivor
  echo "$output" | jq -e 'map(.alias) as $a | ($a | index("development")) and ($a | index("development-docs")) and ($a | index("tests"))' >/dev/null
  echo "$output" | jq -e 'length >= 8' >/dev/null
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
  ! grep -Eqi 'placeholder' "$INDEX"
  ! grep -Fq '#746' "$INDEX"
  ! grep -Fq 'flowchart LR' "$INDEX"
}

@test "the landing page keeps ARCHITECTURE.md + MAINTAINING.md as absolute repo URLs (#795)" {
  grep -Fq 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md' "$INDEX"
  grep -Fq 'https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/MAINTAINING.md' "$INDEX"
}

@test "the docs MOC no longer frames architecture as a placeholder (#795)" {
  # broadened from the exact legacy string to the concept, so any reworded
  # placeholder label is caught too
  ! grep -Fqi 'placeholder' "$MOC"
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
