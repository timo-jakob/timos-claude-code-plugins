#!/usr/bin/env zsh
# check-no-cluster-deploy.zsh — fail an APPLICATION repo whose CI deploys
# straight to a cluster (issue #1206, epic #1058; the position is #1189).
#
# ---------------------------------------------------------------------------
# THE RULE
# ---------------------------------------------------------------------------
# The infrastructure repo is the only path to a cluster. An application repo
# publishes versioned, immutable images and never touches a cluster itself; a
# version change reaches the cluster as a pull request against the
# infrastructure repo. ARCHITECTURE.md's "Deployment — GitOps promotion and
# immutable references" section states that contract; this script is the
# application-repo half of enforcing it. (The infrastructure half is the IaC
# check pipeline, kubernetes-ci.yml.)
#
# It scans `.github/workflows/**` for steps whose `run:` body invokes a
# cluster-WRITING command, and exits 1 naming the workflow file, the job id, the
# step name (or its index when the step is unnamed) and the matched command.
#
# ---------------------------------------------------------------------------
# WHY IT FAILS RATHER THAN WARNS, AND WHY THERE IS NO ESCAPE HATCH
# ---------------------------------------------------------------------------
# The whole value of this rule is auditability — every change that reaches a
# cluster went through a reviewed pull request against the infrastructure repo.
# A warn-only gate on such a rule is a gate nobody reads: the warning scrolls
# past in a green check and the deploy step stays. So a hit is a FAILURE.
#
# And there is deliberately NO standing escape hatch — no `# no-cluster-deploy:
# allow` annotation, no allowlist file. This family's stance is that outgrowing
# a decision earns "a deliberate re-decision, which is not the same as a
# standing escape hatch" (ARCHITECTURE.md, the Messaging position's *Rationale*
# paragraph). A repo with a genuine exception changes THIS CHECK, in a reviewed
# pull request that a human reads — which is the same audit trail the rule is
# about — rather than annotating past it in the file that broke the rule.
#
# That decision is also why the `--dry-run` exemption below is scoped to the
# COMMAND and not to the step: a step-wide test would let one `--dry-run`
# anywhere in a body — in a comment, in an `echo`, on an unrelated earlier
# command — silence every real deploy beside it, which is a self-service
# annotation in all but name.
#
# ---------------------------------------------------------------------------
# THE IaC EXEMPTION, AND WHY IT READS `primary:` AS A GRANT
# ---------------------------------------------------------------------------
# An infrastructure repo is SUPPOSED to write to a cluster, so it is exempt. The
# exemption keys on `.maintenance.yml` recording `primary: kubernetes` — the
# repo's own declaration of its primary type for /development:maintenance.
#
# This is a DELIBERATE DEPARTURE from the bootstrap skill's §3l rule, and a
# reader of this script must know it. There, a recorded primary may only VETO
# the IaC path, never GRANT it: `detect-stack.sh` resolves the path from the
# kubernetes marker plus a detected language, and a recorded `primary:
# kubernetes` cannot override a detected language (that mixed repo is #1193).
# SKILL.md §3l also states there is "no `iac_only` key in its JSON (it is a
# private shell variable)".
#
# Here the record is read as a POSITIVE declaration, for two reasons:
#   1. There is no detector to consult. This script runs inside a CONSUMER
#      repo's CI, where `detect-stack.sh` is not installed — the veto-vs-grant
#      rule presumes a heuristic this side of the fence does not have.
#   2. The value is not an inference. `primary:` is written at bootstrap under
#      human approval, so reading it as a declaration is reading a human
#      decision, not guessing from file shapes.
# The consequence is stated rather than hidden: a repo can exempt itself by
# writing `primary: kubernetes`. That edit is visible in a reviewed diff, which
# is the same standard the no-escape-hatch decision above holds to.
#
# A repo that carries a Kubernetes marker (a Chart.yaml, a kustomization) but
# records a LANGUAGE primary is FLAGGED, not exempt (#1193's mixed repo): a repo
# that builds an application is an application repo, whatever else it carries.
#
# It is a REPO-WIDE exemption, and the only one — the two below are scoped to a
# job and to a command. Anywhere this script's rules are restated, all three
# have to be, or the restatement understates how the gate can go quiet.
#
# ---------------------------------------------------------------------------
# WHAT MATCHES (v1 — a CLOSED set)
# ---------------------------------------------------------------------------
#   kubectl apply|create|replace|patch|delete, kubectl rollout restart,
#   kubectl set image, kubectl scale,
#   helm install, helm upgrade (with OR without --install), helm rollback,
#   helm uninstall (and its aliases `delete`, `del`, `un` — helm 3 documents
#     them as the same command, so matching them is implementing the listed
#     verb, not widening the set),
#   argocd app sync|create|set,
#   flux reconcile, flux bootstrap
#
# Deliberately NOT matched (read-only or render-only):
#   kubectl get|describe|diff|logs|wait, helm template|lint|diff,
#   `kustomize build` on its own, argocd app diff, kubeconform, conftest
# `kustomize build | kubectl apply -f -` needs no case of its own — the
# `kubectl apply` arm already matches the pipeline.
#
# NOT matched but NOT read-only either — v1's CLOSED set leaves these out, and
# they are named here so the omission is auditable rather than implied:
#   kubectl run|edit|annotate|label|expose|cordon|uncordon|drain|taint|exec,
#   `helm plugin install`.
# Each mutates a cluster. Widening the set is a deliberate re-decision (a
# follow-up issue), not something to slip in — but a reader must not mistake
# their absence for a judgement that they are harmless.
# (`kubectl create` in every form, generators included, IS matched — it is in
# the v1 set above. It is called out here only because it is easy to assume the
# generator form escapes: it does not.)
#
# TWO SCOPED EXEMPTIONS (plus the repo-wide IaC one above):
#   * EPHEMERAL, job-scoped. A job that creates its OWN cluster in an earlier
#     step (`kind create cluster`, `k3d cluster create`, `minikube start`,
#     `ctlptl apply`) exempts the cluster-writing steps that FOLLOW it in that
#     same job — an integration test that spins up kind and applies manifests to
#     it is not a deploy. The scope is the job, not the file: the same step in a
#     SIBLING job still fails, because a sibling job runs against whatever
#     cluster its own credentials point at. It runs forward from the creating
#     step, because a job that deploys and only afterwards stands up a kind
#     cluster deployed to someone else's. "At or after", precisely: the rest of
#     the CREATING step's own body is exempt too, since the creation is earlier
#     in that body — the single-step `run: |` with `kind create cluster` then
#     `kubectl apply` is the common integration-job shape and is exempt.
#     GUARDED CREATORS narrow it, and the narrowing is not a blanket refusal.
#     The exemption keys on the EARLIEST creating step in the job and on THAT
#     step's condition: an unconditional one exempts every cluster-writing step
#     at or after it, while one carrying an `if:` guard exempts only a step
#     carrying the byte-identical condition. The branch-per-environment shape
#     (`if: pull_request` stands up kind, `if: ref == main` deploys) is exactly
#     what this gate exists to catch: there the two are mutually exclusive and
#     the deploy hits the real cluster, so a DIFFERING condition — and an
#     unguarded deploy under a guarded creator — fails CLOSED, a false alarm a
#     human reads. The identical-condition pair, both steps guarded alike, is
#     the commonest real integration shape and keeps the exemption; see the
#     PASS 2 comment at the implementation for the two `continue` arms.
#   * DRY RUN, COMMAND-scoped. A command carrying a REAL dry-run flag never
#     matches: bare `--dry-run`, `--dry-run=client`, `--dry-run=server`,
#     `--dry-run=true`, or the separate-argument `--dry-run client|server`.
#     `--dry-run=none` and `--dry-run=false` mean the OPPOSITE and do NOT
#     exempt. Scoped to the command, not the step, for the reason given under
#     the no-escape-hatch decision above: a step-wide test is an annotation.
#     It applies to the CLUSTER-CREATION set too: `minikube start --dry-run`
#     validates configuration and creates nothing, so it confers no ephemeral
#     exemption — a creator that creates nothing must not exempt anything.
#
# The credential heuristic — match only steps referencing KUBECONFIG or a
# secret — was REJECTED: a cloud OIDC login writes a kubeconfig in a SEPARATE
# step, so the deploy step carries no secret literal and the heuristic would
# miss precisely the case this gate exists to catch.
#
# ---------------------------------------------------------------------------
# KNOWN GAPS (v1) — stated, not implied
# ---------------------------------------------------------------------------
# A PASS means "no cluster-writing command appears literally in a workflow's own
# `run:` text". It is NOT proof the repo never writes to a cluster. Concretely:
#   * Only `run:` script bodies are inspected. A deploy expressed as a
#     marketplace action (`uses: azure/k8s-deploy@v4` and friends) or a
#     reusable workflow is NOT detected. A follow-up issue covers it.
#   * INDIRECTION is not followed. `run: ./scripts/deploy.sh`, `run: make
#     deploy`, `run: task deploy`, or a composite action under
#     `.github/actions/**` reaches a cluster with nothing here to see.
#   * The ephemeral exemption reads `run:` bodies for the same reason, so a
#     cluster stood up by a marketplace action (`helm/kind-action`) does not
#     exempt its job. That direction fails CLOSED (a false alarm a human sees),
#     which is the safe side of the same gap.
#   * Only the EARLIEST creating step in a job is recorded, along with its
#     condition, so a job whose first creator is `if:`-guarded and whose SECOND
#     creator is unconditional is judged against the guarded condition — an
#     unguarded deploy after both fails, although a cluster was unconditionally
#     stood up. Fails CLOSED, and the shape is rare enough that recording every
#     creator is not worth the ambiguity of choosing between them; reorder the
#     unconditional creator first if you hit it.
#   * An `if:` written as a YAML BOOLEAN is not a string, so the extractor
#     records NO condition and the creator is read as unconditional. The two
#     spellings are NOT the same defect:
#       - `if: true` — the step always runs, so "unconditional" is the CORRECT
#         reading. Right answer, reached without inspecting the value.
#       - `if: false` — the usual way to park a step. It never runs and no
#         cluster is created, yet the creator still exempts every
#         cluster-writing step at or after it, unguarded ones included. This
#         one fails OPEN: a `kind create cluster` parked with `if: false`
#         currently exempts a real `helm upgrade --install` after it. Write the
#         guard as an expression string (`if: ${{ false }}`) if you need the
#         narrowing. Tracked for a fix.
#     A fix must map a YAML `true` to UNCONDITIONAL — not to the condition
#     string `true` — or it reds the always-run integration job the
#     guarded-creator clause exists to keep exempt.
#   * A command reached only through a shell variable or an alias defined
#     earlier in the same body is not resolved.
#   * A NESTED command substitution (`$( … $( … ) … )`) is lifted at the first
#     `)`, so the outer remainder is scanned as text rather than as a command.
#   * `--dry-run` is read per COMMAND, so a genuinely-exempt step whose flag is
#     computed rather than written literally is not recognised — an unresolved
#     value is treated as NOT a dry run, which is the fail-closed side.
#   * A HEREDOC body, and a quoted string spanning several physical lines, are
#     scanned line by line as commands. A step that writes documentation or a
#     deploy script naming a banned command inside one is REPORTED. That fails
#     CLOSED — a false alarm a human reads — and is stated here rather than
#     discovered; making the scanner heredoc-aware is a follow-up.
#   * A tool invoked inside a CONTAINER (`docker run … bitnami/kubectl apply`)
#     is not resolved: `docker` is the command, and the image argument is not
#     walked. Named separately from the indirection gap above because the
#     banned command IS written literally on the line.
#   * The command inside `sh -c "…"` is re-scanned, but not re-split, so only
#     its first command is resolved (`sh -c "cd x && kubectl apply -f ."`).
#
# ---------------------------------------------------------------------------
# EXIT CODES
# ---------------------------------------------------------------------------
#   0  no cluster-writing step found, or the repo is IaC-exempt
#   1  at least one hit, or at least one workflow file could not be parsed
#   2  usage; missing or wrong-flavour tooling; an unusable temp file; or a
#      --repo target that is not a repo root (refusing to report a scan that
#      never ran)
#   130 / 143 / 129  interrupted (SIGINT / SIGTERM / SIGHUP) — a cancelled or
#      superseded run, never a verdict
#
# A workflow file that cannot be parsed FAILS the check, naming the file — it is
# never skipped silently, the same fail-closed stance the family's other guards
# take. Parsing is PER FILE, never one batched invocation, because yq aborts on
# the first parse failure and the remaining files would go unscanned.
#
# Bootstrap installs it at scripts/check-no-cluster-deploy.zsh and wires it as
# the `no-cluster-deploy` workflow job. Source template:
# development/skills/bootstrap/templates/common/scripts/check-no-cluster-deploy.zsh
emulate -L zsh
setopt pipe_fail no_unset

