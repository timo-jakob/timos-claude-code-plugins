#!/usr/bin/env bash
# branch-protection.sh — apply Zero-Tolerance branch protection on the default
# branch via the GitHub API. Idempotent (PUT replaces the rule each time).
#
# Usage:
#   branch-protection.sh --visibility public|private \
#                        --has-dockerfile true|false \
#                        [--has-ko true|false] \
#                        --has-codeql true|false \
#                        [--codeql-languages "python javascript ..."] \
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
# sonarcloud, semgrep, pre-commit, license-fs — would be required contexts that no
# workflow ever reports, pinning every PR on the permanent `expected` state. The
# repo's checks are the six kubernetes-ci.yml jobs instead. Everything else the
# rule applies (PR required, linear history, no force-push/deletion, and the
# repo-level merge settings auto-merge arming depends on) is unchanged: the
# contexts differ, the protection does not.
#
# --codeql-languages is required when --has-codeql=true. CodeQL's analyze
# job runs as a matrix per language and GitHub reports each one as
# `analyze (<lang>)`, so a bare `analyze` context never resolves.
#
# Requires: gh CLI authenticated, repository admin permission. On 403 the
# script falls back to printing manual instructions.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

VISIBILITY=""
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
		VISIBILITY="$2"
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

[[ "$VISIBILITY" =~ ^(public|private)$ ]] || die "--visibility must be public or private"
# validated like --visibility, not merely compared: an unvalidated flag silently
# falls through to the language-app context set on any value but the literal
# "true" — `True`, `yes`, or a following flag swallowed as the value — and that
# is exactly the permanent-`expected` state --iac-only exists to prevent
[[ "$IAC_ONLY" =~ ^(true|false)$ ]] || die "--iac-only must be true or false"

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
# forever and block each PR. The visibility case below is skipped for the same
# reason — its contexts come from that same unrendered workflow.
if [[ "$IAC_ONLY" == "true" ]]; then
	# the six jobs of templates/iac/.github/workflows/kubernetes-ci.yml.tmpl,
	# in pipeline order
	checks=("render" "schema" "lint" "policy" "config-scan" "argocd")
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
	# (the automate-*.sh callers set REPO_ROOT=$(pwd) and never cd), so the path is
	# repo-relative.
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

	case "$VISIBILITY" in
	public)
		# Note: `snyk-code` and `snyk-open-source` are NOT workflow jobs in the
		# current public template. Snyk runs via the GitHub integration, which
		# reports a single `security/snyk` check on the PR rather than per-rule
		# GitHub Actions status checks — see quality-public.yml.tmpl's `# ---
		# Snyk source-code + open-source scans ---` comment block. Listing
		# them here would produce a permanent stuck-on-expected state.
		checks+=("sonarcloud" "license-fs")
		[[ "$image_required" == "true" ]] && checks+=("image") # ko-image shares the `image` job name (#875)
		if [[ "$HAS_CODEQL" == "true" ]]; then
			# CodeQL's `analyze` job is a matrix over `language`, so GitHub
			# reports one check per language as `analyze (<lang>)`. The bare
			# `analyze` context never resolves to a real check — must be
			# language-suffixed.
			if [[ -n "$CODEQL_LANGUAGES" ]]; then
				for lang in $CODEQL_LANGUAGES; do
					checks+=("analyze ($lang)")
				done
			else
				warn "--has-codeql=true but --codeql-languages was not provided."
				warn "Skipping CodeQL contexts — without language list, the bare"
				warn "'analyze' context would never resolve. Pass --codeql-languages"
				warn "\"python javascript ...\" (space-separated) to enable them."
			fi
		fi
		;;
	private)
		checks+=("sonarqube" "trivy-fs" "license-fs")
		[[ "$image_required" == "true" ]] && checks+=("image") # ko-image shares the `image` job name (#875)
		;;
	esac
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
