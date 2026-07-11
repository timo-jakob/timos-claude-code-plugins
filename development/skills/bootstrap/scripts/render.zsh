#!/usr/bin/env zsh
# Deterministic template renderer for /development:bootstrap (#546).
#
# Before this script, every bootstrap session hand-wrote its own ad-hoc
# renderer from the SKILL.md prose — a fresh reimplementation of the spec
# each run, with fresh bugs (the tick-server-simulator session's renderer
# flagged the intentional {{PYTHON_VERSION}} default in the unconditional
# pre-commit CI job as an error). This script IS the spec, in one tested
# place: the placeholder table and the conditional-block stripping rules
# from SKILL.md Step 3, byte-identical across sessions for the same inputs.
#
# What it does, per template file:
#   1. Strips `# --- TAG-START ---` / `# --- TAG-END ---` conditional blocks
#      whose tag does not apply (marker lines + content); kept blocks retain
#      their markers. Tags normalize `-` to `_` (the pre-commit template
#      spells CLAUDE-PLUGIN, the SKILL.md table CLAUDE_PLUGIN).
#   2. Substitutes the {{UPPERCASE}} placeholder table. A placeholder is
#      substituted only when its flag was passed or has a spec default —
#      an unprovided value is NOT silently blanked; it survives and trips
#      the leftover check below, naming exactly what's missing.
#   3. Collapses runs of 3+ blank lines to one (stripped adjacent blocks
#      otherwise pile up blank lines that fail yamllint's empty-lines rule).
#   4. Writes to <out>/<relpath> with a trailing `.tmpl` suffix removed;
#      parent directories are created. Files without placeholders/blocks
#      pass through unchanged.
#
# After all files: fails loudly (exit 1) listing every surviving
# `{{UPPERCASE}}` placeholder as file:line. GitHub `${{ ... }}` expressions
# and docker-metadata literals (`{{version}}`, `{{major}}`,
# `{{is_default_branch}}`, `{{json .SBOM}}`) never match that shape and are
# untouched by design.
#
# Usage:
#   render.zsh --templates <template-root> --out <output-dir> \
#              [value flags below] <template-relpath>...
#
#   The relpaths are relative to --templates (e.g.
#   `public/.github/workflows/quality-public.yml.tmpl`). WHICH templates
#   apply stays the skill's judgment (Step 3a-3f, dependabot-vs-renovate,
#   idempotency decisions); this script only renders the chosen set.
#
# Value flags (source: detect-stack.sh output + the Step 1 questions):
#   --project-name <s>            {{PROJECT_NAME}}
#   --project-slug <owner/repo>   {{PROJECT_SLUG}}
#   --project-key <s>             {{PROJECT_KEY}}
#   --org-key <s>                 {{ORG_KEY}}
#   --default-branch <s>          {{DEFAULT_BRANCH}}   (default: main)
#   --languages "<a b c>"         {{LANGUAGES}} + block keep set; may be ""
#   --primary <s>                 {{PRIMARY}}
#   --coverage-threshold <n>      {{COVERAGE_THRESHOLD}} (default: 90)
#   --python-version <x.y>        {{PYTHON_VERSION}} (default: 3.12; the
#                                 compact form {{PYTHON_VERSION_COMPACT}} is
#                                 always derived from it)
#   --java-version <n>            {{JAVA_VERSION}} (default: 21)
#   --xcode-scheme <s>            {{XCODE_SCHEME}}
#   --codeql-languages <csv>      {{CODEQL_LANGUAGES}} (default: mapped from
#                                 --languages when that was passed)
#   --acceptance-interfaces <csv> {{ACCEPTANCE_INTERFACES}} — the runtime
#                                 interfaces detect-stack.sh found (#242),
#                                 comma-joined (e.g. `cli, web-ui`), minus
#                                 `library`. No default: it survives to the
#                                 leftover check unless passed, so acceptance.yml
#                                 is only ever rendered with a real interface set
#   --claude-plugins-repo <o/r>   {{CLAUDE_PLUGINS_REPO}}
#                                 (default: timo-jakob/timos-claude-code-plugins)
#   --approver-lang <lang>        {{APPROVER_LANG}} — the resolved Approver
#                                 language (SKILL Step 3e), used by the
#                                 approver-policy core template (#241)
#   --security-contact-email <s>  {{SECURITY_CONTACT_BLOCK}} — email block
#                                 when non-empty, the no-email fallback block
#                                 when passed empty; without the flag the
#                                 placeholder survives to the leftover check
#   --visibility public|private   PRIVATE block (default: public)
#   --docker true|false           DOCKER block (default: false)
#   --claude-plugin true|false    CLAUDE_PLUGIN block (default: false)
#   --swift-build-system swiftpm|xcode
#                                 SWIFT_SWIFTPM / SWIFT_XCODE blocks
#                                 (default: swiftpm)

