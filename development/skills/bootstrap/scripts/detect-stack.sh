#!/usr/bin/env bash
# detect-stack.sh — emits JSON describing the current repository's state.
# Used by /development:bootstrap to drive its setup flow.
#
# Output keys:
#   git_initialized       bool
#   has_github_remote     bool
#   github_repo           string  (owner/repo or "")
#   default_branch        string  ("" if not detectable)
#   visibility            "public" | "private" | "unknown"
#   languages             []string  subset of [swift, typescript, python, go, java]
#   has_dockerfile        bool     (unchanged semantics: an exact `Dockerfile`
#                                  exists — now a NARROWER fact than `containers`,
#                                  since a bootBuildImage repo has a container yet
#                                  has_dockerfile=false; that is correct, #799)
#   containers            []object  named deployable images this repo builds, each
#                                  {name, source, evidence} — see shape below (#799)
#   detection_confidence  string   "complete" | "inconclusive" — "inconclusive"
#                                  when the repo shows container-ish evidence that
#                                  resists resolution into a named image (#799)
#   contracts             []object  committed API contracts (OpenAPI specs, .proto
#                                  files), each {type, evidence} — see shape (#799)
#   live_majors           []string  the per-major dirs carrying a canonical
#                                  contracts/vN/openapi spec, e.g. ["v1","v2"]
#                                  (#694). >1 => an anti-corruption adapter is
#                                  scaffolded per OLD major.
#   interfaces            []object  runtime interface(s) a deployed build is
#                                  exercised through, each with its detection
#                                  evidence — see shape below (#242)
#   language_meta         object   per-language detection metadata — see shape below
#   is_claude_plugin      bool     repo carries a .claude-plugin marker (selects the
#                                  Renovate dependency-bot path over Dependabot)
#   existing_artifacts    object   path -> true for files we would otherwise generate
#   missing_artifacts     []string templates expected under THIS repo's conditions
#                                  (visibility/languages/bot path) that are absent —
#                                  the State D auto-render gap-fill signal. Carries
#                                  only confidently-expected gaps; holds out non-1:1
#                                  candidates (.gitignore, LICENSE), the non-selected
#                                  bot file, and flag/spec-gated files (Approver
#                                  pair, api-stability.yml) — see the held_out note.
#   github_state          object   GitHub-side state — see github_state shape below
#
# language_meta shape (added 2026-06-17 per issue #305 — nests what used to be
# the flat python_version / has_pytest_cov keys, keyed by language, so a second
# language (Java) can carry its own metadata without flat-key sprawl). Only
# detected languages get an entry. The maintenance skill copies the dispatched
# language's `version` into the request payload; bootstrap reads `has_cov` /
# `build_system` directly:
#   language_meta.python.version         string  ("3.13", "3.12", ...)
#   language_meta.python.version_source  "parsed" | "default"  (parsed from a
#                                         manifest vs guessed fallback, #258)
#   language_meta.python.has_cov         bool    (pytest-cov in dev deps already)
#   language_meta.java.version           string  ("21", "17", ...; default LTS 21)
#   language_meta.java.version_source    "parsed" | "default"  ("default" means
#                                         the build declared no toolchain — the
#                                         version is a guess, not a real pin)
#   language_meta.java.gradle_dsl        "kotlin" | "groovy" | ""  (#343: family
#                                        maintains build.gradle.kts ONLY; "groovy"
#                                        must be converted, "" = not Gradle)
#   language_meta.java.build_system      "gradle" | "maven" | ""  (Gradle-first;
#                                         Maven is recorded but unsupported, #296)
#   language_meta.java.has_cov           bool    (JaCoCo present in the build)
#   language_meta.swift.version          string  ("6.0", "5.10", ...; default 6.0)
#   language_meta.swift.version_source   "parsed" | "default"  ("default" means
#                                         no manifest/.swift-version/pbxproj pin
#                                         was found — the version is a guess, #258)
#   language_meta.swift.build_system     "xcode" | "swiftpm" | ""  (#297 Slice A:
#                                         Xcode wins when an .xcodeproj/.xcworkspace
#                                         is present — the app is the product; a
#                                         bare Package.swift is swiftpm)
#   language_meta.swift.has_cov          bool    (test targets present; Swift
#                                         coverage is toolchain-built-in — xccov for
#                                         Xcode, `swift test --enable-code-coverage`
#                                         for SwiftPM — so unlike JaCoCo there is no
#                                         dependency to declare; test presence is the
#                                         real coverage precondition)
#
# interfaces shape (added 2026-07-11 per issue #242 — the runtime interface(s)
# through which a deployed build is exercised, so bootstrap can render
# interface-appropriate acceptance tests, #243). A *set*, not a scalar: a
# project can be several at once (e.g. a CLI plus a web UI). Each entry pairs
# the interface with the evidence that detected it, so the bootstrap
# conversation can show the user WHY and let them confirm/correct:
#   [{"interface":"cli","evidence":"[project.scripts] entry point in pyproject.toml"},
#    {"interface":"web-ui","evidence":"flask + jinja2 in dependencies (server-rendered templates)"}]
#   interface ∈ {cli, rest, web-ui, library}:
#     cli      invoked from a command line (entry point / __main__ / click|typer)
#     rest     serves an HTTP/REST API (a web framework, no server-rendered UI)
#     web-ui   serves a browser UI (a web framework + templates/static/frontend)
#     library  imported, no runtime interface of its own — renders no acceptance
#              workflow (unit/integration tests are the whole story)
# Detection is ADVISORY and PYTHON-only in v1 (#242) — other languages emit
# their own set under their plugins; `interfaces` is [] when Python isn't
# detected. A `--interfaces cli,rest` flag overrides detection outright (every
# named interface then carries "user override" as its evidence).
#
# containers shape (added 2026-07-17 per issue #799 — the named deployable units
# in this repo's container topology, consumed by C4 seeding (#791) and c4_drift
# (#793)). Mostly images the repo BUILDS (Dockerfile / Containerfile /
# bootBuildImage / Jib); the `compose` source additionally reports every service
# a compose file DECLARES, which for a Container diagram legitimately includes a
# pulled datastore/queue (e.g. `db: image: postgres`) — such a service is a real
# container in the deployed system even though this repo doesn't build its image.
# Each entry pairs the container's name (its real deployable identifier — compose
# service, image name, gradle project) with the mechanism that detected it and
# the on-disk evidence, mirroring the #242 `interfaces` precedent:
#   [{"name":"aido","source":"dockerfile","evidence":"./Dockerfile"},
#    {"name":"tick-client-snapper","source":"bootBuildImage",
#     "evidence":"bootBuildImage via the Spring Boot Gradle plugin in build.gradle.kts"}]
#   source ∈ {dockerfile, containerfile, compose, bootBuildImage, jib, user override}
# When a name has no intrinsic source — a root-level (or `docker/`-dir) Dockerfile,
# or a gradle root project with no `rootProject.name` — it falls back to the
# REPOSITORY directory name. That name is derived worktree-safely from the MAIN
# checkout via `git rev-parse --git-common-dir` (#833), NEVER `basename "$cwd"`,
# which inside a git worktree is the worktree dir (e.g. a resolve-issue worktree),
# not the repo — the bug that named a seeded container after the worktree.
# Detection is ADVISORY (like `interfaces`); `--containers a,b` overrides it
# outright (each carries "user override" as its source and evidence). The
# enumeration is deliberately bounded — "what image does this repo produce" has no
# general solution — so unrecognised mechanisms (ko, pack/project.toml, Nixpacks,
# PaaS manifests, k8s/Helm image refs) are NOT emitted as containers; they instead
# flip `detection_confidence` to "inconclusive" (below).
#
# detection_confidence (#799): "complete" | "inconclusive". "No containers
# detected" and "this repo has no containers" are DIFFERENT claims. It is
# "inconclusive" when the repo shows container-ish evidence that could not be
# resolved into a named image (a docker/build-push-action CI step, a Helm chart's
# image: ref, an unrecognised builder) AND no local mechanism resolved anything —
# so consumers (#791/#793) can decline to assert rather than assert wrongly:
# #791 must not fabricate a container on "inconclusive", and #793 must emit no
# declared-but-not-detected drift on "inconclusive". A `--containers` override is
# always "complete".
#
# contracts shape (#799): committed API-contract artifacts — the external-boundary
# signal a Context diagram needs. Each entry is {type, evidence}:
#   [{"type":"openapi","evidence":"api/openapi.yaml"},
#    {"type":"proto","evidence":"proto/orders.proto"}]
#   type ∈ {openapi, proto}. Independent of the `--containers` override.
#
# github_state shape (added 2026-06-04 per issue #90 — keeps detection
# honest about GitHub-side configuration the on-disk artifacts don't see):
#   branch_protection.state                "applied" | "missing" | "forbidden" | "unknown" | "skipped"
#   branch_protection.applied_contexts     []string  (when state="applied")
#   branch_protection.required_reviews     int
#   branch_protection.linear_history       bool
#   branch_protection.force_push           bool
#   branch_protection.required_signatures  bool | null  (null = couldn't probe;
#                                                       false = rule exists but
#                                                       signed-commits is off)
#   merge_settings.allow_auto_merge        bool      (repo setting; needed by the
#   merge_settings.delete_branch_on_merge  bool       maintenance approval gate #224;
#                                                     merge_settings = null when unreadable)
#   secrets.names                          []string  (configured Actions secrets)
#   sonar_project_exists                   bool | null  (null = unknown / private / no project key)
#
# `github_state` is `{}` when has_github_remote=false OR gh is not
# authenticated. State="skipped" means a specific probe didn't run
# (e.g., no project key for the Sonar probe).
#
# All paths are evaluated relative to the current working directory.

