#!/usr/bin/env bash
# gather-go-findings.sh — per-tool maintenance payload for a Go project.
# Slice B (#871) of the #868 development-go full-maintenance epic.
#
# Usage:
#   gather-go-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": {
#       "format_lint": true|false   # golangci-lint v2 (the blessed stack)
#     },
#     "findings_by_tool": {
#       "format_lint": [ ... or omitted when not configured ... ]
#     },
#     "coverage": {                 # WITHHELD this slice — arrives in Slice E (#874)
#       "overall": null,
#       "by_module": {},
#       "regions": [],
#       "measurement": { "source", "reliable", "reason" }
#     },
#     "notes": [ ... ]
#   }
#
# SCOPE (#871, the core-loop slice of the #868 epic). Tool universe so far:
#   - format_lint (golangci-lint v2)  — this slice (the runnable loop)
# Later slices add: sonarcloud / code_scanning / semgrep (Slice D, #873),
# coverage via `go test -coverprofile` (Slice E, #874), and the vendor-PR
# sources dependabot + snyk_prs + renovate (Slice G, #876). Each new tool
# extends `tooling_configured` + `findings_by_tool` the same way the Swift and
# Java gathers grew across their slices. Declaring only the tools this plugin
# actually supports is deliberate: reporting an unsupported tool as
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

# --- coverage — WITHHELD until Slice E (#874) --------------------------------
# Go coverage is `go test -coverprofile` + `go tool cover`, and the enforced
# number's semantics (per-package profile vs -coverpkg) is an explicit Slice E
# decision (#868 hard part 4). Until that decision is made and the parser
# exists, the figure is WITHHELD rather than guessed — trustworthy-or-withheld
# (#258). `regions` is always present (the region-scoped gate consumes it) and
# empty while coverage is unmeasured.
coverage_overall="null"
coverage_by_module="{}"
coverage_regions="[]"
coverage_source="none"
coverage_reliable="false"
coverage_reason="Go coverage measurement arrives in Slice E (#874); no figure is produced or guessed this slice."

# Emit one provenance note ALWAYS, so the figure's trust level is never silent.
notes+=("coverage measurement: source=$coverage_source, reliable=$coverage_reliable — $coverage_reason")

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
	--argjson format_lint_findings "$format_lint_json" \
	--argjson sonar_findings "$sonar_json" \
	--argjson cs_findings "$code_scanning_json" \
	--argjson semgrep_findings "$semgrep_json" \
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
    semgrep:       $semgrep_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint:          $format_lint_findings} else {} end) +
    (if $sonar_findings       != null then {sonarcloud:           $sonar_findings}       else {} end) +
    (if $cs_findings          != null then {code_scanning_alerts: $cs_findings}          else {} end) +
    (if $semgrep_findings     != null then {semgrep:              $semgrep_findings}     else {} end)
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
