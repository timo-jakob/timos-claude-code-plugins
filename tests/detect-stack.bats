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

# --- Go detection (#870, slice A of #868) -------------------------------------

@test "detect-stack: #870 root go.mod with module+go+toolchain -> go token, parsed meta" {
  printf 'module github.com/acme/tenant-management\n\ngo 1.25\n\ntoolchain go1.25.1\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("go")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.25" ]
  [ "$(jq -r .language_meta.go.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.go.toolchain <<<"$out")" = "go1.25.1" ]
  [ "$(jq -r .language_meta.go.module <<<"$out")" = "github.com/acme/tenant-management" ]
}

@test "detect-stack: #870 no go.mod -> go not detected, no language_meta.go, others unaffected" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("go")' <<<"$out")" = "null" ]
  [ "$(jq -r '.language_meta.go // "absent"' <<<"$out")" = "absent" ]
  [ "$(jq -r '.languages | index("python")' <<<"$out")" != "null" ]
}

@test "detect-stack: #870 go.mod without toolchain directive -> toolchain empty" {
  printf 'module example.com/svc\n\ngo 1.24\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.24" ]
  [ "$(jq -r .language_meta.go.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.go.toolchain <<<"$out")" = "" ]
}

@test "detect-stack: #870 malformed go.mod (no module directive) -> no crash, no false go token" {
  printf 'this is not a valid go.mod at all\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("go")' <<<"$out")" = "null" ]
  [ "$(jq -r '.language_meta.go // "absent"' <<<"$out")" = "absent" ]
}

@test "detect-stack: #870 go.mod with module but no go directive -> default version 1.26" {
  printf 'module example.com/minimal\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("go")' <<<"$out")" != "null" ]
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.26" ]
  [ "$(jq -r .language_meta.go.version_source <<<"$out")" = "default" ]
}

@test "detect-stack: #870 three-part go directive (go 1.24.5) -> version 1.24, toolchain synthesized" {
  printf 'module example.com/modern\n\ngo 1.24.5\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # Modern `go mod tidy` writes three-part directives; the contract emits
  # major.minor. With no toolchain directive, the go directive IS the
  # effective toolchain pin (Go module spec) -> synthesized go1.24.5.
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.24" ]
  [ "$(jq -r .language_meta.go.version_source <<<"$out")" = "parsed" ]
  [ "$(jq -r .language_meta.go.toolchain <<<"$out")" = "go1.24.5" ]
}

@test "detect-stack: #870 explicit toolchain + three-part go directive -> explicit wins, no synthesis clobber" {
  printf 'module example.com/both\n\ngo 1.24.5\n\ntoolchain go1.25.1\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # The -z guard is load-bearing: an explicit toolchain directive must never
  # be overwritten by the value synthesized from the go directive.
  [ "$(jq -r .language_meta.go.toolchain <<<"$out")" = "go1.25.1" ]
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.24" ]
}

@test "detect-stack: #870 quoted module path -> quotes stripped from module" {
  printf 'module "github.com/acme/quoted"\n\ngo 1.25\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # go.mod's lexer permits quoted directive arguments; the value must not
  # keep the quotes.
  [ "$(jq -r .language_meta.go.module <<<"$out")" = "github.com/acme/quoted" ]
}

@test "detect-stack: #870 CRLF go.mod -> no carriage returns leak into values" {
  printf 'module example.com/crlf\r\n\r\ngo 1.24\r\ntoolchain go1.24.5\r\n' > go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  jq -e . <<<"$out" >/dev/null
  [ "$(jq -r .language_meta.go.module <<<"$out")" = "example.com/crlf" ]
  [ "$(jq -r .language_meta.go.toolchain <<<"$out")" = "go1.24.5" ]
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.24" ]
}

@test "detect-stack: #870 go + python coexist -> valid JSON, both language_meta entries" {
  printf 'module example.com/poly\n\ngo 1.25\n' > go.mod
  printf '[project]\nname = "x"\nversion = "0.1.0"\nrequires-python = ">=3.13"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # The go entry is the last comma-joined language_meta branch — a broken
  # separator only shows up in a polyglot repo (cf. the python+java test).
  jq -e . <<<"$out" >/dev/null
  [ "$(jq -r .language_meta.go.version <<<"$out")" = "1.25" ]
  [ "$(jq -r .language_meta.go.module <<<"$out")" = "example.com/poly" ]
  [ "$(jq -r .language_meta.python.version <<<"$out")" = "3.13" ]
}

