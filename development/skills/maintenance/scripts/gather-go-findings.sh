#!/usr/bin/env bash
# gather-go-findings.sh — per-tool maintenance payload for a Go project.
# Slice B (#871) of the #868 development-go full-maintenance epic.
#
# Usage:
#   gather-go-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": { "format_lint", "sonarcloud", "code_scanning",
#                             "semgrep", "govulncheck", "dependabot",
#                             "snyk_prs", "renovate", "grpc", "api_contract" },
#     "findings_by_tool":   { <key per CONFIGURED tool; code_scanning -> code_scanning_alerts> },
#     "coverage": {                 # MEASURED (per-package) as of Slice E (#874)
#       "overall":   <float|null>,  #   null + reliable:false when withheld
#       "by_module": { "<rel path>": <pct>, ... },
#       "regions":   [ { "file", "name", "start_line", "end_line", "pct" }, ... ],
#       "measurement": { "source", "reliable", "reason" }
#     },
#     "sonar_quality_gate": <object|null>,
#     "notes": [ ... ]
#   }
#
# SCOPE — the tool universe grows one slice at a time (#868 epic):
#   - format_lint (golangci-lint v2)                       — Slice B (#871)
#   - sonarcloud / code_scanning / semgrep triage          — Slice D (#873)
#   - coverage via `go test -coverprofile` (per-package)   — Slice E (#874)
#   - govulncheck (Go vuln source of truth) + vendor-PR    — Slice G (#876)
#     sources dependabot + snyk_prs + renovate
#   - grpc + api_contract advisors (proto-first)           — Slice I (#878)
#     grpc = buf/protobuf gRPC codegen (.proto present); api_contract =
#     proto-first REST pipeline (.proto carrying google.api.http). Config-audit
#     advisors, not scanners — one finding each, coverage-exempt (they edit buf
#     config / CI, not source under test), like Java's grpc/openapi advisors.
# govulncheck is authoritative for Go code vulns; Snyk OSS is disabled for
# gomod (no double-triage) — so there is NO Snyk-OSS vuln key here, and
# `snyk_prs` is Snyk's version-bump PRs only. Declaring only the tools this
# plugin actually supports is deliberate: reporting an unsupported tool as
# `configured: false` would imply development-go can process it once set up.
#
# format_lint = ONE pinned binary, golangci-lint v2, covering both halves of
# the mechanical layer:
#   - format: `golangci-lint fmt` runs the `formatters` section (gofumpt +
#     import ordering via gci/goimports). With an empty/absent `formatters`
#     block v2 still applies standard Go formatting, so the pass is never a
#     no-op — the bootstrap template's formatters section (Slice F, #875) only
#     widens it to gofumpt.
#   - lint:   `golangci-lint run --fix` applies the autofixable subset.
# Findings here come from `golangci-lint fmt --diff`, which reports what is
# unformatted WITHOUT changing files — so every emitted finding is
# mechanically fixable, the same guarantee `spotlessCheck` gives the Java
# gather and `swift-format lint` gives the Swift one. Non-autofixable
# golangci-lint diagnostics are NOT format_lint; they belong to a triage agent
# in Slice D (#873).
#
# Failure modes are graceful: a configured tool whose binary is absent is
# reported configured-but-no-findings with a `notes` entry explaining why.

set -euo pipefail

repo="${1:-}"
if [[ -z "$repo" || ! -d "$repo" ]]; then
	echo "usage: gather-go-findings.sh <repo_path>" >&2
	exit 2
fi
# Resolve the script dir BEFORE cd'ing into the repo, so the sibling helpers
# (gather-sonarcloud.zsh, gather-github-security.zsh) are found regardless of
# the caller's cwd; and normalize `repo` to an absolute path so those helpers
# get a stable argument even when the caller passed a relative one.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)" ||
	{
		echo "gather-go-findings.sh: cannot resolve its own script dir" >&2
		exit 2
	}
# `-d` passed the guard, but cd can still fail (no execute bit, or removed
# between the check and here) — surface it as the usage contract (exit 2), not
# a bare set -e abort.
repo="$(cd -- "$repo" 2>/dev/null && pwd)" ||
	{
		echo "usage: gather-go-findings.sh <repo_path>" >&2
		exit 2
	}
cd "$repo"

notes=()

# --- tooling_configured: format_lint ----------------------------------------
# Configured when a golangci-lint config is committed — the blessed Go
# format/lint stack (bootstrap renders .golangci.yml). golangci-lint reads any
# of these four names; accept them all rather than assuming the rendered one.
has_format_lint_config="false"
if [[ -f ".golangci.yml" || -f ".golangci.yaml" || -f ".golangci.toml" || -f ".golangci.json" ]]; then
	has_format_lint_config="true"
fi

