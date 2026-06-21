#!/usr/bin/env bats
#
# Behavioral tests for the language detection in detect-stack.sh and
# verify-python-state.sh.
#
# Python regression net for #271: a no-match `requires-python` grep used to trip
# `set -euo pipefail` and abort before the 3.12 fallback, so any Python project
# without a `requires-python` pin crashed detection.
#
# Java detection + the nested `language_meta` block were added in #305 (first
# slice of the #296 Java/Gradle epic). The Python assertions read the migrated
# `.language_meta.python.*` paths (formerly the flat `.python_version` key).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  DETECT="$REPO_ROOT/development/skills/bootstrap/scripts/detect-stack.sh"
  VERIFY="$REPO_ROOT/development/skills/maintenance/scripts/verify-python-state.sh"
  WORK="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WORK"
  cd "$WORK"
  git init -q
}

@test "detect-stack: pyproject WITHOUT requires-python -> exit 0, python 3.12 fallback" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.python.version <<<"$out")" = "3.12" ]
  [ "$(jq -r .language_meta.python.version_source <<<"$out")" = "default" ]
  [ "$(jq -r '.languages | index("python")' <<<"$out")" != "null" ]
}

@test "detect-stack: pyproject WITH requires-python -> parsed version" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.python.version <<<"$out")" = "3.13" ]
  [ "$(jq -r .language_meta.python.version_source <<<"$out")" = "parsed" ]
}

@test "detect-stack: pyproject WITH pytest-cov -> language_meta.python.has_cov true" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n[project.optional-dependencies]\ndev = ["pytest-cov>=5"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.python.has_cov <<<"$out")" = "true" ]
}

@test "detect-stack: no pyproject -> exit 0, python not detected" {
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("python")' <<<"$out")" = "null" ]
  # No Python -> no python entry in language_meta.
  [ "$(jq -r '.language_meta.python // "absent"' <<<"$out")" = "absent" ]
}

# --- Java / Gradle detection (#305) -----------------------------------------

@test "detect-stack: gradle groovy toolchain + jacoco -> java 21, gradle, has_cov" {
  printf 'plugins {\n  id "java"\n  id "jacoco"\n}\njava {\n  toolchain {\n    languageVersion = JavaLanguageVersion.of(21)\n  }\n}\n' > build.gradle
  printf "rootProject.name = 'x'\n" > settings.gradle
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("java")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.java.version <<<"$out")" = "21" ]
  [ "$(jq -r .language_meta.java.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "gradle" ]
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "groovy" ]
  [ "$(jq -r .language_meta.java.has_cov <<<"$out")" = "true" ]
}

@test "detect-stack: gradle kts sourceCompatibility VERSION_17, no jacoco" {
  printf 'plugins {\n  java\n}\njava {\n  sourceCompatibility = JavaVersion.VERSION_17\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.java.version <<<"$out")" = "17" ]
  [ "$(jq -r .language_meta.java.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "gradle" ]
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "kotlin" ]
  [ "$(jq -r .language_meta.java.has_cov <<<"$out")" = "false" ]
}

# --- #343 Gradle DSL policy: Kotlin DSL only, Groovy needs conversion --------

@test "detect-stack: #343 Groovy build.gradle only -> gradle_dsl groovy (needs conversion)" {
  printf 'plugins { id "java" }\n' > build.gradle
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "gradle" ]
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "groovy" ]
}

@test "detect-stack: #343 build.gradle.kts -> gradle_dsl kotlin (blessed)" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "kotlin" ]
}

@test "detect-stack: #343 both DSLs present -> kotlin wins (the one we maintain)" {
  printf 'plugins { id "java" }\n' > build.gradle
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "kotlin" ]
}

@test "detect-stack: #343 settings.gradle.kts only -> gradle_dsl kotlin" {
  printf 'rootProject.name = "x"\n' > settings.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "gradle" ]
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "kotlin" ]
}

@test "detect-stack: gradle without any version marker -> default LTS 21, source=default" {
  printf 'plugins {\n  java\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.java.version <<<"$out")" = "21" ]
  [ "$(jq -r .language_meta.java.version_source <<<"$out")" = "default" ]
}