@test "detect-stack: #870 nested-only go.mod (no root) -> go not detected (root-manifest rule)" {
  mkdir -p examples/demo
  printf 'module example.com/demo\n\ngo 1.25\n' > examples/demo/go.mod
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.languages | index("go")' <<<"$out")" = "null" ]
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

# --- #714 acceptance stage: conditional gap so existing repos adopt it ---------

@test "detect-stack: #714 cli repo lacking acceptance.yml -> it IS a missing_artifact" {
  # An already-bootstrapped repo with a runtime interface but no acceptance stage
  # must see it as a gap, so a re-bootstrap adopts it (the whole point of #714).
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["flask", "jinja2"]\n[project.scripts]\nx = "x:main"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/acceptance.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("tests/acceptance/cli/test_smoke.py")' <<<"$out")" != "null" ]
}

@test "detect-stack: #714 library-only repo -> acceptance stage stays held out" {
  # `library` has no runtime interface -> renders no acceptance stage at all.
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["requests"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.interfaces[0].interface' <<<"$out")" = "library" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/acceptance.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("tests/acceptance/cli/test_smoke.py")' <<<"$out")" = "null" ]
}

@test "detect-stack: #714 rest-only repo -> acceptance.yml is a gap, cli smoke is held out" {
  # A non-library interface warrants acceptance.yml; the cli smoke test only when
  # cli is present (rest/web-ui harnesses land with #704).
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["fastapi>=0.110"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/acceptance.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("tests/acceptance/cli/test_smoke.py")' <<<"$out")" = "null" ]
}

@test "detect-stack: #714 non-Python repo -> acceptance.yml stays held out (no interfaces)" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/acceptance.yml")' <<<"$out")" = "null" ]
}

@test "detect-stack: #714 present acceptance stage is tracked, not re-flagged as a gap" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n[project.scripts]\nx = "x:main"\n' > pyproject.toml
  mkdir -p .github/workflows tests/acceptance/cli
  printf 'name: acceptance\n' > .github/workflows/acceptance.yml
  printf 'def test_x():\n    assert True\n' > tests/acceptance/cli/test_smoke.py
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.existing_artifacts["'".github/workflows/acceptance.yml"'"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.existing_artifacts["tests/acceptance/cli/test_smoke.py"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/acceptance.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("tests/acceptance/cli/test_smoke.py")' <<<"$out")" = "null" ]
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

# --- #766 docs machinery: unconditional gaps + interface-conditional stubs -----

@test "detect-stack: #766 repo without docs machinery -> mkdocs.yml + docs tree are missing_artifacts" {
  # The docs set is an unconditionally-expected gap: this is how an
  # already-bootstrapped repo adopts the end-user docs machinery (SKILL §3h).
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("mkdocs.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/index.md")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/docs.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/docs-deploy.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/docs-publish.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("Dockerfile.docs")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("requirements-docs.txt")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("scripts/docs-nav-to-chapters.zsh")' <<<"$out")" != "null" ]
}

@test "detect-stack: #766 cli repo -> cli docs stub is a gap, rest/web-ui stubs held out" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n[project.scripts]\nx = "x:main"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-cli.md")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-rest-api.md")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-web-ui.md")' <<<"$out")" = "null" ]
}

@test "detect-stack: #766 rest-only repo -> rest docs stub is a gap, cli/web-ui stubs held out" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\ndependencies = ["fastapi>=0.110"]\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-rest-api.md")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-cli.md")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-web-ui.md")' <<<"$out")" = "null" ]
}

@test "detect-stack: #766 no-interface repo -> all docs surface stubs held out, docs tree still a gap" {
  printf 'plugins { java }\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-cli.md")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-rest-api.md")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/how-to/use-the-web-ui.md")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("mkdocs.yml")' <<<"$out")" != "null" ]
}

