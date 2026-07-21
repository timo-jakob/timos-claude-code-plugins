#!/usr/bin/env zsh
# seed-orval-targets.zsh — detect a consuming repo's pinned OpenAPI spec packages
# and seed an editable orval.config.ts with one generation target per spec.
# Slice 2 (#727) of the #683 development-javascript epic.
#
# Usage:
#   seed-orval-targets.zsh [--plan] <repo_path>
#
# It is BOTH the detector and the seeder for the contract-consumer machinery
# (§3k of the bootstrap SKILL): the bootstrap flow runs it on every javascript
# repo, and its EXIT CODE is the detection signal —
#   0  → at least one *-api-spec dependency found. In --plan mode NOTHING is
#        written (the repo is only inspected — safe to run while assembling the
#        Step 2 plan, before the user has approved anything); without --plan,
#        orval.config.ts is in place (freshly seeded, or already present and left
#        untouched). Render §3k.
#   3  → no *-api-spec dependency — the repo is not a contract consumer. Skip
#        §3k entirely (this is the common case, not an error).
#   2  → usage / precondition error.
#
# --plan  Detect only: emit the JSON summary (with the targets that WOULD be
#         seeded) and write no file. Use this during Step 2 planning; run
#         without --plan in Step 3, after the user approves the plan.
#
# It emits a JSON summary on stdout so the caller can report what was seeded:
#   {
#     "seeded": true|false,       # true only when this run WROTE the file
#     "planned": true,            # present ONLY in --plan mode (nothing written)
#     "config_path": "…/orval.config.ts",
#     "targets": [ { "name", "package", "input", "output" } ],
#     "reason": "…"               # why nothing was seeded, when applicable
#   }
#
# The seeded config is a STARTER — authoritative and editable thereafter
# (idempotency rule 3: an existing orval.config.ts is never clobbered). One spec
# → one target; multiple specs → multiple targets. A spec package is expected to
# ship its contract at `<pkg>/openapi.yaml` (the #684 machine-channel
# convention); the generated `input` points there under node_modules.

emulate -L zsh
set -euo pipefail

plan_only="false"
if [[ "${1:-}" == "--plan" ]]; then
	plan_only="true"
	shift
fi