set -euo pipefail

usage() {
	print -u2 -- "usage: render.zsh --templates <root> --out <dir> [value flags] <template-relpath>..."
	print -u2 -- "       (see the header comment for the full flag list)"
	exit 2
}

die() {
	print -u2 -- "render.zsh: $1"
	exit 1
}

templates=""
out=""
languages=""
languages_set=0
visibility="public"
docker="false"
claude_plugin="false"
swift_build_system="swiftpm"
security_email=""
security_email_set=0

# Placeholder values. A key is substituted iff present in this map; spec
# defaults are preloaded, no-default values only enter via their flag.
typeset -A vals
vals[DEFAULT_BRANCH]="main"
vals[COVERAGE_THRESHOLD]="90"
vals[PYTHON_VERSION]="3.12"
vals[JAVA_VERSION]="21"
vals[CLAUDE_PLUGINS_REPO]="timo-jakob/timos-claude-code-plugins"

typeset -a files
while (($# > 0)); do
	case "$1" in
	--templates) templates="$2" && shift 2 ;;
	--out) out="$2" && shift 2 ;;
	--project-name) vals[PROJECT_NAME]="$2" && shift 2 ;;
	--project-slug) vals[PROJECT_SLUG]="$2" && shift 2 ;;
	--project-key) vals[PROJECT_KEY]="$2" && shift 2 ;;
	--org-key) vals[ORG_KEY]="$2" && shift 2 ;;
	--default-branch) vals[DEFAULT_BRANCH]="$2" && shift 2 ;;
	--languages) languages="$2" && languages_set=1 && shift 2 ;;
	--primary) vals[PRIMARY]="$2" && shift 2 ;;
	--coverage-threshold) vals[COVERAGE_THRESHOLD]="$2" && shift 2 ;;
	--python-version) vals[PYTHON_VERSION]="$2" && shift 2 ;;
	--java-version) vals[JAVA_VERSION]="$2" && shift 2 ;;
	--xcode-scheme) vals[XCODE_SCHEME]="$2" && shift 2 ;;
	--codeql-languages) vals[CODEQL_LANGUAGES]="$2" && shift 2 ;;
	--acceptance-interfaces) vals[ACCEPTANCE_INTERFACES]="$2" && shift 2 ;;
	--claude-plugins-repo) vals[CLAUDE_PLUGINS_REPO]="$2" && shift 2 ;;
	--approver-lang) vals[APPROVER_LANG]="$2" && shift 2 ;;
	--security-contact-email) security_email="$2" && security_email_set=1 && shift 2 ;;
	--visibility) visibility="$2" && shift 2 ;;
	--docker) docker="$2" && shift 2 ;;
	--claude-plugin) claude_plugin="$2" && shift 2 ;;
	--swift-build-system) swift_build_system="$2" && shift 2 ;;
	--help | -h) usage ;;
	--*) print -u2 -- "render.zsh: unknown flag: $1" && usage ;;
	*) files+=("$1") && shift ;;
	esac
done

[[ -n "$templates" && -n "$out" ]] || usage
((${#files} > 0)) || usage
[[ -d "$templates" ]] || die "template root not found: $templates"

# --- derived values ----------------------------------------------------------

typeset -a langs
langs=(${=languages})

has_lang() { ((${langs[(Ie)$1]})); }

if ((languages_set)); then
	vals[LANGUAGES]="$languages"
	# CodeQL identifier mapping from the SKILL.md placeholder table; an
	# explicit --codeql-languages wins. Unsupported languages map to nothing
	# (whether to drop codeql.yml entirely stays the skill's judgment).
	if [[ -z "${vals[CODEQL_LANGUAGES]:-}" ]]; then
		typeset -a codeql
		typeset l
		for l in "${langs[@]}"; do
			case "$l" in
			typescript) codeql+=("javascript-typescript") ;;
			python | go | swift | java) codeql+=("$l") ;;
			esac
		done
		((${#codeql})) && vals[CODEQL_LANGUAGES]="${(j:,:)codeql}"
	fi
fi

# {{PYTHON_VERSION_COMPACT}} is always PYTHON_VERSION minus the dot.
vals[PYTHON_VERSION_COMPACT]="${vals[PYTHON_VERSION]//./}"

# The two canonical SECURITY_CONTACT_BLOCK bodies from SKILL.md Step 3
# (4-space indented to sit at the template's markdown list level).
security_block=""
if ((security_email_set)); then
	if [[ -n "$security_email" ]]; then
		security_block="   Email **${security_email}**. For sensitive material, include the line
   \"Please respond via a private channel\" in your subject so we route the
   reply appropriately."
	else
		security_block="   No email channel is configured for this project. If you cannot reach us
   through GitHub Security Advisories, open a public issue *only* with the
   description \"request to contact maintainers privately about a security
   matter\" — do not include vulnerability details — and a maintainer will
   follow up over a private channel."
	fi
fi

# --- block keep set (SKILL.md "Block stripping in templates" table) ----------

keep_block() {
	local tag="${1//-/_}" # CLAUDE-PLUGIN (template) == CLAUDE_PLUGIN (table)
	case "$tag" in
	TYPESCRIPT) has_lang typescript ;;
	PYTHON) has_lang python ;;
	GO) has_lang go ;;
	JAVA) has_lang java ;;
	SWIFT) has_lang swift ;;
	LINUX_TESTS) has_lang typescript || has_lang python || has_lang go || has_lang java ;;
	SWIFT_SWIFTPM) has_lang swift && [[ "$swift_build_system" == "swiftpm" ]] ;;
	SWIFT_XCODE) has_lang swift && [[ "$swift_build_system" == "xcode" ]] ;;
	DOCKER) [[ "$docker" == "true" ]] ;;
	PRIVATE) [[ "$visibility" == "private" ]] ;;
	CLAUDE_PLUGIN) [[ "$claude_plugin" == "true" ]] ;;
	*) return 2 ;; # unknown tag — the caller fails loudly
	esac
}