@test "detect-stack: #766 present docs machinery is tracked, not re-flagged as a gap" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  printf 'site_name: x\n' > mkdocs.yml
  mkdir -p docs
  printf '# x\n' > docs/index.md
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.existing_artifacts["mkdocs.yml"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.existing_artifacts["docs/index.md"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.missing_artifacts | index("mkdocs.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/index.md")' <<<"$out")" = "null" ]
}

# --- container + contract detection (issue #799) -----------------------------
# Additive structural detection: named deployable images across the family's
# blessed mechanisms, committed API contracts, and a complete/inconclusive
# confidence flag. has_dockerfile keeps its exact prior semantics.

@test "detect-stack #799: a Dockerfile emits a container with its path as evidence, has_dockerfile true" {
  printf 'FROM alpine\n' > Dockerfile
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '.containers | length' <<<"$out")" = "1" ]
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "dockerfile" ]
  [ "$(jq -r '.containers[0].evidence' <<<"$out")" = "./Dockerfile" ]
  [ "$(jq -r '.has_dockerfile' <<<"$out")" = "true" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #799: a Containerfile is detected identically, has_dockerfile stays false" {
  printf 'FROM alpine\n' > Containerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "containerfile" ]
  [ "$(jq -r '.containers[0].evidence' <<<"$out")" = "./Containerfile" ]
  [ "$(jq -r '.has_dockerfile' <<<"$out")" = "false" ]
}

@test "detect-stack #799: multiple Dockerfiles all emit, named by their directory" {
  mkdir -p services/api services/worker
  printf 'FROM x\n' > services/api/Dockerfile
  printf 'FROM x\n' > services/worker/Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | sort | join(",")' <<<"$out")" = "api,worker" ]
  [ "$(jq -r 'all(.containers[]; .source=="dockerfile")' <<<"$out")" = "true" ]
}

@test "detect-stack #799: docker-compose emits each service name; a repo with none emits no compose entries" {
  printf 'services:\n  web:\n    image: nginx\n  db:\n    image: postgres\nvolumes:\n  data:\n' > docker-compose.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[] | select(.source=="compose") | .name] | sort | join(",")' <<<"$out")" = "db,web" ]
  # the volumes: key is not a service
  [ "$(jq -r 'any(.containers[]; .name=="data")' <<<"$out")" = "false" ]
}

@test "detect-stack #799: bootBuildImage with NO Dockerfile emits a bootBuildImage container and has_dockerfile false" {
  printf 'rootProject.name = "tick-client-snapper"\n' > settings.gradle.kts
  printf 'plugins {\n  id("org.springframework.boot") version "3.2.0"\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "tick-client-snapper" ]
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "bootBuildImage" ]
  [ "$(jq -r '.has_dockerfile' <<<"$out")" = "false" ]
}

@test "detect-stack #799: a Jib-configured build emits a jib-sourced container" {
  printf 'rootProject.name = "jibby"\n' > settings.gradle.kts
  printf 'plugins {\n  id("com.google.cloud.tools.jib") version "3.4.0"\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "jib" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "jibby" ]
}

@test "detect-stack #799: committed OpenAPI spec and .proto files are emitted as contracts; neither -> empty" {
  mkdir -p proto
  printf 'openapi: 3.0.0\n' > openapi.yaml
  printf 'syntax="proto3";\n' > proto/orders.proto
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.contracts[].type] | sort | join(",")' <<<"$out")" = "openapi,proto" ]
  [ "$(jq -r '.contracts[] | select(.type=="proto") | .evidence' <<<"$out")" = "proto/orders.proto" ]
}

@test "detect-stack #799: a repo with no contract files emits contracts: []" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.contracts' <<<"$out")" = "[]" ]
}

@test "detect-stack #799: a repo with no container evidence emits containers [] + detection_confidence complete" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #799: unresolvable container evidence (build-push-action, no local mechanism) -> inconclusive, not []" {
  mkdir -p .github/workflows
  printf 'jobs:\n  build:\n    steps:\n      - uses: docker/build-push-action@v5\n' > .github/workflows/ci.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "inconclusive" ]
}