set -euo pipefail

cwd="$(pwd)"

# --- args --------------------------------------------------------------------
# --interfaces cli,rest,web-ui,library  overrides interface auto-detection
# (detection is advisory; bootstrap presents the detected set and lets the user
# confirm/correct before rendering acceptance workflows — #242). Unknown args
# are ignored so the JSON contract stays additive for existing callers.
interfaces_override=""
containers_override=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--interfaces)
		interfaces_override="${2:-}"
		shift 2 2>/dev/null || shift
		;;
	--interfaces=*)
		interfaces_override="${1#*=}"
		shift
		;;
	--containers)
		containers_override="${2:-}"
		shift 2 2>/dev/null || shift
		;;
	--containers=*)
		containers_override="${1#*=}"
		shift
		;;
	*)
		shift
		;;
	esac
done

json_bool() { [[ "$1" == "true" ]] && printf "true" || printf "false"; }
# Escape backslash FIRST, then double-quote — #799 widened this helper's input
# domain to filesystem/content-derived values (dir names, evidence paths,
# rootProject.name), so an unescaped backslash would emit invalid JSON.
json_str() {
	local s="${1//\\/\\\\}"
	s="${s//\"/\\\"}"
	# escape the control chars that can appear in filesystem-derived values; a raw
	# tab/newline/CR in a JSON string is invalid and breaks jq-consuming callers.
	s="${s//$'\t'/\\t}"
	s="${s//$'\n'/\\n}"
	s="${s//$'\r'/\\r}"
	printf '"%s"' "$s"
}

# --- git ---------------------------------------------------------------------
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
	git_initialized="true"
else
	git_initialized="false"
fi

# --- github remote -----------------------------------------------------------
has_github_remote="false"
github_repo=""
default_branch=""
visibility="unknown"

if [[ "$git_initialized" == "true" ]]; then
	origin_url="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
	if [[ "$origin_url" =~ github\.com[:/]+([^/]+/[^/.]+) ]]; then
		has_github_remote="true"
		github_repo="${BASH_REMATCH[1]}"
	fi

	if command -v gh >/dev/null 2>&1 && [[ "$has_github_remote" == "true" ]]; then
		gh_json="$(gh repo view "$github_repo" --json visibility,defaultBranchRef 2>/dev/null || true)"
		if [[ -n "$gh_json" ]]; then
			vis_raw="$(printf '%s' "$gh_json" | sed -n 's/.*"visibility":"\([^"]*\)".*/\1/p')"
			case "$vis_raw" in
			PUBLIC) visibility="public" ;;
			PRIVATE) visibility="private" ;;
			*) visibility="unknown" ;;
			esac
			default_branch="$(printf '%s' "$gh_json" | sed -n 's/.*"defaultBranchRef":{"name":"\([^"]*\)".*/\1/p')"
		fi
	fi

	# Fall back to the locally-checked-out branch when gh didn't tell us
	# (no remote, no auth, or repo view failed). Without this fallback the
	# orchestrator has no value to substitute for {{DEFAULT_BRANCH}}.
	if [[ -z "$default_branch" ]]; then
		default_branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || echo "")"
	fi
fi

# --- languages ---------------------------------------------------------------
detect_lang() {
	local lang="$1"
	shift
	for marker in "$@"; do
		while IFS= read -r -d '' _; do
			printf '%s\n' "$lang"
			return
		done < <(find "$cwd" \
			-path '*/node_modules' -prune -o \
			-path '*/.git' -prune -o \
			-path '*/vendor' -prune -o \
			-path '*/.build' -prune -o \
			-path '*/dist' -prune -o \
			-name "$marker" -print0 2>/dev/null)
	done
}

langs=()
[[ -n "$(detect_lang swift Package.swift '*.xcodeproj' '*.xcworkspace')" ]] && langs+=("swift")
[[ -n "$(detect_lang typescript package.json tsconfig.json)" ]] && langs+=("typescript")
[[ -n "$(detect_lang python pyproject.toml requirements.txt setup.py)" ]] && langs+=("python")
[[ -n "$(detect_lang go go.mod)" ]] && langs+=("go")
[[ -n "$(detect_lang java build.gradle 'build.gradle.kts' settings.gradle 'settings.gradle.kts' pom.xml)" ]] && langs+=("java")

languages_json="["
for i in "${!langs[@]}"; do
	[[ "$i" -gt 0 ]] && languages_json+=","
	languages_json+="$(json_str "${langs[$i]}")"
done
languages_json+="]"

# --- python version + pytest-cov --------------------------------------------
# Both only meaningful when Python is in the detected language set. We still
# emit defaults ("3.12" / false) when Python isn't detected so the
# orchestrator doesn't have to special-case the JSON shape.
python_version=""
python_version_source="default"
has_pytest_cov="false"

python_in_langs="false"
for l in ${langs[@]+"${langs[@]}"}; do
	[[ "$l" == "python" ]] && python_in_langs="true"
done

if [[ "$python_in_langs" == "true" ]]; then
	pyproject="$cwd/pyproject.toml"

	# Parse `requires-python` and strip operators (>=, ~=, ^, <, >). Prefer
	# python3's tomllib (stdlib 3.11+); fall back to grep so the script
	# doesn't hard-require a recent Python on the host.
	if [[ -f "$pyproject" ]] && command -v python3 >/dev/null 2>&1; then
		python_version="$(
			python3 - <<EOF 2>/dev/null || true
import re, sys
try:
    import tomllib
    with open("$pyproject", "rb") as f:
        data = tomllib.load(f)
    rp = data.get("project", {}).get("requires-python", "")
    m = re.search(r"\d+\.\d+", rp)
    print(m.group(0) if m else "")
except Exception:
    pass
EOF
		)"
	fi

	# Fallback: grep for "requires-python" if Python's tomllib path didn't
	# yield anything (older python3 on host, malformed file, etc.).
	if [[ -z "$python_version" && -f "$pyproject" ]]; then
		# `|| true`: a no-match grep exits 1, which under `set -euo pipefail`
		# (pipefail) would abort the script before the 3.12 fallback below — the
		# common case of a pyproject.toml without `requires-python`.
		python_version="$(grep -E '^[[:space:]]*requires-python' "$pyproject" 2>/dev/null |
			grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
	fi

	# Sensible default — current stable interpreter at time of writing.
	# Track whether the version was parsed from a manifest or guessed, so
	# downstream can distinguish a real pin from a fallback (#258 reliability).
	if [[ -n "$python_version" ]]; then
		python_version_source="parsed"
	else
		python_version="3.12"
		python_version_source="default"
	fi

	# pytest-cov detection: search pyproject dev extras + requirements files.
	if [[ -f "$pyproject" ]] && command -v python3 >/dev/null 2>&1; then
		if python3 - <<EOF >/dev/null 2>&1; then
import sys
try:
    import tomllib
    with open("$pyproject", "rb") as f:
        data = tomllib.load(f)
    deps = data.get("project", {}).get("optional-dependencies", {}).get("dev", [])
    for d in deps:
        if d.lower().startswith("pytest-cov"):
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
EOF
			has_pytest_cov="true"
		fi
	fi

	# Also scan requirements*.txt files (a common pattern for projects that
	# split runtime + dev deps across multiple manifest files).
	if [[ "$has_pytest_cov" == "false" ]]; then
		for rf in "$cwd"/requirements*.txt; do
			[[ -f "$rf" ]] || continue
			if grep -qiE '^[[:space:]]*pytest-cov' "$rf" 2>/dev/null; then
				has_pytest_cov="true"
				break
			fi
		done
	fi
fi

# --- java version + build system + jacoco -----------------------------------
# Only meaningful when Java is detected. Gradle-first (#296): when both Gradle
# and Maven markers exist, classify as gradle. Maven is recorded but
# unsupported. Version sources, in priority order: Gradle toolchain
# `JavaLanguageVersion.of(N)`, Gradle source/targetCompatibility, `.java-version`,
# then Maven compiler properties; default to the current LTS.
java_version=""
java_version_source="default"
java_build_system=""
has_jacoco="false"

java_in_langs="false"
for l in ${langs[@]+"${langs[@]}"}; do
	[[ "$l" == "java" ]] && java_in_langs="true"
done

