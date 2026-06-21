#!/usr/bin/env bats
#
# Behavioral tests for reconcile-precommit-hooks.zsh (#409): a config file the
# suite ships is only load-bearing if its consuming pre-commit hook is also
# wired. The bootstrap gap-fill renders whole MISSING files, but an existing
# .pre-commit-config.yaml that predates a newer hook is "present" and left
# untouched — so a freshly gap-filled .yamllint sits orphaned. This reconciler
# closes that gap hook-by-hook.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/reconcile-precommit-hooks.zsh"
  CONFIG="$BATS_TEST_TMPDIR/.pre-commit-config.yaml"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
}

run_it() { run zsh "$S" "$CONFIG" "$RENDERED"; }

# A rendered template carrying the universal + yamllint + gitleaks providers.
write_rendered() {
  cat > "$RENDERED" <<'YAML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: check-yaml

  # --- YAML lint -------------------------------------------------------------
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint

  # --- secret scanning -------------------------------------------------------
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
}

@test "reconcile: #409 config present, consuming yamllint hook absent -> hook added" {
  # An older config that predates the yamllint hook (the exact #409 scenario).
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: check-yaml
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  run_it
  [ "$status" -eq 0 ]
  # The yamllint hook is now wired exactly once.
  [ "$(grep -c 'id: yamllint' "$CONFIG")" -eq 1 ]
  echo "$output" | grep -q "wired hook provider: yamllint"
}

@test "reconcile: #409 already-present hooks are not duplicated (idempotent)" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: check-yaml
YAML
  write_rendered
  run_it
  [ "$status" -eq 0 ]
  [ "$(grep -c 'id: yamllint' "$CONFIG")" -eq 1 ]
  echo "$output" | grep -q "nothing to wire"
}

@test "reconcile: #409 second run on a freshly-wired config changes nothing" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  run_it            # adds the universal block + yamllint
  [ "$status" -eq 0 ]
  before="$(cat "$CONFIG")"
  run_it            # idempotent
  [ "$status" -eq 0 ]
  [ "$before" = "$(cat "$CONFIG")" ]
}

@test "reconcile: #409 a user-customized rev on a present provider is preserved" {
  # User pinned an OLDER yamllint rev; the provider is present, so the
  # reconciler must NOT touch it (additive-only — never overwrites user pins).
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.30.0
    hooks:
      - id: yamllint
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  run_it
  [ "$status" -eq 0 ]
  grep -q 'rev: v1.30.0' "$CONFIG"
  [ "$(grep -c 'id: yamllint' "$CONFIG")" -eq 1 ]
}

@test "reconcile: missing args -> usage error (exit 2)" {
  run zsh "$S" "$CONFIG"
  [ "$status" -eq 2 ]
}

@test "reconcile: nonexistent config -> exit 1" {
  write_rendered
  run zsh "$S" "$BATS_TEST_TMPDIR/nope.yaml" "$RENDERED"
  [ "$status" -eq 1 ]
}