@test "detect-stack #799: a resolved Dockerfile alongside a build-push-action stays complete (the action builds it)" {
  mkdir -p .github/workflows
  printf 'FROM alpine\n' > Dockerfile
  printf 'jobs:\n  build:\n    steps:\n      - uses: docker/build-push-action@v5\n' > .github/workflows/ci.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #859: compose service that builds from the repo's own Dockerfile collapses to ONE container (block build form)" {
  # The ai-doc-organizer case: a bare ./Dockerfile AND a compose service that
  # builds from it (context: .) are one deployable, not two. The compose service
  # name is authoritative; the repo-dir-name Dockerfile entry must be dropped.
  printf 'FROM alpine\n' > Dockerfile
  printf 'services:\n  aido:\n    build:\n      context: .\n    image: aido:latest\n' > docker-compose.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers | length' <<<"$out")" = "1" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "aido" ]
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "compose" ]
  # no phantom dockerfile-source entry named after the repo directory
  [ "$(jq -r 'any(.containers[]; .source=="dockerfile")' <<<"$out")" = "false" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #859: inline 'build: .' scalar form also collapses" {
  printf 'FROM alpine\n' > Dockerfile
  printf 'services:\n  app:\n    build: .\n    image: app:latest\n' > docker-compose.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers | length' <<<"$out")" = "1" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "app" ]
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "compose" ]
}

@test "detect-stack #859: a Dockerfile NOT referenced by any compose build stays its own container" {
  # Guard against over-collapsing: the compose service pulls a prebuilt image and
  # does not build; the standalone Dockerfile is a genuinely separate deployable.
  printf 'FROM alpine\n' > Dockerfile
  printf 'services:\n  cache:\n    image: redis:7\n' > docker-compose.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[].source] | sort | join(",")' <<<"$out")" = "compose,dockerfile" ]
}

@test "detect-stack #859: subdir Dockerfile built by a compose service in the same dir collapses" {
  mkdir -p svc
  printf 'FROM alpine\n' > svc/Dockerfile
  printf 'services:\n  svc:\n    build:\n      context: .\n    image: svc:latest\n' > svc/docker-compose.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers | length' <<<"$out")" = "1" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "svc" ]
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "compose" ]
}

@test "detect-stack #799: --containers overrides detection outright with source 'user override'" {
  printf 'FROM alpine\n' > Dockerfile
  out=$(bash "$DETECT" --containers "alpha,beta" 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | join(",")' <<<"$out")" = "alpha,beta" ]
  [ "$(jq -r 'all(.containers[]; .source=="user override")' <<<"$out")" = "true" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #799: the full output is still valid JSON with all pre-existing keys (additive contract)" {
  printf 'FROM alpine\n' > Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  echo "$out" | jq -e . >/dev/null
  for k in git_initialized has_github_remote languages has_dockerfile interfaces language_meta \
           is_claude_plugin existing_artifacts missing_artifacts github_state containers \
           detection_confidence contracts; do
    [ "$(jq --arg k "$k" 'has($k)' <<<"$out")" = "true" ]
  done
}

# --- #799 round-2: naming, all inconclusive triggers, override precedence ----

@test "detect-stack #799: a root Dockerfile is named by the repo directory" {
  printf 'FROM x\n' > Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$(basename "$WORK")" ]
}

@test "detect-stack #799: a docker/Dockerfile is named by the repo directory, not 'docker'" {
  mkdir -p docker; printf 'FROM x\n' > docker/Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$(basename "$WORK")" ]
}

@test "detect-stack #799: a sub/docker/Dockerfile is named by the module dir (parent of docker/)" {
  mkdir -p svc/docker; printf 'FROM x\n' > svc/docker/Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "svc" ]
}

@test "detect-stack #799: Helm Chart.yaml (unresolvable image ref) -> inconclusive" {
  printf 'name: x\nversion: 0.1.0\n' > Chart.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "inconclusive" ]
}

@test "detect-stack #799: a PaaS/builder marker file (fly.toml) -> inconclusive" {
  printf 'app = "x"\n' > fly.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "inconclusive" ]
}

@test "detect-stack #799: a Maven jib-maven-plugin pom.xml (unresolved by this family) -> inconclusive" {
  printf '<project><build><plugins><plugin><artifactId>jib-maven-plugin</artifactId></plugin></plugins></build></project>\n' > pom.xml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "inconclusive" ]
}