if [[ "$java_in_langs" == "true" ]]; then
	# Candidate build files (prune build-output + VCS dirs). Newline-separated;
	# passed unquoted to grep below, which is safe for the conventional
	# space-free Gradle/Maven filenames these globs match.
	gradle_files="$(find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/.gradle' -prune -o \
		-path '*/build' -prune -o \
		\( -name 'build.gradle' -o -name 'build.gradle.kts' \) -print 2>/dev/null)"
	pom_files="$(find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/target' -prune -o \
		-name 'pom.xml' -print 2>/dev/null)"

	# Build system: Gradle wins when both are present.
	gradle_settings="$(find "$cwd" \
		-path '*/.git' -prune -o \
		\( -name 'settings.gradle' -o -name 'settings.gradle.kts' \) -print -quit 2>/dev/null)"
	if [[ -n "$gradle_files" || -n "$gradle_settings" ]]; then
		java_build_system="gradle"
	elif [[ -n "$pom_files" ]]; then
		java_build_system="maven"
	fi

	# Gradle DSL flavor (#343 Kotlin-DSL-only policy). The family maintains
	# ONLY build.gradle.kts; a Groovy build.gradle must be converted to be
	# maintained, and Maven is out of scope. Emit the flavor so consumers
	# (bootstrap, maintenance) can route: "kotlin" → proceed; "groovy" →
	# needs conversion; "" → not Gradle (Maven/none). A `.kts` anywhere wins
	# (a repo with both is treated as Kotlin — that's the one we maintain).
	java_gradle_dsl=""
	if [[ "$java_build_system" == "gradle" ]]; then
		if printf '%s\n' "$gradle_files" "$gradle_settings" | grep -q '\.kts$'; then
			java_gradle_dsl="kotlin"
		elif [[ -n "$gradle_files" || -n "$gradle_settings" ]]; then
			java_gradle_dsl="groovy"
		fi
	fi

	# --- version (first match wins) ---
	# 1) Gradle toolchain languageVersion = JavaLanguageVersion.of(N)
	if [[ -z "$java_version" && -n "$gradle_files" ]]; then
		# shellcheck disable=SC2086
		java_version="$(grep -hoE 'JavaLanguageVersion\.of\([0-9]+\)' $gradle_files 2>/dev/null |
			grep -oE '[0-9]+' | head -n1 || true)"
	fi
	# 2) Gradle source/targetCompatibility (JavaVersion.VERSION_N or numeric)
	if [[ -z "$java_version" && -n "$gradle_files" ]]; then
		# shellcheck disable=SC2086
		java_version="$(grep -hoE '(source|target)Compatibility[^0-9]*[0-9]+' $gradle_files 2>/dev/null |
			grep -oE '[0-9]+' | head -n1 || true)"
	fi
	# 3) .java-version (asdf / jenv)
	if [[ -z "$java_version" && -f "$cwd/.java-version" ]]; then
		java_version="$(grep -oE '[0-9]+' "$cwd/.java-version" 2>/dev/null | head -n1 || true)"
	fi
	# 4) Maven compiler properties
	if [[ -z "$java_version" && -n "$pom_files" ]]; then
		# shellcheck disable=SC2086
		java_version="$(grep -hoE '<(maven\.compiler\.release|java\.version|maven\.compiler\.source)>[0-9]+' $pom_files 2>/dev/null |
			grep -oE '[0-9]+' | head -n1 || true)"
	fi
	# Default to the current LTS at time of writing. Track parsed-vs-guessed
	# (#258 reliability) — the build SHOULD declare its toolchain, and the
	# maintainer's forward-compat matrix (deploy on LTS, probe newer non-LTS)
	# needs to know the real declared version, not a fallback.
	if [[ -n "$java_version" ]]; then
		java_version_source="parsed"
	else
		java_version="21"
		java_version_source="default"
	fi

	# --- jacoco (coverage analog of pytest-cov) ---
	# shellcheck disable=SC2086
	if [[ -n "$gradle_files" ]] && grep -qE 'jacoco' $gradle_files 2>/dev/null; then
		has_jacoco="true"
	elif [[ -n "$pom_files" ]] && grep -qE 'jacoco-maven-plugin' $pom_files 2>/dev/null; then
		has_jacoco="true"
	fi
fi

# --- swift version + build system + coverage --------------------------------
# Only meaningful when Swift is detected (#297 Slice A). Build system: Xcode
# wins when an .xcodeproj/.xcworkspace is present (the app is the product); a
# bare Package.swift (no Xcode project) is SwiftPM. Version sources, first match
# wins: Package.swift `// swift-tools-version:`, then `.swift-version`, then the
# Xcode `SWIFT_VERSION` build setting; default to the current stable. Coverage
# is toolchain-built-in for Swift (no JaCoCo-style dependency to declare), so
# `has_cov` records the real precondition: whether test targets exist to measure.
swift_version=""
swift_version_source="default"
swift_build_system=""
has_swift_cov="false"

swift_in_langs="false"
for l in ${langs[@]+"${langs[@]}"}; do
	[[ "$l" == "swift" ]] && swift_in_langs="true"
done

if [[ "$swift_in_langs" == "true" ]]; then
	# Build system: Xcode wins when a project/workspace is present.
	xcode_proj="$(find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/.build' -prune -o \
		\( -name '*.xcodeproj' -o -name '*.xcworkspace' \) -print -quit 2>/dev/null)"
	package_swift="$(find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/.build' -prune -o \
		-name 'Package.swift' -print -quit 2>/dev/null)"
	if [[ -n "$xcode_proj" ]]; then
		swift_build_system="xcode"
	elif [[ -n "$package_swift" ]]; then
		swift_build_system="swiftpm"
	fi

	# --- version (first match wins) ---
	# 1) Package.swift tools-version pin: `// swift-tools-version:6.0`
	if [[ -z "$swift_version" && -n "$package_swift" ]]; then
		swift_version="$(grep -oiE 'swift-tools-version:[[:space:]]*[0-9]+(\.[0-9]+)?' "$package_swift" 2>/dev/null |
			grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)"
	fi
	# 2) .swift-version (swiftenv)
	if [[ -z "$swift_version" && -f "$cwd/.swift-version" ]]; then
		swift_version="$(grep -oE '[0-9]+(\.[0-9]+)?' "$cwd/.swift-version" 2>/dev/null | head -n1 || true)"
	fi
	# 3) Xcode SWIFT_VERSION build setting (language mode) from the pbxproj
	if [[ -z "$swift_version" ]]; then
		pbxproj="$(find "$cwd" \
			-path '*/.git' -prune -o \
			-name 'project.pbxproj' -print -quit 2>/dev/null)"
		if [[ -n "$pbxproj" ]]; then
			swift_version="$(grep -oE 'SWIFT_VERSION = [0-9]+(\.[0-9]+)?' "$pbxproj" 2>/dev/null |
				grep -oE '[0-9]+(\.[0-9]+)?' | head -n1 || true)"
		fi
	fi
	# Default to the current stable Swift at time of writing. Track parsed-vs-
	# guessed (#258 reliability) — Swift 6 migration work (Slice G) needs the
	# real declared version, not a fallback.
	if [[ -n "$swift_version" ]]; then
		swift_version_source="parsed"
	else
		swift_version="6.0"
		swift_version_source="default"
	fi

	# --- coverage precondition: test targets present ---
	# SwiftPM: a `.testTarget(` in Package.swift or a Tests/ dir. Otherwise any
	# XCTest file (conventionally named `*Tests.swift` / `*Test.swift`).
	if [[ -n "$package_swift" ]] && grep -qE '\.testTarget\(' "$package_swift" 2>/dev/null; then
		has_swift_cov="true"
	elif [[ -d "$cwd/Tests" ]]; then
		has_swift_cov="true"
	elif find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/.build' -prune -o \
		\( -name '*Tests.swift' -o -name '*Test.swift' \) -print -quit 2>/dev/null | grep -q .; then
		has_swift_cov="true"
	fi
fi

# --- interfaces (issue #242) -------------------------------------------------
# The runtime interface(s) through which a deployed build is exercised — the
# signal that lets bootstrap render interface-appropriate acceptance tests
# (#243). A *set*: a project can be several at once (a CLI plus a web UI). v1
# heuristics are PYTHON-only; other languages emit their own under their
# plugins, so `interfaces` is [] when Python isn't detected. Detection is
# ADVISORY — `--interfaces` overrides it outright.
#
# The Flask/Django dependency alone can't tell rest from web-ui — the UI
# markers disambiguate: a web framework serving templates/static/a frontend
# build is a browser UI (web-ui); serving neither is a bare API (rest).
# `library` is the fallback — a [project] build target with no cli/rest/web-ui.
interfaces_json="[]"
# Space-separated interface names (e.g. "cli web-ui"), used below to decide
# whether the interface-gated acceptance artifacts are an expected gap (#714).
detected_ifaces=""

# emit_interfaces_json: newline-separated "interface|evidence" pairs -> JSON array.
emit_interfaces_json() {
	local pairs="$1" out="[" first=1 line iface ev
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		iface="${line%%|*}"
		ev="${line#*|}"
		[[ $first -eq 1 ]] && first=0 || out+=","
		out+="$(printf '{"interface":%s,"evidence":%s}' "$(json_str "$iface")" "$(json_str "$ev")")"
	done <<<"$pairs"
	out+="]"
	printf '%s' "$out"
}

if [[ -n "$interfaces_override" ]]; then
	# User-specified set wins outright; each named interface records the override.
	iface_pairs=""
	iface_oldifs="$IFS"
	IFS=','
	for iface in $interfaces_override; do
		iface="$(printf '%s' "$iface" | tr -d '[:space:]')"
		[[ -z "$iface" ]] && continue
		iface_pairs+="$iface|user override"$'\n'
	done
	IFS="$iface_oldifs"
	interfaces_json="$(emit_interfaces_json "$iface_pairs")"
	detected_ifaces="$(printf '%s' "$iface_pairs" | sed 's/|.*//' | tr '\n' ' ')"
