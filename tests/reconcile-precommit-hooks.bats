#!/usr/bin/env bats
#
# Behavioral tests for reconcile-precommit-hooks.zsh (#409): a config file the
# suite ships is only load-bearing if its consuming pre-commit hook is also
# wired. The bootstrap gap-fill renders whole MISSING files, but an existing
# .pre-commit-config.yaml that predates a newer hook is "present" and left
# untouched — so a freshly gap-filled .yamllint sits orphaned. This reconciler
# closes that gap hook-by-hook.
#
# #410 adds --scan: after wiring, run each newly-wired hook repo-wide so
# pre-existing violations are discovered before the commit, not at push.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$REPO_ROOT/development/skills/bootstrap/scripts/reconcile-precommit-hooks.zsh"
  CONFIG="$BATS_TEST_TMPDIR/.pre-commit-config.yaml"
  RENDERED="$BATS_TEST_TMPDIR/rendered.yaml"
  PC_LOG="$BATS_TEST_TMPDIR/pc.log"
  : > "$PC_LOG"
}

run_it() { run zsh "$S" "$CONFIG" "$RENDERED"; }

# Fake pre-commit (PRE_COMMIT_BIN seam): logs every `run <id> --all-files` call.
# Any hook id listed in $FAIL_HOOKS exits 1 (violation/auto-fix); others pass.
write_fake_precommit() {
  FAKE_PC="$BATS_TEST_TMPDIR/pre-commit"
  cat > "$FAKE_PC" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$PC_LOG"
for bad in \${FAIL_HOOKS:-}; do
  [ "\$2" = "\$bad" ] && exit 1
done
exit 0
EOF
  chmod +x "$FAKE_PC"
}

run_scan() { run env PRE_COMMIT_BIN="$FAKE_PC" FAIL_HOOKS="${1:-}" zsh "$S" --scan "$CONFIG" "$RENDERED"; }

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

# --- #410: proactive repo-wide scan of newly-wired hooks ---------------------

@test "scan: #410 newly-wired hook is scanned repo-wide before commit" {
  # gitleaks already present -> only yamllint + the universal block are wired,
  # and ONLY those are scanned (the present gitleaks is not re-scanned).
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  write_fake_precommit
  run_scan ""           # nothing fails -> clean
  [ "$status" -eq 0 ]
  # The newly-wired hooks were scanned --all-files...
  grep -qx "run yamllint --all-files" "$PC_LOG"
  grep -qx "run trailing-whitespace --all-files" "$PC_LOG"
  # ...but the already-present gitleaks was NOT.
  ! grep -qx "run gitleaks --all-files" "$PC_LOG"
  echo "$output" | grep -q "safe to commit"
}

@test "scan: #410 a violation in a newly-wired hook surfaces before commit (exit 3)" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  write_fake_precommit
  run_scan "yamllint"   # the pre-existing 133-char-line scenario from #410
  [ "$status" -eq 3 ]
  grep -qx "run yamllint --all-files" "$PC_LOG"
  echo "$output" | grep -q "BEFORE committing"
}

@test "scan: #410 nothing newly wired -> no scan runs" {
  # Every provider already present: reconcile wires nothing, so --scan is a no-op.
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: check-yaml
  - repo: https://github.com/adrienverge/yamllint
    rev: v1.38.0
    hooks:
      - id: yamllint
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  write_fake_precommit
  run_scan ""
  [ "$status" -eq 0 ]
  [ ! -s "$PC_LOG" ]    # no pre-commit invocations at all
}

@test "scan: #410 pre-commit not installed -> scan skipped, exit stays 0" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  run env PRE_COMMIT_BIN="$BATS_TEST_TMPDIR/nonexistent-pc" zsh "$S" --scan "$CONFIG" "$RENDERED"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "skipping the proactive repo-wide"
  # The hook was still wired despite the skipped scan.
  [ "$(grep -c 'id: yamllint' "$CONFIG")" -eq 1 ]
}

@test "scan: #410 without --scan, no scan runs (back-compat)" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks
YAML
  write_rendered
  write_fake_precommit
  run env PRE_COMMIT_BIN="$FAKE_PC" zsh "$S" "$CONFIG" "$RENDERED"
  [ "$status" -eq 0 ]
  [ ! -s "$PC_LOG" ]
}

@test "scan: unknown flag -> usage error (exit 2)" {
  write_rendered
  run zsh "$S" --bogus "$CONFIG" "$RENDERED"
  [ "$status" -eq 2 ]
}