@test "detect-stack #799: --containers forces complete even over otherwise-inconclusive evidence" {
  mkdir -p .github/workflows
  printf 'jobs:\n  b:\n    steps:\n      - uses: docker/build-push-action@v5\n' > .github/workflows/ci.yml
  out=$(bash "$DETECT" --containers "alpha" 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | join(",")' <<<"$out")" = "alpha" ]
  [ "$(jq -r '.detection_confidence' <<<"$out")" = "complete" ]
}

@test "detect-stack #799: contracts are detected independently of the --containers override" {
  printf 'openapi: 3.0.0\n' > openapi.yaml
  out=$(bash "$DETECT" --containers "alpha" 2>/dev/null)
  [ "$(jq -r '[.contracts[].type] | join(",")' <<<"$out")" = "openapi" ]
}

@test "detect-stack #799: --containers does not pathname-expand a glob field" {
  touch aaa bbb
  out=$(bash "$DETECT" --containers '*' 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | join(",")' <<<"$out")" = "*" ]
}

@test "detect-stack #799: compose service extraction is indent-agnostic and skips nested keys" {
  printf 'services:\n    web:\n        build: .\n        ports:\n          - "80:80"\n    db:\n        image: postgres\n' > compose.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[]|select(.source=="compose")|.name] | sort | join(",")' <<<"$out")" = "db,web" ]
}

@test "detect-stack #799: bootBuildImage without a settings file falls back to the repo dir name" {
  printf 'plugins {\n  id("org.springframework.boot")\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "bootBuildImage" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$(basename "$WORK")" ]
}

@test "detect-stack #799: an 'apply false' root aggregator is NOT a container; only the applied module is" {
  printf 'rootProject.name = "myroot"\n' > settings.gradle.kts
  printf 'plugins {\n  id("org.springframework.boot") version "3.2.0" apply false\n}\n' > build.gradle.kts
  mkdir -p app; printf 'plugins {\n  id("org.springframework.boot")\n}\n' > app/build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | join(",")' <<<"$out")" = "app" ]
  [ "$(jq -r 'any(.containers[]; .name=="myroot")' <<<"$out")" = "false" ]
}

@test "detect-stack #799: a Spring Boot dependency coordinate (BOM use, no plugin) is NOT a container" {
  printf 'dependencies {\n  implementation("org.springframework.boot:spring-boot-starter-web")\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
}

# --- #799 round-3: Groovy plugin form, dedup, getenv fallback, apply(false) ---

@test "detect-stack #799: the paren-less Groovy plugins-DSL form id 'org.springframework.boot' is detected" {
  printf "rootProject.name = 'groovyapp'\n" > settings.gradle
  printf "plugins {\n  id 'org.springframework.boot' version '3.2.0'\n}\n" > build.gradle
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "bootBuildImage" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "groovyapp" ]
}

@test "detect-stack #799: a repo with both ./Dockerfile and ./docker/Dockerfile dedupes to one container" {
  mkdir -p docker
  printf 'FROM x\n' > Dockerfile
  printf 'FROM x\n' > docker/Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[]|select(.source=="dockerfile")] | length' <<<"$out")" = "1" ]
}

@test "detect-stack #799: a non-literal rootProject.name (System.getenv) falls back to the repo dir name" {
  printf 'rootProject.name = System.getenv("APP_NAME")\n' > settings.gradle.kts
  printf 'plugins {\n  id("org.springframework.boot")\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$(basename "$WORK")" ]
}

@test "detect-stack #799: an apply-false aggregator that also mentions bootBuildImage in subprojects{} is NOT a container" {
  printf 'rootProject.name = "aggroot"\n' > settings.gradle.kts
  printf 'plugins {\n  id("org.springframework.boot") version "3.2.0" apply false\n}\nsubprojects {\n  tasks.named("bootBuildImage") { }\n}\n' > build.gradle.kts
  mkdir -p app; printf 'plugins {\n  id("org.springframework.boot")\n}\n' > app/build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.containers[].name] | join(",")' <<<"$out")" = "app" ]
}

@test "detect-stack #799: the Kotlin apply(false) method form is treated as not-applied" {
  printf 'plugins {\n  id("org.springframework.boot").version("3.2.0").apply(false)\n}\n' > build.gradle.kts
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.containers' <<<"$out")" = "[]" ]
}