# --- format_lint findings ----------------------------------------------------
# `golangci-lint fmt --diff` prints the formatting diff without rewriting
# files — the clean mechanical signal. One finding per unformatted .go file.
#
# Path extraction is anchored to the diff's HEADER lines, never the whole log.
# The Swift gather can grep its whole log because `swift-format lint` emits
# only `path:line:col:` lines — every path in it IS a violator. A unified diff
# has no such property: hunk bodies carry `//go:generate` directives, generated
# -code banners, and string literals like "cmd/main.go", and stderr is merged
# in, so an unanchored grep invents findings for correctly-formatted or
# nonexistent files. Each candidate is then required to exist on disk, which
# also absorbs header-style variance (`a/`+`b/` prefixes, gofmt's `.orig`
# suffix) without depending on which spelling this golangci-lint build emits.
format_lint_json="null"
if [[ "$has_format_lint_config" == "true" ]]; then
	if command -v golangci-lint >/dev/null 2>&1; then
		fmt_log="$(mktemp)"
		# shellcheck disable=SC2064  # expand fmt_log now: the trap must survive an early exit
		trap "rm -f '$fmt_log'" EXIT
		# Exit codes: 0 = already formatted, 1 = a diff exists (the normal
		# "found work" case), >1 = a real failure (bad config, no Go files,
		# internal error). Only 0/1 mean the log is a parseable diff.
		fmt_rc=0
		golangci-lint fmt --diff >"$fmt_log" 2>&1 || fmt_rc=$?

		# Count the header lines separately from the paths we accept, so the
		# notes below can tell "the tool emitted no diff at all" apart from
		# "it named files we couldn't resolve" — two very different faults.
		hdr_count=$(grep -cE '^(diff |--- |\+\+\+ )' "$fmt_log" 2>/dev/null || true)
		: "${hdr_count:=0}"

		# Parse each header POSITIONALLY rather than by character class: a
		# class like [[:alnum:]_./-] silently truncates a path containing a
		# space (or `+`/`@`), and a truncated tail that happens to exist on
		# disk would pass the -f check and emit a finding for the WRONG file.
		# Stripping a fixed prefix keeps whatever the path actually contains.
		violating=""
		gofmt_pair=0 # set by a `--- *.orig` header; governs its `+++` partner
		if ((fmt_rc <= 1)); then
			while IFS= read -r line; do
				# Strip the marker AND its VCS prefix atomically, bound to the
				# side it belongs to. Stripping `a/` then `b/` in sequence
				# would double-strip a real path under a top-level `b/` dir
				# (`--- a/b/tool.go` -> `tool.go`) — dropping the true
				# violator, or worse, naming an unrelated root `tool.go`.
				# `diff ...` command lines are deliberately NOT parsed: taking
				# their last token truncates spaced paths, and every unified
				# diff carrying one also carries the ---/+++ pair, so the arm
				# could only ever add a duplicate or a wrong path.
				# `a/`/`b/` is only a VCS prefix in git-style output; in
				# gofmt-style output it can be a REAL top-level directory.
				# Disambiguate by header PAIR, not per line: an `.orig` suffix
				# on the `---` side is definitionally gofmt, and that verdict
				# governs the `+++` line that follows it. Per-line guessing
				# can't work — `+++ b/tool.go` is genuinely ambiguous alone,
				# and a repo with both a real `b/` dir and a root `tool.go`
				# resolves it the wrong way round. `lit` keeps the literal
				# reading as a fallback when the prefixed one names nothing.
				lit=""
				case "$line" in
				'--- '*.orig)
					cand="${line#* }"
					gofmt_pair=1
					;;
				'--- a/'*)
					cand="${line:6}"
					lit="${line#* }"
					gofmt_pair=0
					;;
				'--- '*)
					cand="${line#* }"
					gofmt_pair=0
					;;
				'+++ b/'*)
					if ((gofmt_pair)); then
						cand="${line#* }"
					else
						cand="${line:6}"
						lit="${line#* }"
					fi
					;;
				'+++ '*) cand="${line#* }" ;;
				*) continue ;;
				esac
				cand="${cand%%$'\t'*}" # drop a tab-separated timestamp
				cand="${cand%.orig}"   # gofmt-style `x.go.orig` header
				if [[ -n "$lit" && ! -f "${cand#"$PWD"/}" ]]; then
					lit="${lit%%$'\t'*}"
					cand="${lit%.orig}"
				fi
				[[ "$cand" == *.go ]] || continue
				cand="${cand#"$PWD"/}" # keep components repo-relative
				[[ -f "$cand" ]] && violating+="$cand"$'\n'
			done < <(grep -E '^(diff |--- |\+\+\+ )' "$fmt_log" 2>/dev/null || true)
			violating="$(printf '%s' "$violating" | sort -u)"
		fi

		if [[ -n "$violating" ]]; then
			format_lint_json=$(printf '%s\n' "$violating" | jq -R '{
				type: "format",
				severity: "MINOR",
				rule: "golangci-lint:fmt",
				component: .,
				line: 0,
				message: "File is not formatted per golangci-lint fmt; run golangci-lint fmt.",
				key: ("format_lint:" + .)
			}' | jq -s '.')
		else
			format_lint_json="[]"
		fi

		# Never report a tool failure as a clean repo. Three distinct faults,
		# three distinct notes — a single catch-all would misdiagnose two of
		# them (e.g. calling a resolution failure a "v1 binary").
		if ((fmt_rc > 1)); then
			notes+=("format_lint: 'golangci-lint fmt --diff' failed (exit $fmt_rc): $(tail -1 "$fmt_log"). Findings can't be collected — check .golangci.yml and that golangci-lint is v2.")
		elif ((fmt_rc == 1)) && ((hdr_count == 0)); then
			notes+=("format_lint: 'golangci-lint fmt --diff' exited 1 but emitted no diff header at all: $(tail -1 "$fmt_log"). This usually means a golangci-lint v1 binary (no 'fmt' subcommand); findings can't be collected.")
		elif ((fmt_rc == 1)) && [[ -z "$violating" ]]; then
			notes+=("format_lint: 'golangci-lint fmt --diff' reported a diff over $hdr_count header line(s), but none named a .go file present in this repo. Findings were dropped rather than guessed; check for an unexpected diff-header format.")
		fi

		rm -f "$fmt_log"
		trap - EXIT
	else
		format_lint_json="[]"
		notes+=("format_lint is configured but 'golangci-lint' is not on PATH ('brew install golangci-lint'). Findings can't be collected until it's available.")
	fi
