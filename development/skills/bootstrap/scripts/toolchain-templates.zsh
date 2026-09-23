#!/usr/bin/env zsh
# The tool-scoped template set for a resolved quality toolchain (#1670).
#
# Bootstrap used to render one of two whole trees, templates/public/ or
# templates/private/, chosen by visibility. The toolchain is now a declaration
# (resolve-tools.zsh, #1651), so WHICH of those templates apply is keyed on the
# resolved tools — the file-level half of the artifact map (D5). The job-level
# half lives inside the templates themselves, as render.zsh's per-tool block
# tags. This script is the one place the file-level map is written down:
# detect-stack.sh scopes its candidates with it, SKILL.md Step 3 renders what it
# prints, and the bats render tests enumerate their rows through it.
#
#   every combination      <vis>/.github/workflows/quality-<vis>.yml.tmpl
#                          <vis>/.github/workflows/quality-<vis>-noop.yml.tmpl
#                          (file names stay keyed on visibility, so an existing
#                          repo's workflow never moves)
#   public                 public/.github/workflows/scorecard.yml.tmpl
#   sonarcloud             public/sonar-project.properties.tmpl
#   sonarqube              private/sonar-project.properties.tmpl
#                          private/infra/sonarqube/docker-compose.yml.tmpl
#                          private/infra/sonarqube/README.md
#   self-hosted runner     private/infra/github-runner/README.md
#   (iff sonarqube)
#   snyk                   public/.snyk.tmpl
#   trivy                  (no file of its own — trivy.yaml is common to every
#                          combination; its job and hook are block-tagged)
#   codeql (public only)   public/.github/workflows/codeql.yml.tmpl
#                          public/.github/workflows/codeql-noop.yml.tmpl
#
# Templates under common/ render for every combination and are not listed here.
# The tree a template lives in (public/, private/) is where it was first written,
# not a visibility rule: a private repo on sonarcloud renders
# public/sonar-project.properties.tmpl, and deploys it at the tree-relative path
# (sonar-project.properties) like any other.
#
# Usage:
#   toolchain-templates.zsh --visibility public|private \
#     --static-analysis sonarcloud|sonarqube --vulnerabilities snyk|trivy \
#     --code-scanning codeql|none
#
# Pass the values resolve-tools.zsh printed. Output: one template relpath
# (relative to templates/) per line, sorted (LC_ALL=C). The two combinations
# resolve-tools.zsh rejects at its step 4 — public + sonarqube, private + codeql
# — are refused here too (exit 1), so no caller can render a set for either.
# Exit codes: 0 printed; 1 a rejected combination; 2 usage error (a missing
# flag or a value outside its category's set).

set -euo pipefail

usage() {
	print -u2 -- "usage: toolchain-templates.zsh --visibility public|private --static-analysis sonarcloud|sonarqube"
	print -u2 -- "       --vulnerabilities snyk|trivy --code-scanning codeql|none"
	exit 2
}

typeset -A val
typeset -A allowed=(
	visibility "public private"
	static_analysis "sonarcloud sonarqube"
	vulnerabilities "snyk trivy"
	code_scanning "codeql none"
)

while (($# > 0)); do
	case "$1" in
	--visibility | --static-analysis | --vulnerabilities | --code-scanning)
		(($# >= 2)) || { print -u2 -- "toolchain-templates: $1 needs a value" && usage; }
		val[${${1#--}//-/_}]="$2"
		shift 2
		;;
	--help | -h) usage ;;
	*) print -u2 -- "toolchain-templates: unknown argument: $1" && usage ;;
	esac
done

typeset k
typeset -a set
for k in visibility static_analysis vulnerabilities code_scanning; do
	((${+val[$k]})) || { print -u2 -- "toolchain-templates: --${k//_/-} is required" && usage; }
	set=(${=allowed[$k]})
	((${set[(Ie)${val[$k]}]})) ||
		{ print -u2 -- "toolchain-templates: --${k//_/-}: ${val[$k]} is not one of: ${allowed[$k]// / | }" && usage; }
done

vis="${val[visibility]}"
if [[ "$vis" == public && "${val[static_analysis]}" == sonarqube ]]; then
	print -u2 -- "toolchain-templates: public + sonarqube is never rendered (resolve-tools.zsh step 4)"
	exit 1
fi
if [[ "$vis" == private && "${val[code_scanning]}" == codeql ]]; then
	print -u2 -- "toolchain-templates: private + codeql is never rendered (resolve-tools.zsh step 4)"
	exit 1
fi

typeset -a out=(
	"$vis/.github/workflows/quality-$vis.yml.tmpl"
	"$vis/.github/workflows/quality-$vis-noop.yml.tmpl"
)
[[ "$vis" == public ]] && out+=(public/.github/workflows/scorecard.yml.tmpl)
case "${val[static_analysis]}" in
sonarcloud) out+=(public/sonar-project.properties.tmpl) ;;
sonarqube)
	out+=(
		private/sonar-project.properties.tmpl
		private/infra/sonarqube/docker-compose.yml.tmpl
		private/infra/sonarqube/README.md
		# the self-hosted runner follows sonarqube alone (resolve-tools.zsh)
		private/infra/github-runner/README.md
	)
	;;
esac
[[ "${val[vulnerabilities]}" == snyk ]] && out+=(public/.snyk.tmpl)
if [[ "${val[code_scanning]}" == codeql ]]; then
	out+=(public/.github/workflows/codeql.yml.tmpl public/.github/workflows/codeql-noop.yml.tmpl)
fi

print -rl -- "${out[@]}" | LC_ALL=C sort