# --- C4 pages in State-D adoption path (#791) ---------------------------------

@test "detect-stack #791: a repo lacking the C4 pages flags both as missing_artifacts (State-D adoption)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("docs/architecture/c4-context.md")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index("docs/architecture/c4-container.md")' <<<"$out")" != "null" ]
}

@test "detect-stack #791: once the C4 pages exist they are existing_artifacts, not gaps (idempotent re-run)" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  mkdir -p docs/architecture
  printf '# ctx\n' > docs/architecture/c4-context.md
  printf '# cont\n' > docs/architecture/c4-container.md
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.existing_artifacts["docs/architecture/c4-context.md"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.existing_artifacts["docs/architecture/c4-container.md"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.missing_artifacts | index("docs/architecture/c4-context.md")' <<<"$out")" = "null" ]
}

# --- #833: worktree-safe container/project naming -----------------------------
# Inside a git worktree, `basename "$cwd"` is the worktree dir, not the repo —
# which named a seeded container after the worktree (session c2561459). The name
# must derive from the MAIN checkout. Two call sites: the root/docker Dockerfile
# branch, and gradle_project_name's fallback (bootBuildImage/Jib).

@test "detect-stack #833: a root Dockerfile run from a worktree is named by the repo, not the worktree dir" {
  printf 'FROM x\n' > Dockerfile
  git -c user.email=t@e -c user.name=t add -A
  git -c user.email=t@e -c user.name=t commit -qm init
  main_name=$(bash "$DETECT" 2>/dev/null | jq -r '.containers[0].name')
  [ "$main_name" = "$(basename "$WORK")" ]

  wt="$BATS_TEST_TMPDIR/worktree-fizzy-booping-kitten"
  git worktree add -q "$wt" HEAD
  cd "$wt"
  out=$(bash "$DETECT" 2>/dev/null)
  # named after the REPO, identical to the main-checkout run — never the worktree
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$main_name" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" != "$(basename "$wt")" ]
}

@test "detect-stack #833: a gradle project with no rootProject.name run from a worktree is named by the repo, not the worktree dir" {
  # no settings.gradle rootProject.name -> gradle_project_name falls back to repo_dir_name
  printf 'plugins {\n  id("org.springframework.boot") version "3.2.0"\n}\n' > build.gradle.kts
  git -c user.email=t@e -c user.name=t add -A
  git -c user.email=t@e -c user.name=t commit -qm init
  main_name=$(bash "$DETECT" 2>/dev/null | jq -r '.containers[0].name')
  [ "$main_name" = "$(basename "$WORK")" ]

  wt="$BATS_TEST_TMPDIR/worktree-zesty-otter"
  git worktree add -q "$wt" HEAD
  cd "$wt"
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.containers[0].source' <<<"$out")" = "bootBuildImage" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "$main_name" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" != "$(basename "$wt")" ]
}

@test "detect-stack #833: outside a git repo (State A, pre git-init) a root Dockerfile falls back to the cwd dir name" {
  # exercises repo_dir_name's non-git fallback (else branch): no git repo -> basename "$cwd"
  ng="$BATS_TEST_TMPDIR/nogit-alpha"
  mkdir -p "$ng"
  cd "$ng"
  # Hermetic: stop `git rev-parse` from discovering an ancestor repo if TMPDIR is
  # itself nested inside a checkout (bats-in-Docker with a mounted repo).
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  printf 'FROM x\n' > Dockerfile
  out=$(bash "$DETECT" 2>/dev/null)
  # self-verify the non-git branch was actually taken, then the fallback name
  [ "$(jq -r '.git_initialized' <<<"$out")" = "false" ]
  [ "$(jq -r '.containers[0].name' <<<"$out")" = "nogit-alpha" ]
}

# --- #692 API contracts machinery: detection + conditional gap-fill -----------
# The per-major contracts/vN/ layout must be detected as an OpenAPI surface, and
# the machinery's Spectral ruleset + lint/publish workflows are held out of
# missing_artifacts UNLESS such a surface is present (the same conditional
# pattern as the acceptance stage, #714). The SEED spec (contracts/v1/openapi.yaml)
# is held out UNCONDITIONALLY — it is a scaffold, never blind-gap-filled.