@test "detect-stack: maven pom -> build_system maven, jacoco-maven-plugin detected" {
  printf '<project><properties><maven.compiler.release>21</maven.compiler.release></properties><build><plugins><plugin><artifactId>jacoco-maven-plugin</artifactId></plugin></plugins></build></project>\n' > pom.xml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("java")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.java.version <<<"$out")" = "21" ]
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "maven" ]
  # #343: Maven has no Gradle DSL — gradle_dsl is empty (consumers reject Maven).
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "" ]
  [ "$(jq -r .language_meta.java.has_cov <<<"$out")" = "true" ]
}

@test "detect-stack: gradle wins when both gradle and maven markers present" {
  printf 'plugins { java }\n' > build.gradle.kts
  printf '<project></project>\n' > pom.xml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.java.build_system <<<"$out")" = "gradle" ]
  [ "$(jq -r .language_meta.java.gradle_dsl <<<"$out")" = "kotlin" ]
}

@test "detect-stack: python + java coexist in language_meta" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n' > pyproject.toml
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.python.version <<<"$out")" = "3.13" ]
  [ "$(jq -r .language_meta.java.version <<<"$out")" = "21" ]
}

# --- #406 missing_artifacts: gap-fill detection that drift can't see ----------

@test "detect-stack: #406 missing_artifacts flags every-repo templates that are absent" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # template-drift-watch is an every-repo template -> a bare repo is missing it.
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/template-drift-watch.yml")' <<<"$out")" != "null" ]
}

@test "detect-stack: #406 a present every-repo file is NOT flagged missing" {
  printf 'plugins { java }\n' > build.gradle.kts
  mkdir -p .github/workflows
  printf 'name: drift\n' > .github/workflows/template-drift-watch.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/template-drift-watch.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.existing_artifacts["'".github/workflows/template-drift-watch.yml"'"]' <<<"$out")" = "true" ]
}

@test "detect-stack: #406 flag-gated Approver pair is held out of missing_artifacts" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  # Approver workflow + policy are gated by --claude-approver (no filesystem
  # trace when opted out) -> never auto-render gaps.
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/claude-approver.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".claude/approver-policy.md")' <<<"$out")" = "null" ]
}

@test "detect-stack: #406 language-spec-gated api-stability.yml is held out" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/api-stability.yml")' <<<"$out")" = "null" ]
}

@test "detect-stack: #406 no bot present + not a plugin -> dependabot expected, renovate held out" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .is_claude_plugin <<<"$out")" = "false" ]
  [ "$(jq -r '.missing_artifacts | index(".github/dependabot.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("renovate.json")' <<<"$out")" = "null" ]
}

@test "detect-stack: #406 renovate.json present -> dependabot held out (no dueling bots)" {
  printf 'plugins { java }\n' > build.gradle.kts
  printf '{ "extends": ["config:recommended"] }\n' > renovate.json
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .is_claude_plugin <<<"$out")" = "false" ]
  [ "$(jq -r '.missing_artifacts | index(".github/dependabot.yml")' <<<"$out")" = "null" ]
}

@test "detect-stack: #406 claude-plugin repo -> is_claude_plugin true, renovate expected, dependabot held out" {
  mkdir -p .claude-plugin
  printf '{}\n' > .claude-plugin/marketplace.json
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .is_claude_plugin <<<"$out")" = "true" ]
  [ "$(jq -r '.missing_artifacts | index("renovate.json")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/dependabot.yml")' <<<"$out")" = "null" ]
}

@test "detect-stack: #406 approver-policy candidate maps to .claude/approver-policy.md" {
  printf 'plugins { java }\n' > build.gradle.kts
  mkdir -p .claude
  printf '# policy\n' > .claude/approver-policy.md
  out=$(bash "$DETECT" 2>/dev/null)
  # The present policy is tracked at its real render path, not a bare root file.
  [ "$(jq -r '.existing_artifacts["'".claude/approver-policy.md"'"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.existing_artifacts["approver-policy.md"] // "absent"' <<<"$out")" = "absent" ]
}

@test "verify-python-state: pyproject WITHOUT requires-python -> exit 0 (no crash)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  bash "$VERIFY" "$WORK" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}

@test "verify-python-state: Dockerfile without a python FROM -> exit 0 (no crash)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  printf 'FROM alpine:3.20\n' > Dockerfile
  bash "$VERIFY" "$WORK" >/dev/null 2>&1
  [ "$?" -eq 0 ]
}