elif [[ "$python_in_langs" == "true" ]]; then
	pyproject="$cwd/pyproject.toml"
	iface_pairs=""

	# Lowercased pyproject as a dependency haystack for framework/lib checks.
	# Coarse (the whole file, not just [dependencies]) but adequate for a
	# name-presence heuristic, and it degrades to "" when there's no pyproject.
	dep_hay=""
	[[ -f "$pyproject" ]] && dep_hay="$(tr '[:upper:]' '[:lower:]' <"$pyproject" 2>/dev/null || true)"

	# --- cli: an installable entry point, a runnable module, or a CLI framework.
	cli_ev=""
	if [[ -f "$pyproject" ]] && grep -qE '^\[project\.scripts\]' "$pyproject" 2>/dev/null; then
		cli_ev="[project.scripts] entry point in pyproject.toml"
	elif [[ -f "$pyproject" ]] && grep -qE '^\[project\.entry-points\."?console_scripts"?\]' "$pyproject" 2>/dev/null; then
		cli_ev="console_scripts entry point in pyproject.toml"
	elif find "$cwd" \
		-path '*/.git' -prune -o \
		-path '*/.venv' -prune -o \
		-path '*/venv' -prune -o \
		-path '*/.tox' -prune -o \
		-path '*/node_modules' -prune -o \
		-path '*/.build' -prune -o \
		-path '*/dist' -prune -o \
		-name '__main__.py' -print 2>/dev/null | grep -q .; then
		cli_ev="__main__.py runnable module present"
	elif [[ -n "$dep_hay" ]] && printf '%s' "$dep_hay" | grep -qE '(^|[^a-z])(click|typer)([^a-z]|$)'; then
		cli_ev="click/typer in dependencies"
	fi
	[[ -n "$cli_ev" ]] && iface_pairs+="cli|$cli_ev"$'\n'

	# --- web framework? -> rest vs web-ui, disambiguated by UI markers.
	web_fw=""
	if [[ -n "$dep_hay" ]]; then
		for fw in fastapi flask django starlette aiohttp sanic tornado bottle falcon quart; do
			if printf '%s' "$dep_hay" | grep -qE "(^|[^a-z])$fw([^a-z]|\$)"; then
				web_fw="$fw"
				break
			fi
		done
	fi
	if [[ -n "$web_fw" ]]; then
		ui_ev=""
		# 1) a server-side template engine in deps
		if printf '%s' "$dep_hay" | grep -qE '(^|[^a-z])jinja2([^a-z]|$)'; then
			ui_ev="$web_fw + jinja2 in dependencies (server-rendered templates)"
		fi
		# 2) template/static assets wired into pyproject package-data
		if [[ -z "$ui_ev" && -f "$pyproject" ]] && grep -qiE '(templates?/|static/|\.html)' "$pyproject" 2>/dev/null; then
			ui_ev="$web_fw + templates/static in pyproject package-data"
		fi
		# 3) a templates/ or static/ directory in the source tree
		if [[ -z "$ui_ev" ]]; then
			ui_dir="$(find "$cwd" \
				-path '*/.git' -prune -o \
				-path '*/.venv' -prune -o \
				-path '*/venv' -prune -o \
				-path '*/node_modules' -prune -o \
				-path '*/.build' -prune -o \
				-type d \( -name templates -o -name static \) -print -quit 2>/dev/null)"
			[[ -n "$ui_dir" ]] && ui_ev="$web_fw + ${ui_dir##*/}/ directory in source tree"
		fi
		# 4) a frontend build (package.json with a build script) alongside python
		if [[ -z "$ui_ev" ]]; then
			fe_pkg="$(find "$cwd" -maxdepth 2 -name package.json \
				-not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null)"
			if [[ -n "$fe_pkg" ]] && grep -qE '"build"[[:space:]]*:' "$fe_pkg" 2>/dev/null; then
				ui_ev="$web_fw + frontend build (package.json build script)"
			fi
		fi
		if [[ -n "$ui_ev" ]]; then
			iface_pairs+="web-ui|$ui_ev"$'\n'
		else
			iface_pairs+="rest|$web_fw in dependencies (no server-rendered UI detected)"$'\n'
		fi
	fi

	# --- library: a [project] build target with no runtime interface of its own.
	if [[ -z "$iface_pairs" && -f "$pyproject" ]] && grep -qE '^\[project\]' "$pyproject" 2>/dev/null; then
		iface_pairs="library|[project] build target with no cli/rest/web-ui interface"$'\n'
	fi

	interfaces_json="$(emit_interfaces_json "$iface_pairs")"
	detected_ifaces="$(printf '%s' "$iface_pairs" | sed 's/|.*//' | tr '\n' ' ')"
fi

# --- language_meta (nested per-language detection metadata) ------------------
# Replaces the former flat python_version / has_pytest_cov keys; keyed by
# language so each carries its own metadata (issue #305). Only detected
# languages get an entry.
language_meta_json="{"
lm_first=1
if [[ "$python_in_langs" == "true" ]]; then
	[[ $lm_first -eq 1 ]] && lm_first=0 || language_meta_json+=","
	language_meta_json+="$(printf '"python":{"version":%s,"version_source":%s,"has_cov":%s}' \
		"$(json_str "$python_version")" "$(json_str "$python_version_source")" "$(json_bool "$has_pytest_cov")")"
fi
if [[ "$java_in_langs" == "true" ]]; then
	[[ $lm_first -eq 1 ]] && lm_first=0 || language_meta_json+=","
	language_meta_json+="$(printf '"java":{"version":%s,"version_source":%s,"build_system":%s,"gradle_dsl":%s,"has_cov":%s}' \
		"$(json_str "$java_version")" "$(json_str "$java_version_source")" "$(json_str "$java_build_system")" "$(json_str "$java_gradle_dsl")" "$(json_bool "$has_jacoco")")"
fi
if [[ "$swift_in_langs" == "true" ]]; then
	[[ $lm_first -eq 1 ]] && lm_first=0 || language_meta_json+=","
	language_meta_json+="$(printf '"swift":{"version":%s,"version_source":%s,"build_system":%s,"has_cov":%s}' \
		"$(json_str "$swift_version")" "$(json_str "$swift_version_source")" "$(json_str "$swift_build_system")" "$(json_bool "$has_swift_cov")")"
fi
language_meta_json+="}"

# --- dockerfile --------------------------------------------------------------
has_dockerfile="false"
if [[ -f "$cwd/Dockerfile" ]] ||
	[[ -f "$cwd/docker/Dockerfile" ]] ||
	find "$cwd" -maxdepth 3 -name 'Dockerfile' -not -path '*/node_modules/*' -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
	has_dockerfile="true"
fi

# --- containers + contracts (issue #799) -------------------------------------
# The named deployable images this repo builds, detected across the family's
# blessed mechanisms and emitted as evidence-bearing entries (not a boolean), so
# C4 seeding (#791) and c4_drift (#793) can name real containers. Purely additive:
# has_dockerfile keeps its exact prior semantics.

# emit_containers_json: newline-separated "name|source|evidence" -> JSON array.
emit_containers_json() {
	local pairs="$1" out="[" first=1 line nm rest src ev
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		nm="${line%%|*}"
		rest="${line#*|}"
		src="${rest%%|*}"
		ev="${rest#*|}"
		[[ $first -eq 1 ]] && first=0 || out+=","
		out+="$(printf '{"name":%s,"source":%s,"evidence":%s}' \
			"$(json_str "$nm")" "$(json_str "$src")" "$(json_str "$ev")")"
	done <<<"$pairs"
	out+="]"
	printf '%s' "$out"
}

# emit_contracts_json: newline-separated "type|evidence" -> JSON array.
emit_contracts_json() {
	local pairs="$1" out="[" first=1 line ty ev
	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		ty="${line%%|*}"
		ev="${line#*|}"
		[[ $first -eq 1 ]] && first=0 || out+=","
		out+="$(printf '{"type":%s,"evidence":%s}' "$(json_str "$ty")" "$(json_str "$ev")")"
	done <<<"$pairs"
	out+="]"
	printf '%s' "$out"
}

# repo_dir_name: the repository's directory name, worktree-SAFE (#833). Inside a
# git worktree (e.g. a resolve-issue worktree under .claude/worktrees/<name>),
# `basename "$cwd"` is the WORKTREE's name, not the repo — which wrongly named a
# seeded container after the worktree dir (session c2561459). `git rev-parse
# --git-common-dir` resolves to the MAIN repo's .git regardless of which worktree
# we're in; its parent directory is the main checkout's toplevel, whose basename
# is the repo name. Falls back to `basename "$cwd"` only when cwd is not a git
# repo at all (State A, before `git init`).
repo_dir_name() {
	local common_dir root
	# --git-common-dir resolves to the MAIN repo's .git even from a linked
	# worktree (--path-format=absolute guarantees an absolute path; needs git
	# >= 2.31). Only the standard "<root>/.git" shape lets us take its PARENT as
	# the repo toplevel — a submodule (".git/modules/<p>"), a --separate-git-dir,
	# or a bare setup does NOT, so those fall back to the checkout dir name
	# (correct for a submodule, and .claude/worktrees don't apply to them here).
	if common_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" &&
		[[ -n "$common_dir" && "$(basename "$common_dir")" == ".git" ]]; then
		root="$(dirname "$common_dir")"
		basename "$root"
	else
		basename "$cwd"
	fi
}

