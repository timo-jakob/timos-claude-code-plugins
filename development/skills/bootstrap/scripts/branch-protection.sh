#!/usr/bin/env bash
# branch-protection.sh — apply Zero-Tolerance branch protection on the default
# branch via the GitHub API. Idempotent (PUT replaces the rule each time).
#
# Usage:
#   branch-protection.sh --static-analysis sonarcloud|sonarqube \
#                        --vulnerabilities snyk|trivy \
#                        --has-dockerfile true|false \
#                        [--has-ko true|false] \
#                        --has-codeql true|false \
#                        [--codeql-languages "python javascript-typescript ..."] \
#                        [--iac-only true|false] \
#                        --default-branch main \
#                        [--require-signed-commits true|false]
#
# --iac-only true is the infrastructure-as-code path (the bootstrap skill's §3l):
# the kubernetes topic marker with no application language AND no other
# `primary:` recorded. A detected language, or a recorded language /
# claude-plugin primary, settles it false whatever the marker says; the mixed
# repo (marker plus a stray tooling language) is #1193. There, the language-app
# quality workflow is not rendered at all, so its checks — test-and-coverage,
# semgrep, pre-commit, license-fs, the static-analysis job and trivy-fs — would
# be required contexts that no
# workflow ever reports, pinning every PR on the permanent `expected` state. The
# repo's one check is kubernetes-ci.yml's single `gate` job instead. Everything
# else the rule applies (PR required, linear history, no force-push/deletion, and
# the repo-level merge settings auto-merge arming depends on) is unchanged: the
# contexts differ, the protection does not. It refuses (exit 1, before any rule
# is written) when .github/workflows/kubernetes-ci.yml is absent, has no `gate`
# job, or has a `gate` job carrying `name:`, `strategy:` or a reusable-workflow
# `uses:` (GitHub then reports the check under that name, `gate (<leg>)` per
# matrix entry, or `gate / <called job>`), since the `gate` context would never
# report. It refuses the same way (#1641) when the `gate` job is written in flow
# style or through an anchor, alias, tag or `<<:` merge key (a line reader cannot
# see what such a job carries), when the workflow does not run on every pull
# request (its `on:` lacks a bare `pull_request`, or filters it with `types:`,
# `branches:`, `branches-ignore:`, `paths:` or `paths-ignore:` — a PR it skips
# never reports `gate`), and when awk could not read the file at all ("could not
# read", naming the awk status), rather than blaming a file it never read.
#
# Declined limitation (#1641): a `gate` job whose `strategy:` holds no `matrix:`
# is still refused, although GitHub reports it as `gate`. Accepting it was
# declined: `fail-fast`/`max-parallel` do nothing without a matrix, so the
# refusal only costs deleting a no-op key, while telling the two apart would
# mean reading the block's children for a shape that buys the owner nothing.
#
# --static-analysis and --vulnerabilities are the RESOLVED toolchain
# (resolve-tools.zsh's `static_analysis` / `vulnerabilities`, #1671). The
# language-app context set follows #1670 D1 — toolchain plus stack, with no
# visibility term — so this script neither accepts nor derives visibility: a
# `--visibility` exits 1 naming the two flags that replaced it. Neither flag is
# required or read under --iac-only true, whose context set is `gate` alone.
#
# --has-codeql is true exactly when the resolved `code_scanning` is `codeql`;
# CodeQL's public-only rule is enforced at the plan (resolve-tools.zsh step 4,
# #1670 D8), not here. --codeql-languages is required when --has-codeql=true,
# and takes the languages space- or comma-separated (#1793).
# CodeQL's analyze job runs as a matrix per language and GitHub reports each one
# as `analyze (<lang>)`, so a bare `analyze` context never resolves.
#
# Requires: gh CLI authenticated, repository admin permission. On 403 the
# script falls back to printing manual instructions.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

