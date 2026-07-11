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

# --- Swift detection (#297 Slice A) -----------------------------------------

@test "detect-stack: SwiftPM Package.swift tools-version + testTarget -> swiftpm, parsed, has_cov" {
  printf '// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(\n  name: "X",\n  targets: [\n    .target(name: "X"),\n    .testTarget(name: "XTests", dependencies: ["X"]),\n  ]\n)\n' > Package.swift
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("swift")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.swift.version <<<"$out")" = "6.0" ]
  [ "$(jq -r .language_meta.swift.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.swift.build_system <<<"$out")" = "swiftpm" ]
  [ "$(jq -r .language_meta.swift.has_cov <<<"$out")" = "true" ]
}

@test "detect-stack: Xcode project SWIFT_VERSION -> xcode build_system, parsed version, no tests -> has_cov false" {
  mkdir -p App.xcodeproj
  printf '\t\t\t\tSWIFT_VERSION = 5.0;\n' > App.xcodeproj/project.pbxproj
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("swift")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.swift.build_system <<<"$out")" = "xcode" ]
  [ "$(jq -r .language_meta.swift.version <<<"$out")" = "5.0" ]
  [ "$(jq -r .language_meta.swift.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.swift.has_cov <<<"$out")" = "false" ]
}

@test "detect-stack: Swift both Package.swift and .xcodeproj -> xcode wins (the app is the product)" {
  printf '// swift-tools-version:5.9\n' > Package.swift
  mkdir -p App.xcodeproj
  printf '\t\t\t\tSWIFT_VERSION = 6.0;\n' > App.xcodeproj/project.pbxproj
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r .language_meta.swift.build_system <<<"$out")" = "xcode" ]
  # version: first match wins = Package.swift tools-version (5.9)
  [ "$(jq -r .language_meta.swift.version <<<"$out")" = "5.9" ]
}

@test "detect-stack: SwiftPM no tools-version pin -> default 6.0, source=default" {
  printf 'import PackageDescription\nlet package = Package(name: "X")\n' > Package.swift
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.swift.version <<<"$out")" = "6.0" ]
  [ "$(jq -r .language_meta.swift.version_source <<<"$out")" = "default" ]
  [ "$(jq -r .language_meta.swift.build_system <<<"$out")" = "swiftpm" ]
}

@test "detect-stack: Swift .swift-version pin + Tests/ dir -> parsed version, has_cov true" {
  printf 'import PackageDescription\n' > Package.swift
  printf '5.10\n' > .swift-version
  mkdir -p Tests
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.swift.version <<<"$out")" = "5.10" ]
  [ "$(jq -r .language_meta.swift.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.swift.has_cov <<<"$out")" = "true" ]
}

@test "detect-stack: no Swift markers -> swift not detected, no language_meta.swift" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("swift")' <<<"$out")" = "null" ]
  [ "$(jq -r '.language_meta.swift // "absent"' <<<"$out")" = "absent" ]
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

@test "detect-stack: #408 present check-api-stability.py is tracked at its deploy path, not flagged missing" {
  # The script's template lives at languages/python/check-api-stability.py but
  # deploys to .github/scripts/check-api-stability.py. A 1:1 tree->target mapping
  # probed the bare-root path and reported a present file as a phantom gap.
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  mkdir -p .github/scripts
  printf '# api stability wrapper\n' > .github/scripts/check-api-stability.py
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.existing_artifacts["'".github/scripts/check-api-stability.py"'"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.existing_artifacts["check-api-stability.py"] // "absent"' <<<"$out")" = "absent" ]
  [ "$(jq -r '.missing_artifacts | index(".github/scripts/check-api-stability.py")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("check-api-stability.py")' <<<"$out")" = "null" ]
}

@test "detect-stack: #408 absent check-api-stability.py is held out (gated like api-stability.yml)" {
  # The script + its workflow render together as one api-stability feature gated
  # by a signal detect-stack can't observe, so an absent script is never an
  # auto-render gap (would otherwise orphan the script without its workflow).
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/scripts/check-api-stability.py")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("check-api-stability.py")' <<<"$out")" = "null" ]
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

# --- #242 interfaces: runtime interface detection (cli/rest/web-ui/library) --

@test "detect-stack: #242 [project.scripts] -> cli interface with evidence" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n[project.scripts]\nx = "x.cli:main"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '[.interfaces[].interface] | index("cli")' <<<"$out")" != "null" ]
  [ "$(jq -r '.interfaces[] | select(.interface=="cli") | .evidence' <<<"$out")" = "[project.scripts] entry point in pyproject.toml" ]
}

@test "detect-stack: #242 typer dependency -> cli interface" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["typer>=0.9"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface] | index("cli")' <<<"$out")" != "null" ]
}

@test "detect-stack: #242 fastapi without UI markers -> rest (not web-ui)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["fastapi>=0.110"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface] | index("rest")' <<<"$out")" != "null" ]
  [ "$(jq -r '[.interfaces[].interface] | index("web-ui")' <<<"$out")" = "null" ]
}

@test "detect-stack: #242 flask + jinja2 -> web-ui (UI markers disambiguate from rest)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["flask>=3", "jinja2>=3"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface] | index("web-ui")' <<<"$out")" != "null" ]
  [ "$(jq -r '[.interfaces[].interface] | index("rest")' <<<"$out")" = "null" ]
}

@test "detect-stack: #242 flask + templates/ directory -> web-ui" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["flask>=3"]\n' > pyproject.toml
  mkdir -p app/templates
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface] | index("web-ui")' <<<"$out")" != "null" ]
}

@test "detect-stack: #242 cli + web-ui coexist (the ai-doc-organizer shape)" {
  printf '[project]\nname = "aido"\nversion = "0.1.0"\ndependencies = ["flask>=3", "jinja2>=3"]\n[project.scripts]\naido = "aido.cli:main"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface] | index("cli")' <<<"$out")" != "null" ]
  [ "$(jq -r '[.interfaces[].interface] | index("web-ui")' <<<"$out")" != "null" ]
  [ "$(jq -r '.interfaces | length' <<<"$out")" = "2" ]
}

@test "detect-stack: #242 plain [project] with no interface -> library" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["requests"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.interfaces[0].interface' <<<"$out")" = "library" ]
  [ "$(jq -r '.interfaces | length' <<<"$out")" = "1" ]
}

@test "detect-stack: #242 --interfaces overrides detection outright" {
  # A CLI-looking project, overridden to rest+web-ui — the override wins and
  # every named interface carries "user override" as its evidence.
  printf '[project]\nname = "x"\nversion = "0.1.0"\n[project.scripts]\nx = "x:main"\n' > pyproject.toml
  out=$(bash "$DETECT" --interfaces "rest, web-ui" 2>/dev/null)
  [ "$(jq -r '[.interfaces[].interface]' <<<"$out" | tr -d ' \n')" = '["rest","web-ui"]' ]
  [ "$(jq -r '.interfaces[0].evidence' <<<"$out")" = "user override" ]
}

@test "detect-stack: #242 non-Python project -> interfaces [] (Python-only in v1)" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.interfaces' <<<"$out")" = "[]" ]
}

@test "detect-stack: #242 interfaces key is additive — prior keys unchanged, valid JSON" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # Still valid JSON and prior keys intact.
  jq -e . <<<"$out" >/dev/null
  [ "$(jq -r .language_meta.python.version <<<"$out")" = "3.13" ]
  [ "$(jq -r '.interfaces | type' <<<"$out")" = "array" ]
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