repo="${1:-}"
# Reject an unknown flag, a missing/extra argument, or a non-directory. Without
# the `--*` / arg-count guards, a misordered `<repo> --plan` would silently
# discard the flag and fall through to a real (pre-approval) write.
if [[ -z "$repo" || "$repo" == --* || $# -gt 1 || ! -d "$repo" ]]; then
	print -u2 "usage: seed-orval-targets.zsh [--plan] <repo_path>"
	exit 2
fi

pkg_json="$repo/package.json"
if [[ ! -f "$pkg_json" ]]; then
	print -u2 "seed-orval-targets: no package.json at $repo — not a Node repo."
	exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
	print -u2 "seed-orval-targets: jq is required but not on PATH."
	exit 2
fi
# A malformed package.json is a PRECONDITION error (exit 2), not "not a
# consumer" (exit 3): a jq failure inside the detection process-substitution
# below would otherwise read as zero specs and silently skip §3k. Validate up
# front so the caller sees the real cause.
# `-s` (slurp) so a multi-document file (e.g. `[] {}`) is rejected as one input
# rather than passing on its last document — otherwise the detection jq below
# would error invisibly inside the process substitution and degrade to exit 3.
if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$pkg_json" >/dev/null 2>&1; then
	print -u2 "seed-orval-targets: $pkg_json is not a valid JSON object — cannot detect spec deps."
	exit 2
fi

# --- detect *-api-spec dependencies -----------------------------------------
# A spec package is any dependency (runtime or dev) whose bare name ends in
# `-api-spec`, with or without an `@scope/` prefix — the #684 naming convention.
# jq walks dependencies + devDependencies + peerDependencies and keeps matches.
specs=()
while IFS= read -r name; do
	[[ -n "$name" ]] && specs+=("$name")
done < <(jq -r '
  [ (.dependencies // {}), (.devDependencies // {}), (.peerDependencies // {}) ]
  | add // {}
  | keys[]
  | select(test("(^|/)[^/]*-api-spec$"))
' "$pkg_json" | sort -u)

if ((${#specs[@]} == 0)); then
	jq -n '{seeded: false, config_path: null, targets: [],
		reason: "no *-api-spec dependency in package.json — repo is not a contract consumer"}'
	exit 3
fi

# --- build one target per spec ----------------------------------------------
# Target name: strip a leading @scope/ and the trailing -api-spec
# (@acme/orders-api-spec → orders; billing-api-spec → billing). Collisions
# (two scopes, same bare name) are disambiguated by suffixing an index so no
# target silently overwrites another's output directory.
targets_json="[]"
typeset -A seen_names
for pkg in "${specs[@]}"; do
	bare="${pkg##*/}"      # drop @scope/
	name="${bare%-api-spec}"
	[[ -n "$name" ]] || name="$bare"   # a package literally named -api-spec keeps its bare name
	# Disambiguate a name collision, and keep looping until the derived name is
	# genuinely free (and register it), so a suffixed name can never collide with
	# a real package's target — the silent-overwrite the output dirs must avoid.
	if [[ -n "${seen_names[$name]:-}" ]]; then
		base="$name"
		while [[ -n "${seen_names[$name]:-}" ]]; do
			seen_names[$base]=$((seen_names[$base] + 1))
			name="${base}-${seen_names[$base]}"
		done
	fi
	seen_names[$name]=1
	input="./node_modules/${pkg}/openapi.yaml"
	output="src/api/generated/${name}"
	targets_json=$(jq \
		--arg name "$name" --arg package "$pkg" \
		--arg input "$input" --arg output "$output" \
		'. + [ { name: $name, package: $package, input: $input, output: $output } ]' \
		<<<"$targets_json")
done

config_path="$repo/orval.config.ts"

# --- plan mode: report what WOULD be seeded, write nothing ------------------
# Run during Step 2 planning, before the user has approved anything — so the
# seeder never mutates the repo pre-approval.
if [[ "$plan_only" == "true" ]]; then
	if [[ -f "$config_path" ]]; then
		jq -n --arg cp "$config_path" --argjson targets "$targets_json" \
			'{seeded: false, planned: true, config_path: $cp, targets: $targets,
			  reason: "orval.config.ts already present — would be left untouched"}'
	else
		jq -n --arg cp "$config_path" --argjson targets "$targets_json" \
			'{seeded: false, planned: true, config_path: $cp, targets: $targets, reason: null}'
	fi
	exit 0
fi

# --- render orval.config.ts (unless one already exists) ---------------------
if [[ -f "$config_path" ]]; then
	jq -n --arg cp "$config_path" --argjson targets "$targets_json" \
		'{seeded: false, config_path: $cp, targets: $targets,
		  reason: "orval.config.ts already present — left untouched (edit it directly)"}'
	exit 0
fi

# Render to a temp file and mv into place as the last step, so a mid-render
# failure never leaves a truncated orval.config.ts that the idempotency guard
# above would then protect forever.
tmp_config="${config_path}.tmp.$$"
trap 'rm -f "$tmp_config"' EXIT
{
	print -r -- '// orval.config.ts — seeded by /development:bootstrap'
	print -r -- '// (development-javascript contract-consumer, #727) from the *-api-spec'
	print -r -- '// dependencies in package.json. This file is authoritative and editable:'
	print -r -- '// re-run generation with `npm run generate`. The generated client + MSW'
	print -r -- '// handlers are COMMITTED under each target’s output dir so a spec-bump PR'
	print -r -- '// diff shows the API-surface change.'
	print -r -- 'import { defineConfig } from "orval";'
	print -r --
	print -r -- 'export default defineConfig({'
	for ((ti = 1; ti <= ${#specs[@]}; ti++)); do
		t_name=$(jq -r ".[$((ti - 1))].name" <<<"$targets_json")
		t_input=$(jq -r ".[$((ti - 1))].input" <<<"$targets_json")
		t_output=$(jq -r ".[$((ti - 1))].output" <<<"$targets_json")
		print -r -- "  \"${t_name}\": {"
		print -r -- '    input: {'
		print -r -- "      target: \"${t_input}\","
		print -r -- '      override: {'
		print -r -- '        // Carry deprecated:true + x-sunset to @deprecated JSDoc (#707).'
		print -r -- '        transformer: "./orval-deprecation-transformer.mjs",'
		print -r -- '      },'
		print -r -- '    },'
		print -r -- '    output: {'
		print -r -- '      mode: "tags-split",'
		print -r -- "      target: \"${t_output}\","
		print -r -- '      client: "fetch",'
		print -r -- '      mock: true,'
		print -r -- '      clean: true,'
		print -r -- '      baseUrl: "/api",'
		print -r -- '      override: {'
		print -r -- '        // Keep deprecated operations in the client so their'
		print -r -- '        // @deprecated call sites can be linted (#707).'
		print -r -- '        useDeprecatedOperations: true,'
		print -r -- '      },'
		print -r -- '    },'
		print -r -- '  },'
	done
	print -r -- '});'
} >"$tmp_config"
mv -- "$tmp_config" "$config_path"
trap - EXIT

jq -n --arg cp "$config_path" --argjson targets "$targets_json" \
	'{seeded: true, config_path: $cp, targets: $targets, reason: null}'