STATIC_ANALYSIS=""
VULNERABILITIES=""
HAS_DOCKERFILE="false"
HAS_KO="false"
HAS_CODEQL="false"
CODEQL_LANGUAGES=""
IAC_ONLY="false"
DEFAULT_BRANCH="main"
REQUIRE_SIGNED_COMMITS="false"

while [[ $# -gt 0 ]]; do
	case "$1" in
	--visibility)
		# no alias: the context set follows the toolchain, never visibility (#1671)
		die "--visibility is no longer accepted — pass the resolved toolchain instead: --static-analysis sonarcloud|sonarqube and --vulnerabilities snyk|trivy"
		;;
	--static-analysis)
		[[ $# -ge 2 ]] || die "--static-analysis must be sonarcloud or sonarqube (the resolved static_analysis)"
		STATIC_ANALYSIS="$2"
		shift 2
		;;
	--vulnerabilities)
		[[ $# -ge 2 ]] || die "--vulnerabilities must be snyk or trivy (the resolved vulnerabilities)"
		VULNERABILITIES="$2"
		shift 2
		;;
	--has-dockerfile)
		HAS_DOCKERFILE="$2"
		shift 2
		;;
	--has-ko)
		HAS_KO="$2"
		shift 2
		;;
	--has-codeql)
		HAS_CODEQL="$2"
		shift 2
		;;
	--codeql-languages)
		CODEQL_LANGUAGES="$2"
		shift 2
		;;
	--iac-only)
		IAC_ONLY="$2"
		shift 2
		;;
	--default-branch)
		DEFAULT_BRANCH="$2"
		shift 2
		;;
	--require-signed-commits)
		REQUIRE_SIGNED_COMMITS="$2"
		shift 2
		;;
	*) die "Unknown argument: $1" ;;
	esac
done

# validated, not merely compared: an unvalidated flag silently falls through to
# the language-app context set on any value but the literal "true" — `True`,
# `yes`, or a following flag swallowed as the value — and that is exactly the
# permanent-`expected` state --iac-only exists to prevent
[[ "$IAC_ONLY" =~ ^(true|false)$ ]] || die "--iac-only must be true or false"
# The toolchain names the language-app contexts, so it is required exactly on
# that path — and never read on the IaC path, which requires `gate` alone.
if [[ "$IAC_ONLY" != "true" ]]; then
	[[ "$STATIC_ANALYSIS" =~ ^(sonarcloud|sonarqube)$ ]] ||
		die "--static-analysis must be sonarcloud or sonarqube (the resolved static_analysis)"
	[[ "$VULNERABILITIES" =~ ^(snyk|trivy)$ ]] ||
		die "--vulnerabilities must be snyk or trivy (the resolved vulnerabilities)"
fi

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
[[ -n "$REPO" ]] || die "Could not determine current repo from gh"

# --- build required-status-checks list ---------------------------------------
# These names must match the `jobs.<id>` keys in the generated workflow files.
checks=("test-and-coverage" "semgrep" "pre-commit")