@test "detect-stack #692: a per-major contracts/v1/openapi.yaml is detected as an openapi contract" {
  mkdir -p contracts/v1
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -r '[.contracts[] | select(.type=="openapi") | .evidence] | join(",")' <<<"$out")" = "contracts/v1/openapi.yaml" ]
}

@test "detect-stack #692: two live majors (v1 + v2) are both detected as openapi contracts" {
  mkdir -p contracts/v1 contracts/v2
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  printf 'openapi: 3.1.0\n' > contracts/v2/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '[.contracts[] | select(.type=="openapi") | .evidence] | sort | join(",")' <<<"$out")" = "contracts/v1/openapi.yaml,contracts/v2/openapi.yaml" ]
}

@test "detect-stack #692: OpenAPI surface present -> the ruleset + workflows + semver gate ARE missing_artifacts when absent" {
  mkdir -p contracts/v1
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  # only the seed spec exists; the ruleset + workflows + gate do not
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".spectral.yaml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/contracts-lint.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/spec-publish.yml")' <<<"$out")" != "null" ]
  # #693 semver gate (workflow + wrapper) is surfaced on the same signal
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/contracts-semver.yml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/scripts/check-contracts-semver.sh")' <<<"$out")" != "null" ]
  # #695 CONTRACTS.md policy index is surfaced on the same signal
  [ "$(jq -r '.missing_artifacts | index("CONTRACTS.md")' <<<"$out")" != "null" ]
  # the present seed spec is tracked, and is NEVER a gap (held out unconditionally)
  [ "$(jq -r '.existing_artifacts["contracts/v1/openapi.yaml"]' <<<"$out")" = "true" ]
  [ "$(jq -r '.missing_artifacts | index("contracts/v1/openapi.yaml")' <<<"$out")" = "null" ]
}

@test "detect-stack #692: surface present but ALL machinery present -> nothing re-flagged as a gap (idempotent)" {
  mkdir -p contracts/v1 .github/workflows
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  printf 'extends: ["spectral:oas"]\n' > .spectral.yaml
  printf 'name: Contracts Lint\n' > .github/workflows/contracts-lint.yml
  printf 'name: Spec Publish\n' > .github/workflows/spec-publish.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index(".spectral.yaml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/contracts-lint.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/spec-publish.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.existing_artifacts[".spectral.yaml"]' <<<"$out")" = "true" ]
}

@test "detect-stack #692: seed spec is held out UNCONDITIONALLY even when the surface lives elsewhere" {
  # real spec at api/openapi.yaml, NO contracts/v1/ — the stub must NOT be a gap
  # (blind-rendering it would publish a placeholder as the authoritative contract)
  mkdir -p api
  printf 'openapi: 3.1.0\n' > api/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("contracts/v1/openapi.yaml")' <<<"$out")" = "null" ]
  # but the surface IS detected, so the ruleset + workflows are legitimate gaps
  [ "$(jq -r '.missing_artifacts | index(".spectral.yaml")' <<<"$out")" != "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/spec-publish.yml")' <<<"$out")" != "null" ]
}

@test "detect-stack #692: no OpenAPI surface -> the contracts machinery is held out of missing_artifacts" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -r '.missing_artifacts | index("contracts/v1/openapi.yaml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".spectral.yaml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/contracts-lint.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/spec-publish.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/contracts-semver.yml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/scripts/check-contracts-semver.sh")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index("CONTRACTS.md")' <<<"$out")" = "null" ]
}

@test "detect-stack #692: a proto-only surface does NOT trigger the OpenAPI contracts machinery" {
  mkdir -p proto
  printf 'syntax="proto3";\n' > proto/orders.proto
  out=$(bash "$DETECT" 2>/dev/null)
  # proto is a contract, but the openapi-gated machinery stays held out
  [ "$(jq -r '.missing_artifacts | index(".spectral.yaml")' <<<"$out")" = "null" ]
  [ "$(jq -r '.missing_artifacts | index(".github/workflows/spec-publish.yml")' <<<"$out")" = "null" ]
}