# --- rendering ---------------------------------------------------------------

render_file() {
	local rel="$1"
	local src="$templates/$rel"
	[[ -f "$src" ]] || die "template not found: $src"
	local dst="$out/${rel%.tmpl}"
	mkdir -p "${dst:h}"

	local -a in_lines out_lines
	in_lines=("${(@f)$(<"$src")}")

	local line tag key i rc skip_tag="" lineno=0
	for line in "${in_lines[@]}"; do
		((lineno += 1))
		if [[ "$line" =~ '^[[:space:]]*# --- ([A-Z_-]+)-START' ]]; then
			tag="${match[1]}"
			if [[ -n "$skip_tag" ]]; then
				continue # inside a stripped block — inner markers go with it
			fi
			rc=0
			keep_block "$tag" || rc=$?
			case $rc in
			0) out_lines+=("$line") ;; # kept blocks retain their markers
			2) die "$rel:$lineno: unknown block tag '$tag' — teach render.zsh its keep-rule first" ;;
			*) skip_tag="$tag" ;;
			esac
			continue
		fi
		if [[ "$line" =~ '^[[:space:]]*# --- ([A-Z_-]+)-END' ]]; then
			if [[ -n "$skip_tag" ]]; then
				[[ "${match[1]}" == "$skip_tag" ]] && skip_tag=""
				continue
			fi
			# kept block's END marker falls through and stays
		fi
		[[ -n "$skip_tag" ]] && continue

		if [[ "$line" == *'{{SECURITY_CONTACT_BLOCK}}'* && -n "$security_block" ]]; then
			out_lines+=("${(@f)security_block}")
			continue
		fi
		for key in "${(k)vals[@]}"; do
			line="${line//\{\{${key}\}\}/${vals[$key]}}"
		done
		out_lines+=("$line")
	done
	[[ -n "$skip_tag" ]] && die "$rel: unterminated block '${skip_tag}-START' (no matching END)"

	# Collapse runs of 3+ blank lines to one (adjacent stripped blocks pile
	# up blanks that fail yamllint's empty-lines max).
	local -a final
	local blanks=0
	for line in "${out_lines[@]}"; do
		if [[ -z "$line" ]]; then
			((blanks += 1))
			continue
		fi
		if ((blanks > 0)); then
			if ((blanks >= 3)); then
				final+=("")
			else
				for ((i = 0; i < blanks; i++)); do final+=(""); done
			fi
			blanks=0
		fi
		final+=("$line")
	done
	((blanks > 0)) && final+=("") # trailing blanks collapse to one

	if ((${#final})); then
		print -rl -- "${final[@]}" >"$dst"
	else
		: >"$dst"
	fi
	rendered+=("$dst")
}

typeset -a rendered
typeset rel
for rel in "${files[@]}"; do
	render_file "$rel"
done

# --- leftover-placeholder check ------------------------------------------------
# Only {{UPPERCASE_NAMES}} count: GitHub `${{ ... }}` expressions carry spaces
# after the braces and docker-metadata literals are lowercase, so neither
# matches. Any hit means a needed value flag wasn't passed — fail loudly.

typeset -a leftovers
typeset f hits h
for f in "${rendered[@]}"; do
	hits="$(grep -nEo '\{\{[A-Z_][A-Z0-9_]*\}\}' "$f" 2>/dev/null)" || continue
	for h in "${(@f)hits}"; do leftovers+=("$f:$h"); done
done
if ((${#leftovers})); then
	print -u2 -- "render.zsh: unsubstituted placeholders survive — pass the matching value flags:"
	for f in "${leftovers[@]}"; do print -u2 -- "  $f"; done
	exit 1
fi

print -rl -- "${rendered[@]}"