# The gradle root project name (the deployable identifier for a bootBuildImage /
# Jib image), falling back to the repo directory name.
gradle_project_name() {
	local sf line val
	for sf in "$cwd/settings.gradle.kts" "$cwd/settings.gradle"; do
		[[ -f "$sf" ]] || continue
		# first uncommented rootProject.name assignment
		line="$(grep -E '^[[:space:]]*rootProject\.name[[:space:]]*=' "$sf" 2>/dev/null | head -1 || true)"
		[[ -z "$line" ]] && continue
		# the value must be a quoted LITERAL directly after '=' — this rejects a
		# non-literal form like `= System.getenv("APP_NAME")` (whose first quote
		# would otherwise be mistaken for the name), falling through to basename.
		val="${line#*=}"
		val="${val#"${val%%[![:space:]]*}"}" # strip leading whitespace
		case "$val" in
		\"*)
			val="${val#\"}"
			val="${val%%\"*}"
			;;
		\'*)
			val="${val#\'}"
			val="${val%%\'*}"
			;;
		*) val="" ;;
		esac
		[[ -n "$val" ]] && {
			printf '%s' "$val"
			return
		}
	done
	repo_dir_name
}

# gradle_plugin_applied: true when a Gradle build file APPLIES the given plugin
# id and NOT merely declares it `apply false` (the multi-module root aggregator
# pattern, which builds no image on the root). Matches the Kotlin `id("<id>")`,
# the paren-less Groovy `id '<id>'`, and the `apply plugin: "<id>"` forms; a
# dependency coordinate (`<id>:artifact`) never matches because it has a `:`
# where the closing quote would be. $2 is a dot-escaped literal.
gradle_plugin_applied() {
	local f="$1" pid="$2" lines
	lines="$(grep -E "id[[:space:]]*\\(?[[:space:]]*[\"']${pid}[\"']|apply plugin:[[:space:]]*[\"']${pid}[\"']" "$f" 2>/dev/null || true)"
	[[ -z "$lines" ]] && return 1
	# applied iff at least one matching line is NOT an `apply false` / `apply(false)`
	printf '%s\n' "$lines" | grep -qvE 'apply[[:space:]]*\(?[[:space:]]*false'
}

# extract_compose_services: the service names under a compose file's top-level
# `services:` key, indentation-agnostic (locks to the first service's indent).
extract_compose_services() {
	awk '
		BEGIN { inservices=0; svc_indent=-1 }
		/^[^[:space:]#]/ { if (inservices) inservices=0 }
		/^services:/ { inservices=1; svc_indent=-1; next }
		inservices {
			if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
			match($0, /^[[:space:]]*/); ind=RLENGTH
			if (svc_indent==-1) svc_indent=ind
			if (ind==svc_indent && $0 ~ /^[[:space:]]*["'\'']?[A-Za-z0-9._-]+["'\'']?:/) {
				name=$0
				sub(/^[[:space:]]*/,"",name)
				sub(/:.*$/,"",name)
				gsub(/["'\'']/,"",name)
				print name
			} else if (ind < svc_indent) { inservices=0 }
		}
	' "$1" 2>/dev/null || true
}

# extract_compose_builds: for each service that BUILDS (rather than only pulling a
# prebuilt `image:`), emit "context|dockerfile" — the build context and the
# Dockerfile name it builds. Both the inline scalar (`build: .`) and the block
# (`build:` / `context:` / `dockerfile:`) forms are handled. Empty fields mean the
# compose defaults (context ".", dockerfile "Dockerfile"). Used by #859 to collapse
# a compose service that builds from a Dockerfile we ALSO detected as its own
# `dockerfile`-source container — one deployable, not two.
extract_compose_builds() {
	awk '
		BEGIN { inservices=0; svc_indent=-1; buildseen=0; inbuild=0; ctx=""; dfile="" }
		function flush() {
			if (buildseen) print ctx "|" dfile
			buildseen=0; inbuild=0; ctx=""; dfile=""
		}
		/^[^[:space:]#]/ { if (inservices) { flush(); inservices=0 } }
		/^services:/ { inservices=1; svc_indent=-1; next }
		inservices {
			if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
			match($0, /^[[:space:]]*/); ind=RLENGTH
			if (svc_indent==-1) svc_indent=ind
			if (ind==svc_indent && $0 ~ /^[[:space:]]*["'\'']?[A-Za-z0-9._-]+["'\'']?:/) {
				flush()   # entering a new service — close the previous one
			} else if (ind < svc_indent) { flush(); inservices=0; next }
			# inline scalar: build: <ctx>
			if ($0 ~ /^[[:space:]]*build:[[:space:]]*[^[:space:]#]/) {
				buildseen=1; inbuild=0
				v=$0; sub(/^[[:space:]]*build:[[:space:]]*/,"",v); sub(/[[:space:]]*(#.*)?$/,"",v); gsub(/["'\'']/,"",v)
				ctx=v
			} else if ($0 ~ /^[[:space:]]*build:[[:space:]]*$/) {
				buildseen=1; inbuild=1
			} else if (inbuild && $0 ~ /^[[:space:]]*context:/) {
				v=$0; sub(/^[[:space:]]*context:[[:space:]]*/,"",v); sub(/[[:space:]]*(#.*)?$/,"",v); gsub(/["'\'']/,"",v); ctx=v
			} else if (inbuild && $0 ~ /^[[:space:]]*dockerfile:/) {
				v=$0; sub(/^[[:space:]]*dockerfile:[[:space:]]*/,"",v); sub(/[[:space:]]*(#.*)?$/,"",v); gsub(/["'\'']/,"",v); dfile=v
			}
		}
		END { if (inservices) flush() }
	' "$1" 2>/dev/null || true
}

# normalize_relpath: collapse "//", "/./", and leading "./" in a repo-relative
# path so a built Dockerfile path can be matched against a detected one. Uses sed
# (the bash `${p//\/.\//\/}` form inserts a literal backslash in the replacement).
# "../" is left as-is: a compose context above its own dir is vanishingly rare and
# never matches a repo-local Dockerfile entry anyway.
normalize_relpath() {
	printf '%s' "$1" | sed -e 's#//*#/#g' -e 's#/\./#/#g' -e 's#^\(\./\)*##' -e 's#/\.$##'
}

container_pairs="" # name|source|evidence, newline-separated
contract_pairs=""  # type|evidence, newline-separated
detection_confidence="complete"

if [[ -n "$containers_override" ]]; then
	# The user's set wins outright (mirrors --interfaces). Split into an array so
	# a field like '*' is NOT pathname-expanded against the cwd (read -a is
	# bash-3.2-safe and does no globbing).
	IFS=',' read -r -a override_names <<<"$containers_override"
	# bash 3.2: an empty array under set -u errors on "${arr[@]}" — guard it.
	for cnm in ${override_names[@]+"${override_names[@]}"}; do
		cnm="$(printf '%s' "$cnm" | tr -d '[:space:]')"
		[[ -z "$cnm" ]] && continue
		container_pairs+="$cnm|user override|user override"$'\n'
	done
else
	# --- Dockerfile / Containerfile (paths, not presence) ---
	while IFS= read -r df; do
		[[ -z "$df" ]] && continue
		rel="${df#"$cwd"/}"
		d="$(dirname "$rel")"
		bn="$(basename "$df")"
		if [[ "$d" == "." || "$d" == "docker" ]]; then
			cname="$(repo_dir_name)"
		else
			pdir="$(basename "$d")"
			if [[ "$pdir" == "docker" ]]; then cname="$(basename "$(dirname "$d")")"; else cname="$pdir"; fi
		fi
		if [[ "$bn" == "Containerfile" ]]; then csrc="containerfile"; else csrc="dockerfile"; fi
		container_pairs+="$cname|$csrc|./$rel"$'\n'
	done < <(find "$cwd" -maxdepth 3 \( -name Dockerfile -o -name Containerfile \) \
		-not -path '*/node_modules/*' -not -path '*/.git/*' -print 2>/dev/null | sort)

	# --- compose services ---
	# compose_built_df collects the repo-relative Dockerfile path each building
	# service compiles, so #859 can drop a `dockerfile`-source entry that is the
	# same deployable as a compose service that builds it.
	compose_built_df=""
	while IFS= read -r cf; do
		[[ -z "$cf" ]] && continue
		crel="${cf#"$cwd"/}"
		cdir="$(dirname "$crel")"
		while IFS= read -r svc; do
			[[ -z "$svc" ]] && continue
			container_pairs+="$svc|compose|$crel#services.$svc"$'\n'
		done < <(extract_compose_services "$cf")
		while IFS='|' read -r bctx bdfile; do
			[[ -z "$bctx" ]] && bctx="."
			[[ -z "$bdfile" ]] && bdfile="Dockerfile"
			compose_built_df+="$(normalize_relpath "$cdir/$bctx/$bdfile")"$'\n'
		done < <(extract_compose_builds "$cf")
	done < <(find "$cwd" -maxdepth 2 \
		\( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) \
		-not -path '*/node_modules/*' -not -path '*/.git/*' -print 2>/dev/null | sort)

	# #859: a compose service that builds from a Dockerfile we also emitted as a
	# `dockerfile`/`containerfile` container is ONE deployable — drop the Dockerfile
	# entry (its name is a repo-dir-name guess) and keep the compose service (whose
	# name is the real image identity). Match on the resolved Dockerfile path
	# (a dockerfile entry's evidence `./<rel>` vs the built `<rel>`).
	if [[ -n "$compose_built_df" ]]; then
		# Pass the built-Dockerfile set through the environment, not `-v`: a `-v`
		# value carrying newlines aborts BSD awk ("newline in string").
		container_pairs="$(printf '%s' "$container_pairs" | COMPOSE_BUILT_DF="$compose_built_df" awk -F'|' '
			BEGIN { n=split(ENVIRON["COMPOSE_BUILT_DF"], a, "\n"); for (i=1;i<=n;i++) if (a[i]!="") B[a[i]]=1 }
			NF {
				ev=$3; sub(/^\.\//,"",ev)
				if (($2=="dockerfile" || $2=="containerfile") && (ev in B)) next
				print
			}')"
	fi

	# --- bootBuildImage (Spring Boot Gradle plugin, no Dockerfile) + Jib ---
	while IFS= read -r bf; do
		[[ -z "$bf" ]] && continue
		brel="${bf#"$cwd"/}"
		bdir="$(dirname "$brel")"
		if [[ "$bdir" == "." ]]; then bname="$(gradle_project_name)"; else bname="$(basename "$bdir")"; fi
		if gradle_plugin_applied "$bf" 'com\.google\.cloud\.tools\.jib'; then
			container_pairs+="$bname|jib|Jib plugin applied in $brel"$'\n'
		fi
		# bootBuildImage is available when the Spring Boot plugin is APPLIED (not
		# `apply false`, not a dependency coordinate), or configured explicitly via
		# a bootBuildImage task block. The literal fallback is GATED so it does not
		# re-admit an `apply false` aggregator root (which may still mention the
		# task in a subprojects{} block or a comment) that builds no image itself.
		if gradle_plugin_applied "$bf" 'org\.springframework\.boot' ||
			{ grep -qE 'bootBuildImage' "$bf" 2>/dev/null &&
				! grep -qE 'org\.springframework\.boot.*apply[[:space:]]*\(?[[:space:]]*false' "$bf" 2>/dev/null; }; then
			container_pairs+="$bname|bootBuildImage|bootBuildImage via the Spring Boot Gradle plugin in $brel"$'\n'
		fi
	done < <(find "$cwd" -maxdepth 2 \( -name 'build.gradle.kts' -o -name 'build.gradle' \) \
		-not -path '*/build/*' -not -path '*/.git/*' -print 2>/dev/null | sort)
fi

# --- contracts (OpenAPI + proto), independent of the --containers override ---
while IFS= read -r sp; do
	[[ -z "$sp" ]] && continue
	contract_pairs+="openapi|${sp#"$cwd"/}"$'\n'
done < <(find "$cwd" -maxdepth 3 \
	\( -iname 'openapi.yaml' -o -iname 'openapi.yml' -o -iname 'openapi.json' \
	-o -iname 'swagger.yaml' -o -iname 'swagger.yml' -o -iname 'swagger.json' \
	-o -iname '*.openapi.yaml' -o -iname '*.openapi.yml' -o -iname '*.openapi.json' \) \
	-not -path '*/node_modules/*' -not -path '*/.git/*' \
	-not -path '*/build/*' -not -path '*/.build/*' -not -path '*/dist/*' -not -path '*/target/*' \
	-print 2>/dev/null | sort)
while IFS= read -r pr; do
	[[ -z "$pr" ]] && continue
	contract_pairs+="proto|${pr#"$cwd"/}"$'\n'
done < <(find "$cwd" -maxdepth 4 -name '*.proto' \
	-not -path '*/node_modules/*' -not -path '*/.git/*' \
	-not -path '*/build/*' -not -path '*/.build/*' -not -path '*/dist/*' -not -path '*/target/*' \
	-print 2>/dev/null | sort)

# Dedupe by the identity consumers care about. For containers that is (name,
# source): a repo carrying both ./Dockerfile and ./docker/Dockerfile resolves the
# same name+source under two evidence paths — one container node, not two. (Two
# different sources for one name, e.g. jib + bootBuildImage, are kept: they are
# genuinely distinct mechanisms.) Contracts dedupe on the whole line (a path is a
# contract's identity). Order is preserved.
container_pairs="$(printf '%s' "$container_pairs" | awk -F'|' 'NF && !seen[$1 FS $2]++')"
contract_pairs="$(printf '%s' "$contract_pairs" | awk 'NF && !seen[$0]++')"

containers_json="$(emit_containers_json "$container_pairs")"
contracts_json="$(emit_contracts_json "$contract_pairs")"

# live_majors (#694): the distinct per-major dirs under contracts/ that carry the
# canonical (lowercase) openapi spec — contracts/vN/openapi.{yaml,yml,json}. This
# is the signal that decides whether bootstrap scaffolds an anti-corruption
# adapter — a repo serving >1 live major needs one adapter per OLD major (the
# service natively implements only the newest; older majors are served by a
# translating adapter). A single (or zero) major needs no adapter.
live_majors_lines=""
while IFS= read -r _cp; do
	[[ "$_cp" == openapi\|* ]] || continue
	_ev="${_cp#openapi|}"
	if [[ "$_ev" =~ ^contracts/(v[0-9]+)/openapi\.(yaml|yml|json)$ ]]; then
		live_majors_lines+="${BASH_REMATCH[1]}"$'\n'
	fi
done <<<"$contract_pairs"
# Build the array by hand (json_str, no jq — detect-stack degrades gracefully
# when jq is absent, so the core output never depends on it), deduped and sorted
# NUMERICALLY on the digits after `v`: a lexical sort orders v10 before v2, and a
# consumer reading "the highest" as the newest major would then pick the wrong one.
live_majors_json="["
_lm_first=1
while IFS= read -r _m; do
	[[ -z "$_m" ]] && continue
	[[ $_lm_first -eq 1 ]] && _lm_first=0 || live_majors_json+=","
	live_majors_json+="$(json_str "$_m")"
done < <(printf '%s' "$live_majors_lines" | awk 'NF && !seen[$0]++' | sort -t v -k2,2n)
live_majors_json+="]"

# --- detection_confidence ----------------------------------------------------
# "complete" unless the repo shows container-ish evidence we could NOT resolve
# into a named image AND we resolved nothing locally. A user override is always
# complete; anything we DID resolve makes the soft signal moot (it plausibly
# refers to what we found).
if [[ -n "$containers_override" || "$containers_json" != "[]" ]]; then
	detection_confidence="complete"
else
	detection_confidence="complete"
	if [[ -d "$cwd/.github/workflows" ]] &&
		grep -rqE 'docker/build-push-action|buildx|docker[[:space:]]+build' "$cwd/.github/workflows" 2>/dev/null; then
		detection_confidence="inconclusive"
	elif find "$cwd" -maxdepth 3 -name 'Chart.yaml' -not -path '*/.git/*' -print -quit 2>/dev/null | grep -q .; then
		detection_confidence="inconclusive"
	else
		for m in project.toml nixpacks.toml Procfile fly.toml heroku.yml app.yaml .ko.yaml; do
			if [[ -e "$cwd/$m" ]]; then
				detection_confidence="inconclusive"
				break
			fi
		done
	fi
	# Maven container mechanisms (jib-maven-plugin, spring-boot-maven-plugin's
	# build-image) are NOT resolved here — this family is Gradle-first — but their
	# presence means "this repo has no containers" would be a false claim, so flip
	# to inconclusive rather than assert complete+[].
	if [[ "$detection_confidence" == "complete" ]]; then
		while IFS= read -r pf; do
			[[ -z "$pf" ]] && continue
			if grep -qE 'jib-maven-plugin|spring-boot-maven-plugin' "$pf" 2>/dev/null; then
				detection_confidence="inconclusive"
				break
			fi
		done < <(find "$cwd" -maxdepth 2 -name pom.xml -not -path '*/target/*' -not -path '*/.git/*' -print 2>/dev/null)
	fi
fi

# --- existing artifacts ------------------------------------------------------
# Files we would generate. We mark which already exist so the skill can
# skip/diff. The candidate list is derived dynamically from the templates
# directory so new templates auto-include without touching this script.
#
# Mapping rules:
#   templates/<scope>/foo              → foo
#   templates/<scope>/foo.tmpl         → foo
#   templates/<scope>/.github/x.yml    → .github/x.yml
# Language fragments (templates/languages/<lang>/*) follow the same shape
# but are only candidates for languages actually detected above.
# The merged .gitignore and conditional LICENSE are added explicitly.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
templates_dir="$(cd -- "$script_dir/../templates" &>/dev/null && pwd)"

# A "gitignore" fragment inside templates/languages/<lang>/ is merged into the
# project's single top-level .gitignore — not a stand-alone file. Skip it from
# the candidate list (the merged .gitignore is added explicitly below).
collect_from() {
	local dir="$1"
	[[ -d "$dir" ]] || return 0
	while IFS= read -r tmpl_path; do
		rel="${tmpl_path#"$dir"/}"              # strip prefix
		rel="${rel%.tmpl}"                      # strip .tmpl suffix if present
		[[ "$rel" == "gitignore" ]] && continue # fragment, not a target file
		# The multi-major anti-corruption adapter (#694) is a per-OLD-major
		# scaffold seed (rendered to src/api/<vN>/… once per OLD major by SKILL
		# §3j), not a fixed 1:1 artifact — never a gap-fill candidate.
		[[ "$rel" == src/api/* ]] && continue
		candidate_paths+=("$rel")
	done < <(find "$dir" -type f 2>/dev/null)
}

candidate_paths=()
collect_from "$templates_dir/common"
# Scope by visibility: a public repo never expects private-path files and vice
# versa. Over-collecting both was harmless for the present-only existing_artifacts
# map (an absent out-of-scope file just didn't appear), but missing_artifacts must
# not flag out-of-scope files as gaps. When visibility is still unknown (no remote
# yet), the scope can't be determined, so collect neither — missing_artifacts then
# carries only scope-free candidates until the path is locked in.
case "$visibility" in
public) collect_from "$templates_dir/public" ;;
private) collect_from "$templates_dir/private" ;;
esac

# Language-specific fragments (only for detected languages).
# `${langs[@]+...}` guards against the array being empty under `set -u`.
for lang in ${langs[@]+"${langs[@]}"}; do
	collect_from "$templates_dir/languages/$lang"
done

# Always-check files that don't map 1:1 to a template:
#   .gitignore (merged from language fragments above)
#   LICENSE (asked of user if missing)
candidate_paths+=(".gitignore" "LICENSE")

# Dedupe (some files like sonar-project.properties exist in both public/ and
# private/ scope — we'd otherwise list it twice).
# NOTE: `mapfile`/`readarray` is bash 4+; this script runs on macOS's stock bash
# 3.2, so we use the array-from-command-substitution form instead. The candidate
# paths are known config filenames from `find` (no spaces), so the intentional
# word-splitting is safe.
# shellcheck disable=SC2207
candidate_paths=($(printf '%s\n' "${candidate_paths[@]}" | awk '!seen[$0]++'))

# The two seeded C4 pages (#791) are generated OUTPUT, not templates, so they are
# never collected from templates/ above — append them explicitly so State-D
# gap-fill adopts them on an already-bootstrapped repo. The guard keys on the docs
# machinery being in scope (the collected architecture/index.md candidate). Note:
# the #766 docs tree is UNIVERSAL — collect_from always adds
# architecture/index.md.tmpl for every repo — so this guard is true on every
# reachable input today; it is defensive, staying correct if the docs tree ever
# becomes conditionally scoped (then the C4 pages would follow it out of scope,
# never appearing as phantom gaps on a repo that legitimately has no docs tree).
# When in scope, the C4 pages are unconditionally-expected gaps (not held out), so
# a docs repo missing them is flagged for adoption.
if printf '%s\n' "${candidate_paths[@]}" | grep -qx 'docs/architecture/index.md'; then
	candidate_paths+=("docs/architecture/c4-context.md" "docs/architecture/c4-container.md")
fi

# A few templates render to a deploy path that differs from their location in
# the templates tree, so the 1:1 mapping above produces the wrong (bare-root)
# candidate — and the existence probe then checks a path the file never lands at,
# reporting a present file as a phantom gap. Rewrite each such candidate to its
# real on-disk deploy path (SKILL Step 3 mapping table) so existing_artifacts and
# missing_artifacts probe where the file actually is. Keep this in sync whenever a
# template's deploy path != its tree path:
#   approver-policy-core.md     common/            -> .claude/approver-policy.md
#   approver-policy-overlay.md  languages/<lang>/  -> .claude/approver-policy.md
#                                  (core + overlay render INTO one file, #241)
#   check-api-stability.py      languages/python/  -> .github/scripts/...   (#408)
# Indexed array of from=to pairs (not an associative array — this script runs on
# macOS's stock bash 3.2, which has no `declare -A`).
deploy_path_overrides=(
	"approver-policy-core.md=.claude/approver-policy.md"
	"approver-policy-overlay.md=.claude/approver-policy.md"
	"check-api-stability.py=.github/scripts/check-api-stability.py"
)
for i in "${!candidate_paths[@]}"; do
	for ov in "${deploy_path_overrides[@]}"; do
		from="${ov%%=*}"
		to="${ov#*=}"
		[[ "${candidate_paths[i]}" == "$from" ]] && candidate_paths[i]="$to" && break
	done
done
# Re-dedupe: the core + overlay templates both map to the single policy file,
# so the override step can reintroduce a duplicate.
# shellcheck disable=SC2207
candidate_paths=($(printf '%s\n' "${candidate_paths[@]}" | awk '!seen[$0]++'))

# Dependency-update bot is renovate.json XOR .github/dependabot.yml — both live in
# templates/common, so collect_from picks up both, but exactly one is ever
# rendered. A claude-plugin repo (or a repo already carrying renovate.json) is the
# Renovate path; everything else is the Dependabot default. Resolve which file is
# the real gap so auto-render never installs the wrong (or a dueling second) bot.
is_claude_plugin="false"
if [[ -e "$cwd/.claude-plugin/marketplace.json" ]] ||
	[[ -n "$(find "$cwd" -path '*/.claude-plugin/plugin.json' -not -path '*/.git/*' 2>/dev/null | head -n1)" ]]; then
	is_claude_plugin="true"
fi
renovate_present="false"
[[ -e "$cwd/renovate.json" || -e "$cwd/.github/renovate.json" ]] && renovate_present="true"
# Renovate path when the repo is a plugin repo OR already on Renovate.
if [[ "$is_claude_plugin" == "true" || "$renovate_present" == "true" ]]; then
	excluded_bot=".github/dependabot.yml"
else
	excluded_bot="renovate.json"
fi

# existing_artifacts: present-only map (path -> true) — unchanged.
# missing_artifacts: candidates that detect-stack can say WITH CONFIDENCE are an
#   expected-but-absent gap, given only what it reliably sees (visibility,
#   languages, bot path). It is the deterministic auto-render signal for State D,
#   so it must never include a file whose render is gated by a signal detect-stack
#   can't observe — otherwise gap-fill installs something a fresh bootstrap would
#   not have. Held-out candidates (tracked in existing_artifacts when PRESENT, but
#   never reported as a gap when absent):
#     - .gitignore / LICENSE     — not 1:1 templates (merged / user-chosen)
#     - the non-selected bot file — renovate.json XOR dependabot.yml
#     - the Approver policy       — gated by --claude-approver (no filesystem trace
#                                   when opted out; the workflow half is gone since
#                                   epic #476 — approval is a local skill, not CI)
#     - api-stability.yml +       — gated by a language plugin's api-stability spec
#       check-api-stability.py       (Python-only today); detect-stack can't see
#                                    it, and the workflow + its wrapper script
#                                    render together as one feature (#408), so the
#                                    script is held out for the same reason as the
#                                    workflow — never one without the other.
#   The acceptance stage (acceptance.yml + tests/acceptance/cli/test_smoke.py,
#   #242/#697/#698) is held out CONDITIONALLY, not unconditionally (#714): unlike
#   api-stability's language-plugin spec, its gating signal — the detected
#   `interfaces` — IS in this script's own output, so it can legitimately flag the
#   gap. It is an expected gap only when its interface is present:
#     - acceptance.yml           when a NON-`library` interface is detected;
#     - tests/acceptance/cli/…    when `cli` is detected.
#   Otherwise (no interface / `library`-only / non-cli) both stay held out — a
#   `library` project renders no acceptance stage at all. When surfaced, they are
#   the one exception to "render blind": the State-D gap-fill renders them with
#   the interface flags detection already supplies (--acceptance-interfaces from
#   `interfaces` minus library; --cli-entry-point from [project.scripts]) — see
#   SKILL.md §"State D" step 4 and §3g. This is what lets an already-bootstrapped
#   repo (e.g. ai-doc-organizer) adopt the stage on re-bootstrap.
#   The per-surface docs how-to stubs (docs/how-to/use-the-{cli,rest-api,web-ui}.md,
#   #766) are held out CONDITIONALLY on the same interface signal: each is an
#   expected gap only when its interface is detected. Like the acceptance pair,
#   their State-D render is NOT blind — the docs set renders with
#   --project-name/--project-slug plus --acceptance-interfaces so mkdocs.yml's
#   surface-conditional nav and the stub files stay in lockstep (SKILL.md §3h).
#   These stay installable via a full re-bootstrap with the right flags; only the
#   unconditionally-expected gaps auto-render.
held_out=(
	".gitignore" "LICENSE" "$excluded_bot"
	".claude/approver-policy.md"
	".github/workflows/api-stability.yml" ".github/scripts/check-api-stability.py"
)
# Conditionally hold out the acceptance stage unless its interface is present.
acceptance_gappable="false"
cli_gappable="false"
rest_gappable="false"
webui_gappable="false"
for _iface in ${detected_ifaces}; do
	[[ "$_iface" != "library" ]] && acceptance_gappable="true"
	[[ "$_iface" == "cli" ]] && cli_gappable="true"
	[[ "$_iface" == "rest" ]] && rest_gappable="true"
	[[ "$_iface" == "web-ui" ]] && webui_gappable="true"
done
[[ "$acceptance_gappable" == "true" ]] || held_out+=(".github/workflows/acceptance.yml")
[[ "$cli_gappable" == "true" ]] || held_out+=("tests/acceptance/cli/test_smoke.py")
# The per-surface docs how-to stubs (#766) follow the same conditional pattern:
# each is an expected gap only when its interface is detected — a CLI-only repo
# must never be told it's missing the REST how-to (and blind-rendering it would
# desync the stub set from mkdocs.yml's surface-conditional nav, failing the
# strict docs build on an omitted-from-nav page).
[[ "$cli_gappable" == "true" ]] || held_out+=("docs/how-to/use-the-cli.md")
[[ "$rest_gappable" == "true" ]] || held_out+=("docs/how-to/use-the-rest-api.md")
[[ "$webui_gappable" == "true" ]] || held_out+=("docs/how-to/use-the-web-ui.md")
# The API contracts machinery (#692) is held out CONDITIONALLY on an OpenAPI
# surface — the same pattern as the acceptance stage (#714). Its gating signal,
# a committed OpenAPI contract, IS in this script's own `contracts` output, so a
# repo that exposes one can legitimately be told the Spectral ruleset and the
# lint + publish workflows are an expected gap; a repo with no OpenAPI surface
# never sees them as gaps (and State-D never blind-installs an API contract
# pipeline into a repo that has no API). When surfaced, those three render NOT
# blind — the set renders with core flags detection already supplies
# (--project-name, --default-branch), and both workflows no-op on an empty
# contracts/. See SKILL.md §3i.
#
# The per-major SEED spec (contracts/v1/openapi.yaml) is held out
# UNCONDITIONALLY: it is a scaffold, not a drift-tracked artifact, and blind-
# rendering a stub v1 contract is actively wrong when the repo's real spec lives
# elsewhere (e.g. api/openapi.yaml) or when v1 was retired and only
# contracts/v2/ is live — in both cases the stub would then be published as the
# authoritative contract. §3i seeds it only under human/model judgment on a
# fresh bootstrap, never via State-D gap-fill. (`^openapi|` matches only the
# openapi contract lines, built as `openapi|<path>` above; the here-string
# avoids a SIGPIPE from grep -q short-circuiting a large proto-heavy pipe.)
openapi_surface="false"
if grep -q '^openapi|' <<<"$contract_pairs"; then
	openapi_surface="true"
fi
held_out+=("contracts/v1/openapi.yaml")
if [[ "$openapi_surface" != "true" ]]; then
	held_out+=(
		".spectral.yaml" "CONTRACTS.md"
		".github/workflows/contracts-lint.yml" ".github/workflows/spec-publish.yml"
		".github/workflows/contracts-semver.yml" ".github/scripts/check-contracts-semver.sh"
	)
fi
artifacts_json="{"
missing_json="["
first=1
mfirst=1
for p in "${candidate_paths[@]}"; do
	if [[ -e "$cwd/$p" ]]; then
		[[ $first -eq 1 ]] && first=0 || artifacts_json+=","
		artifacts_json+="$(json_str "$p"):true"
		continue
	fi
	# Absent — flag as a gap only if it is not a held-out candidate.
	skip=""
	for h in "${held_out[@]}"; do [[ "$p" == "$h" ]] && skip="1" && break; done
	[[ -n "$skip" ]] && continue
	[[ $mfirst -eq 1 ]] && mfirst=0 || missing_json+=","
	missing_json+="$(json_str "$p")"
done
artifacts_json+="}"
missing_json+="]"

# --- github-side state (issue #90) -------------------------------------------
# Probe GitHub for state the bootstrap installs in Step 4 (branch protection,
# secrets, SonarCloud project). detect_stack used to be files-only, so a repo
# with all 19 generated artifacts looked "fully bootstrapped" even when none
# of Step 4 had completed. This block makes the JSON honest about what's
# actually configured on the remote.
#
# Behavior:
#   - Returns {} when has_github_remote=false OR gh is not authenticated.
#   - Each probe degrades gracefully on auth/network failure; the orchestrator
#     can distinguish "not yet applied" from "could not check" by reading
#     the per-probe state field.
github_state="{}"

if [[ "$has_github_remote" == "true" ]] &&
	command -v gh >/dev/null 2>&1 &&
	command -v curl >/dev/null 2>&1 &&
	command -v jq >/dev/null 2>&1 &&
	gh auth status >/dev/null 2>&1; then

	gh_token="$(gh auth token 2>/dev/null || true)"

	# --- branch protection ---
	bp_tmp="$(mktemp)"
	bp_status=$(curl -sS -o "$bp_tmp" -w '%{http_code}' \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $gh_token" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"https://api.github.com/repos/$github_repo/branches/$default_branch/protection" \
		2>/dev/null || echo "000")
	case "$bp_status" in
	200)
		bp_contexts=$(jq -c '.required_status_checks.contexts // []' "$bp_tmp" 2>/dev/null || echo "[]")
		bp_reviews=$(jq -r '.required_pull_request_reviews.required_approving_review_count // 0' "$bp_tmp" 2>/dev/null || echo "0")
		bp_linear=$(jq -r '.required_linear_history.enabled // false' "$bp_tmp" 2>/dev/null || echo "false")
		bp_force=$(jq -r '.allow_force_pushes.enabled // false' "$bp_tmp" 2>/dev/null || echo "false")

		# `required_signatures` lives on its own endpoint, not the main
		# protection object. Probe separately. Endpoint returns 200 with
		# `enabled: true|false` when the parent rule exists.
		sig_status=$(curl -sS -o "$bp_tmp.sig" -w '%{http_code}' \
			-H "Accept: application/vnd.github+json" \
			-H "Authorization: token $gh_token" \
			-H "X-GitHub-Api-Version: 2022-11-28" \
			"https://api.github.com/repos/$github_repo/branches/$default_branch/protection/required_signatures" \
			2>/dev/null || echo "000")
		case "$sig_status" in
		200) bp_sigs=$(jq -r '.enabled // false' "$bp_tmp.sig" 2>/dev/null || echo "false") ;;
		*) bp_sigs="null" ;;
		esac
		rm -f "$bp_tmp.sig"

		bp_json=$(printf '{"state":"applied","applied_contexts":%s,"required_reviews":%s,"linear_history":%s,"force_push":%s,"required_signatures":%s}' \
			"$bp_contexts" "$bp_reviews" "$bp_linear" "$bp_force" "$bp_sigs")
		;;
	404) bp_json='{"state":"missing"}' ;;
	403) bp_json='{"state":"forbidden"}' ;;
	*) bp_json=$(printf '{"state":"unknown","http_code":"%s"}' "$bp_status") ;;
	esac
	rm -f "$bp_tmp"

	# --- repo merge settings (#226) ---
	# The maintenance approval gate (plugins#224) arms GitHub native auto-merge,
	# which needs allow_auto_merge; delete_branch_on_merge handles head-branch
	# cleanup for those armed merges. branch-protection.sh sets both; probe them
	# so the State D gap-fill can see when they're missing. null = couldn't read.
	merge_settings=$(gh api "repos/$github_repo" \
		--jq '{allow_auto_merge: (.allow_auto_merge // false), delete_branch_on_merge: (.delete_branch_on_merge // false)}' \
		2>/dev/null || echo "null")
	[[ -z "$merge_settings" ]] && merge_settings="null"

	# --- secrets (Actions scope) ---
	secrets_names=$(gh secret list --repo "$github_repo" --json name --jq '[.[].name]' 2>/dev/null || echo "[]")
	[[ -z "$secrets_names" ]] && secrets_names="[]"

	# --- SonarCloud project (anonymous query — no token needed) ---
	# Only meaningful for public-path bootstraps. Skip when visibility is
	# private or the project key can't be derived from sonar-project.properties.
	sonar_exists="null"
	if [[ "$visibility" == "public" && -f "$cwd/sonar-project.properties" ]]; then
		sonar_key=$(grep -E '^[[:space:]]*sonar\.projectKey[[:space:]]*=' "$cwd/sonar-project.properties" 2>/dev/null |
			head -n1 | cut -d= -f2- | tr -d '[:space:]')
		if [[ -n "$sonar_key" ]]; then
			sonar_status=$(curl -sS -o /dev/null -w '%{http_code}' \
				"https://sonarcloud.io/api/components/show?component=$sonar_key" 2>/dev/null || echo "000")
			case "$sonar_status" in
			200) sonar_exists="true" ;;
			404) sonar_exists="false" ;;
			*) sonar_exists="null" ;;
			esac
		fi
	fi

	github_state=$(printf '{"branch_protection":%s,"merge_settings":%s,"secrets":{"names":%s},"sonar_project_exists":%s}' \
		"$bp_json" "$merge_settings" "$secrets_names" "$sonar_exists")
fi

# --- emit --------------------------------------------------------------------
cat <<EOF
{
  "git_initialized": $(json_bool "$git_initialized"),
  "has_github_remote": $(json_bool "$has_github_remote"),
  "github_repo": $(json_str "$github_repo"),
  "default_branch": $(json_str "$default_branch"),
  "visibility": $(json_str "$visibility"),
  "languages": $languages_json,
  "has_dockerfile": $(json_bool "$has_dockerfile"),
  "containers": $containers_json,
  "detection_confidence": $(json_str "$detection_confidence"),
  "contracts": $contracts_json,
  "live_majors": $live_majors_json,
  "interfaces": $interfaces_json,
  "language_meta": $language_meta_json,
  "is_claude_plugin": $(json_bool "$is_claude_plugin"),
  "existing_artifacts": $artifacts_json,
  "missing_artifacts": $missing_json,
  "github_state": $github_state
}
EOF
