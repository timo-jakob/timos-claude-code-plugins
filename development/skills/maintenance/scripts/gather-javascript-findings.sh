#!/usr/bin/env bash
# gather-javascript-findings.sh — per-tool maintenance payload for a
# JavaScript/TypeScript project. Slice 1 (#729) of the #683 development-javascript
# epic.
#
# Usage:
#   gather-javascript-findings.sh <repo_path>
#
# Output (stdout, JSON):
#   {
#     "tooling_configured": { "format_lint": true|false },  # ESLint + Prettier
#     "findings_by_tool":   { "format_lint": [ ... or omitted when not configured ] },
#     "coverage": {                 # WITHHELD this slice — vitest/v8 parser lands later
#       "overall": null, "by_module": {}, "regions": [],
#       "measurement": { "source", "reliable", "reason" }
#     },
#     "notes": [ ... ]
#   }
#
# The existence of this file is what promotes `javascript` from a merely
# BOOTSTRAPPABLE language to a MAINTAINED/dispatched one — the orchestrator
# routes by the `gather-<lang>-findings.sh` filename convention (#249), so no
# orchestrator edit was needed to wire development-javascript in.
#
# SCOPE (#729, the foundation slice). Tool universe so far:
#   - format_lint (ESLint --fix + Prettier --write) — this slice (the runnable loop)
# Later slices add sonarcloud / code_scanning / coverage (slice 4) and the
# contract-consumer machinery (slice 2, #727). Declaring only the tools this
# plugin actually supports is deliberate.
#
# format_lint findings come from `prettier --list-different`, which lists the
# unformatted files WITHOUT rewriting them — the clean mechanical signal, one
# finding per unformatted file, the same guarantee `golangci-lint fmt --diff`
# gives the Go gather. Non-autofixable ESLint diagnostics are NOT format_lint;
# they belong to a later triage slice.
#
# Failure modes are graceful: a configured tool whose binary is absent is
# reported configured-but-no-findings with a `notes` entry explaining why.

set -euo pipefail

repo="${1:-}"
if [[ -z "$repo" || ! -d "$repo" ]]; then
	echo "usage: gather-javascript-findings.sh <repo_path>" >&2
	exit 2
fi
cd "$repo"

notes=()

# --- tooling_configured: format_lint ----------------------------------------
# Configured when EITHER an ESLint config OR a Prettier config is committed —
# the blessed JS format/lint stack (bootstrap renders a flat eslint.config.js +
# a Prettier config). Gate on both tools, not just ESLint: the findings run is
# `prettier`, so a Prettier-only repo whose formatter is really deployed must
# not be silently skipped. Accept the flat-config names and the legacy forms
# rather than assuming the rendered one.
has_format_lint_config="false"
for cfg in \
	eslint.config.js eslint.config.mjs eslint.config.cjs eslint.config.ts \
	.eslintrc.json .eslintrc.js .eslintrc.cjs .eslintrc.yml .eslintrc.yaml \
	.prettierrc .prettierrc.json .prettierrc.yml .prettierrc.yaml \
	.prettierrc.js .prettierrc.cjs .prettierrc.mjs .prettierrc.toml \
	prettier.config.js prettier.config.cjs prettier.config.mjs; do
	if [[ -f "$cfg" ]]; then
		has_format_lint_config="true"
		break
	fi
done
# package.json can also carry the config inline (`prettier` / `eslintConfig`
# keys). jq is a hard dependency, so read it directly.
if [[ "$has_format_lint_config" == "false" && -f "package.json" ]]; then
	if jq -e 'has("prettier") or has("eslintConfig")' package.json >/dev/null 2>&1; then
		has_format_lint_config="true"
	fi
fi