# --- #713: stale coverage-floor hook migration -------------------------------
# A rendered template whose coverage-floor* hooks carry the canonical
# diff-guarded shape (always_run + no files:, guard inside `entry` keyed on the
# origin/main...HEAD diff) — the source the migration copies. Supersedes the
# earlier #602 (always_run → files:) migration, which the #713 fix reversed.
write_rendered_cf() {
  cat > "$RENDERED" <<'YAML'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.30.1
    hooks:
      - id: gitleaks

  - repo: local
    hooks:
      - id: coverage-floor
        name: Coverage floor (90% on new code)
        entry: >-
          bash -c 'base=origin/main;
          if git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 &&
          [ -z "$(git diff --name-only --diff-filter=d "$base...HEAD" -- "*.py")" ];
          then exit 0; fi;
          exec diff-cover coverage.xml --compare-branch=origin/main --fail-under=90'
        language: python
        pass_filenames: false
        always_run: true
        stages: [pre-push]

  - repo: local
    hooks:
      - id: coverage-floor-java
        name: Coverage floor (90% on new code)
        entry: >-
          bash -c 'base=origin/main;
          if git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 &&
          [ -z "$(git diff --name-only --diff-filter=d "$base...HEAD" -- "*.java" "*.kt")" ];
          then exit 0; fi;
          exec diff-cover build/reports/jacoco/test/jacocoTestReport.xml
          --compare-branch=origin/main --fail-under=90'
        language: python
        pass_filenames: false
        always_run: true
        stages: [pre-push]
YAML
}

@test "#713 migrates a stale #379 files:-guarded python coverage-floor to the diff guard" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: coverage-floor
        name: Coverage floor (90% on new code)
        entry: diff-cover coverage.xml --compare-branch=origin/main --fail-under=90
        language: python
        pass_filenames: false
        files: \.py$
        stages: [pre-push]
YAML
  write_rendered_cf
  run_it
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrated stale coverage-floor hook: coverage-floor"
  # The over-firing files: filter is gone; the diff guard + always_run replace it.
  grep -qF 'git diff --name-only' "$CONFIG"
  grep -qE '^\s*always_run: true' "$CONFIG"
  ! grep -qE '^\s*files:' "$CONFIG"
  grep -qE 'stages: \[pre-push\]' "$CONFIG"
}

@test "#713 migrates a pre-#379 unguarded always_run python coverage-floor to the diff guard" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: coverage-floor
        entry: diff-cover coverage.xml --fail-under=90
        language: python
        always_run: true
        stages: [pre-push]
YAML
  write_rendered_cf
  run_it
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "migrated stale coverage-floor hook: coverage-floor"
  grep -qF 'git diff --name-only' "$CONFIG"
}

@test "#713 migrates both python and java stale coverage-floor hooks" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: coverage-floor
        entry: diff-cover coverage.xml --fail-under=90
        language: python
        files: \.py$
        stages: [pre-push]
  - repo: local
    hooks:
      - id: coverage-floor-java
        entry: diff-cover build/reports/jacoco/test/jacocoTestReport.xml --fail-under=90
        language: python
        files: \.(java|kt)$
        stages: [pre-push]
YAML
  write_rendered_cf
  run_it
  [ "$status" -eq 0 ]
  # Both migrated: each now carries its language's diff-guard pathspec.
  grep -qF 'git diff --name-only --diff-filter=d "$base...HEAD" -- "*.py"' "$CONFIG"
  grep -qF 'git diff --name-only --diff-filter=d "$base...HEAD" -- "*.java" "*.kt"' "$CONFIG"
  [ "$(grep -c 'files:' "$CONFIG")" -eq 0 ]
}

@test "#713 is idempotent — an already-diff-guarded coverage-floor is untouched" {
  # Rendered template carries ONLY the already-present, already-guarded hook, so
  # nothing is additively wired either — the file must be byte-for-byte stable.
  cat > "$RENDERED" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: coverage-floor
        entry: >-
          bash -c 'base=origin/main;
          [ -z "$(git diff --name-only "$base...HEAD" -- "*.py")" ] && exit 0;
          exec diff-cover coverage.xml --fail-under=90'
        language: python
        always_run: true
        stages: [pre-push]
YAML
  cp "$RENDERED" "$CONFIG"
  before="$(cat "$CONFIG")"
  run_it
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "migrated stale coverage-floor"
  [ "$(cat "$CONFIG")" = "$before" ]   # byte-for-byte unchanged
}

@test "#713 leaves a NON-coverage-floor hook alone" {
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: my-guard
        name: keep me
        entry: echo hi
        language: system
        always_run: true
        files: \.py$
YAML
  write_rendered_cf
  run_it
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "migrated stale coverage-floor"
  grep -qE '^\s*files: \\\.py\$' "$CONFIG"   # untouched
}

@test "#713 migration and additive wiring co-occur in one run" {
  # coverage-floor present-but-stale; gitleaks missing entirely.
  cat > "$CONFIG" <<'YAML'
repos:
  - repo: local
    hooks:
      - id: coverage-floor
        entry: diff-cover coverage.xml --fail-under=90
        language: python
        files: \.py$
        stages: [pre-push]
YAML
  write_rendered_cf
  run_it
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "wired hook provider: gitleaks"     # additive
  echo "$output" | grep -q "migrated stale coverage-floor hook: coverage-floor"  # migration
  grep -qF 'git diff --name-only' "$CONFIG"
  [ "$(grep -c 'id: gitleaks' "$CONFIG")" -eq 1 ]
}