fi

# --- sonarcloud (Sonar Go analyzer) — Slice D (#873) ------------------------
# Configured when sonar-project.properties is present. Findings + the main
# branch Quality Gate verdict come from the language-agnostic
# gather-sonarcloud.zsh helper (org+project from the properties file; token
# resolved inside the helper). Go rule keys look like `go:Sxxxx`. Sonar's Go
# analyzer is mature (dozens of rules across bugs / code smells /
# vulnerabilities / security hotspots), so the go-sonar-triage agent ships this
# slice — no deferral (contrast Swift semgrep, #443).
has_sonar_config="false"
[[ -f "sonar-project.properties" ]] && has_sonar_config="true"
sonar_json="null"
sonar_quality_gate="null"
if [[ "$has_sonar_config" == "true" ]]; then
	# `|| true`: a properties file missing the key makes grep exit 1, which
	# under `set -euo pipefail` would abort the script — but the missing-key
	# branch below is exactly what must handle that, so tolerate the empty read.
	sonar_org=$(grep -E '^[[:space:]]*sonar\.organization' sonar-project.properties 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' || true)
	sonar_project=$(grep -E '^[[:space:]]*sonar\.projectKey' sonar-project.properties 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' || true)
	sonar_helper="$SCRIPT_DIR/gather-sonarcloud.zsh"
	if [[ -z "$sonar_org" || -z "$sonar_project" ]]; then
		sonar_json="[]"
		notes+=("sonarcloud is configured but sonar-project.properties is missing 'sonar.organization' or 'sonar.projectKey'; live findings can't be fetched until both are set.")
	elif [[ ! -x "$sonar_helper" ]]; then
		sonar_json="[]"
		notes+=("sonarcloud gather: helper script not found or not executable at $sonar_helper. Update your plugin install (cd to the marketplace dir, 'git pull').")
	else
		sonar_raw="$(mktemp)"
		sonar_stderr="$(mktemp)"
		if "$sonar_helper" "$sonar_org" "$sonar_project" >"$sonar_raw" 2>"$sonar_stderr"; then
			# Guard the parses: a helper that exits 0 with unexpected stdout must
			# not abort the whole gather under `set -e`, nor drop the findings
			# key while the tool is configured (the configured-implies-key
			# contract). `jq -s` (slurp) is load-bearing, not just `// []`:
			# non-slurped jq on EMPTY stdout emits nothing and exits 0, so the
			# `|| echo` fallback never fires and the var becomes "" — which the
			# final --argjson then rejects, aborting the emit. Slurping yields
			# `[]`/`null` for empty input and the real value otherwise.
			sonar_json="$(jq -s '(.[0].findings) // []' "$sonar_raw" 2>/dev/null || echo '[]')"
			sonar_quality_gate="$(jq -cs '(.[0].quality_gate) // null' "$sonar_raw" 2>/dev/null || echo 'null')"
		else
			sonar_json="[]"
		fi
		sonar_note="$(tail -1 "$sonar_stderr" 2>/dev/null || true)"
		[[ -n "$sonar_note" ]] && notes+=("$sonar_note")
		rm -f "$sonar_raw" "$sonar_stderr"
	fi
fi

# --- code_scanning (CodeQL go + Scorecard) — Slice D (#873) ------------------
# Configured when a CodeQL workflow is present (bootstrap generates
# .github/workflows/codeql.yml). Alerts come from the language-agnostic
# gather-github-security.zsh helper (gh API; free, no quota). The alert shape
# is identical across languages — only the CodeQL rule IDs differ (go/...).
# CodeQL's Go support is first-class (its own Go-written extractor, module-aware
# extraction, full local + global dataflow), so go-code-scanning-triage ships.
has_code_scanning_config="false"
if ls .github/workflows/codeql*.yml >/dev/null 2>&1; then
	has_code_scanning_config="true"
fi
code_scanning_json="null"
if [[ "$has_code_scanning_config" == "true" ]]; then
	cs_helper="$SCRIPT_DIR/gather-github-security.zsh"
	if [[ ! -x "$cs_helper" ]]; then
		code_scanning_json="[]"
		notes+=("Code Scanning gather: helper script not found or not executable at $cs_helper. Update your plugin install (cd to the marketplace dir, 'git pull').")
	else
		cs_raw="$(mktemp)"
		cs_stderr="$(mktemp)"
		if "$cs_helper" "$repo" >"$cs_raw" 2>"$cs_stderr"; then
			# Slurped (see the sonar parse): a missing key, unexpected stdout,
			# or EMPTY stdout on exit 0 must not omit the findings key
			# (configured-implies-key) or abort the gather.
			code_scanning_json="$(jq -s '(.[0].code_scanning_alerts) // []' "$cs_raw" 2>/dev/null || echo '[]')"
			cs_label="ok"
		else
			code_scanning_json="[]"
			cs_label="failed"
		fi
		cs_content="$(tr '\n' ' ' <"$cs_stderr" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
		[[ -n "$cs_content" ]] && notes+=("Code Scanning gather ($cs_label): $cs_content")
		rm -f "$cs_raw" "$cs_stderr"
	fi
fi

# --- semgrep (Go rules via --config=auto) — Slice D (#873) -------------------
# Configured when a semgrep hook (pre-commit) or CI job is wired. Unlike Swift
# (empty registry → deferred, #443), semgrep's Go support is GA with cross-file
# dataflow and the community rules cover Go, so `--config=auto` finds real
# findings and go-semgrep-triage ships — exactly as Java's does. `--error`
# makes semgrep exit non-zero on findings, which we tolerate; normalize to the
# results array.
has_semgrep_config="false"
if grep -qE 'returntocorp/semgrep|semgrep/semgrep' .pre-commit-config.yaml 2>/dev/null ||
	grep -qE 'semgrep ci|returntocorp/semgrep|semgrep/semgrep' .github/workflows/*.yml 2>/dev/null; then
	has_semgrep_config="true"
fi
semgrep_json="null"
if [[ "$has_semgrep_config" == "true" ]]; then
	if command -v semgrep >/dev/null 2>&1; then
		semgrep_raw="$(mktemp)"
		# `--error` exit codes: 0 = clean, 1 = findings, >1 = a real failure
		# (bad rule fetch, no network to the registry, internal error). Only 0/1
		# produce a parseable results document — never report a >1 failure as a
		# clean repo (the header's graceful-degradation contract).
		semgrep_rc=0
		semgrep --config=auto --json --quiet --error --metrics=off . >"$semgrep_raw" 2>/dev/null || semgrep_rc=$?
		if ((semgrep_rc > 1)); then
			semgrep_json="[]"
			notes+=("semgrep: 'semgrep --config=auto' failed (exit $semgrep_rc); findings can't be collected — check network access to the semgrep registry.")
		else
			# jq -s so a truncated/interleaved document can't emit a partial
			# array followed by the `|| echo` fallback (two concatenated JSON
			# values would make the final --argjson reject the whole payload).
			semgrep_json="$(jq -s '(.[0].results) // []' "$semgrep_raw" 2>/dev/null || echo '[]')"
		fi
		rm -f "$semgrep_raw"
	else
		semgrep_json="[]"
		notes+=("semgrep is configured but the 'semgrep' binary is not on PATH; install with 'brew install semgrep' or 'pip install semgrep'.")
	fi
fi

# --- coverage — measured via first-party tooling (Slice E, #874) -------------
# ENFORCED SEMANTICS: per-PACKAGE coverage (`go test ./... -coverprofile`, the
# default — deliberately NOT `-coverpkg=./...`). Rationale (epic #868 hard part
# 4): the region-scoped gate asks "is THIS function directly tested before an
# agent edits it?" Per-package credits only a package's own tests, so an
# integration test that incidentally executes a function elsewhere does not mask
# a genuinely untested unit; `-coverpkg` would inflate exactly that. The
# go-coverage-improver writes package-local tests, which per-package credits.
# The number is the same one the improver targets and the pre-flight gates.
#
# Coverage is trustworthy-or-withheld (#258): first-party tooling makes the
# figure reliable BY CONSTRUCTION when the suite runs and the profile parses,
# but we still emit provenance + a reliability verdict, and WITHHOLD (null,
# reliable=false, with a reason) on any failure rather than guessing. `regions`
# is always present (the gate consumes it). Generated sources (*.pb.go,
# *.pb.gw.go) are excluded by the parser. Measurement is gated on test presence
# so the hermetic bats fixtures never trigger a real `go test`.
coverage_overall="null"
coverage_by_module="{}"
coverage_regions="[]"
coverage_source="none"
coverage_reliable="false"
coverage_reason="Coverage was not measured."

# Test presence: any *_test.go anywhere under the module (Go's coverage is
# toolchain-built-in, so there's no config to detect — tests are the gate).
go_has_tests="false"
if find . -path '*/.git' -prune -o -name '*_test.go' -print -quit 2>/dev/null | grep -q .; then
	go_has_tests="true"
fi

cov_tmp="$(mktemp -d)"
if [[ "$go_has_tests" != "true" ]]; then
	coverage_reason="no *_test.go files found; coverage was not measured — there is nothing to cover."
elif ! command -v go >/dev/null 2>&1; then
	coverage_reason="Go tests exist but 'go' is not on PATH; coverage was not measured (e.g. CI without the toolchain)."
elif ! command -v python3 >/dev/null 2>&1; then
	coverage_reason="Go tests exist but 'python3' (the coverage parser's interpreter) is not on PATH; coverage was not measured."
else
	coverage_source="go-test-coverprofile"
	go_module="$(grep -E '^[[:space:]]*module[[:space:]]+' go.mod 2>/dev/null | head -1 |
		sed -E 's/^[[:space:]]*module[[:space:]]+//; s/[[:space:]]+$//' | tr -d '"' || true)"
	[[ -z "$go_module" ]] && notes+=("coverage: go.mod has no 'module' directive; coverage paths may not be repo-relative.")
	cov_profile="$cov_tmp/cover.out"
	cov_func="$cov_tmp/cover.func.txt"
	test_exit=0
	# Per-package (no -coverpkg). Discard test stdout; the signal is the profile.
	go test ./... -coverprofile="$cov_profile" >"$cov_tmp/test.log" 2>&1 || test_exit=$?
	# A package that failed to COMPILE or SET UP is different from a red
	# assertion: `go test` prints `FAIL <pkg> [build failed]` / `[setup failed]`,
	# and that package contributes NO blocks — its files silently vanish from the
	# figure, an incomplete measurement presented as valid. Withhold. Anchor the
	# patterns to go's REAL line shapes: a bare `[build failed]` or a loose `^# `
	# would also match a red test replaying `# HELP`/`# TYPE` metrics, a `# TODO`,
	# or a markdown heading in an expected/actual diff (the metrics/gRPC test-bed
	# makes that plausible), misdiagnosing a merely-red suite as a build break —
	# so the `^# ` arm requires an import-path-shaped token (a `/` or `.`), which
	# a package header always has and prose almost never does.
	build_failed="false"
	grep -qE '^(FAIL|ok|----)[[:space:]].*\[(build|setup) failed\]$|^# [^[:space:]]*[./][^[:space:]]*([[:space:]]\[[^]]+\])?$|^go: .*cannot find|build constraints exclude all Go files' "$cov_tmp/test.log" 2>/dev/null && build_failed="true"
	if [[ "$build_failed" == "true" ]]; then
		coverage_reason="a package failed to compile or set up during 'go test ./...' ($(tail -1 "$cov_tmp/test.log" 2>/dev/null)); the profile would omit that package entirely, so coverage is withheld rather than reported incomplete."
	elif [[ -s "$cov_profile" ]]; then
		# `go tool cover -func` re-reads each source file to find function
		# boundaries, so it can fail independently of the profile. Capture its
		# rc: a failure means `regions` is unavailable (the gate's primary
		# input), which must be disclosed, not silently emitted as [].
		func_rc=0
		go tool cover -func="$cov_profile" >"$cov_func" 2>/dev/null || func_rc=$?
		parsed="$(python3 "$SCRIPT_DIR/parse-go-coverage.py" "$cov_profile" "$cov_func" "$go_module" 2>/dev/null || true)"
		if [[ -n "$parsed" ]] && jq -e . >/dev/null 2>&1 <<<"$parsed"; then
			maybe_overall="$(jq '.overall' <<<"$parsed")"
			if [[ "$maybe_overall" != "null" ]]; then
				coverage_overall="$maybe_overall"
				coverage_by_module="$(jq -c '.by_module' <<<"$parsed")"
				coverage_regions="$(jq -c '.regions // []' <<<"$parsed")"
				coverage_reliable="true"
				# Disclose the per-package scope: packages with NO *_test.go
				# contribute no statements, so `overall` is over the tested
				# packages only — not the whole repo. The improver targets the
				# untested ones separately.
				coverage_reason="measured via 'go test ./... -coverprofile' (per-package; packages without any *_test.go contribute no statements to this figure), parsed by parse-go-coverage.py."
				if ((func_rc > 0)) || [[ "$coverage_regions" == "[]" ]]; then
					notes+=("coverage: per-function regions could not be derived (go tool cover -func exit $func_rc); by_module/overall are valid but the region-scoped gate has no regions to resolve against.")
				fi
				((test_exit > 0)) && notes+=("Go test suite exited $test_exit during coverage measurement; the figure covers the packages that compiled and ran — the suite is currently red.")
			else
				coverage_reason="coverage profile parsed but contained no measurable (non-generated) statements; figure withheld."
			fi
		else
			coverage_reason="coverage profile produced but could not be parsed by parse-go-coverage.py; coverage withheld."
		fi
	else
		coverage_reason="ran 'go test ./... -coverprofile' (exit $test_exit) but no non-empty profile was produced ($(tail -1 "$cov_tmp/test.log" 2>/dev/null)); coverage withheld."
	fi
fi
rm -rf "$cov_tmp"

# Emit one provenance note ALWAYS, so the figure's trust level is never silent.
notes+=("coverage measurement: source=$coverage_source, reliable=$coverage_reliable — $coverage_reason")

# --- govulncheck — the single source of truth for Go code vulns (Slice G #876)
# DECISION (epic #868, 2026-07-19): govulncheck is authoritative for Go code
# vulnerabilities; Snyk OSS is DISABLED for gomod (no double-triage) — so this
# gather emits NO Snyk-OSS vuln source, only govulncheck. Container-image +
# GitHub-Actions scanning are unchanged (Go's blessed image path is ko, which
# has no Dockerfile to scan). govulncheck ships WITH the Go toolchain and needs
# no config file, so it is "configured" whenever the repo is a Go module
# (go.mod present). Findings route to go-major-upgrade (the advised fixed
# version clears the vuln). Graceful: binary/network failure → [] + a note.
has_govulncheck_config="false"
if [[ -f "go.mod" ]]; then
	has_govulncheck_config="true"
fi
govulncheck_json="null"
if [[ "$has_govulncheck_config" == "true" ]]; then
	if command -v govulncheck >/dev/null 2>&1; then
		gv_raw="$(mktemp)"
		gv_err="$(mktemp)"
		# govulncheck -json emits a STREAM of {config|progress|osv|finding}
		# messages, not one document. jq -s slurps them; we join each `finding`
		# to its `osv` advisory and reduce to one record per vuln, preferring the
		# CALLED occurrence (its top trace frame carries a non-null function) over
		# a merely-imported one.
		#
		# EXIT CODES (govulncheck docs): with -json/-format=json it exits **0
		# even when vulns are found** (exit 3 = ErrVulnerabilitiesFound is
		# text-mode only). A non-zero code therefore means a REAL failure —
		# package-load error, no network to vuln.go.dev, a bad module — which must
		# be WITHHELD, not reported as a clean []. So treat any rc other than 0
		# (tolerating 3 defensively, in case a future/text invocation leaks it) as
		# a failure, and surface the captured stderr so the cause is diagnosable
		# rather than a hardcoded guess (#258 trustworthy-or-withheld).
		gv_rc=0
		govulncheck -json ./... >"$gv_raw" 2>"$gv_err" || gv_rc=$?
		if ((gv_rc != 0 && gv_rc != 3)); then
			govulncheck_json="[]"
			gv_detail="$(tail -1 "$gv_err" 2>/dev/null || true)"
			[[ -z "$gv_detail" ]] && gv_detail="no error detail captured"
			notes+=("govulncheck: exited $gv_rc; vulnerabilities NOT measured (withheld, not reported clean) — $gv_detail.")
		else
			govulncheck_json="$(jq -s '
				(map(select(.osv) | {(.osv.id): (.osv.summary // .osv.details // "")}) | add // {}) as $sum
				| [ .[] | select(.finding) | .finding
					| (.trace[0]) as $t
					| { osv: .osv,
						fixed_version: (.fixed_version // null),
						module: ($t.module // null),
						version: ($t.version // null),
						called: (($t.function // null) != null) } ]
				| group_by(.osv)
				| map((sort_by(.called) | reverse) | .[0])
				# Two severity buckets: called|imported. govulncheck also emits
				# module-level findings for required-but-unimported modules
				# (trace[0].package null); those coarsen to "imported" here — a
				# slight over-statement the planner tolerates (both route to the
				# same upgrade agent). Refine to a 3rd "required" bucket if the
				# planner ever needs to deprioritize them.
				| map({
					type: "vulnerability",
					rule: .osv,
					key: ("govulncheck:" + .osv),
					severity: (if .called then "called" else "imported" end),
					component: .module,
					line: null,
					message: ($sum[.osv] // .osv),
					package: .module,
					current_version: .version,
					target_version: .fixed_version,
					cve_reference: .osv
				})
			' "$gv_raw" 2>/dev/null || echo '[]')"
		fi
		rm -f "$gv_raw" "$gv_err"
	else
		govulncheck_json="[]"
		notes+=("govulncheck is the Go vulnerability source of truth but its binary is not on PATH; install with 'go install golang.org/x/vuln/cmd/govulncheck@latest'.")
	fi
fi

# --- vendor-PR sources: dependabot / snyk_prs / renovate (Slice G #876) -------
# Raw open-PR records for the planner's ecosystem + bump-level classification
# (go-maintenance-planner § 5a). NOTE: `snyk_prs` here is Snyk's auto-Fix/Upgrade
# *PRs* (version bumps) — NOT an OSS-vuln scan (that is govulncheck's job, above;
# Snyk OSS is disabled for gomod). Requires gh authenticated; degrades to []
# plus a note otherwise.
has_dependabot_config="false"
[[ -f ".github/dependabot.yml" ]] && has_dependabot_config="true"

has_snyk_prs_config="false"
[[ -f ".snyk" ]] && has_snyk_prs_config="true"

has_renovate_config="false"
if [[ -f "renovate.json" || -f "renovate.json5" || -f ".github/renovate.json" ||
	-f ".github/renovate.json5" || -f ".renovaterc" || -f ".renovaterc.json" ||
	-f ".renovaterc.json5" || -f ".gitlab/renovate.json" ]]; then
	has_renovate_config="true"
fi

dependabot_json="null"
if [[ "$has_dependabot_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		dependabot_json="$(gh pr list --author "app/dependabot" --state open \
			--json number,title,body,headRefName 2>/dev/null || echo "[]")"
	else
		dependabot_json="[]"
		notes+=("dependabot is configured but 'gh' is not available/authenticated; can't list open Dependabot PRs.")
	fi
fi

snyk_prs_json="null"
if [[ "$has_snyk_prs_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		snyk_prs_json="$({
			gh pr list --state open --search "head:snyk-fix-" \
				--json number,title,body,headRefName 2>/dev/null || echo "[]"
			gh pr list --state open --search "head:snyk-upgrade-" \
				--json number,title,body,headRefName 2>/dev/null || echo "[]"
		} | jq -s 'add // []' 2>/dev/null || echo "[]")"
	else
		snyk_prs_json="[]"
		notes+=(".snyk file present but 'gh' is not available/authenticated; can't list open Snyk PRs.")
	fi
fi

renovate_json="null"
if [[ "$has_renovate_config" == "true" ]]; then
	if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
		renovate_json="$(gh pr list --author "app/renovate" --state open \
			--json number,title,body,headRefName 2>/dev/null || echo "[]")"
	else
		renovate_json="[]"
		notes+=("renovate is configured but 'gh' is not available/authenticated; can't list open Renovate PRs.")
	fi
fi

# --- grpc + api_contract advisors (proto-first) — Slice I (#878) -------------
# Config-audit advisors, mirroring Java's grpc/openapi: a grep sees the config
# path but can't reason about the multi-plugin buf wiring, annotation
# completeness, gateway registration, or the spec-conversion step — so we emit
# ONE audit finding and let the advisor Read the config and decide.
#
#   grpc         — configured when .proto files exist (the authoritative gRPC
#                  contract). go-grpc-advisor audits the buf generate wiring
#                  (protoc-gen-go + protoc-gen-go-grpc, pinned).
#   api_contract — configured when a .proto declares an EXTERNAL REST surface,
#                  i.e. carries a `google.api.http` annotation. Absent
#                  annotations means an internal-only gRPC service (the normal
#                  "gRPC internal, REST external" state) — NOT a gap, so
#                  api_contract stays false and no REST facade is pushed.
#                  go-api-contract-advisor audits the four-stage proto-first
#                  REST pipeline (buf wiring, annotation completeness, gateway
#                  registration, 2.0->3.0 spec conversion).
has_grpc_config="false"
if find . -path '*/.git/*' -prune -o -path '*/third_party/*' -prune -o \
	-name '*.proto' -print -quit 2>/dev/null | grep -q .; then
	has_grpc_config="true"
fi

has_api_contract_config="false"
# Only meaningful when protos exist; a `google.api.http` reference in ANY .proto
# marks a declared external REST surface. `grep -rl` exits 1 on no match, which
# under `set -e` would abort — the `|| true` and the string test absorb it.
if [[ "$has_grpc_config" == "true" ]]; then
	if [[ -n "$(grep -rlE 'google\.api\.http' --include='*.proto' . 2>/dev/null || true)" ]]; then
		has_api_contract_config="true"
	fi
fi

# Shared component: the codegen config the advisor Reads. Prefer buf.gen.yaml
# (where the plugins are pinned), then buf.yaml, else the first .proto so the
# finding still points somewhere concrete when buf isn't wired yet.
proto_component=""
if [[ "$has_grpc_config" == "true" ]]; then
	if [[ -f "buf.gen.yaml" ]]; then
		proto_component="buf.gen.yaml"
	elif [[ -f "buf.yaml" ]]; then
		proto_component="buf.yaml"
	else
		proto_component="$(find . -path '*/.git/*' -prune -o -name '*.proto' -print 2>/dev/null | head -n1)"
		proto_component="${proto_component#./}"
	fi
fi

grpc_json="null"
if [[ "$has_grpc_config" == "true" ]]; then
	grpc_json="$(jq -n --arg c "$proto_component" '[{
		type: "config", severity: "MINOR", rule: "grpc:proto-audit",
		component: $c, line: 0,
		message: "Audit the buf protobuf/gRPC code-generation wiring — buf generate with pinned protoc-gen-go + protoc-gen-go-grpc producing the Go message + gRPC stubs from the authoritative .proto contract, with buf lint + buf breaking gating the contract and generated sources (*.pb.go, *_grpc.pb.go) excluded from coverage.",
		key: ("grpc:proto-audit:" + $c)
	}]')"
fi

api_contract_json="null"
if [[ "$has_api_contract_config" == "true" ]]; then
	api_contract_json="$(jq -n --arg c "$proto_component" '[{
		type: "config", severity: "MINOR", rule: "api_contract:contract-audit",
		component: $c, line: 0,
		message: "Audit the proto-first REST contract pipeline — google.api.http annotations as the source of truth, grpc-gateway as the generated REST facade, and protoc-gen-openapiv2 output converted 2.0->3.0 into the contracts machinery. Checks buf wiring, annotation completeness on external RPCs, gateway mux registration, and the spec conversion step.",
		key: ("api_contract:contract-audit:" + $c)
	}]')"
fi

# --- notes -> JSON -----------------------------------------------------------
if [[ ${#notes[@]} -gt 0 ]]; then
	notes_json=$(printf '%s\n' "${notes[@]}" | jq -R . | jq -s '.')
else
	notes_json="[]"
fi

# --- emit --------------------------------------------------------------------
jq -n \
	--argjson format_lint_cfg "$has_format_lint_config" \
	--argjson sonar_cfg "$has_sonar_config" \
	--argjson code_scanning_cfg "$has_code_scanning_config" \
	--argjson semgrep_cfg "$has_semgrep_config" \
	--argjson govulncheck_cfg "$has_govulncheck_config" \
	--argjson dependabot_cfg "$has_dependabot_config" \
	--argjson snyk_prs_cfg "$has_snyk_prs_config" \
	--argjson renovate_cfg "$has_renovate_config" \
	--argjson grpc_cfg "$has_grpc_config" \
	--argjson api_contract_cfg "$has_api_contract_config" \
	--argjson format_lint_findings "$format_lint_json" \
	--argjson sonar_findings "$sonar_json" \
	--argjson cs_findings "$code_scanning_json" \
	--argjson semgrep_findings "$semgrep_json" \
	--argjson govulncheck_findings "$govulncheck_json" \
	--argjson dependabot_findings "$dependabot_json" \
	--argjson snyk_prs_findings "$snyk_prs_json" \
	--argjson renovate_findings "$renovate_json" \
	--argjson grpc_findings "$grpc_json" \
	--argjson api_contract_findings "$api_contract_json" \
	--argjson sonar_quality_gate "$sonar_quality_gate" \
	--argjson coverage_overall "$coverage_overall" \
	--argjson coverage_by_module "$coverage_by_module" \
	--argjson coverage_regions "$coverage_regions" \
	--arg coverage_source "$coverage_source" \
	--argjson coverage_reliable "$coverage_reliable" \
	--arg coverage_reason "$coverage_reason" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    format_lint:   $format_lint_cfg,
    sonarcloud:    $sonar_cfg,
    code_scanning: $code_scanning_cfg,
    semgrep:       $semgrep_cfg,
    govulncheck:   $govulncheck_cfg,
    dependabot:    $dependabot_cfg,
    snyk_prs:      $snyk_prs_cfg,
    renovate:      $renovate_cfg,
    grpc:          $grpc_cfg,
    api_contract:  $api_contract_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings  != null then {format_lint:          $format_lint_findings}  else {} end) +
    (if $sonar_findings        != null then {sonarcloud:           $sonar_findings}        else {} end) +
    (if $cs_findings           != null then {code_scanning_alerts: $cs_findings}           else {} end) +
    (if $semgrep_findings      != null then {semgrep:              $semgrep_findings}      else {} end) +
    (if $govulncheck_findings  != null then {govulncheck:          $govulncheck_findings}  else {} end) +
    (if $dependabot_findings   != null then {dependabot:           $dependabot_findings}   else {} end) +
    (if $snyk_prs_findings     != null then {snyk_prs:             $snyk_prs_findings}     else {} end) +
    (if $renovate_findings     != null then {renovate:             $renovate_findings}     else {} end) +
    (if $grpc_findings         != null then {grpc:                 $grpc_findings}         else {} end) +
    (if $api_contract_findings != null then {api_contract:         $api_contract_findings} else {} end)
  ),
  coverage: {
    overall:   $coverage_overall,
    by_module: $coverage_by_module,
    regions:   $coverage_regions,
    measurement: {
      source:   $coverage_source,
      reliable: $coverage_reliable,
      reason:   $coverage_reason
    }
  },
  sonar_quality_gate: $sonar_quality_gate,
  notes: $notes
}
'