# --- the #1206 direct-to-cluster gate ----------------------------------------
# `no-cluster-deploy` is the application-repo half of the promotion contract: an
# app repo publishes images and never writes to a cluster itself. Required on
# THIS path only — an infrastructure repo is supposed to write to a cluster, so
# §3l renders no such workflow and requiring the context there would pin every
# IaC PR on the permanent `expected` state. Its workflow carries no path filter
# for the same reason, so when it exists it always reports.
#
# Gated on the workflow actually being ON DISK, exactly as the `image` context
# is gated on ko-image.yml below, and for the same reason. Unlike
# `test-and-coverage`, this workflow is NEW (#1206): every repo bootstrapped
# before it lacks the file, and this script is documented as runnable standalone
# and is re-run by the State-D gap-fill. Requiring a context no workflow reports
# wedges every PR at `expected` forever — the failure this file warns about four
# separate times. branch-protection.sh always runs from the target repo root, so
# the path is repo-relative.
if [[ "$IAC_ONLY" != "true" ]]; then
	# BOTH halves, because the workflow runs the script: a present workflow with
	# a missing checker makes every PR fail with `no such file or directory`
	# instead of a verdict — the same wedge one level down.
	if [[ -f .github/workflows/no-cluster-deploy.yml && -f scripts/check-no-cluster-deploy.zsh ]]; then
		checks+=("no-cluster-deploy")
	else
		missing_half=".github/workflows/no-cluster-deploy.yml"
		[[ -f "$missing_half" ]] && missing_half="scripts/check-no-cluster-deploy.zsh"
		warn "\`$missing_half\` is absent — NOT requiring the \`no-cluster-deploy\`"
		warn "check (it would never report a usable verdict). Re-run"
		warn "/development:bootstrap to render the #1206 direct-to-cluster gate."
	fi
fi