# --- format_lint findings ----------------------------------------------------
# `prettier --list-different` prints one repo-relative path per unformatted file
# to STDOUT (bare, no prefix) and DOES NOT rewrite anything. Do NOT also pass
# `--check`: with both flags check-mode wins prettier's per-file logger and
# reroutes every path to STDERR as "[warn] <path>", which this parser would then
# drop as a non-existent file — reporting a genuinely-unformatted repo as clean.
# stderr is captured to a SEPARATE file (used only for the failure note) so it
# can never pollute the parsed path list. Every path prettier prints is a real
# violator, so a straight read is safe; each candidate is still required to exist
# on disk to absorb any stray line.
format_lint_json="null"
if [[ "$has_format_lint_config" == "true" ]]; then
	if command -v npx >/dev/null 2>&1; then
		fmt_log="$(mktemp)"
		# shellcheck disable=SC2064  # expand paths now: the trap must survive an early exit
		trap "rm -f '$fmt_log'" EXIT
		fmt_err="$(mktemp)"
		# shellcheck disable=SC2064  # widen once the second temp exists (guards a leak if this mktemp itself failed)
		trap "rm -f '$fmt_log' '$fmt_err'" EXIT
		# Exit codes: 0 = all formatted, 1 = some files differ (the normal
		# "found work" case), 2 = a real error (bad config, a parse error). npx's
		# OWN failure (prettier not installed) also exits 1, with an error on
		# stderr and no file list — caught by the empty-violator guard below.
		fmt_rc=0
		npx --no-install prettier --list-different . >"$fmt_log" 2>"$fmt_err" || fmt_rc=$?

		violating=""
		if ((fmt_rc <= 1)); then
			# `|| [[ -n "$cand" ]]` keeps a final unterminated line (a tool
			# killed mid-write) instead of silently dropping the last violator.
			while IFS= read -r cand || [[ -n "$cand" ]]; do
				[[ -n "$cand" ]] || continue
				cand="${cand#"$PWD"/}" # keep components repo-relative
				[[ -f "$cand" ]] && violating+="$cand"$'\n'
			done <"$fmt_log"
			violating="$(printf '%s' "$violating" | sort -u)"
		fi

		if [[ -n "$violating" ]]; then
			format_lint_json=$(printf '%s\n' "$violating" | jq -R 'select(length > 0) | {
				type: "format",
				severity: "MINOR",
				rule: "prettier:format",
				component: .,
				line: 0,
				message: "File is not formatted per Prettier; run prettier --write (eslint --fix also applies).",
				key: ("format_lint:" + .)
			}' | jq -s '.')
		else
			format_lint_json="[]"
		fi

		# Never report a tool failure as a clean repo.
		if ((fmt_rc > 1)); then
			format_lint_json="[]"
			err_tail="$(tail -1 "$fmt_err" 2>/dev/null || true)"
			: "${err_tail:=<no stderr captured>}"
			notes+=("format_lint: 'prettier --list-different' failed (exit $fmt_rc): $err_tail. Findings can't be collected — check the Prettier config and that prettier is installed (npm i -D prettier).")
		elif ((fmt_rc == 1)) && [[ -z "$violating" ]]; then
			# prettier exits 1 ONLY when files differ, so an empty violator set
			# after exit 1 means the output was not a file list — almost always
			# npx failing because prettier is not installed ("could not determine
			# executable to run"). Surface it instead of a silent clean verdict.
			format_lint_json="[]"
			notes+=("format_lint: 'prettier --list-different' exited 1 but named no unformatted file present in this repo — prettier is likely not installed (run npm ci, or npm i -D prettier). Findings can't be collected.")
		fi

		rm -f "$fmt_log" "$fmt_err"
		trap - EXIT
	else
		format_lint_json="[]"
		notes+=("format_lint is configured but 'npx' (Node) is not on PATH. Findings can't be collected until Node/npm is available.")
	fi
fi

# --- coverage — WITHHELD this slice -----------------------------------------
# JS coverage is vitest + v8; the parser and the enforced-number semantics land
# in a later slice. Until then the figure is WITHHELD rather than guessed —
# trustworthy-or-withheld (#258). `regions` is always present (the region-scoped
# gate consumes it) and empty while coverage is unmeasured.
coverage_overall="null"
coverage_by_module="{}"
coverage_regions="[]"
coverage_source="none"
coverage_reliable="false"
coverage_reason="JavaScript coverage measurement (vitest + v8) arrives in a later #683 slice; no figure is produced or guessed this slice."

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
	--argjson format_lint_findings "$format_lint_json" \
	--argjson coverage_overall "$coverage_overall" \
	--argjson coverage_by_module "$coverage_by_module" \
	--argjson coverage_regions "$coverage_regions" \
	--arg coverage_source "$coverage_source" \
	--argjson coverage_reliable "$coverage_reliable" \
	--arg coverage_reason "$coverage_reason" \
	--argjson notes "$notes_json" '
{
  tooling_configured: {
    format_lint: $format_lint_cfg
  },
  findings_by_tool: (
    {} +
    (if $format_lint_findings != null then {format_lint: $format_lint_findings} else {} end)
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
  notes: $notes
}
'
