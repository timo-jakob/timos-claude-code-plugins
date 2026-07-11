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
#   has_dockerfile        bool
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
	*)
		shift
		;;
	esac
done

json_bool() { [[ "$1" == "true" ]] && printf "true" || printf "false"; }
json_str() { printf '"%s"' "${1//\"/\\\"}"; }

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
#     - acceptance.yml +          — gated by the detected `interfaces` set (#242/
#       tests/acceptance/cli/         #697): rendered only when a runtime interface
#       test_smoke.py                 is detected, and their render needs values
#                                    detect-stack doesn't supply blind — the
#                                    interface matrix (--acceptance-interfaces ->
#                                    {{ACCEPTANCE_INTERFACES}}) and, for the cli
#                                    smoke test, the entry point (--cli-entry-point
#                                    -> {{CLI_ENTRY_POINT}}, #698). A blank State-D
#                                    gap-fill would trip render.zsh's leftover
#                                    check; a `library`-only project renders none
#                                    at all. Held out; rendered via the interactive
#                                    Step 3 flow that passes the interface set.
#   These stay installable via a full re-bootstrap with the right flags; only the
#   unconditionally-expected gaps auto-render.
held_out=(
	".gitignore" "LICENSE" "$excluded_bot"
	".claude/approver-policy.md"
	".github/workflows/api-stability.yml" ".github/scripts/check-api-stability.py"
	".github/workflows/acceptance.yml" "tests/acceptance/cli/test_smoke.py"
)
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
  "interfaces": $interfaces_json,
  "language_meta": $language_meta_json,
  "is_claude_plugin": $(json_bool "$is_claude_plugin"),
  "existing_artifacts": $artifacts_json,
  "missing_artifacts": $missing_json,
  "github_state": $github_state
}
EOF