# --- #694 live_majors: the multi-major-serving signal -------------------------
# live_majors is the sorted set of contracts/vN/ dirs carrying a canonical
# openapi spec — bootstrap scaffolds an anti-corruption adapter per OLD major
# only when there is more than one. The producer-side adapter skeleton is a
# per-major scaffold seed, never a fixed gap-fill artifact.

@test "detect-stack #694: no OpenAPI surface -> live_majors is []" {
  printf '[project]\nname = "x"\nversion = "0.1.0"\n' > pyproject.toml
  out=$(bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  [ "$(jq -c '.live_majors' <<<"$out")" = "[]" ]
}

@test "detect-stack #694: a single contracts/v1 -> live_majors [\"v1\"]" {
  mkdir -p contracts/v1
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.live_majors' <<<"$out")" = '["v1"]' ]
}

@test "detect-stack #694: contracts/v1 + contracts/v2 -> live_majors [\"v1\",\"v2\"] (multi-major)" {
  mkdir -p contracts/v1 contracts/v2
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  printf 'openapi: 3.1.0\n' > contracts/v2/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.live_majors' <<<"$out")" = '["v1","v2"]' ]
  [ "$(jq -r '.live_majors | length' <<<"$out")" -eq 2 ]
}

@test "detect-stack #694: a non-per-major spec (api/openapi.yaml) is NOT a live major" {
  mkdir -p api
  printf 'openapi: 3.1.0\n' > api/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  # it is still a detected contract, but not a contracts/vN/ live major
  [ "$(jq -c '.live_majors' <<<"$out")" = "[]" ]
  [ "$(jq -r '[.contracts[].evidence] | index("api/openapi.yaml")' <<<"$out")" != "null" ]
}

@test "detect-stack #694: the multi-major adapter skeleton is never a missing/existing artifact" {
  mkdir -p contracts/v1 contracts/v2
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  printf 'openapi: 3.1.0\n' > contracts/v2/openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  # nothing under src/api/ is a gap-fill candidate (it is a per-major scaffold)
  [ "$(jq -r '[.missing_artifacts[] | select(startswith("src/api/"))] | length' <<<"$out")" -eq 0 ]
  [ "$(jq -r '[.existing_artifacts | keys[] | select(startswith("src/api/"))] | length' <<<"$out")" -eq 0 ]
}

@test "detect-stack #694: live_majors is sorted NUMERICALLY (v10 after v2, not lexically)" {
  mkdir -p contracts/v1 contracts/v2 contracts/v10
  for d in v1 v2 v10; do printf 'openapi: 3.1.0\n' > "contracts/$d/openapi.yaml"; done
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.live_majors' <<<"$out")" = '["v1","v2","v10"]' ]
}

@test "detect-stack #694: a contracts/vN/openapi.json (or .yml) major counts too" {
  mkdir -p contracts/v1 contracts/v3
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.json
  printf 'openapi: 3.1.0\n' > contracts/v3/openapi.yml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.live_majors' <<<"$out")" = '["v1","v3"]' ]
}

@test "detect-stack #694: a non-canonical filename in a vN dir is a contract but NOT a live major" {
  mkdir -p contracts/v4
  printf 'openapi: 3.1.0\n' > contracts/v4/orders.openapi.yaml
  out=$(bash "$DETECT" 2>/dev/null)
  [ "$(jq -c '.live_majors' <<<"$out")" = "[]" ]
  [ "$(jq -r '[.contracts[].evidence] | index("contracts/v4/orders.openapi.yaml")' <<<"$out")" != "null" ]
}

@test "detect-stack #694: live_majors does not require jq (core output degrades gracefully without it)" {
  mkdir -p contracts/v1 contracts/v2
  printf 'openapi: 3.1.0\n' > contracts/v1/openapi.yaml
  printf 'openapi: 3.1.0\n' > contracts/v2/openapi.yaml
  # run detection with jq removed from PATH; the JSON (incl. live_majors) must
  # still be produced (json_str-built, no jq dependency in the core output)
  out=$(PATH=/usr/bin:/bin bash "$DETECT" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ]
  # parse with the real jq (back on PATH) to assert the field is correct JSON
  [ "$(jq -c '.live_majors' <<<"$out")" = '["v1","v2"]' ]
}