# --- the infrastructure-as-code path takes an entirely different check set ----
# Not an addition to the language-app set but a REPLACEMENT: on this path
# quality-*.yml is not rendered, so every context above would sit at `expected`
# forever and block each PR. The toolchain contexts below are skipped for the same
# reason — its contexts come from that same unrendered workflow.
if [[ "$IAC_ONLY" == "true" ]]; then
	# Gated on the job actually being ON DISK, like `no-cluster-deploy` above and
	# `image` below — but REFUSED rather than dropped. A repo bootstrapped before
	# #1604 still carries the per-stage kubernetes-ci.yml, which never reports
	# `gate`, and this script re-runs standalone and from the State-D gap-fill:
	# requiring `gate` there would swap working required contexts for one nothing
	# reports, and dropping it would silently require no check at all. So stop
	# before any rule is written and name the fix for the file's PROVENANCE (#1606):
	# a file carrying the plugin's marker is refreshed from its template once its
	# diff is reviewed, an unmarked one is the user's to edit. **Re-running
	# bootstrap helps only a marked file** — State D's refusal branch refreshes
	# that one through the idempotency reviewer; on an UNMARKED file bootstrap
	# keeps the user's copy and reaches this same refusal again, which is why the
	# message hands that case back to the user instead.
	#
	# The probe reads the `jobs:` mapping rather than the whole file, at whatever
	# indent that block uses (YAML fixes none), so a comment, a step, an `env:`
	# key or any other mapping merely MENTIONING gate never satisfies it — and a
	# consumer's four-space workflow with a real `gate` job is not refused for its
	# layout. It also refuses a `gate` job carrying `name:`, a `strategy:` block
	# or a reusable-workflow `uses:` — the three ways a job stops being reported
	# under its own id (that name, `gate (<leg>)`, `gate / <called job>`) — so
	# requiring `gate` would wedge every PR at `expected`, the very failure this
	# guard exists to prevent, and the shape the message already asks for. A
	# `gate` job it cannot read line by line (flow style, an anchor, alias, tag or
	# `<<:` merge key) and a workflow whose `on:` skips some pull requests are
	# refused for the same reason, each with its own message (#1641).
	# Anchored at the work-tree root, not the CWD: unlike the two probes that
	# merely DROP a context with a warning, this one is fatal, so a run from a
	# subdirectory (where `gh repo view` still resolves the repo) would otherwise
	# refuse a repo whose workflow is fine — and send the operator to render the
	# template into that subdirectory. Outside a work tree there is nothing better
	# to resolve against, so it falls back to the CWD rather than refusing: that
	# keeps the probe no stricter than the two beside it.
	iac_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	iac_ci="$iac_root/.github/workflows/kubernetes-ci.yml"
	iac_tmpl="templates/iac/.github/workflows/kubernetes-ci.yml.tmpl"
	if [[ ! -f "$iac_ci" ]]; then
		die "\`$iac_ci\` is absent — NOT applying branch protection: its \`gate\` check would never report. Render it from the plugin's $iac_tmpl into the working tree first, then re-run this script."
	fi
	# 0: a `gate` job GitHub reports as `gate`; 1: no `gate` job; 2: a `gate` job
	# whose reported name is something else; 3: a `gate` job this line reader
	# cannot read — an inline value on its key (`{…}`, `&anchor`, `*alias`,
	# `!tag`), or a line among its own keys that is neither a plain block key nor
	# a flush sequence item (the same nodes opening on the next line, a tagged or
	# `?` key, a `<<:` merge key), any of which can carry a `name:` or
	# `strategy:` the reader never sees. Every line-end match goes
	# through `[[:space:]]*`, which a CRLF-authored workflow's trailing CR
	# satisfies, so such a file is read like any other.
	#
	# An awk that exits non-zero read nothing, so its verdict is never taken:
	# under `set -e` a bare failure would abort with no message, and a status
	# read as a verdict would blame a file that was never read (#1641).
	gate_job_state=$(
		awk '
			/^["\047]?jobs["\047]?[[:space:]]*:[[:space:]]*(#.*)?$/ { in_jobs = 1; next }
			in_jobs && /^[^[:space:]#]/ { in_jobs = 0 }
			in_jobs && /^[[:space:]]+[^[:space:]#]/ {
				match($0, /^[[:space:]]+/)
				this_indent = substr($0, 1, RLENGTH)
				body = substr($0, RLENGTH + 1)
				if (job_indent == "") { job_indent = this_indent }
				if (this_indent == job_indent) {
					in_gate = (body ~ /^["\047]?gate["\047]?[[:space:]]*:([[:space:]]|$)/)
					if (in_gate) {
						found = 1
						# anything but a comment after the key is an inline value
						if (body !~ /^["\047]?gate["\047]?[[:space:]]*:[[:space:]]*(#.*)?$/) { flow = 1 }
					}
					gate_key_indent = ""
				} else if (in_gate && length(this_indent) > length(job_indent)) {
					# only keys belonging to the gate job ITSELF: the first child
					# line fixes their indent, so a step name, a `with:` map or a
					# block scalar writing YAML sits deeper and never trips this
					if (gate_key_indent == "") { gate_key_indent = this_indent }
					if (this_indent == gate_key_indent) {
						# at this indent only a plain block key or a flush
						# sequence item (`steps:` written flush) is readable;
						# anything else — a flow node, alias, anchor or tag
						# opening the job on the line after `gate:`, a tagged
						# or `?` key, a `<<:` merge key — can hide a `name:`
						if (body ~ /^-([[:space:]]|$)/) {
						} else if (body !~ /^["\047]?[A-Za-z0-9_-]+["\047]?[[:space:]]*:([[:space:]]|$)/) {
							flow = 1
						} else if (body ~ /^["\047]?(name|strategy|uses)["\047]?[[:space:]]*:/) {
							renamed = 1
						}
					}
				}
			}
			END { print (found ? (flow ? 3 : (renamed ? 2 : 0)) : 1) }
		' "$iac_ci"
	) || die "could not read \`$iac_ci\` (awk exited $? while probing its \`gate\` job) — NOT applying branch protection. Make the file readable, then re-run this script."
	if [[ "$gate_job_state" == 3 ]]; then
		die "\`$iac_ci\`'s \`gate\` job is written in flow style, or through an anchor, alias, tag or \`<<:\` merge key — NOT applying branch protection: this script reads the job's own keys line by line and cannot tell whether GitHub reports it as \`gate\`. Write it as a block mapping — \`gate:\` alone on its line, its keys indented beneath it, no \`<<:\` — then re-run this script."
	fi
	if [[ "$gate_job_state" == 2 ]]; then
		die "\`$iac_ci\`'s \`gate\` job carries \`name:\`, a \`strategy:\` block or a reusable-workflow \`uses:\`, so GitHub reports it under another name (that name, \`gate (<leg>)\` per matrix entry, or \`gate / <called job>\`) — NOT applying branch protection: the \`gate\` context would never report. Drop \`name:\`/\`strategy:\` from the job (its steps may keep their own \`name:\`/\`uses:\`; a \`strategy:\` without \`matrix:\` does nothing for a lone job), or — for a reusable-workflow \`uses:\` — inline the called workflow's steps into the \`gate\` job, then re-run this script."
	fi
	if [[ "$gate_job_state" != 0 ]]; then
		# 0 is marked, 1 is unmarked; any other status read nothing
		marker_status=0
		awk 'NR <= 10 && /^# claude-bootstrap: rendered from iac\//{ found = 1 } NR > 10 { exit } END { exit !found }' "$iac_ci" ||
			marker_status=$?
		case "$marker_status" in
		0) die "\`$iac_ci\` carries the plugin's provenance marker but has no \`gate\` job (a pre-#1604 per-stage one?) — NOT applying branch protection: \`gate\` would never report. Refresh it from the plugin's $iac_tmpl into the working tree (after reviewing the diff), then re-run this script." ;;
		1) ;;
		*) die "could not read \`$iac_ci\` (awk exited $marker_status while probing its provenance marker) — NOT applying branch protection. Make the file readable, then re-run this script." ;;
		esac
		die "\`$iac_ci\` is user-owned and has no \`gate\` job — NOT applying branch protection: \`gate\` would never report. Give it a job with id \`gate\` that GitHub reports under that id (no \`name:\`, no \`strategy:\`/matrix, no reusable-workflow \`uses:\`), or remove it so the plugin's $iac_tmpl is rendered, then re-run this script."
	fi
	# The `gate` job reports as `gate` — but only on the pull requests the
	# workflow's `on:` runs it for. A PR it skips never reports `gate` and waits
	# at `expected` forever, so require a bare `pull_request` (#1641): the scalar
	# `on: pull_request`, the token in a flow list, a block-list item, or a
	# block-mapping key valued empty, `~`, `null` or `{}` with no child lines.
	# Any child — `types:`, `branches:`, `branches-ignore:`, `paths:`,
	# `paths-ignore:` — narrows it, and a flow-mapping `on: {…}` is not read.
	# Other triggers may sit beside it. 0: runs on every PR; 1: does not.
	trigger_state=$(
		awk '
			function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
			function uncomment(s) { sub(/(^|[[:space:]])#.*$/, "", s); return trim(s) }
			function is_pr(s) {
				s = trim(s)
				if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) { s = substr(s, 2, length(s) - 2) }
				return s ~ /^pull_request$/
			}
			/^["\047]?on["\047]?[[:space:]]*:([[:space:]]|$)/ {
				v = $0
				sub(/^[^:]*:/, "", v)
				v = uncomment(v)
				in_on = (v == "")
				if (v ~ /^\[.*\]$/) {
					n = split(substr(v, 2, length(v) - 2), toks, ",")
					for (i = 1; i <= n; i++) { if (is_pr(toks[i])) { ok = 1 } }
				} else if (v !~ /^\{/ && is_pr(v)) { ok = 1 }
				next
			}
			in_on && /^[^[:space:]#]/ { in_on = 0; if (pr_open) { ok = 1; pr_open = 0 } }
			in_on && /^[[:space:]]+[^[:space:]#]/ {
				match($0, /^[[:space:]]+/)
				this_indent = substr($0, 1, RLENGTH)
				body = substr($0, RLENGTH + 1)
				if (on_indent == "") { on_indent = this_indent }
				if (length(this_indent) > length(on_indent)) {
					# a child line: under an open `pull_request:` it is a filter
					if (pr_open) { pr_open = 0 }
					next
				}
				if (pr_open) { ok = 1; pr_open = 0 }
				if (body ~ /^-([[:space:]]|$)/) {
					if (is_pr(uncomment(substr(body, 2)))) { ok = 1 }
				} else if (body ~ /^["\047]?pull_request["\047]?[[:space:]]*:([[:space:]]|$)/) {
					v = body
					sub(/^[^:]*:/, "", v)
					v = uncomment(v)
					if (v == "" || v == "~" || v == "null" || v ~ /^\{[[:space:]]*\}$/) { pr_open = 1 }
				}
			}
			END { if (pr_open) { ok = 1 }; print (ok ? 0 : 1) }
		' "$iac_ci"
	) || die "could not read \`$iac_ci\` (awk exited $? while probing its \`on:\` triggers) — NOT applying branch protection. Make the file readable, then re-run this script."
	if [[ "$trigger_state" != 0 ]]; then
		die "\`$iac_ci\` does not run on every pull request — NOT applying branch protection: a PR its \`on:\` skips never reports \`gate\` and waits at \`expected\` forever. Trigger it on a bare \`pull_request\` with no \`types:\`, \`branches:\`, \`branches-ignore:\`, \`paths:\` or \`paths-ignore:\` filter (other triggers may stay beside it), then re-run this script."
	fi
	# the one job of templates/iac/.github/workflows/kubernetes-ci.yml.tmpl: it
	# carries no `name:` and no matrix, so GitHub reports it under its id
	checks=("gate")
fi

# Everything below builds the LANGUAGE-APP context set, so the IaC path skips it
# whole: its `image`/CodeQL/Sonar contexts all come from workflows that path does
# not render.
if [[ "$IAC_ONLY" != "true" ]]; then
	# --- does any workflow actually PROVIDE the shared `image` check? -------------
	# Both the Docker lane (quality-*.yml's `image` job) and the ko lane
	# (ko-image.yml's `image` job) report a status check literally named `image`.
	# A repo has one provider or the other, never both — a Go repo uses ko OR, for
	# the documented cgo exception, a Dockerfile instead of ko. The Docker lane
	# ships in quality-*.yml whenever a Dockerfile exists (any language), so
	# HAS_DOCKERFILE alone is a sufficient provider signal. The ko lane, though, is
	# rendered only for Go repos, so a raw `.ko.yaml` is NOT proof its workflow
	# exists: a stray root .ko.yaml in a non-Go repo, or a Go repo whose ko-image
	# install was declined, would otherwise make `image` a required context that no
	# workflow ever reports — the permanent stuck-on-`expected` state the Snyk note
	# below exists to avoid. So gate the ko half on the workflow file actually
	# being present. branch-protection.sh always runs from the target repo root
	# (bootstrap's Step 4b invokes it there), so the path is repo-relative.
	image_required="false"
	[[ "$HAS_DOCKERFILE" == "true" ]] && image_required="true"
	[[ "$HAS_KO" == "true" && -f .github/workflows/ko-image.yml ]] && image_required="true"
	# Surface the fail-open path rather than silently dropping the gate: a repo that
	# advertised .ko.yaml but has no ko-image workflow gets no `image` requirement,
	# and the operator should know why it's absent from the printed check list.
	if [[ "$HAS_KO" == "true" && ! -f .github/workflows/ko-image.yml ]]; then
		warn ".ko.yaml was detected but .github/workflows/ko-image.yml is absent —"
		warn "NOT requiring the \`image\` check (no workflow would ever report it)."
	fi
	if [[ "$HAS_DOCKERFILE" == "true" && "$HAS_KO" == "true" ]]; then
		warn "Both a Dockerfile and a root .ko.yaml were detected. The Docker and ko"
		warn "image lanes both report a check named \`image\`, so their two workflows"
		warn "would collide — GitHub keeps only the most recent \`image\` result for a"
		warn "required context, which can mask a red build. Use ko OR a Dockerfile,"
		warn "not both."
	fi

	# --- the toolchain's contexts (#1670 D1) -----------------------------------
	# `license-fs` runs on every combination. The analyser's job is named for
	# the analyser (`sonarcloud` / `sonarqube`). `trivy-fs` exists only when the
	# resolved vulnerabilities tool is Trivy: Snyk has NO CI job — it runs via
	# the GitHub integration, which reports `security/snyk` rather than a GitHub
	# Actions status check (see the quality templates' `# --- Snyk source-code +
	# open-source scans ---` comment block), so requiring a Snyk context would
	# produce a permanent stuck-on-expected state.
	checks+=("license-fs" "$STATIC_ANALYSIS")
	[[ "$VULNERABILITIES" == "trivy" ]] && checks+=("trivy-fs")
	[[ "$image_required" == "true" ]] && checks+=("image") # ko-image shares the `image` job name (#875)
	if [[ "$HAS_CODEQL" == "true" ]]; then
		# Gated on codeql.yml actually being ON DISK, like `image`/ko-image and
		# `no-cluster-deploy` above: a context no workflow reports wedges every
		# PR at `expected`. Warn and drop rather than refuse.
		if [[ ! -f .github/workflows/codeql.yml ]]; then
			warn "--has-codeql=true but .github/workflows/codeql.yml is absent —"
			warn "NOT requiring any \`analyze (<lang>)\` check (no workflow would ever"
			warn "report it). Re-run /development:bootstrap to render CodeQL."
		elif [[ -n "$CODEQL_LANGUAGES" ]]; then
			# CodeQL's `analyze` job is a matrix over `language`, so GitHub
			# reports one check per language as `analyze (<lang>)`. The bare
			# `analyze` context never resolves to a real check — must be
			# language-suffixed. Commas are normalised to spaces first, so the
			# comma-separated {{CODEQL_LANGUAGES}} form splits like the spaced one
			# instead of becoming one `analyze (python,javascript)` context
			# nothing reports (#1793).
			CODEQL_LANGUAGES=${CODEQL_LANGUAGES//,/ }
			for lang in $CODEQL_LANGUAGES; do
				checks+=("analyze ($lang)")
			done
		else
			warn "--has-codeql=true but --codeql-languages was not provided."
			warn "Skipping CodeQL contexts — without language list, the bare"
			warn "'analyze' context would never resolve. Pass --codeql-languages"
			warn "\"python javascript-typescript ...\" (space- or comma-separated) to enable them."
		fi
	fi
fi

# --- assemble JSON payload ----------------------------------------------------
contexts_json=$(printf '%s\n' "${checks[@]}" | jq -R . | jq -s .)
payload=$(jq -n \
	--argjson contexts "$contexts_json" \
	'{
    required_status_checks: {
      strict: true,
      contexts: $contexts
    },
    enforce_admins: false,
    required_pull_request_reviews: {
      required_approving_review_count: 1,
      dismiss_stale_reviews: true,
      require_code_owner_reviews: false
    },
    restrictions: null,
    required_linear_history: true,
    allow_force_pushes: false,
    allow_deletions: false,
    required_conversation_resolution: true
  }')

info "Applying branch protection on $REPO@$DEFAULT_BRANCH"
dim "Required checks:"
printf '  • %s\n' "${checks[@]}"

# --- PUT --------------------------------------------------------------------
http_body=$(mktemp)
http_status=$(curl -sS -o "$http_body" -w '%{http_code}' \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: token $(gh auth token)" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	-X PUT \
	"https://api.github.com/repos/$REPO/branches/$DEFAULT_BRANCH/protection" \
	--data "$payload")

case "$http_status" in
200)
	ok "Branch protection applied"
	;;
403)
	warn "403 — your account does not have admin permission on $REPO"
	cat <<EOF

You'll need to apply branch protection manually. In GitHub:
  Settings → Branches → Add rule → Branch name pattern: $DEFAULT_BRANCH

Required status checks:
$(printf '  • %s\n' "${checks[@]}")

Plus: require PR before merging, require linear history, block force pushes,
block deletions. See SETUP.md for the full list.

Also enable in Settings → General → Pull Requests:
  • Allow auto-merge                       (needed by the maintenance
                                            approval gate, plugins#224)
  • Automatically delete head branches     (branch cleanup for auto-merged PRs)
EOF
	rm -f "$http_body"
	exit 0 # not a hard failure — user can do it by hand
	;;
*)
	err "Branch protection failed (HTTP $http_status):"
	cat "$http_body" >&2
	rm -f "$http_body"
	exit 1
	;;
esac

rm -f "$http_body"

# --- repo merge settings (auto-merge + delete-branch + squash-only) ----------
# The maintenance pipeline's approval gate (plugins#224) arms GitHub native
# auto-merge when no approving review has landed within the gate window;
# arming requires the repo-level "Allow auto-merge" setting. And because gh
# isn't running when GitHub later performs an armed merge, `--delete-branch`
# can't act — head-branch cleanup for those merges needs
# delete_branch_on_merge instead.
#
# Squash-only: the whole family uses `gh pr merge --squash` (linear history is
# enforced in branch protection), but nothing stopped a manual UI merge-commit
# or rebase. Disable both at the repo level so the squash convention holds even
# for hand-merges. Idempotent (PATCH sets absolute state).
info "Setting repo merge settings on $REPO (auto-merge + delete-branch + squash-only)"
ms_status=$(curl -sS -o /dev/null -w '%{http_code}' \
	-H "Accept: application/vnd.github+json" \
	-H "Authorization: token $(gh auth token)" \
	-H "X-GitHub-Api-Version: 2022-11-28" \
	-X PATCH \
	"https://api.github.com/repos/$REPO" \
	--data '{"allow_auto_merge":true,"delete_branch_on_merge":true,"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false}')
case "$ms_status" in
200) ok "Repo merge settings applied (auto-merge, head-branch delete, squash-only)" ;;
403) warn "Could not set repo merge settings (403 — admin needed). Enable manually: Settings → General → Pull Requests → 'Allow auto-merge' + 'Automatically delete head branches'." ;;
*) warn "Repo merge-settings PATCH returned HTTP $ms_status — check Settings → General → Pull Requests manually." ;;
esac