usage() {
  print -u2 -- "usage: check-no-cluster-deploy.zsh [--repo <path>]"
  print -u2 -- "  scans <path>/.github/workflows/** for cluster-writing run: steps"
  exit 2
}

REPO="."
while (( $# > 0 )); do
  case "$1" in
    --repo) (( $# >= 2 )) || usage; REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) print -u2 -- "unexpected argument: $1"; usage ;;
  esac
done
[[ -d "$REPO" ]] || { print -u2 -- "not a directory: $REPO"; usage; }

for tool in yq jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    print -r -u2 -- "::error:: '$tool' not found on PATH"
    exit 2
  }
done
# FLAVOUR, not just presence. Debian's and Homebrew's `python-yq` (kislyuk's) is
# also called `yq` and answers `command -v`, but has no `-o=json` — every parse
# probe below would then fail and every workflow would be reported unparseable,
# i.e. exit 1 ("this repo has a problem") for what is actually exit 2 ("this
# runner has a problem"). A required check must not send a consumer hunting a
# YAML error that does not exist.
print -- 'a: 1' | yq -o=json -I=0 '.' >/dev/null 2>&1 || {
  print -u2 -- "::error:: the 'yq' on PATH does not support -o=json — this check needs"
  print -u2 -- "::error:: mikefarah/yq (https://github.com/mikefarah/yq), not python-yq"
  exit 2
}

# ---- the IaC exemption ------------------------------------------------------
# Same `primary:` parse the family's other readers use (detect-stack.sh, the
# maintenance SKILL recipe, review-dispatch.zsh): strip an inline comment and
# trailing whitespace END-ANCHORED FIRST, quotes after. Reversed, a
# CRLF-authored `primary: "kubernetes"` leaves a trailing \r that defeats the
# closing-quote strip and the value reads as `kubernetes"` — here that would
# wrongly FLAG a genuine GitOps repo. The comparison is exact, so a future
# `primary: kubernetes-operator` does not take the exemption on a prefix match.
if [[ -f "$REPO/.maintenance.yml" ]]; then
  recorded_primary="$(sed -n 's/^[[:space:]]*primary:[[:space:]]*//p' "$REPO/.maintenance.yml" 2>/dev/null |
    head -n1 | sed -E -e 's/[[:space:]]*(#.*)?$//' -e 's/^["'"'"']//' -e 's/["'"'"']$//' || true)"
  if [[ "$recorded_primary" == "kubernetes" ]]; then
    print -- "no-cluster-deploy EXEMPT: .maintenance.yml records primary: kubernetes"
    print -- "  an infrastructure repo is the one place a cluster write belongs — not scanned"
    exit 0
  fi
fi

# ---- resolving a command's SUBCOMMAND ---------------------------------------
# The subcommand is resolved POSITIONALLY — the first token that is neither a
# flag nor the VALUE of a flag — never by searching for a known verb.
#
# Searching a vocabulary is the obvious implementation and it is wrong in two
# ways that both fail OPEN, which is the direction that matters for a gate:
#   * a flag VALUE that happens to be a verb wins. `helm -n test upgrade myapp`
#     resolves to `test`, `kubectl -n events apply -f k8s/` to `events`; both
#     are real namespace names, and both deploys walk through.
#   * a wrapper verb wins over the verb it delegates to. `helm secrets upgrade`
#     resolves to `secrets` — and helm-secrets upgrade deploys.
# Positional resolution handles the first directly and the second through the
# PASSTHROUGH list below. It also keeps `helm diff upgrade` (the helm-diff
# plugin, render-only) correctly UNMATCHED, because `diff` is the subcommand
# and is not a pass-through.
#
# Flags taking a SEPARATE value, for the four tools whose subcommand is resolved
# here. The `--flag=value` form needs no entry — it is one token. An unlisted
# value-taking flag costs a false NEGATIVE, so this list is the one place to
# extend when a new global flag appears.
typeset -a VALUE_FLAGS
VALUE_FLAGS=(
  -n --namespace --kubeconfig --context --kube-context --kube-apiserver
  --kube-token --kube-ca-file --kube-as-user --kube-as-group
  --registry-config --repository-cache --repository-config --burst-limit --qps
  -o --output -s --server --token --user --cluster --as --as-group --as-uid
  --request-timeout --cache-dir --tls-server-name --client-certificate
  --client-key --certificate-authority --log-file --chdir --config
  --grpc-web-root-path --auth-token --server-crt --controller-name --profile
  --timeout -v --v --username --password --token-file --client-crt --client-crt-key
)
# Subcommands that DELEGATE to a real verb rather than being one. Only helm has
# these in practice, and only `secrets` is common enough to name; the cost of a
# missing entry is a false negative, the cost of a wrong entry is a false
# positive, so the list stays short and evidence-led.
typeset -a PASSTHROUGH_SUBS
PASSTHROUGH_SUBS=(secrets)
# Wrappers that PRECEDE the real command. `sudo kubectl apply` and
# `xargs kubectl delete` are the command they wrap, so the command position
# walks past them (and past `VAR=value` prefixes, and past flags/numbers that
# belong to the wrapper) to find the real one.
typeset -a CMD_WRAPPERS
CMD_WRAPPERS=(sudo env time nice ionice nohup xargs command timeout stdbuf doas)
# Shell wrappers whose COMMAND IS AN ARGUMENT — `sh -c "kubectl apply -f k8s/"`.
# Their quoted argument is re-scanned as a command in its own right; every other
# quoted argument is inert text (`grep "kubectl apply"` runs grep, not kubectl).
typeset -a SHELL_WRAPPERS
SHELL_WRAPPERS=(sh bash zsh ksh dash)
# Shell KEYWORDS that can stand where a command does. Splitting on `;` puts one
# of these first in every one-line compound statement — `for f in k8s/*.yaml;
# do kubectl apply -f "$f"; done` yields a segment beginning `do`, and a walk
# that gave up on the first unrecognised token dropped the deploy entirely.
# That is one of the commonest ways a deploy step is written, and it failed
# OPEN. `if`/`while`/`until` are here too, so `if kubectl apply …; then` matches.
typeset -a SHELL_KEYWORDS
SHELL_KEYWORDS=(do then else elif if while until case esac fi done '{' '}' '!' '(')
# Wrapper flags that take a SEPARATE value. Without these the walk stops on the
# value and the tool behind it is never seen: `timeout 5m kubectl apply`,
# `sudo -u deployer kubectl apply`, `xargs -I {} kubectl delete`. An unlisted
# flag costs a false NEGATIVE, so this list is the place to extend.
# Keyed BY WRAPPER, not unioned: several of these take a value for one wrapper
# and none for another, and a union skips two tokens where it should skip one —
# swallowing the tool itself. `sudo -E kubectl apply` (preserve the environment,
# the usual way to keep KUBECONFIG across sudo) is the reachable case: `-E`
# takes a value for xargs, none for sudo, so the union skipped `kubectl` and
# read `apply` as the command. Fail-open, the very shape the wrapper walk was
# added to close. An unlisted value-taking flag costs a false NEGATIVE, so this
# is the place to extend.
typeset -A WRAPPER_VALUE_FLAGS_OF
WRAPPER_VALUE_FLAGS_OF=(
  sudo    '-u -g -C -p -r -t -U --user --group --chdir --prompt --close-from'
  doas    '-u -C'
  xargs   '-I -L -n -P -s -E -a -d --replace --max-args --max-procs --delimiter'
  timeout '-s -k --signal --kill-after'
  env     '-u -C -S --unset --chdir --split-string'
  nice    '-n --adjustment'
  ionice  '-c -n -p'
  stdbuf  '-i -o -e'
  time    '-o -f'
  command ''
  nohup   ''
)

_in_list() {
  local needle="$1"; shift
  local x
  for x in "$@"; do
    [[ "$x" == "$needle" ]] && return 0
  done
  return 1
}

# resolve_sub <token>... — sets SUB to the resolved subcommand and SUB_NEXT to
# the NEXT one, both resolved POSITIONALLY: flags are skipped, and so is the
# separate value of a flag known to take one.
#
# SUB_NEXT is resolved the same way rather than being the physically adjacent
# token, because cobra strips global flags while it walks to the subcommand, so
# the two-word verbs are NOT adjacent by syntax: `kubectl rollout -n prod
# restart deployment/api`, `kubectl set --namespace prod image deploy/api …` and
# `argocd app --grpc-web sync myapp` are all valid and all write to a cluster.
# Adjacency-only matching missed every one of them. This cannot widen the match
# set — `kubectl rollout status`, `helm plugin install` and `argocd app diff`
# still resolve to a non-matching second word.
resolve_sub() {
  local -a toks=("$@")
  local tok i=1
  SUB=""
  SUB_NEXT=""
  while (( i <= ${#toks[@]} )); do
    _norm "${toks[i]}"
    tok="$NORM"
    if [[ "$tok" == -* ]]; then
      if _in_list "$tok" "${VALUE_FLAGS[@]}"; then
        (( i += 2 ))   # skip the flag AND its separate value
      else
        (( i += 1 ))
      fi
      continue
    fi
    if _in_list "$tok" "${PASSTHROUGH_SUBS[@]}"; then
      (( i += 1 ))
      continue
    fi
    # An opaque ARGUMENT may expand to a flag, a namespace, or nothing. Stepping
    # over it and reading the next real token as the subcommand is the
    # fail-CLOSED choice: `kubectl ${{ env.ARGS }} apply -f k8s/` — quoted or
    # not — then still resolves `apply`.
    if _is_opaque "$tok"; then
      (( i += 1 ))
      continue
    fi
    # `$tok` is already the normalised spelling, so a quoted literal
    # (`kubectl "apply"`) stores `apply` rather than `__Q1__`
    if [[ -z "$SUB" ]]; then
      SUB="$tok"
      (( i += 1 ))
      continue
    fi
    SUB_NEXT="$tok"
    return 0
  done
  [[ -n "$SUB" ]] && return 0
  return 1
}

# ---- turning a run: body into command segments -------------------------------
#
# THE ORDER HERE IS THE WHOLE DESIGN, and getting it wrong is what made an
# earlier version both fail open and fail closed on ordinary prose.
#
# Segmenting first and stripping prose afterwards means any `;`, `|`, `&`, `)`
# or `$(` INSIDE a comment or an echoed string ends the protection, and the
# prose after it is re-parsed as a live command:
#
#   kubectl get pods   # deploys live in infra; kind create cluster is e2e-only
#     -> the `;` split the comment, ` kind create cluster is e2e-only` became a
#        segment, the JOB was marked ephemeral, and every real deploy in it was
#        silenced. Fail-open, and a self-service annotation in all but name.
#   kubectl get pods   # never (ever) helm upgrade from here
#     -> the `)` split the comment and the gate reported `helm upgrade` from a
#        line that runs nothing. Fail-closed, on a gate with no escape hatch, so
#        the consumer's only remedy is to fork the checker.
#
# So prose is neutralised at LINE level, before anything is split:
#   1. a trailing `# …` comment is removed from the line;
#   2. `$(…)` and `` `…` `` spans are LIFTED OUT as their own segments and
#      replaced by an opaque placeholder — the inner command is still scanned,
#      and the outer command stays contiguous (so a trailing `--dry-run` still
#      belongs to the command it was written on);
#   3. quoted runs are replaced by an opaque placeholder, so a `;` inside a
#      string can never become a separator. The text is kept, and re-scanned
#      only when the command position turns out to be a shell wrapper (`sh -c`).
# Only then is the residue split on `|`, `;`, `&`, `(` and `)`.

# _strip_trailing_comment <line> — drop from the first whitespace-preceded `#`.
# A token merely CONTAINING `#` (`--set tag=v1#2`) is an argument, not a
# comment, so the whitespace is required.
_strip_trailing_comment() {
  local s="$1" out="" c q="" prev=" " i
  # QUOTE-AWARE, and deliberately not simply `${1%%[[:space:]]\#*}`: a `#`
  # inside a string is data, and cutting there deletes the rest of the line —
  # `echo "Deploying build #${N}" && kubectl apply -f k8s/` would lose the
  # deploy entirely (fail-open). The cut must still happen BEFORE segmentation
  # (that is the round-3 rule), so it is made quote-aware rather than moved.
  # An unterminated quote means no cut, which is the fail-closed side.
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"
    if [[ -n "$q" ]]; then
      [[ "$c" == "$q" ]] && q=""
    elif [[ "$c" == '"' || "$c" == "'" ]]; then
      q="$c"
    elif [[ "$c" == "#" && "$prev" == [[:space:]] ]]; then
      break
    fi
    out+="$c"
    prev="$c"
  done
  LINE_OUT="$out"
}

# _lift_expressions <line> — collapse every `${{ … }}` to one opaque token.
#
# This runs FIRST, before spans, quotes and splitting, because a GitHub
# expression is an ARGUMENT, never shell syntax — and the canonical spelling has
# spaces inside the braces, so leaving it alone word-splits it into `${{`,
# `env.NS`, `}}`. That defeated everything downstream on ordinary deploy lines:
#
#   kubectl -n ${{ env.NAMESPACE }} apply -f k8s/
#     -> `-n` is a VALUE_FLAG, so the skip consumed `${{` and landed on
#        `env.NAMESPACE`, which became the subcommand. The apply was never seen.
#   timeout ${{ env.DEPLOY_TIMEOUT }} kubectl apply -f k8s/
#     -> the wrapper walk broke on `${{` and gave up.
#   kubectl -n ${{ a && 'prod' || 'dev' }} apply -f k8s/
#     -> the `&&` inside the expression was read as a shell separator, severing
#        the tool from its verb.
#
# All three failed OPEN, and the verdict flipped on quoting alone (the quoted
# form was already caught, because quotes were lifted). This is NOT the
# shell-variable known gap: the tool and its verb are both written literally on
# the line.
_lift_expressions() {
  local s="$1" pre post
  while [[ "$s" == *'${{'* ]]; do
    pre="${s%%\$\{\{*}"
    post="${s#*\$\{\{}"
    if [[ "$post" == *'}}'* ]]; then
      post="${post#*\}\}}"
    else
      post=""
    fi
    s="${pre}__EXPR__${post}"
  done
  LINE_OUT="$s"
}

# _lift_spans <line> — fills LIFTED with the inner text of every `$(…)` and
# `` `…` `` span and prints the line with each span replaced by a placeholder.
# Non-nested by design: a nested `$( $( ) )` splits at the first `)`, which is a
# stated known gap rather than a silent one.
_lift_spans() {
  local s="$1" pre post inner
  LIFTED=()
  while [[ "$s" == *'$('* ]]; do
    pre="${s%%\$\(*}"
    post="${s#*\$\(}"
    if [[ "$post" == *')'* ]]; then
      inner="${post%%\)*}"
      post="${post#*\)}"
    else
      inner="$post"
      post=""
    fi
    LIFTED+=("$inner")
    s="${pre}__SPAN__${post}"
  done
  while [[ "$s" == *'`'*'`'* ]]; do
    pre="${s%%\`*}"
    post="${s#*\`}"
    inner="${post%%\`*}"
    post="${post#*\`}"
    LIFTED+=("$inner")
    s="${pre}__SPAN__${post}"
  done
  LINE_OUT="$s"
}

# _lift_quotes <line> — fills QUOTED with the contents of each quoted run and
# prints the line with each replaced by `__Q<n>__`. This is what stops a `;`
# inside a string from becoming a separator, while keeping the text available
# for the one case that needs it (`sh -c`).
_lift_quotes() {
  local s="$1" pre post inner q out="" guard=0
  QUOTED=()
  while [[ "$s" == *'"'*'"'* || "$s" == *"'"*"'"* ]]; do
    # whichever quote character comes first
    if [[ "$s" == *'"'* && ( "$s" != *"'"* || ${#s%%\"*} -lt ${#s%%\'*} ) ]]; then
      q='"'
    else
      q="'"
    fi
    pre="${s%%${q}*}"
    post="${s#*${q}}"
    if [[ "$post" != *"${q}"* ]]; then
      # An UNPAIRABLE quote character delimits nothing — an apostrophe in
      # ordinary prose (`echo Can't wait; "kubectl" apply -f k8s/`). Dropping it
      # and continuing is what keeps the OTHER quote kind on the same line
      # liftable: breaking out here left `"kubectl"` with literal quotes, so the
      # tool was unrecognisable and the deploy passed — and left a `;` inside a
      # later string free to become a separator again, resurrecting prose as a
      # command. Bounded by the loop counter below.
      s="${pre}${post}"
      (( guard += 1 ))
      (( guard > 64 )) && break
      continue
    fi
    inner="${post%%${q}*}"
    post="${post#*${q}}"
    QUOTED+=("$inner")
    s="${pre}__Q${#QUOTED}__${post}"
  done
  LINE_OUT="$s"
}

# _tokens_of <segment> — sets TOKS to the segment's tokens, quote characters
# already gone (they were lifted), then truncates at a token that begins with
# `#` (a comment the line-level strip could not see, e.g. one produced by a
# lifted span).
# _unlift <token> — map a `__Q<n>__` placeholder back to the text it replaced,
# so a comparison against a literal spelling still works. Anything else passes
# through unchanged.
_unlift() {
  local t="$1" n iter=0
  # LOOPS, because adjacent quoted runs concatenate into ONE shell word:
  # `kubectl "app""ly" -f k8s/` tokenises as `__Q1____Q2__`, and resolving only
  # the first placeholder yields the mixed spelling `app__Q2__` — which matches
  # no verb, is not opaque, and lets the deploy through. Resolving both yields
  # `apply`, which is what the shell would have run.
  #
  # BOUNDED by the number of lifted runs, so a literal `__Q1__` an author wrote
  # inside a quoted string cannot re-expand or spin.
  while (( iter < ${#QUOTED[@]} )); do
    [[ "$t" == *__Q<->__* ]] || break
    n="${t#*__Q}"
    n="${n%%__*}"
    [[ "$n" == <-> ]] || break
    (( n >= 1 && n <= ${#QUOTED[@]} )) || break
    t="${t%%__Q*}${QUOTED[n]}${t#*__Q${n}__}"
    (( iter += 1 ))
  done
  UNLIFTED="$t"
}

# _is_opaque <token> — true when this token's VALUE cannot be read here.
#
# ONE predicate, three callers. After the lifting passes there are exactly five
# ways a token can be unreadable — `__EXPR__`, `__SPAN__`, a `__Q<n>__` hiding
# either of those, `${VAR}` and bare `$VAR` — and exactly three places that need
# to ask: the subcommand walk, the wrapper walk and the dry-run value test.
# Each used to answer inline with its own list, the three lists drifted, and
# every hole rounds 5 and 6 found was a cell in that 3x5 table: a quoted
# expression passed the subcommand walk, a quoted or substituted wrapper
# argument broke the wrapper walk, and a bare `$VAR` GRANTED the dry-run
# exemption. Filling the table once closes the category by construction — a
# future lifting pass adds its marker here, not in four places.
#
# `_unlift` FIRST is what keeps this tightening rather than widening: a quoted
# LITERAL (`kubectl "apply" -f k8s/`) unlifts to `apply` and is not opaque, so
# it still resolves as the subcommand and still fails the check.
# _norm <token> — THE spelling every predicate at a walk must compare.
#
# Round 6 unified WHICH predicate asks "is this readable?"; it did not unify
# WHICH SPELLING each predicate reads. `_unlift` was applied at two predicates
# and not at their siblings, so a walk tested some conditions against the raw
# `__Q<n>__` placeholder and others against the text behind it. Every hole round
# 7 found is that mixture: `timeout "5m" kubectl apply` broke the wrapper walk
# (the shape test saw a placeholder, the opacity test saw a readable `5m`, so
# neither arm accepted it), `"kubectl" apply` was never recognised as a tool,
# and `kubectl "-n" prod apply` never reached the flag arm. Each unquoted twin
# was caught, so the verdict turned on quoting alone.
#
# So: normalise ONCE per token, then let every predicate at that site read the
# result — `"-n"`, `"kubectl"`, `"5m"` and `"apply"` all compare as their text.
#
# A MULTI-word quoted run (`sh -c "kubectl apply -f k8s/"`) needs no special
# case: it is a command PAYLOAD, and the one path that consumes it — the `sh -c`
# rescan — indexes QUOTED with the RAW `__Q<n>__` token, not with this spelling.
# Everywhere else a multi-word value matches no flag, verb or tool name, exactly
# as the placeholder did. An earlier version carried a single-word guard here;
# the suite proved it inert, and an unexercised branch in a required check is
# worse than no branch at all.
_norm() {
  local t="$1"
  _unlift "$t"
  NORM="$UNLIFTED"
}

_is_opaque() {
  local t="$1"
  _unlift "$t"
  t="$UNLIFTED"
  [[ "$t" == *__EXPR__* || "$t" == *__SPAN__* || "$t" == *'$'* ]]
}

_tokens_of() {
  local seg="$1" t
  TOKS=(${=seg})
  for (( t = 1; t <= ${#TOKS[@]}; t++ )); do
    if [[ "${TOKS[t]}" == \#* ]]; then
      TOKS=("${TOKS[@]:0:$((t - 1))}")
      break
    fi
  done
}

# _resolve_command <token>... — finds the tool in COMMAND POSITION, not
# anywhere in the segment. Sets TOOL and REST; returns 1 when the segment does
# not run one of our tools.
#
# Scanning every token instead is what made `grep -rn "kubectl apply" .github`
# report a deploy (fail-closed on a repo linting for this very rule) and
# `grep -q "kind create cluster" …` grant a job the ephemeral exemption
# (fail-open). A command's identity is its first word, so that is what is read.
_resolve_command() {
  local -a toks=("$@")
  local tok base i=1 saw_dash_c=""
  TOOL=""
  REST=()
  while (( i <= ${#toks[@]} )); do
    _norm "${toks[i]}"
    tok="$NORM"
    # `FOO=bar cmd …` — an assignment prefix, not the command
    if [[ "$tok" == [A-Za-z_]*=* ]]; then
      (( i += 1 )); continue
    fi
    if _in_list "$tok" "${SHELL_KEYWORDS[@]}"; then
      (( i += 1 )); continue
    fi
    base="${tok:t}"   # basename: /usr/local/bin/kubectl is still kubectl
    if _in_list "$base" "${CMD_WRAPPERS[@]}"; then
      (( i += 1 ))
      # a wrapper's own flags, their separate values, and its numeric or
      # duration arguments (`timeout 60 …`, `timeout 5m …`)
      local -a wvf
      wvf=(${=WRAPPER_VALUE_FLAGS_OF[$base]:-})
      local cur
      while (( i <= ${#toks[@]} )); do
        _norm "${toks[i]}"
        cur="$NORM"
        if (( ${#wvf[@]} > 0 )) && _in_list "$cur" "${wvf[@]}"; then
          (( i += 2 )); continue
        fi
        [[ "$cur" == -* || "$cur" == <-> || "$cur" == <->[smhdSMHD] ]] \
          || _is_opaque "$cur" || break
        (( i += 1 ))
      done
      continue
    fi
    if _in_list "$base" "${SHELL_WRAPPERS[@]}"; then
      (( i += 1 ))
      local sflag
      while (( i <= ${#toks[@]} )); do
        # A SINGLE-dash flag cluster ending in `c` is `-c` for every shell in
        # SHELL_WRAPPERS: `-c`, `-ec`, `-lc`, `-euxc`. `--`-forms take no
        # command argument, so they are excluded. Read the NORMALISED spelling,
        # so `sh "-c" "kubectl apply …"` is recognised too.
        _norm "${toks[i]}"
        sflag="$NORM"
        [[ "$sflag" == -* && "$sflag" != --* && "$sflag" == *c ]] && saw_dash_c=1
        [[ "$sflag" == -* ]] || break
        (( i += 1 ))
      done
      # `sh -c __Q1__` — the command lives inside the lifted quoted run
      if [[ -n "$saw_dash_c" && "${toks[i]:-}" == __Q*__ ]]; then
        SHELL_ARG="${toks[i]}"
      fi
      continue
    fi
    case "$base" in
      kubectl|helm|argocd|flux|kind|k3d|minikube|ctlptl)
        TOOL="$base"
        REST=("${toks[@]:$i}")
        return 0 ;;
    esac
    return 1   # some other command entirely — its arguments are not ours
  done
  return 1
}

# scan_body <run-body> <mode> — MODE is `deploy` (the v1 IN set) or `ephemeral`
# (the cluster-creation set). On a match it prints the matched command (e.g.
# `helm upgrade`) on stdout and returns 0; otherwise returns 1.
scan_body() {
  local body="$1" mode="$2"
  local line seg nl t k is_dry src qi dr_flag dr_val
  local -a kept_lines sources

  nl=$'\n'
  # ORDER IS LOAD-BEARING — see the block above, plus:
  #   * strip \r first: a CRLF workflow leaves \r on the last token of every
  #     line, defeating every exact-token comparison (for the ephemeral
  #     spellings that fails OPEN), and it also ends a wrapped line as `\` + \r
  #     + \n, which the fold below would not match;
  #   * drop whole-line comments BEFORE folding: a shell comment ends at the
  #     newline and a trailing `\` does NOT continue it, so folding first would
  #     glue `# see the runbook \` to the command on the next line and skip both.
  body="${body//$'\r'/}"
  kept_lines=()
  while IFS= read -r line; do
    [[ "$line" =~ '^[[:space:]]*#' ]] && continue
    kept_lines+=("$line")
  done <<< "$body"
  body="${(F)kept_lines}"
  body="${body//\\${nl}/ }"

  while IFS= read -r line; do
    _strip_trailing_comment "$line"
    line="$LINE_OUT"
    [[ -z "${line// /}" ]] && continue
    # BEFORE spans and quotes: a `${{ … }}` may contain `$( )`, quotes, `&&`
    # and `||`, none of which are shell syntax inside an expression.
    _lift_expressions "$line"
    line="$LINE_OUT"
    [[ -z "${line// /}" ]] && continue
    # spans first, THEN quotes: a `"$(kubectl apply …)"` is a real command
    # inside a string, and lifting the span first keeps it scannable.
    _lift_spans "$line"
    line="$LINE_OUT"
    sources=("$line" ${LIFTED[@]+"${LIFTED[@]}"})
    for src in "${sources[@]}"; do
      _lift_quotes "$src"
      src="$LINE_OUT"
      # every separator the shell uses to end one command and start another.
      # `(`/`)` included, so `(kubectl apply -f k8s/) || true` is not one opaque
      # token starting `(kubectl`.
      src="${src//|/$nl}"
      src="${src//;/$nl}"
      src="${src//&/$nl}"
      src="${src//\(/$nl}"
      src="${src//\)/$nl}"
      while IFS= read -r seg; do
        [[ -z "${seg// /}" ]] && continue
        SHELL_ARG=""
        _tokens_of "$seg"
        (( ${#TOKS[@]} > 0 )) || continue
        if ! _resolve_command ${TOKS[@]+"${TOKS[@]}"}; then
          # `sh -c "<command>"` — rescan the quoted argument as a command
          if [[ -n "${SHELL_ARG:-}" ]]; then
            qi="${SHELL_ARG#__Q}"
            qi="${qi%__}"
            if [[ "$qi" == <-> ]] && (( qi >= 1 && qi <= ${#QUOTED[@]} )); then
              _tokens_of "${QUOTED[qi]}"
              _resolve_command ${TOKS[@]+"${TOKS[@]}"} || continue
            else
              continue
            fi
          else
            continue
          fi
        fi
        (( ${#REST[@]} > 0 )) || continue

        # COMMAND-scoped dry-run exemption, in BOTH modes.
        #
        # It was deploy-only while the test was step-scoped, so that a
        # `--dry-run` elsewhere in an integration job could not suppress the
        # ephemeral signal. Command scoping removed that concern and left the
        # guard actively harmful: `minikube start --dry-run` is a real,
        # documented flag that VALIDATES configuration and creates no cluster,
        # and `ctlptl apply --dry-run=client` is the same shape — yet each
        # conferred the JOB-WIDE exemption, clearing every real cluster write
        # after it. A creator that creates nothing must not exempt anything, so
        # the test runs here too and that direction now fails CLOSED.
        #
        # A PREFIX test on the flag NAME would be a working escape hatch:
        # `--dry-run=none` is kubectl's documented "do not dry-run" (and its
        # default), and helm's pre-3.13 boolean takes `--dry-run=false` — both
        # really write, and a reviewer reads `--dry-run` and moves on.
        is_dry=""
        for (( k = 1; k <= ${#REST[@]}; k++ )); do
          # UNLIFT first: `--dry-run="client"` reaches here as
          # `--dry-run=__Q1__`, which matches no arm (a false FAILURE on an
          # exempt command), and `--dry-run "none"` as `__Q1__`, which is not
          # `none` and so exempts a real write (a working escape hatch).
          _unlift "${REST[k]}";     dr_flag="$UNLIFTED"
          if (( k < ${#REST[@]} )); then
            _unlift "${REST[k+1]}"; dr_val="$UNLIFTED"
          else
            dr_val=""
          fi
          case "$dr_flag" in
            --dry-run)
              if (( k < ${#REST[@]} )); then
                if _is_opaque "${REST[k+1]}"; then
                  # a value we cannot read may well be `none`/`false`, so it
                  # does NOT grant the exemption — the fail-closed side, and
                  # what stops `--dry-run $DRY_RUN` from silencing the gate
                  # via a job-level `env:` entry
                  :
                else
                  case "$dr_val" in
                    none|false|0) : ;;   # explicitly NOT a dry run
                    *) is_dry=1 ;;       # a real dry-run value
                  esac
                fi
              else
                is_dry=1               # bare trailing flag
              fi
              ;;
            --dry-run=client|--dry-run=server|--dry-run=true) is_dry=1 ;;
          esac
          [[ -n "$is_dry" ]] && break
        done
        [[ -n "$is_dry" ]] && continue

        resolve_sub ${REST[@]+"${REST[@]}"} || continue

        if [[ "$mode" == "deploy" ]]; then
          case "$TOOL" in
            kubectl)
              case "$SUB" in
                apply|create|replace|patch|delete|scale)
                  print -r -- "kubectl $SUB"; return 0 ;;
                rollout)
                  [[ "$SUB_NEXT" == "restart" ]] && { print -r -- "kubectl rollout restart"; return 0; } ;;
                set)
                  [[ "$SUB_NEXT" == "image" ]] && { print -r -- "kubectl set image"; return 0; } ;;
              esac
              ;;
            helm)
              case "$SUB" in
                install|upgrade|rollback)
                  print -r -- "helm $SUB"; return 0 ;;
                # helm 3 documents `delete`, `del` and `un` as aliases of
                # `uninstall`; report the canonical spelling whichever was written.
                uninstall|delete|del|un)
                  print -r -- "helm uninstall"; return 0 ;;
              esac
              ;;
            argocd)
              if [[ "$SUB" == "app" ]]; then
                case "$SUB_NEXT" in
                  sync|create|set) print -r -- "argocd app $SUB_NEXT"; return 0 ;;
                esac
              fi
              ;;
            flux)
              case "$SUB" in
                reconcile|bootstrap) print -r -- "flux $SUB"; return 0 ;;
              esac
              ;;
          esac
        else
          case "$TOOL" in
            kind)
              [[ "$SUB" == "create" && "$SUB_NEXT" == "cluster" ]] \
                && { print -r -- "kind create cluster"; return 0; } ;;
            k3d)
              [[ "$SUB" == "cluster" && "$SUB_NEXT" == "create" ]] \
                && { print -r -- "k3d cluster create"; return 0; } ;;
            minikube)
              [[ "$SUB" == "start" ]] && { print -r -- "minikube start"; return 0; } ;;
            ctlptl)
              [[ "$SUB" == "apply" ]] && { print -r -- "ctlptl apply"; return 0; } ;;
          esac
        fi
      done <<< "$src"
    done
  done <<< "$body"
  return 1
}

# ---- scan --------------------------------------------------------------------
typeset -a failures
fail() { failures+=("$1"); print -r -u2 -- "::error:: $1"; }

# GitHub reads workflows from .github/workflows; the sweep is recursive so a
# workflow parked in a subdirectory is still read (and still fails closed if it
# cannot be parsed). `(N)` is zsh nullglob for this glob only — an absent
# directory is a repo with no workflows, which is a clean scan, not an error.
typeset -a workflow_files
workflow_files=("$REPO"/.github/workflows/**/*.(yml|yaml)(N.))

if (( ${#workflow_files[@]} == 0 )); then
  # Any repo that RUNS this gate necessarily contains no-cluster-deploy.yml, so
  # zero files almost always means the target is wrong — a `working-directory:`
  # that moved the cwd, or a `--repo` pointing into a subtree. Reporting PASSED
  # there is a green required check that scanned nothing, so demand evidence the
  # target is a repo root before calling it clean.
  if [[ ! -e "$REPO/.git" && ! -d "$REPO/.github" ]]; then
    print -r -u2 -- "::error:: '$REPO' has neither .git nor .github — this is not a repo root."
    print -u2 -- "::error:: Refusing to report a clean scan for a target that was never scanned."
    exit 2
  fi
  print -- "no-cluster-deploy PASSED: no workflow files under .github/workflows"
  exit 0
fi

STEPS_JSON="$(mktemp)" || {
  print -u2 -- "::error:: could not create a temp file — refusing to report a scan that cannot run"
  exit 2
}
# INT/TERM/HUP as well as EXIT: the workflow sets `cancel-in-progress: true`, so
# a superseded run is killed rather than exiting normally. The signal handlers
# EXIT explicitly — a zsh signal trap resumes at the interruption point when it
# returns, so a cleanup-only handler would delete the temp file and then carry
# on scanning until the runner escalated to SIGKILL.
trap 'rm -f "$STEPS_JSON"' EXIT
trap 'rm -f "$STEPS_JSON"; exit 130' INT
trap 'rm -f "$STEPS_JSON"; exit 143' TERM
trap 'rm -f "$STEPS_JSON"; exit 129' HUP

# job id -> the EARLIEST step index in that job that stands up a cluster.
typeset -A ephemeral_at
# job id -> the `if:` guard of that earliest creating step ("" when unguarded)
typeset -A ephemeral_cond
scanned=0

for wf in "${workflow_files[@]}"; do
  rel="${wf#"$REPO"/}"
  rel="${rel#./}"
  # PER-FILE parse. yq aborts on the first parse failure, so one batched call
  # over every workflow would leave the rest of the repo unscanned after a
  # single malformed file — the exact "silently skipped" outcome the fail-closed
  # rule forbids.
  if ! yq -o=json -I=0 '.' "$wf" >/dev/null 2>&1; then
    fail "$rel: cannot be parsed as YAML — a workflow this check cannot read is a workflow it cannot clear"
    continue
  fi
  # `.jobs` may legitimately be absent (a workflow of `on:` and nothing else is
  # invalid to GitHub but parseable here) and a job may be a reusable-workflow
  # call with no `steps`. Both reduce to zero step records, never to an error.
  # A `jobs:` that is a SCALAR parses as YAML but cannot be walked — that is a
  # second fail-closed arm, not a silent skip.
  if ! yq -o=json -I=0 '.' "$wf" 2>/dev/null | jq -c '
        (.jobs // {}) | to_entries[]
        | select((.value | type) == "object")
        | .key as $job
        | ((.value.steps // []) | to_entries[])
        | select((.value | type) == "object")
        | {job: $job, index: .key,
           name: (if (.value.name | type) == "string" then .value.name else null end),
           cond: (if (.value."if" | type) == "string" then .value."if" else null end),
           run:  (if (.value.run  | type) == "string" then .value.run  else null end)}
      ' > "$STEPS_JSON" 2>/dev/null; then
    fail "$rel: parsed as YAML but its jobs/steps could not be read"
    continue
  fi
  scanned=$(( scanned + 1 ))

  # PASS 1 — which jobs of THIS file stand up their own cluster, and at which
  # step. Job-scoped, so the map is rebuilt per file: two files may each have a
  # job called `deploy`, and one file's kind cluster must never exempt the
  # other's.
  ephemeral_at=()
  ephemeral_cond=()
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    run_body="$(jq -r 'if .run == null then "" else .run end' <<< "$rec")"
    [[ -z "$run_body" ]] && continue
    job="$(jq -r '.job' <<< "$rec")"
    idx="$(jq -r '.index' <<< "$rec")"
    # A step guarded by `if:` may not run at all, and the branch-per-environment
    # shape is exactly what this gate exists to catch:
    #   - if: github.event_name == 'pull_request'   -> kind create cluster
    #   - if: github.ref == 'refs/heads/main'       -> helm upgrade --install
    # The two are mutually exclusive, so the deploy hits the REAL cluster
    # whenever kind was not created. Refusing the exemption here fails CLOSED —
    # a false alarm a human reads — which is the direction this file already
    # chose for a cluster stood up by `helm/kind-action`.
    cond="$(jq -r 'if .cond == null then "" else .cond end' <<< "$rec")"
    if scan_body "$run_body" ephemeral >/dev/null; then
      if [[ -z "${ephemeral_at[$job]:-}" ]] || (( idx < ${ephemeral_at[$job]} )); then
        ephemeral_at[$job]="$idx"
        ephemeral_cond[$job]="$cond"
      fi
    fi
  done < "$STEPS_JSON"

  # PASS 2 — the deploy scan, skipping the steps pass 1 exempted. The exemption
  # runs FORWARD from the creating step (`>=`, not "any step of the job"): a job
  # that deploys and only afterwards stands up a kind cluster has not tested
  # against its own cluster, it has deployed to someone else's. `>=` rather than
  # `>` so a single step that creates the cluster and then writes to it — the
  # creation is earlier in that step's own body — is exempt too.
  while IFS= read -r rec; do
    [[ -z "$rec" ]] && continue
    run_body="$(jq -r 'if .run == null then "" else .run end' <<< "$rec")"
    [[ -z "$run_body" ]] && continue
    job="$(jq -r '.job' <<< "$rec")"
    idx="$(jq -r '.index' <<< "$rec")"
    if [[ -n "${ephemeral_at[$job]:-}" ]] && (( idx >= ${ephemeral_at[$job]} )); then
      # An UNCONDITIONAL creator exempts unconditionally. A CONDITIONAL one
      # exempts only a step guarded by the byte-identical condition, because
      # the branch-per-environment shape is what this gate exists to catch:
      #   - if: github.event_name == 'pull_request'  -> kind create cluster
      #   - if: github.ref == 'refs/heads/main'      -> helm upgrade --install
      # There the two are mutually exclusive and the deploy reaches the REAL
      # cluster. The identical-condition pair — the commonest real shape, both
      # steps guarded by `if: github.event_name == 'pull_request'` — runs
      # together or not at all, so it keeps the exemption. Differing (or
      # absent-against-conditional) conditions fail CLOSED.
      cond="$(jq -r 'if .cond == null then "" else .cond end' <<< "$rec")"
      [[ "${ephemeral_cond[$job]:-}" == "$cond" ]] && continue
      [[ -z "${ephemeral_cond[$job]:-}" ]] && continue
    fi
    name="$(jq -r 'if .name == null then "" else .name end' <<< "$rec")"
    # The step NAME when it has one, its INDEX otherwise — a 0-based index into
    # that job's `steps:` array, which is how you find an unnamed step.
    if [[ -n "$name" ]]; then
      where="step '$name'"
    else
      where="step #$idx (unnamed; 0-based index into the job's steps)"
    fi
    if cmd="$(scan_body "$run_body" deploy)"; then
      fail "$rel: job '$job', $where runs \`$cmd\` — an application repo never deploys straight to a cluster"
    fi
  done < "$STEPS_JSON"
done

if (( ${#failures} > 0 )); then
  print -u2 -- "no-cluster-deploy FAILED: ${#failures} problem(s)"
  print -u2 -- "  The infrastructure repo is the only path to a cluster: publish a versioned,"
  print -u2 -- "  immutable image here, and promote it with a pull request against the"
  print -u2 -- "  infrastructure repo. There is deliberately no escape-hatch annotation — a"
  print -u2 -- "  genuine exception changes this check in a reviewed PR."
  exit 1
fi

print -- "no-cluster-deploy PASSED: ${scanned} workflow file(s) scanned, no cluster-writing step"
exit 0