# --- required_signatures (separate endpoint) ---------------------------------
# GitHub's main protection PUT doesn't include the signature requirement; it
# lives on its own endpoint. POST to enable, DELETE to disable. We call the
# matching verb either way so re-runs leave the rule in the requested state.
if [[ "$REQUIRE_SIGNED_COMMITS" == "true" ]]; then
	info "Enabling required_signatures on $REPO@$DEFAULT_BRANCH"
	sig_status=$(curl -sS -o /dev/null -w '%{http_code}' \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $(gh auth token)" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-X POST \
		"https://api.github.com/repos/$REPO/branches/$DEFAULT_BRANCH/protection/required_signatures")
	case "$sig_status" in
	200 | 201) ok "Signed commits required on $DEFAULT_BRANCH" ;;
	403) warn "Could not enable required_signatures (403 — admin needed). Enable manually: Settings → Branches → Edit rule → 'Require signed commits'." ;;
	*) warn "required_signatures returned HTTP $sig_status — check Settings → Branches manually." ;;
	esac
	warn "Every contributor must register a GPG or SSH signing key in their GitHub account before they can push to $DEFAULT_BRANCH. See SETUP.md."
else
	# Disable explicitly so re-runs without the flag clear any previously-set
	# requirement. 404 is fine (means it was already off).
	curl -sS -o /dev/null \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $(gh auth token)" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		-X DELETE \
		"https://api.github.com/repos/$REPO/branches/$DEFAULT_BRANCH/protection/required_signatures" || true
fi
