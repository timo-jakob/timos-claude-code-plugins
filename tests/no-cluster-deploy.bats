#!/usr/bin/env bats
#
# The direct-to-cluster gate (#1206, epic #1058) — the application-repo half of
# the promotion contract #1189 states. Three artifacts under test:
#
#   * templates/common/scripts/check-no-cluster-deploy.zsh — the checker;
#   * templates/common/.github/workflows/no-cluster-deploy.yml.tmpl — the job
#     that runs it, which becomes a REQUIRED status context;
#   * branch-protection.sh — which requires that context on the language-app
#     path and must never require it on the IaC path.
#
# The checker's BEHAVIOUR is executed against real fixture repos, never grepped
# out of its source. A grep cannot tell an arm that fires from one that is
# unreachable, and the failure mode that matters for a required check is not a
# crash but a VACUOUS PASS — exit 0 having scanned nothing. So every pass-path
# case is paired with a positive control: the same fixture plus one known-bad
# step must go red, which proves the 0 was a decision rather than an empty scan.
#
# The WORKFLOW is read structurally with `yq`, not grepped: a substring sweep
# cannot tell a `paths:` key from the word `paths` inside a comment, and the
# no-path-filter rule is the one property that keeps this required check from
# wedging every PR at `expected`.
#
# `yq` is called unguarded (the tests/bootstrap-iac-pipeline.bats precedent) and
# is a declared dependency in .github/workflows/script-tests.yml and
# tests/Dockerfile: an absent one should red these rather than silently skip the
# only coverage the template has.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO_ROOT/development/skills/bootstrap/templates/common/scripts/check-no-cluster-deploy.zsh"
  TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/.github/workflows/no-cluster-deploy.yml.tmpl"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  SETUP_TMPL="$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl"
  # the six IaC contexts, which the --iac-only set must stay exactly equal to
  IAC_JOBS="render schema lint policy config-scan argocd"
  W="$BATS_TEST_TMPDIR/repo"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$W/.github/workflows" "$STUB_BIN"
  # An application repo by default: the IaC exemption keys on this file, so
  # every fixture that expects to be SCANNED must record a language primary.
  printf 'primary: go\n' > "$W/.maintenance.yml"
}

# wf <name> <yaml> — write a workflow file into the fixture repo.
wf() {
  printf '%s\n' "$2" > "$W/.github/workflows/$1"
}

# one_step <run-body> — a fixture whose single job holds one named step.
# Written through printf rather than a heredoc so a caller can pass a body
# containing whatever quoting it likes.
one_step() {
  printf 'name: w\non:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - name: The step\n        run: %s\n' \
    "$1" > "$W/.github/workflows/w.yml"
  # ROUND-TRIP GUARD. A plain YAML scalar silently drops a ` #` comment and
  # normalises CR, so a fixture can assert far less than it appears to — the
  # defect the round-2 mutation sweep caught in the trailing-comment case and
  # round 3 found again in the CRLF case. Every plain-scalar fixture written
  # through this helper now proves the parser hands the checker the body we
  # wrote. A caller passing a BLOCK scalar (`|` + indented lines) is exempt:
  # its literal argument is the YAML source, not the value, so there is nothing
  # to compare — those fixtures use `wf` and assert their own shape.
  case "$1" in
    '|'*) : ;;
    *) [ "$(yq -r '.jobs.build.steps[0].run' "$W/.github/workflows/w.yml")" = "$1" ] ;;
  esac
}

check() {
  run zsh "$CHECK" --repo "$W"
}

# ---------------------------------------------------------------------------
# Fail path — one case per IN command family (decision 5)
# ---------------------------------------------------------------------------

@test "a kubectl apply step fails, naming file, job, step and command (#1206)" {
  # the whole contract of the failure output in one case: a bare "it exited 1"
  # tells a consumer nothing about WHERE, and this check runs over repos whose
  # authors have never read its source.
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" '.github/workflows/w.yml'
  contains "$output" "job 'build'"
  contains "$output" "step 'The step'"
  contains "$output" 'kubectl apply'
}

@test "kubectl create fails (#1206)" {
  one_step 'kubectl create -f k8s/deploy.yaml'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl create'
}

@test "kubectl replace fails (#1206)" {
  one_step 'kubectl replace -f k8s/deploy.yaml'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl replace'
}

@test "kubectl patch fails (#1206)" {
  one_step 'kubectl patch deployment api -p not-json-here'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl patch'
}

@test "kubectl delete fails (#1206)" {
  one_step 'kubectl delete -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl delete'
}

@test "kubectl rollout restart fails (#1206)" {
  one_step 'kubectl rollout restart deployment/api'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl rollout restart'
}

@test "kubectl set image fails (#1206)" {
  one_step 'kubectl set image deployment/api api=ghcr.io/acme/api:1.2.3'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl set image'
}

@test "kubectl scale fails (#1206)" {
  one_step 'kubectl scale deployment/api --replicas=3'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl scale'
}

@test "helm install fails (#1206)" {
  one_step 'helm install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm install'
}

@test "helm rollback fails (#1206)" {
  one_step 'helm rollback myapp 3'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm rollback'
}

@test "helm uninstall fails (#1206)" {
  one_step 'helm uninstall myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm uninstall'
}

@test "argocd app sync fails (#1206)" {
  one_step 'argocd app sync myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'argocd app sync'
}

@test "argocd app create fails (#1206)" {
  one_step 'argocd app create myapp --repo https://example.invalid/r.git'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'argocd app create'
}

@test "argocd app set fails (#1206)" {
  one_step 'argocd app set myapp --helm-set image.tag=1.2.3'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'argocd app set'
}

@test "flux reconcile fails (#1206)" {
  one_step 'flux reconcile kustomization apps --with-source'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'flux reconcile'
}

@test "flux bootstrap fails (#1206)" {
  one_step 'flux bootstrap github --owner=acme --repository=infra'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'flux bootstrap'
}

@test "an UNNAMED step is reported by its 0-based index (#1206)" {
  # the half of the output contract a named-step fixture can never exercise —
  # and the only way a reader finds the offending step in a `steps:` list
  printf 'name: w\non:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n      - run: kubectl apply -f k8s/\n' \
    > "$W/.github/workflows/w.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'step #1'
  contains "$output" 'unnamed'
}

# --- subcommand resolution: the arms that fail OPEN when it is done by
# --- vocabulary search rather than positionally (round-1 CRITICAL)

@test "helm secrets upgrade fails — a wrapper verb does not shield the deploy (#1206)" {
  # helm-secrets is a mainstream way to keep values encrypted, and `helm secrets
  # upgrade` deploys. Resolving the subcommand by searching a verb vocabulary
  # stops at `secrets` and clears it.
  one_step 'helm secrets upgrade myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a flag VALUE that is itself a verb does not become the subcommand — helm (#1206)" {
  # `-n test`: `test` is a helm subcommand AND a plausible namespace. A
  # vocabulary search resolves `test` and the deploy walks through.
  one_step 'helm -n test upgrade myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a flag VALUE that is itself a verb does not become the subcommand — kubectl (#1206)" {
  # `-n events`: `events` is a kubectl subcommand AND a plausible namespace.
  one_step 'kubectl -n events apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a global flag before the verb still resolves the verb (#1206)" {
  one_step 'kubectl -n prod apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "the --flag=value form resolves the verb too (#1206)" {
  one_step 'kubectl --kubeconfig=/tmp/kc apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "helm delete is matched as the uninstall alias it is (#1206)" {
  # helm 3 documents delete/del/un as aliases of uninstall, which IS in the v1
  # IN set — matching them implements the listed verb rather than widening it.
  one_step 'helm delete myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm uninstall'
}

@test "helm un is matched as the uninstall alias it is (#1206)" {
  one_step 'helm un myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm uninstall'
}

@test "helm del is matched as the uninstall alias it is (#1206)" {
  one_step 'helm del myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm uninstall'
}

@test "an absolute tool path still resolves the tool (#1206)" {
  # self-hosted runners routinely invoke absolute paths; the basename arm is
  # what keeps them scanned
  one_step '/usr/local/bin/kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a relative tool path still resolves the tool (#1206)" {
  one_step './bin/helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "sudo before the tool does not hide it (#1206)" {
  one_step 'sudo kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a KUBECONFIG= assignment prefix does not hide the command (#1206)" {
  # the single most idiomatic spelling of a real deploy step
  one_step 'KUBECONFIG=/tmp/kc kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "timeout with its numeric argument does not hide the command (#1206)" {
  one_step 'timeout 60 kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "xargs does not hide the command (#1206)" {
  one_step 'xargs kubectl delete -f -'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl delete'
}

@test "env with an assignment does not hide the command (#1206)" {
  # the wrapper -> assignment-prefix handoff in one fixture
  one_step 'env KUBECONFIG=/tmp/kc kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "sh -ec is scanned like sh -c (#1206)" {
  # `-ec` is the ordinary way to get errexit into a one-liner; an exact `-c`
  # test let it walk past unscanned
  one_step 'sh -ec "kubectl apply -f k8s/"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "bash -lc is scanned like sh -c (#1206)" {
  one_step 'bash -lc "helm upgrade --install myapp ./chart"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a quoted sh -c invocation is still scanned (#1206)" {
  one_step 'sh -c "kubectl apply -f k8s/"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a backslash-continued invocation is still scanned (#1206)" {
  # the tool on one physical line and the verb on the next is the commonest
  # long-invocation spelling, and a trivially discoverable way to reformat past
  # a line-oriented scan
  printf 'name: w\non:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - name: The step\n        run: |\n          kubectl \\\n            --kubeconfig /tmp/kc \\\n            apply -f manifests/\n' \
    > "$W/.github/workflows/w.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a CRLF-authored workflow body is still scanned (#1206)" {
  # a trailing \r on the last token of each line defeats exact-token matching
  printf 'name: w\r\non:\r\n  pull_request:\r\njobs:\r\n  build:\r\n    runs-on: ubuntu-latest\r\n    steps:\r\n      - name: The step\r\n        run: kubectl apply -f k8s/\r\n' \
    > "$W/.github/workflows/w.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

# --- segment splitting: every separator, not just the pipe

@test "a && chain fails on its second command (#1206)" {
  one_step 'cd deploy && kubectl apply -f .'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a && chain whose FIRST command is a read-only helm verb still fails (#1206)" {
  # `helm repo add … && helm upgrade …`: if the two were one segment, the
  # subcommand would resolve to `repo` and the deploy would be cleared
  one_step 'helm repo add acme https://acme.invalid && helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a semicolon chain fails on its second command (#1206)" {
  one_step 'kubectl get pods; kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a command substitution is scanned as its own segment (#1206)" {
  one_step 'OUT=$(kubectl apply -f k8s/)'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "kubectl get piped into grep apply does NOT match (#1206)" {
  # the documented negative of segment splitting: a regression to substring
  # matching across a pipeline would red here
  passes_and_control 'kubectl get pods | grep apply'
}

@test "an echo that MENTIONS a banned command does not fail (#1206)" {
  passes_and_control 'echo "never run helm upgrade here"'
}

@test "a printf that MENTIONS a banned command does not fail (#1206)" {
  passes_and_control 'printf "never run kubectl apply here\n"'
}

@test "NEGATIVE CONTROL: the prose skip is FIRST-TOKEN only, across lines (#1206)" {
  # loosening it to "the segment mentions a message builtin" would clear a real
  # deploy that merely announces itself — a one-line escape hatch
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          echo "deploying to prod"
          kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: the prose skip is FIRST-TOKEN only, same line (#1206)" {
  one_step 'echo "deploying to prod"; kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: a deploy inside a command substitution in an echo still fails (#1206)" {
  # `$(` must be a SEPARATOR, not a space: as one segment the leading `echo`
  # would swallow the inner cluster write
  one_step 'echo "applied $(kubectl apply -f k8s/ -o name)"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a backtick command substitution is scanned as its own segment (#1206)" {
  one_step 'OUT=`kubectl apply -f k8s/`'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a single-quoted sh -c invocation is still scanned (#1206)" {
  one_step "sh -c 'kubectl apply -f k8s/'"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "kubectl rollout status passes — only 'restart' writes (#1206)" {
  # the commonest post-deploy wait in CI; dropping the SUB_NEXT guard would red
  # every consumer repo that runs it
  passes_and_control 'kubectl rollout status deployment/api --timeout=60s'
}

@test "helm plugin install passes — 'plugin' is the subcommand, not 'install' (#1206)" {
  passes_and_control 'helm plugin install https://github.com/databus23/helm-diff'
}

@test "flux get on a resource NAMED bootstrap does not fail (#1206)" {
  # `bootstrap` is a conventional Flux Kustomization name; matching any token
  # after `flux` turns an ordinary read into a red required check
  passes_and_control 'flux get kustomization bootstrap'
}

# --- workflow discovery: extension and recursion

@test "a .yaml workflow is discovered and scanned (#1206)" {
  printf 'name: w\non:\n  pull_request:\njobs:\n  ship:\n    runs-on: ubuntu-latest\n    steps:\n      - name: s\n        run: kubectl apply -f k8s/\n' \
    > "$W/.github/workflows/ship.yaml"
  check
  [ "$status" -eq 1 ]
  contains "$output" '.github/workflows/ship.yaml'
}

@test "a workflow in a SUBDIRECTORY is discovered and scanned (#1206)" {
  mkdir -p "$W/.github/workflows/sub"
  printf 'name: w\non:\n  pull_request:\njobs:\n  ship:\n    runs-on: ubuntu-latest\n    steps:\n      - name: s\n        run: kubectl apply -f k8s/\n' \
    > "$W/.github/workflows/sub/ship.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" '.github/workflows/sub/ship.yml'
}

@test "helm upgrade fails WITHOUT --install (#1206)" {
  # the arm most likely to be written as `helm upgrade --install`, so a
  # regression narrowing the match to that spelling would look correct
  one_step 'helm upgrade myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "helm upgrade fails WITH --install too (#1206)" {
  one_step 'helm upgrade --install myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "kustomize build piped into kubectl apply fails on the apply half (#1206)" {
  # decision 5 gives the pipeline no arm of its own — the `kubectl apply` arm is
  # supposed to already match it. If segment splitting regressed, `kustomize
  # build` alone would be the only command seen and this would pass vacuously.
  one_step 'kustomize build overlays/prod | kubectl apply -f -'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

# ---------------------------------------------------------------------------
# Pass path — one case per OUT command (decision 5), each with a control
# ---------------------------------------------------------------------------
#
# `passes_and_control` runs the OUT command and requires exit 0, then appends a
# second workflow holding a known-bad step and requires exit 1. Without the
# second half every one of these would still pass if the scan stopped finding
# anything at all.
passes_and_control() {
  one_step "$1"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
  wf control.yml 'name: c
on:
  pull_request:
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - name: bad
        run: kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
}

@test "kubectl get passes (#1206)" { passes_and_control 'kubectl get pods -n prod'; }
@test "kubectl describe passes (#1206)" { passes_and_control 'kubectl describe deployment/api'; }
@test "kubectl diff passes (#1206)" { passes_and_control 'kubectl diff -f k8s/'; }
@test "kubectl logs passes (#1206)" { passes_and_control 'kubectl logs deployment/api'; }
@test "kubectl wait passes (#1206)" { passes_and_control 'kubectl wait --for=condition=Ready pod/api'; }
@test "helm template passes (#1206)" { passes_and_control 'helm template ./chart'; }
@test "helm lint passes (#1206)" { passes_and_control 'helm lint ./chart'; }
@test "helm diff passes (#1206)" { passes_and_control 'helm diff upgrade myapp ./chart'; }
@test "kustomize build alone passes (#1206)" { passes_and_control 'kustomize build overlays/prod'; }
@test "argocd app diff passes (#1206)" { passes_and_control 'argocd app diff myapp'; }
@test "kubeconform passes (#1206)" { passes_and_control 'kubeconform -strict rendered/'; }
@test "conftest passes (#1206)" { passes_and_control 'conftest test rendered/'; }

@test "a full-line shell COMMENT naming a banned command does not fail (#1206)" {
  # a repo documenting the rule in its own workflow must not be failed by it —
  # and `helm diff upgrade` above shows why the match cannot simply be a
  # substring sweep either
  passes_and_control '|
          # never: kubectl apply -f k8s/
          echo building'
}

# ---------------------------------------------------------------------------
# Ephemeral exemption — job-scoped, with the sibling-job negative control
# ---------------------------------------------------------------------------

ephemeral_job() {
  printf 'name: it\non:\n  pull_request:\njobs:\n  integration:\n    runs-on: ubuntu-latest\n    steps:\n      - name: cluster\n        run: %s\n      - name: apply\n        run: helm upgrade --install myapp ./chart\n' \
    "$1" > "$W/.github/workflows/it.yml"
}

@test "kind create cluster exempts a later helm upgrade in the SAME job (#1206)" {
  ephemeral_job 'kind create cluster --name it'
  check
  [ "$status" -eq 0 ]
  # non-vacuity: the file WAS scanned, so the 0 is a decision rather than a
  # broken glob or an early exit that found nothing
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "k3d cluster create exempts a later cluster write in the same job (#1206)" {
  ephemeral_job 'k3d cluster create it'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "minikube start exempts a later cluster write in the same job (#1206)" {
  ephemeral_job 'minikube start'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "ctlptl apply exempts a later cluster write in the same job (#1206)" {
  ephemeral_job 'ctlptl apply -f cluster.yaml'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

# The four cases above only ever prove a CORRECT creation spelling confers the
# exemption. These prove a READ-ONLY invocation of the same tool does not —
# the exemption's largest fail-open surface: loosen any matcher to a tool-only
# or single-token test and a job that merely runs `kind get clusters` before a
# real deploy is silently cleared, with every positive test still green.
not_ephemeral() {
  printf 'name: it\non:\n  pull_request:\njobs:\n  integration:\n    runs-on: ubuntu-latest\n    steps:\n      - name: probe\n        run: %s\n      - name: apply\n        run: helm upgrade --install myapp ./chart\n' \
    "$1" > "$W/.github/workflows/it.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'apply'"
}

@test "NEGATIVE CONTROL: kind get clusters does not confer the exemption (#1206)" {
  not_ephemeral 'kind get clusters'
}

@test "NEGATIVE CONTROL: k3d cluster list does not confer the exemption (#1206)" {
  not_ephemeral 'k3d cluster list'
}

@test "NEGATIVE CONTROL: minikube status does not confer the exemption (#1206)" {
  not_ephemeral 'minikube status'
}

@test "NEGATIVE CONTROL: ctlptl get does not confer the exemption (#1206)" {
  not_ephemeral 'ctlptl get cluster'
}

@test "the ephemeral map is rebuilt PER FILE (#1206)" {
  # two files with an identically-named job: a.yml's kind cluster must not
  # exempt b.yml's real deploy. Deleting the per-file reset keeps every other
  # ephemeral test green while silently clearing a production deploy.
  wf a.yml 'name: a
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: kind create cluster --name it
      - name: apply
        run: kubectl apply -f k8s/'
  wf b.yml 'name: b
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: helm upgrade --install myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'b.yml'
  lacks "$output" 'a.yml'
}

@test "a SINGLE step that creates the cluster then writes to it is exempt (#1206)" {
  # the `>=` half of the index rule: the creation is earlier in that step's own
  # body. A `>` would red this legitimate shape.
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster and apply
        run: |
          kind create cluster --name it
          helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "the EARLIEST cluster-creating step is the one that governs (#1206)" {
  # creation at index 0 and again at index 2, with the write at index 1: only
  # earliest-index tracking exempts the write
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: kind create cluster --name a
      - name: apply
        run: kubectl apply -f k8s/
      - name: second cluster
        run: kind create cluster --name b'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "NEGATIVE CONTROL: the same step in a SIBLING job still fails (#1206)" {
  # the exemption's whole boundary. A file-scoped implementation passes every
  # test above AND this fixture's first job — and silently exempts a real deploy
  # that happens to share a workflow file with an integration test.
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: kind create cluster --name it
      - name: apply
        run: helm upgrade --install myapp ./chart
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: helm upgrade --install myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" "job 'deploy'"
  # …and the exempted job is NOT reported, or the exemption did nothing
  lacks "$output" "job 'integration'"
}

@test "NEGATIVE CONTROL: a cluster created AFTER the write does not exempt it (#1206)" {
  # a job that deploys and only afterwards stands up a kind cluster deployed to
  # someone else's cluster. An order-blind implementation passes this silently.
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: helm upgrade --install myapp ./chart --namespace prod
      - name: cluster
        run: kind create cluster --name it'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'ship'"
}

# ---------------------------------------------------------------------------
# Dry-run exemption
# ---------------------------------------------------------------------------

@test "a --dry-run=server step passes (#1206)" { passes_and_control 'kubectl apply --dry-run=server -f k8s/'; }
@test "a --dry-run=client step passes (#1206)" { passes_and_control 'kubectl apply --dry-run=client -f k8s/'; }
@test "a bare --dry-run step passes (#1206)" { passes_and_control 'helm upgrade --install myapp ./chart --dry-run'; }

@test "NEGATIVE CONTROL: --dry-run exempts only its OWN command (#1206)" {
  # the validate-then-apply shape. A step-scoped (or job-scoped) test would
  # clear the real second command — a one-line self-service annotation, which is
  # exactly the standing escape hatch the check says it does not have.
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          kubectl apply --dry-run=client -f k8s/
          kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'ship'"
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: --dry-run=none really writes, so it does NOT exempt (#1206)" {
  # `none` is kubectl's DEFAULT and the documented spelling of "do not dry-run".
  # A prefix test on the flag name reads it as an exemption — an escape hatch a
  # human reviewer skims straight past.
  one_step 'kubectl apply --dry-run=none -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: --dry-run=false really writes, so it does NOT exempt (#1206)" {
  one_step 'helm upgrade --install myapp ./chart --dry-run=false'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "NEGATIVE CONTROL: a separate-argument --dry-run none does NOT exempt (#1206)" {
  one_step 'kubectl apply --dry-run none -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a separate-argument --dry-run server DOES exempt (#1206)" {
  passes_and_control 'kubectl apply --dry-run server -f k8s/'
}

@test "NEGATIVE CONTROL: --dry-run in a TRAILING COMMENT does not exempt (#1206)" {
  # the command-scoped narrowing alone did not close this: the comment's tokens
  # were still scanned for the exemption, so a real deploy could annotate itself
  # clean.
  #
  # A BLOCK SCALAR is load-bearing here. In a plain YAML scalar ` #` starts a
  # YAML comment, so `run: kubectl apply -f k8s/  # … --dry-run …` reaches the
  # checker as `kubectl apply -f k8s/` — the fixture would pass without ever
  # exercising the guard, which is what the mutation sweep caught.
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          kubectl apply -f k8s/  # prod deploy, no --dry-run here'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a trailing comment cannot CREATE a match either (#1206)" {
  # the other direction of the same truncation: prose after a read-only command
  # must not red the build
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: probe
        run: |
          kubectl get pods  # never kubectl apply here'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "NEGATIVE CONTROL: a comment ending in a backslash does not hide the next command (#1206)" {
  # a shell comment ends at the newline — a trailing `\` does not continue it.
  # Folding continuations BEFORE dropping comments glues the two together and
  # skips both.
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          # see the runbook \
          kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: --dry-run in a COMMENT does not silence the step (#1206)" {
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          # we should really use --dry-run here
          kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a dry-run command beside a real creator does not cost the job its exemption (#1206)" {
  # per-COMMAND scoping inside a mixed step: the dry-run `continue` skips only
  # that segment, so the `kind create cluster` on the next line is still seen.
  # (This does NOT pin the mode guard — the two commands are on separate lines,
  # so it reads the same with or without it. The cases below are the ones that
  # reach it.)
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: |
          kubectl apply --dry-run=client -f k8s/
          kind create cluster --name it
      - name: apply
        run: helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

# ---------------------------------------------------------------------------
# The IaC exemption, and #1193's mixed repo
# ---------------------------------------------------------------------------

@test "primary: kubernetes exempts the repo and SAYS it exempted it (#1206)" {
  # "reports that it exempted the repo rather than reporting a clean scan" —
  # a bare exit 0 is indistinguishable from having found nothing, which is the
  # one thing an operator must be able to tell apart here
  printf 'primary: kubernetes\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'EXEMPT'
  contains "$output" 'primary: kubernetes'
  lacks "$output" 'PASSED'
}

@test "a quoted primary: \"kubernetes\" is exempt too (#1206)" {
  printf 'primary: "kubernetes"\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'EXEMPT'
}

@test "a quoted, CRLF-authored primary: \"kubernetes\" still reaches its arm (#1206)" {
  # this is a SECOND copy of the family's `primary:` parse (detect-stack.sh has
  # the other, pinned by tests/detect-stack.bats). Reversing the strip order
  # here leaves the value as `kubernetes"`, which FLAGS every GitOps repo whose
  # .maintenance.yml was authored on Windows — and nothing else would red.
  printf 'primary: "kubernetes"\r\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'EXEMPT'
}

@test "an inline comment after primary: kubernetes does not defeat the exemption (#1206)" {
  printf 'primary: kubernetes  # recorded at bootstrap\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'EXEMPT'
}

@test "a .maintenance.yml recording only topics is SCANNED, not exempt (#1206)" {
  printf 'topics:\n  - kubernetes\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  lacks "$output" 'EXEMPT'
}

@test "primary: kubernetes-operator is NOT exempt — the match is exact (#1206)" {
  # a prefix match would hand every future `kubernetes-*` primary a free pass
  printf 'primary: kubernetes-operator\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
  lacks "$output" 'EXEMPT'
}

@test "MIXED REPO (#1193): a Chart.yaml plus a LANGUAGE primary is flagged (#1206)" {
  # a repo that builds an application is an application repo, whatever else it
  # carries — the exemption keys on the recorded primary, never on the marker
  mkdir -p "$W/charts/app"
  printf 'apiVersion: v2\nname: app\nversion: 0.1.0\n' > "$W/charts/app/Chart.yaml"
  printf 'primary: javascript\n' > "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  lacks "$output" 'EXEMPT'
}

@test "no .maintenance.yml at all is scanned, not exempt (#1206)" {
  # fail-closed on an absent record: an exemption that defaults ON would clear
  # every repo that has not been bootstrapped recently
  rm -f "$W/.maintenance.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
  lacks "$output" 'EXEMPT'
}

# ---------------------------------------------------------------------------
# Fail-closed parsing
# ---------------------------------------------------------------------------

@test "an unparseable workflow FAILS the check, naming that file (#1206)" {
  printf 'name: bad\n  bad: [\n' > "$W/.github/workflows/bad.yml"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'bad.yml'
  contains "$output" 'cannot be parsed'
}

@test "a well-formed sibling is STILL scanned after an unparseable file (#1206)" {
  # proves per-file parsing rather than one aborted batch: yq stops at the first
  # parse failure, so a batched implementation would report the malformed file
  # and silently never look at the deploy step at all
  printf 'name: bad\n  bad: [\n' > "$W/.github/workflows/bad.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'cannot be parsed'
  contains "$output" 'kubectl apply'
}

@test "a repo with no workflows at all passes cleanly (#1206)" {
  rmdir "$W/.github/workflows" "$W/.github"
  mkdir -p "$W/.git"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'no workflow files'
}

@test "a target that is not a repo root exits 2, never a clean scan (#1206)" {
  # zero workflow files is all but unreachable in a repo that RUNS this gate, so
  # in practice it means the cwd moved or --repo points into a subtree. Exiting 0
  # there is a green required check that scanned nothing.
  rmdir "$W/.github/workflows" "$W/.github"
  check
  [ "$status" -eq 2 ]
  contains "$output" 'not a repo root'
}

@test "a reusable-workflow job with no steps is not an error (#1206)" {
  # `jobs.<id>.uses` has no `steps:` key at all; treating that as unreadable
  # would fail every repo that calls a shared workflow
  wf call.yml 'name: c
on:
  pull_request:
jobs:
  shared:
    uses: acme/.github/.github/workflows/shared.yml@main'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "a workflow whose jobs: is a SCALAR fails closed on the second arm (#1206)" {
  # parses as YAML, but `.jobs | to_entries` cannot walk it — a distinct
  # fail-closed arm from "cannot be parsed", and the one a `continue` turned
  # into a silent skip would hide
  wf odd.yml 'name: o
on:
  pull_request:
jobs: nope'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'odd.yml'
  contains "$output" 'jobs/steps could not be read'
}

@test "a NULL job value is skipped without losing its sibling's deploy (#1206)" {
  # the non-object guard must skip the RECORD, not abandon the file
  wf mix.yml 'name: m
on:
  pull_request:
jobs:
  shared:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" "job 'deploy'"
}

@test "the checker exits 2 on a bad flag, distinct from a finding (#1206)" {
  # a required check must not report "you deployed to a cluster" when it was
  # actually invoked wrongly
  run zsh "$CHECK" --nope
  [ "$status" -eq 2 ]
  contains "$output" 'unexpected argument: --nope'
}

@test "--repo pointing at a non-directory exits 2 (#1206)" {
  run zsh "$CHECK" --repo "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  contains "$output" 'not a directory'
}

@test "--repo with no value exits 2 rather than consuming nothing (#1206)" {
  run zsh "$CHECK" --repo
  [ "$status" -eq 2 ]
  contains "$output" 'usage:'
}

@test "--help exits 2 with the usage line (#1206)" {
  run zsh "$CHECK" --help
  [ "$status" -eq 2 ]
  contains "$output" 'usage:'
}

@test "a missing yq exits 2, never 1 (#1206)" {
  # the distinction a consumer acts on: "your CI image lost yq" is not "you
  # deployed to a cluster". A PATH of the base system dirs only — yq lives in
  # /opt/homebrew/bin (macOS leg) or /usr/local/bin (the container leg), neither
  # of which is listed, while zsh/jq/sed are in /bin and /usr/bin on both.
  one_step 'kubectl apply -f k8s/'
  run env PATH="/usr/bin:/bin" zsh "$CHECK" --repo "$W"
  [ "$status" -eq 2 ]
  contains "$output" "'yq' not found on PATH"
}

@test "a missing jq exits 2, never 1 (#1206)" {
  # the OTHER half of the tooling preflight. Without jq every `yq | jq` pipeline
  # fails and each workflow is reported "jobs/steps could not be read" — exit 1,
  # "this repo has a problem", for what is a runner problem. The needle is
  # jq-specific so it cannot pass on the yq branch.
  local stub="$BATS_TEST_TMPDIR/no-jq"
  mkdir -p "$stub"
  local t
  for t in zsh yq sed head mktemp cat; do
    ln -sf "$(command -v "$t")" "$stub/$t"
  done
  one_step 'kubectl apply -f k8s/'
  run env PATH="$stub" zsh "$CHECK" --repo "$W"
  [ "$status" -eq 2 ]
  contains "$output" "'jq' not found on PATH"
}

# NOT TESTED, deliberately: the mktemp-failure exit-2 arm. A bare `mktemp` on
# macOS resolves its directory from `_CS_DARWIN_USER_TEMP_DIR` and ignores
# TMPDIR entirely, so the only fixture that reaches the branch on the Debian leg
# is a no-op on the macOS one — a test that means two different things on the
# two CI legs is worse than none (the same bash-3.2-vs-5 divergence
# tests/assertions.bash exists to eliminate). The branch stays as defensive
# code; it is one line and has no logic to regress.

@test "a .github directory with no workflows is a clean scan, not an error (#1206)" {
  # the OTHER disjunct of the repo-root evidence test: a rendered tree with
  # .github/ but no .git must pass rather than exit 2
  rmdir "$W/.github/workflows"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'no workflow files'
}

@test "a repo path containing a SPACE is scanned and reported relatively (#1206)" {
  local spaced="$BATS_TEST_TMPDIR/with space/repo"
  mkdir -p "$spaced/.github/workflows"
  printf 'primary: go\n' > "$spaced/.maintenance.yml"
  printf 'name: w\non:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - name: s\n        run: kubectl apply -f k8s/\n' \
    > "$spaced/.github/workflows/w.yml"
  run zsh "$CHECK" --repo "$spaced"
  [ "$status" -eq 1 ]
  contains "$output" '.github/workflows/w.yml'
  lacks "$output" "$BATS_TEST_TMPDIR"
}

@test "a WRONG-FLAVOUR yq exits 2, not 1-for-every-file (#1206)" {
  # python-yq answers `command -v` but has no -o=json; without a flavour probe
  # every workflow is reported unparseable and the operator hunts a YAML error
  # that does not exist
  local stub="$BATS_TEST_TMPDIR/fake-yq"
  mkdir -p "$stub"
  ln -sf "$(command -v jq)" "$stub/jq"
  printf '#!/bin/sh\necho "yq: unknown flag -o=json" >&2\nexit 2\n' > "$stub/yq"
  chmod +x "$stub/yq"
  one_step 'kubectl apply -f k8s/'
  run env PATH="$stub:$PATH" zsh "$CHECK" --repo "$W"
  [ "$status" -eq 2 ]
  contains "$output" 'mikefarah/yq'
}

@test "the workflow's own invocation — no --repo, cwd default — works (#1206)" {
  # the rendered workflow runs `zsh scripts/check-no-cluster-deploy.zsh` with no
  # arguments, so the REPO="." default and its relative-path stripping are what
  # every consumer actually exercises; nothing else in this file does
  one_step 'kubectl apply -f k8s/'
  cd "$W"
  run zsh "$CHECK"
  [ "$status" -eq 1 ]
  contains "$output" '.github/workflows/w.yml'
  lacks "$output" './.github/workflows/w.yml'
}

@test "the FAILED summary counts the problems and states the remedy (#1206)" {
  # the only guidance a consumer who has never read the checker receives
  printf 'name: bad\n  bad: [\n' > "$W/.github/workflows/bad.yml"
  one_step 'kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'FAILED: 2 problem(s)'
  contains "$output" 'infrastructure repo is the only path to a cluster'
  contains "$output" 'no escape-hatch annotation'
}

# ---------------------------------------------------------------------------
# The rendered workflow is REQUIRABLE (structural, via yq)
# ---------------------------------------------------------------------------

@test "the workflow declares exactly one job, id no-cluster-deploy (#1206)" {
  # the job id IS the required-context name; a rename here wedges every PR in
  # every consumer repo at the permanent `expected` state
  local jobs
  jobs="$(yq -r '.jobs | keys | .[]' "$TMPL" | tr '\n' ' ')"
  [ "$jobs" = "no-cluster-deploy " ]
  # GitHub reports the check under the job's `name:` when it has one, and a
  # matrix suffixes it — either edit leaves `.jobs | keys` (and branch
  # protection's context list) unchanged while the REPORTED name differs, which
  # pins every PR at `expected` forever
  [ "$(yq -r '.jobs.no-cluster-deploy | has("name")' "$TMPL")" = "false" ]
  [ "$(yq -r '.jobs.no-cluster-deploy | has("strategy")' "$TMPL")" = "false" ]
}

@test "the workflow declares permissions: contents: read (#1206)" {
  [ "$(yq -r '.permissions.contents' "$TMPL")" = "read" ]
  # exactly one grant — a second key would be a privilege this static scan has
  # no use for
  [ "$(yq -r '.permissions | keys | length' "$TMPL")" -eq 1 ]
}

@test "the workflow carries NO paths or paths-ignore filter (#1206)" {
  # the property that keeps this REQUIRED check from sitting at `expected`
  # forever. Read structurally: the word `paths` appears in this template's own
  # header prose explaining why it must not be there, so a grep would red on the
  # correct file. `has` distinguishes an absent key from a null-valued one.
  [ "$(yq -r '.on.pull_request | has("paths")' "$TMPL")" = "false" ]
  [ "$(yq -r '.on.pull_request | has("paths-ignore")' "$TMPL")" = "false" ]
  # the trigger it DOES carry — without this the two assertions above would pass
  # on a template with no pull_request trigger at all
  [ "$(yq -r '.on | has("pull_request")' "$TMPL")" = "true" ]
  [ "$(yq -r '.on.pull_request.branches[0]' "$TMPL")" = "{{DEFAULT_BRANCH}}" ]
}

@test "the workflow installs its toolchain explicitly with a PINNED yq (#1206)" {
  local ver
  ver="$(yq -r '.jobs.no-cluster-deploy.steps[] | select(.env.YQ_VERSION) | .env.YQ_VERSION' "$TMPL")"
  # a floating `latest` would make this required check's verdict depend on
  # whatever upstream released this morning
  matches "$ver" '^[0-9]+\.[0-9]+\.[0-9]+$'
  local install
  install="$(yq -r '.jobs.no-cluster-deploy.steps[] | select(.env.YQ_VERSION) | .run' "$TMPL")"
  contains "$install" 'apt-get install'
  contains "$install" 'jq'
  contains "$install" 'zsh'
  contains "$install" 'mikefarah/yq'
}

@test "the workflow actually RUNS the checker it installs a toolchain for (#1206)" {
  # every structural assertion above is satisfied by a workflow that installs yq
  # and then does nothing — the green-having-checked-nothing shape
  local runs
  runs="$(yq -r '.jobs.no-cluster-deploy.steps[] | .run // ""' "$TMPL" | tr '\n' ' ')"
  contains "$runs" 'scripts/check-no-cluster-deploy.zsh'
}

@test "the workflow checks out the repo, SHA-pinned (#1206)" {
  # without a checkout the workspace is empty, the checker finds neither .git
  # nor .github, and takes the exit-2 "not a repo root" arm on every PR in every
  # bootstrapped repo — the red-having-scanned-nothing counterpart to the
  # green-having-checked-nothing shape the test above rejects
  local uses
  uses="$(yq -r '.jobs.no-cluster-deploy.steps[] | .uses // ""' "$TMPL" | tr '\n' ' ')"
  contains "$uses" 'actions/checkout@'
  matches "$uses" 'actions/checkout@[0-9a-f]{40}'
}

@test "the workflow's concurrency block matches the checker's trap rationale (#1206)" {
  # the checker's signal traps are justified by `cancel-in-progress: true`; if
  # the template drops it the rationale silently becomes false
  [ "$(yq -r '.concurrency."cancel-in-progress"' "$TMPL")" = "true" ]
  contains "$(yq -r '.concurrency.group' "$TMPL")" 'no-cluster-deploy'
  [ "$(yq -r '.on | has("workflow_dispatch")' "$TMPL")" = "true" ]
}

@test "the workflow template is valid YAML and yamllint-clean (#1206)" {
  # .tmpl files are not swept by the repo-wide gate in the same way, and this
  # one becomes a REQUIRED check in every consumer repo
  run yq -o=json -I=0 '.' "$TMPL"
  [ "$status" -eq 0 ]
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$TMPL"
  [ "$status" -eq 0 ]
}

@test "the gate does not fail its OWN rendered workflow (#1206)" {
  # dogfood: a future template edit (a `kubectl version` smoke step, say) would
  # otherwise red every consumer's first PR after bootstrap
  sed 's/{{DEFAULT_BRANCH}}/main/g' "$TMPL" > "$W/.github/workflows/no-cluster-deploy.yml"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'workflow file(s) scanned'
}

@test "YQ_VERSION is identical across all FOUR lockstep sites (#1206)" {
  # MAINTAINING.md declares a four-site lockstep and gives the reason: a partial
  # bump makes the suite validate the shipped checker under a different yq than
  # consumers run. Pinning only the two templates against each other misses it.
  local a b c d
  a="$(yq -r '[.jobs[].steps[]? | select(.env.YQ_VERSION) | .env.YQ_VERSION] | unique | .[]' "$TMPL")"
  b="$(yq -r '[.jobs[].steps[]? | select(.env.YQ_VERSION) | .env.YQ_VERSION] | unique | .[]' \
    "$REPO_ROOT/development/skills/bootstrap/templates/iac/.github/workflows/kubernetes-ci.yml.tmpl")"
  c="$(grep -oE '^ARG YQ_VERSION=(.+)$' "$REPO_ROOT/tests/Dockerfile" | sed 's/^ARG YQ_VERSION=//')"
  d="$(grep -oE 'YQ_VERSION: *[0-9.]+' "$REPO_ROOT/.github/workflows/script-tests.yml" \
    | sed -E 's/YQ_VERSION: *//' | sort -u)"
  # each read must have produced something — an unmatched grep would otherwise
  # make the set trivially unanimous
  [ -n "$a" ]
  [ -n "$b" ]
  [ -n "$c" ]
  [ -n "$d" ]
  [ "$a" = "$b" ]
  [ "$a" = "$c" ]
  [ "$a" = "$d" ]
}


# ---------------------------------------------------------------------------
# Branch protection — both directions
# ---------------------------------------------------------------------------

protection_stubs() {
  CURL_DATA="$BATS_TEST_TMPDIR/curl-data.txt"
  : > "$CURL_DATA"
  export CURL_DATA
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view") echo "acme/app" ;;
  "auth token") echo "stub-token" ;;
esac
exit 0
EOF
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ]; then
    printf '%s' "$a" | jq -c . >> "$CURL_DATA" 2>/dev/null || printf '%s\n' "$a" >> "$CURL_DATA"
  fi
  prev="$a"
done
echo "${CURL_HTTP_STATUS:-200}"
exit 0
EOF
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
}

@test "branch-protection requires no-cluster-deploy on the PUBLIC path (#1206)" {
  protection_stubs
  touch "$W/.github/workflows/no-cluster-deploy.yml"
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'no-cluster-deploy'
  contains "$contexts" 'test-and-coverage'
}

@test "branch-protection requires no-cluster-deploy on the PRIVATE path (#1206)" {
  protection_stubs
  touch "$W/.github/workflows/no-cluster-deploy.yml"
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility private --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'no-cluster-deploy'
  contains "$contexts" 'sonarqube'
}

@test "branch-protection does NOT require a context no workflow would report (#1206)" {
  # the ko-image precedent, applied to a brand-new artifact: a repo bootstrapped
  # before #1206, or one whose render was declined, must not have every PR pinned
  # at `expected` forever. The warn is what keeps the fail-open visible.
  protection_stubs
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  lacks "$contexts" 'no-cluster-deploy'
  # …and it SAYS so, rather than silently dropping the gate
  contains "$output" 'render the #1206 direct-to-cluster gate'
  # positive control: the rest of the language-app set is still required, so the
  # `lacks` above is a decision rather than an empty context list
  contains "$contexts" 'test-and-coverage'
}

@test "the --iac-only context set is UNCHANGED at the six IaC jobs (#1206)" {
  # the other direction, and the one a careless addition breaks: requiring
  # no-cluster-deploy on a GitOps repo pins every IaC PR at `expected`, because
  # §3l renders no such workflow there. EXACT equality, not a `lacks` sweep — a
  # `lacks` would also pass if the whole set were empty.
  protection_stubs
  # stage the PAIR, or the append arm is unreachable on this fixture and the
  # regression this test names (moving the #1206 block below the IaC
  # replacement, or dropping its guard) could never red here
  touch "$W/.github/workflows/no-cluster-deploy.yml"
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts expected
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  expected="$(printf '%s\n' $IAC_JOBS | LC_ALL=C sort | paste -sd, -)"
  [ "$contexts" = "$expected" ]
}

@test "the IaC path stays SILENT about a gate it does not render (#1206)" {
  # the pair is ABSENT here on purpose: with it staged, the `warn` else-branch
  # is unreachable and `lacks` could never fail. Only this fixture makes the
  # negative a decision — and the regression it guards is a GitOps bootstrap
  # telling an operator to install a required check that must never exist there.
  protection_stubs
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts expected
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  expected="$(printf '%s\n' $IAC_JOBS | LC_ALL=C sort | paste -sd, -)"
  [ "$contexts" = "$expected" ]
  # a needle unique to the #1206 warn — `NOT requiring the` is also emitted for
  # the `image`/ko check, so it would not tell the two branches apart
  lacks "$output" 'render the #1206 direct-to-cluster gate'
}

@test "branch-protection omits the context when only the WORKFLOW is present (#1206)" {
  # the wedge one level down: the context would be required and the job would
  # die with `no such file or directory` on every PR
  protection_stubs
  touch "$W/.github/workflows/no-cluster-deploy.yml"
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  lacks "$contexts" 'no-cluster-deploy'
  contains "$output" 'scripts/check-no-cluster-deploy.zsh'
  contains "$contexts" 'test-and-coverage'
}

@test "branch-protection omits the context when only the CHECKER is present (#1206)" {
  protection_stubs
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  cd "$W"
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  lacks "$contexts" 'no-cluster-deploy'
  contains "$output" '.github/workflows/no-cluster-deploy.yml'
  contains "$contexts" 'test-and-coverage'
}

@test "the 403 fallback prints no-cluster-deploy in its manual recipe (#1206)" {
  # a no-admin operator applies the rule by hand from THIS output; omitting the
  # context there ships a repo whose gate is installed but never required
  protection_stubs
  touch "$W/.github/workflows/no-cluster-deploy.yml"
  mkdir -p "$W/scripts"
  touch "$W/scripts/check-no-cluster-deploy.zsh"
  cd "$W"
  CURL_HTTP_STATUS=403 run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  # pin the BRANCH first: the script prints its whole check list before the PUT
  # on every path, so a bare needle on $output matches the 200 path too and
  # proves neither the branch nor the recipe
  contains "$output" '403 — your account does not have admin permission'
  local recipe
  recipe="$(printf '%s' "$output" | sed -n '/apply branch protection manually/,$p')"
  [ -n "$recipe" ]
  contains "$recipe" 'no-cluster-deploy'
}

# ---------------------------------------------------------------------------
# Adoption wiring — the prose sites nothing mechanical would notice losing
# ---------------------------------------------------------------------------

@test "Step 3.6 stamps no-cluster-deploy.yml with the template drift expects (#1206)" {
  # the PRODUCER half of the provenance coupling: without this row every
  # bootstrap ships an unstamped workflow, so the tracked drift entry is fed a
  # file with no marker forever
  local row
  row="$(grep -F '| `.github/workflows/no-cluster-deploy.yml` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" '`common/.github/workflows/no-cluster-deploy.yml.tmpl`'
  # …and the CHECKER's row. It is the half that actually goes stale (it holds
  # the command set), so a dropped row here ships an unstamped checker and feeds
  # its drift entry a markerless file forever — `unknown_provenance`, not drift.
  local srow
  srow="$(grep -F '| `scripts/check-no-cluster-deploy.zsh` |' "$SKILL")"
  [ -n "$srow" ]
  contains "$srow" '`common/scripts/check-no-cluster-deploy.zsh`'
  # the instruction that pairs them, so a table row cannot drift from the prose
  contains "$(tr -s '[:space:]' ' ' < "$SKILL")" 'stamp a provenance marker on **both halves**'
}

@test "SETUP.md.tmpl states the rule, the exemptions and the missing escape hatch (#1206)" {
  # the consumer-facing statement. The checker's header is authoritative, but a
  # user reads SETUP.md — and this section is the one place that warns SETUP.md
  # itself is not drift-tracked, which is exactly the caveat a gap-fill adopter
  # needs and would otherwise never be told.
  local setup
  setup="$(tr -s '[:space:]' ' ' < "$SETUP_TMPL")"
  contains "$setup" 'no-cluster-deploy'
  contains "$setup" 'helm upgrade'
  contains "$setup" 'argocd app sync'
  contains "$setup" 'flux reconcile'
  contains "$setup" 'kind create cluster'
  contains "$setup" '--dry-run'
  contains "$setup" 'primary: kubernetes'
  contains "$setup" 'deliberately no escape hatch'
  contains "$setup" 'scaffold file, so it is deliberately not drift-tracked'
  contains "$setup" '1189'
}

# ---------------------------------------------------------------------------
# Prose is neutralised BEFORE segmentation (round-3 CRITICAL)
# ---------------------------------------------------------------------------
#
# Splitting the line first means any `;`, `|`, `&`, `)` or `$(` inside a comment
# or an echoed string ends the protection and the tail is re-parsed as a live
# command — fail-OPEN when the tail names a cluster-creation command (the whole
# job goes exempt) and fail-CLOSED when it names a banned one.

@test "NEGATIVE CONTROL: a ';' inside a comment does not confer the ephemeral exemption (#1206)" {
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: probe
        run: |
          kubectl get pods -n prod   # deploys live in infra; kind create cluster is e2e-only
      - name: ship
        run: helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'ship'"
}

@test "a ')' inside a comment does not CREATE a false failure (#1206)" {
  # the mirror direction, on a gate with no escape hatch: a comment typo must
  # not force a consumer to fork the checker
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: probe
        run: |
          kubectl get pods -n prod   # never (ever) helm upgrade from here'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "NEGATIVE CONTROL: a ';' inside an echoed STRING does not confer the exemption (#1206)" {
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: note
        run: echo "e2e uses kind; kind create cluster runs in the e2e job"
      - name: ship
        run: helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'ship'"
}

@test "a piped echo into kubectl apply STILL fails (#1206)" {
  # the guard against over-correcting the previous three: neutralising quoted
  # text must not make `echo "$MANIFEST" | kubectl apply -f -` invisible, which
  # is a real deploy
  one_step 'echo "$MANIFEST" | kubectl apply -f -'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

# --- the tool is read from COMMAND POSITION, not from any token

@test "grep for a banned command does NOT fail the build (#1206)" {
  # a repo that lints its own workflows for this very rule was the likeliest
  # victim, and it has no escape hatch
  passes_and_control 'grep -rn "kubectl apply" .github/workflows'
}

@test "NEGATIVE CONTROL: grep for a creation command does not confer the exemption (#1206)" {
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: probe
        run: grep -q "kind create cluster" .github/workflows/it.yml
      - name: ship
        run: helm upgrade --install myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'ship'"
}

@test "sed rewriting a banned command does NOT fail the build (#1206)" {
  passes_and_control "sed -i 's/helm upgrade/helm template/' deploy.sh"
}

# --- two-word verbs survive an interposed global flag

@test "kubectl rollout -n prod restart fails (#1206)" {
  one_step 'kubectl rollout -n prod restart deployment/api'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl rollout restart'
}

@test "kubectl set --namespace prod image fails (#1206)" {
  one_step 'kubectl set --namespace prod image deploy/api api=img:1.2.3'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl set image'
}

@test "argocd app --grpc-web sync fails (#1206)" {
  one_step 'argocd app --grpc-web sync myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'argocd app sync'
}

# --- a command substitution must not detach a trailing --dry-run

@test "a --dry-run after a command substitution still exempts (#1206)" {
  # `--set tag=$(git rev-parse --short HEAD) … --dry-run` is a very common
  # render/validate shape; splitting the outer command at `$(` stranded the flag
  # and failed a legitimately exempt step
  passes_and_control 'helm upgrade --install myapp ./chart --set image.tag=$(git rev-parse --short HEAD) --dry-run'
}

# --- subshell grouping

@test "a one-line for loop does not hide the deploy (#1206)" {
  # splitting on `;` puts the shell KEYWORD `do` in command position, and a
  # walk that gave up there dropped the deploy entirely. `for f in …; do
  # kubectl apply …; done` is one of the commonest ways a deploy step is
  # written, and it failed OPEN.
  one_step 'for f in k8s/*.yaml; do kubectl apply -f "$f"; done'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a one-line if statement does not hide the deploy (#1206)" {
  one_step 'if [ "$ENV" = prod ]; then kubectl apply -f k8s/; fi'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a one-line while loop does not hide the deploy (#1206)" {
  one_step 'while read -r f; do helm upgrade --install "$f" ./chart; done < list'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a brace group does not hide the deploy (#1206)" {
  # a BLOCK scalar is required: `{` opens a YAML flow mapping in a plain scalar,
  # so this shape cannot go through one_step
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          { kubectl apply -f k8s/; } >> log'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "timeout with a DURATION argument does not hide the command (#1206)" {
  one_step 'timeout 5m kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "sudo -u with its value does not hide the command (#1206)" {
  one_step 'sudo -u deployer kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "xargs -I with its value does not hide the command (#1206)" {
  one_step 'xargs -I {} kubectl delete -f {}'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl delete'
}

@test "a hash inside a STRING does not truncate the rest of the line (#1206)" {
  # cutting at the first ` #` while quotes were still literal deleted the
  # deploy. A BLOCK scalar is required: in a plain YAML scalar the ` #42` would
  # be a YAML comment and never reach the checker at all.
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          echo "Deploying build #42" && kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED --dry-run value still exempts (#1206)" {
  # `--dry-run="client"` reaches the comparison as `--dry-run=__Q1__`, which
  # matched no arm — a false failure on an exempt command
  passes_and_control 'kubectl apply --dry-run="client" -f k8s/'
}

@test "NEGATIVE CONTROL: a QUOTED --dry-run none does NOT exempt (#1206)" {
  one_step 'kubectl apply --dry-run "none" -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: an UNRESOLVED --dry-run value does NOT exempt (#1206)" {
  # a value we cannot read may well be `false`; treating it as a dry run would
  # be a self-service exemption driven by a workflow input
  one_step 'kubectl apply --dry-run "${{ inputs.dry_run }}" -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "an if-guarded kind step DOES exempt a deploy under the SAME condition (#1206)" {
  # the commonest real shape: both steps guarded by one expression, so they run
  # together or not at all. A blanket refusal reds an ordinary integration job.
  wf it.yml "name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: Create kind cluster
        if: github.event_name == 'pull_request'
        run: kind create cluster
      - name: Deploy to kind
        if: github.event_name == 'pull_request'
        run: helm upgrade --install myapp ./chart"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "an unquoted GitHub expression as a flag VALUE does not hide the verb (#1206)" {
  # `${{ env.NS }}` word-splits into three tokens, so the `-n` value skip landed
  # on `env.NAMESPACE` and read it as the subcommand. An utterly ordinary deploy
  # line, failing OPEN — and the verdict flipped on quoting alone.
  one_step 'kubectl -n ${{ env.NAMESPACE }} apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "an unquoted GitHub expression before the verb does not hide it (#1206)" {
  one_step 'kubectl ${{ env.EXTRA_ARGS }} apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a GitHub expression as an argocd --server value does not hide the verb (#1206)" {
  one_step 'argocd --server ${{ secrets.ARGOCD_SERVER }} app sync myapp'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'argocd app sync'
}

@test "a GitHub expression as a WRAPPER argument does not hide the tool (#1206)" {
  one_step 'timeout ${{ env.DEPLOY_TIMEOUT }} kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a GitHub expression containing shell operators is ONE argument (#1206)" {
  # `&&` and `||` inside `${{ }}` are expression syntax, not shell separators;
  # splitting there severed the tool from its verb
  one_step "kubectl -n \${{ github.ref == 'refs/heads/main' && 'prod' || 'dev' }} apply -f k8s/"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

# --- the opaque-token table: every unreadable spelling, at every site that asks
#
# Rounds 5 and 6 each found a cell of a 3x5 table — three walks (subcommand,
# wrapper, dry-run value) times five ways a token can be unreadable
# (`__EXPR__`, `__SPAN__`, a `__Q<n>__` hiding either, `${VAR}`, bare `$VAR`).
# The verdict used to flip on quoting alone. These pin the whole table.

@test "a QUOTED GitHub expression as an argument does not hide the verb (#1206)" {
  one_step 'kubectl "${{ env.EXTRA_ARGS }}" apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED command substitution as an argument does not hide the verb (#1206)" {
  one_step 'kubectl "$(extra-args)" apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a bare shell parameter as an argument does not hide the verb (#1206)" {
  one_step 'kubectl $EXTRA_ARGS apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a braced shell parameter as an argument does not hide the verb (#1206)" {
  one_step 'kubectl ${KUBECTL_FLAGS} apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: a QUOTED LITERAL verb still resolves (#1206)" {
  # `_unlift` before the opacity test is what keeps this tightening rather than
  # widening: `"apply"` is readable, so it is the subcommand and still fails
  one_step 'kubectl "apply" -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED expression as a WRAPPER argument does not hide the tool (#1206)" {
  one_step 'timeout "${{ env.DEPLOY_TIMEOUT }}" kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED shell parameter as a WRAPPER argument does not hide the tool (#1206)" {
  # the shape GitHub's own script-injection guidance pushes authors toward
  one_step 'timeout "$DEPLOY_TIMEOUT" kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a bare shell parameter as a WRAPPER argument does not hide the tool (#1206)" {
  one_step 'timeout $DEPLOY_TIMEOUT kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a command substitution as a WRAPPER argument does not hide the tool (#1206)" {
  one_step 'timeout $(compute-timeout) kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "nice -n with a quoted parameter does not hide the tool (#1206)" {
  one_step 'nice -n "$N" kubectl delete -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl delete'
}

@test "NEGATIVE CONTROL: a bare \$VAR --dry-run value does NOT exempt (#1206)" {
  # setting `DRY_RUN=` (or `none`) in a job `env:` would otherwise silence the
  # gate for that command while the real deploy runs — a self-service hatch
  one_step 'kubectl apply --dry-run $DRY_RUN -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "NEGATIVE CONTROL: a braced \${VAR} --dry-run value does NOT exempt (#1206)" {
  one_step 'helm upgrade --install myapp ./chart --dry-run ${MODE}'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

# --- the QUOTED-LITERAL column of the same table
#
# Round 6 pinned every cell whose quoted text was OPAQUE (`"${{ … }}"`, `"$V"`).
# The quoted-LITERAL column was open, and it fails the other way: the text
# unlifts to something readable, so the opacity arm declines it while the shape
# and membership arms still saw a placeholder. Each unquoted twin below is
# already pinned elsewhere in this file, so these pin that the verdict does not
# turn on quoting.

@test "a QUOTED tool name is still recognised (#1206)" {
  # a BLOCK scalar: a body STARTING with `"` is a quoted YAML scalar, so this
  # shape cannot go through one_step
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          "kubectl" apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED tool name behind a wrapper is still recognised (#1206)" {
  one_step 'sudo "kubectl" apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED absolute tool path is still recognised (#1206)" {
  # a BLOCK scalar: a body STARTING with `"` is a quoted YAML scalar, so this
  # shape cannot go through one_step
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          "/usr/local/bin/kubectl" apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED duration wrapper argument does not break the walk (#1206)" {
  one_step 'timeout "5m" kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED numeric wrapper argument does not break the walk (#1206)" {
  one_step 'timeout "60" kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED env assignment does not break the walk (#1206)" {
  one_step 'env "KUBECONFIG=/tmp/kc" kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED wrapper FLAG and its value do not break the walk (#1206)" {
  one_step 'timeout "-k" 30s kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED sudo -u and its value do not break the walk (#1206)" {
  one_step 'sudo "-u" deployer kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED global flag before the verb still resolves the verb (#1206)" {
  one_step 'kubectl "-n" prod apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a QUOTED helm passthrough verb is still stepped over (#1206)" {
  one_step 'helm "secrets" upgrade myapp ./chart'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "a QUOTED -c is still rescanned (#1206)" {
  one_step 'sh "-c" "kubectl apply -f k8s/"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "CONCATENATED quoted runs still resolve the verb (#1206)" {
  # adjacent quoted runs are ONE shell word (`__Q1____Q2__`); resolving only the
  # first placeholder left the mixed spelling `app__Q2__`, which matches no verb
  one_step 'kubectl "app""ly" -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "an unpairable APOSTROPHE does not hide a later quoted tool (#1206)" {
  # breaking out of quote-lifting at a lone apostrophe left `"kubectl"` carrying
  # literal quotes, so the tool was unrecognisable and the deploy passed
  # DOUBLE-quoted here so the fixture can actually contain an apostrophe — a
  # single-quoted bats argument cannot, and the test would prove nothing
  wf w.yml "name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          echo Can't wait; \"kubectl\" apply -f k8s/"
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "sudo -E does not swallow the tool (#1206)" {
  # `-E` takes a value for xargs and none for sudo; a unioned flag table skipped
  # `kubectl` and read `apply` as the command
  one_step 'sudo -E kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "sudo -n does not swallow the tool (#1206)" {
  one_step 'sudo -n kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "flux --timeout with its value does not hide the verb (#1206)" {
  one_step 'flux --timeout 5m reconcile kustomization apps'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'flux reconcile'
}

@test "kubectl -v with its value does not hide the verb (#1206)" {
  one_step 'kubectl -v 6 apply -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "an UNCONDITIONAL kind step exempts a CONDITIONAL deploy (#1206)" {
  # the sole reason the "unconditional creator exempts unconditionally" clause
  # exists: an unguarded `kind create cluster` followed by a deploy carrying
  # `if: …` is a bog-standard integration job, and failing it would be a false
  # alarm on a required check with no escape hatch
  wf it.yml "name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: kind create cluster
      - name: Deploy
        if: github.event_name == 'pull_request'
        run: helm upgrade --install myapp ./chart"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "NEGATIVE CONTROL: a CONDITIONAL creator does not exempt an UNGUARDED deploy (#1206)" {
  # the documented absent-against-conditional clause: the creator may not run,
  # the deploy always does, so it reaches the real cluster. Fails closed.
  wf it.yml "name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        if: github.event_name == 'pull_request'
        run: kind create cluster
      - name: Deploy
        run: helm upgrade --install myapp ./chart"
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'Deploy'"
}

@test "a subshell-grouped deploy fails (#1206)" {
  one_step '(kubectl apply -f k8s/)'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a subshell-grouped deploy with || true fails (#1206)" {
  one_step '(helm upgrade --install myapp ./chart) || true'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

# --- a CONDITIONAL cluster-creating step does not confer the exemption

@test "NEGATIVE CONTROL: minikube start --dry-run confers NO exemption (#1206)" {
  # `--dry-run` is a real minikube flag: it validates configuration and creates
  # nothing. A creator that creates nothing must not exempt anything, or it is a
  # one-line self-service hatch on a gate whose header says it has none.
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: minikube start --dry-run
      - name: apply
        run: helm upgrade --install myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'apply'"
}

@test "NEGATIVE CONTROL: ctlptl apply --dry-run confers NO exemption (#1206)" {
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: cluster
        run: ctlptl apply --dry-run=client -f cluster.yaml
      - name: apply
        run: helm upgrade --install myapp ./chart --namespace prod'
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'apply'"
}

@test "NEGATIVE CONTROL: an if-guarded kind step does not exempt the job (#1206)" {
  # branch-per-environment: the two conditions are mutually exclusive, so the
  # deploy hits the REAL cluster whenever kind was not created
  wf it.yml "name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: Start kind
        if: github.event_name == 'pull_request'
        run: kind create cluster
      - name: Deploy
        if: github.ref == 'refs/heads/main'
        run: helm upgrade --install myapp ./chart"
  check
  [ "$status" -eq 1 ]
  contains "$output" "step 'Deploy'"
}

# --- the remaining documented dry-run spellings

@test "--dry-run=true exempts (#1206)" { passes_and_control 'kubectl apply --dry-run=true -f k8s/'; }
@test "a separate-argument --dry-run client exempts (#1206)" { passes_and_control 'kubectl apply --dry-run client -f k8s/'; }
@test "a bare --dry-run mid-command exempts (#1206)" { passes_and_control 'kubectl apply --dry-run -f k8s/'; }

@test "NEGATIVE CONTROL: a separate-argument --dry-run false does NOT exempt (#1206)" {
  one_step 'helm upgrade --install myapp ./chart --dry-run false'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

@test "NEGATIVE CONTROL: a separate-argument --dry-run 0 does NOT exempt (#1206)" {
  one_step 'kubectl apply --dry-run 0 -f k8s/'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a token merely CONTAINING a hash is an argument, not a comment (#1206)" {
  # loosening the truncation to `*#*` would drop every flag after it — here the
  # `--dry-run` that makes this step legitimately exempt
  passes_and_control 'helm upgrade --install myapp ./chart --set tag=v1#2 --dry-run'
}

# --- scan SCOPE

@test "YAML outside .github/workflows is NOT scanned (#1206)" {
  # a widened glob would red every consumer repo that vendors manifests or a
  # chart — a required check failing repos for holding data files.
  #
  # The out-of-tree fixtures are WORKFLOW-SHAPED on purpose. Written as bare
  # `run:` fragments they carry no `jobs:` key, so a widened glob would scan
  # them, find zero steps and still exit 0 — the test would stay green under
  # the exact mutation it names. With a real `jobs:` block, widening the glob
  # produces findings and reds. The count needle is the second half of that:
  # `no workflow files` can only hold while the glob stays bounded.
  mkdir -p "$W/k8s" "$W/charts/app/templates" "$W/.github/actions/deploy"
  local body
  body='name: v
on:
  push:
jobs:
  x:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: %s
'
  printf "$body" 'kubectl apply -f k8s/' > "$W/k8s/deploy.yaml"
  printf "$body" 'helm upgrade --install myapp ./chart' > "$W/charts/app/templates/job.yaml"
  printf 'runs:\n  steps:\n    - run: argocd app sync myapp\n' > "$W/.github/actions/deploy/action.yml"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'no workflow files'
  # positive control: a workflow in the real location IS scanned
  wf control.yml 'name: c
on:
  pull_request:
jobs:
  ship:
    runs-on: ubuntu-latest
    steps:
      - name: bad
        run: kubectl apply -f k8s/'
  check
  [ "$status" -eq 1 ]
}

@test "the scanned COUNT reflects every file, not just the last (#1206)" {
  mkdir -p "$W/.github/workflows/sub"
  wf a.yml 'name: a
on:
  pull_request:
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: kubectl get pods'
  wf b.yml 'name: b
on:
  pull_request:
jobs:
  b:
    runs-on: ubuntu-latest
    steps:
      - run: helm template ./chart'
  printf 'name: c\non:\n  pull_request:\njobs:\n  c:\n    runs-on: ubuntu-latest\n    steps:\n      - run: kubectl get svc\n' \
    > "$W/.github/workflows/sub/c.yml"
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 3 workflow file(s) scanned'
}

@test "a hash inside a QUOTED sh -c payload truncates that command (#1206)" {
  # the only path that reaches `_tokens_of`'s `#`-token truncation: the `#` is
  # inside a quoted run, so the quote-aware line-level strip deliberately does
  # not cut, and the `sh -c` rescan tokenises the raw text. Without the
  # truncation the trailing `--dry-run` becomes the last token of REST, the
  # bare-flag arm fires, and the deploy is exempt — a working escape hatch.
  # BLOCK scalar: in a plain YAML scalar the ` #` is a YAML comment and never
  # reaches the checker at all
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: ship
        run: |
          sh -c "kubectl apply -f k8s/ # --dry-run"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'kubectl apply'
}

@test "a trailing comment cannot CREATE a match when the command has no tool (#1206)" {
  # the shape that actually discriminates: without the truncation the tool
  # search finds `kubectl` inside the comment and reports a deploy
  wf w.yml 'name: w
on:
  pull_request:
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: render
        run: |
          kustomize build overlays/prod  # then kubectl apply -f -'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "a REAL carriage return does not defeat the ephemeral matcher (#1206)" {
  # yq normalises CR/LF line breaks, so a CRLF-authored FILE never delivers a CR
  # to the checker. A double-quoted YAML scalar does: `\r` is a genuine escape.
  #
  # The CR must land on the LAST token of the creating command, and the deploy
  # must stay on its own line — an earlier version put `\r` mid-line, which glued
  # the two commands into one segment whose command position was `kind`. That
  # fixture passed with the \r strip removed AND with the whole ephemeral
  # machinery deleted: a permanent pass. Here, without the strip, SUB_NEXT is
  # `cluster\r`, no exemption is conferred, and the `helm upgrade` reds the check.
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: all in one
        run: "kind create cluster\r\nhelm upgrade --install myapp ./chart"'
  check
  [ "$status" -eq 0 ]
  contains "$output" 'PASSED: 1 workflow file(s) scanned'
}

@test "POSITIVE CONTROL: the second line of a CR-separated body IS reachable (#1206)" {
  # without this, the exit 0 above proves nothing about the deploy being visible
  wf it.yml 'name: it
on:
  pull_request:
jobs:
  integration:
    runs-on: ubuntu-latest
    steps:
      - name: all in one
        run: "kubectl get pods\r\nhelm upgrade --install myapp ./chart"'
  check
  [ "$status" -eq 1 ]
  contains "$output" 'helm upgrade'
}

# ---------------------------------------------------------------------------
# The prose lockstep — every restatement agrees with the code
# ---------------------------------------------------------------------------
#
# The checker's header says "anywhere this script's rules are restated, all
# three have to be", and MAINTAINING.md names the seven sites. Prose alone does
# not hold: round 3 found MAINTAINING.md claiming FOUR sites when there were
# seven, discovered because a `--dry-run` rule change had reached two
# restatements and not the other three. A closed hand-maintained list rots, so
# this pins the substantive clauses mechanically instead — the invariant, not
# the inventory.

# Every site that restates the rules, EXCLUDING the authoritative header.
# DERIVED from the same sweep MAINTAINING.md prescribes rather than transcribed:
# a hand-maintained inventory is the thing this section exists to argue against,
# and a seventh site added tomorrow must be subjected to these invariants
# automatically, not only to the MAINTAINING table test below.
restatement_sites() {
  local rel
  while IFS= read -r rel; do
    case "$rel" in
      # wiring and index sites, which carry no restatement of the rules
      development/skills/bootstrap/scripts/*) continue ;;
      development/skills/bootstrap/templates/common/scripts/*) continue ;;  # authoritative
      docs/how-to/index.md|MAINTAINING.md|ARCHITECTURE.md) continue ;;
    esac
    printf '%s\n' "$REPO_ROOT/$rel"
  done < <(cd "$REPO_ROOT" && grep -rln 'no-cluster-deploy' \
    development/skills/bootstrap docs MAINTAINING.md ARCHITECTURE.md | sort)
}

@test "the derived restatement-site list is not empty or shrunken (#1206)" {
  # a broken grep would turn both lockstep invariants below into silent no-ops
  local sites n
  sites="$(restatement_sites)"
  n="$(printf '%s\n' "$sites" | grep -c . )"
  [ "$n" -ge 6 ]
  contains "$sites" 'SETUP.md.tmpl'
  contains "$sites" 'keep-app-repos-out-of-the-cluster.md'
  contains "$sites" 'no-cluster-deploy.yml.tmpl'
}

@test "every restatement site says THREE exemptions, never two (#1206)" {
  # the count is the cheapest tell that a site has gone stale, and the
  # repo-wide `primary: kubernetes` one is the exemption a stale site drops —
  # the single edit that turns the whole required check into a permanent no-op
  local f body
  while IFS= read -r f; do
    [ -f "$f" ]
    body="$(tr -s '[:space:]' ' ' < "$f")"
    lacks "$body" 'the two exemptions'
    lacks "$body" 'both exemptions'
    # POSITIVE arm, and the one that catches the likely drift: a site loses a
    # bullet without anyone rewriting the prose to say "two". A site that
    # enumerates the exemptions at all must name ALL THREE — and the repo-wide
    # one is the exemption a stale site drops, which is the single edit that
    # turns the whole required check into a permanent no-op.
    case "$body" in
      *--dry-run*)
        # the repo-wide one is the exemption a stale site drops — the single
        # edit that turns the whole required check into a permanent no-op
        contains "$body" 'primary: kubernetes'
        ;;
    esac
  done < <(restatement_sites)
}

@test "every site that mentions --dry-run carries the VALUE rule (#1206)" {
  # `--dry-run=none` is kubectl's DEFAULT and really writes. A site that says
  # only "carrying --dry-run" licenses the reader to add the one spelling that
  # does not exempt — or to call a red check a checker bug.
  local f body
  while IFS= read -r f; do
    body="$(tr -s '[:space:]' ' ' < "$f")"
    case "$body" in
      *--dry-run*) contains "$body" '--dry-run=none' ;;
      *) : ;;   # a site need not mention the exemption at all
    esac
  done < <(restatement_sites)
}

@test "every site that enumerates the command set names ALL of it (#1206)" {
  # MAINTAINING.md declares the lockstep as the v1 command set AND the three
  # exemptions. The two sweeps above pin the exemption half; this pins the other,
  # which is the half a widening actually touches — the checker's header names
  # `kubectl run|edit|annotate|…` as candidates for a deliberate re-decision, so
  # the realistic change reaches the header and leaves a restatement stale.
  local f body gated=0
  while IFS= read -r f; do
    body="$(tr -s '[:space:]' ' ' < "$f")"
    # gate on a site that enumerates the set at all — a site may legitimately
    # reference the gate without restating its commands
    case "$body" in
      *"kubectl apply"*) : ;;
      *) continue ;;
    esac
    gated=$(( gated + 1 ))
    # Needles chosen to survive BOTH spellings a site may use: the expanded
    # form (`kubectl apply`, `kubectl create`, …) and the pipe-compressed one
    # (`kubectl apply|create|replace|patch|delete`). A needle that only matched
    # the expanded form would pass on half the sites by accident.
    local verb
    for verb in 'kubectl apply' 'create' 'replace' 'patch' 'delete' \
                'kubectl rollout restart' 'kubectl set image' 'kubectl scale' \
                'install' 'upgrade' 'rollback' 'uninstall' \
                'app sync' 'reconcile' 'bootstrap'; do
      contains "$body" "$verb"
    done
    # …and the OUT set's discriminator is never listed as banned
    lacks "$body" 'Fails | `helm diff`'
  done < <(restatement_sites)
  # NON-VACUITY: at least one site must have taken the gated arm, or a marker
  # that stopped matching would turn this whole sweep into a silent no-op
  [ "$gated" -ge 1 ]
}

@test "MAINTAINING.md's lockstep list names every site the sweep finds (#1206)" {
  # the list that rotted. Derived, not transcribed: the grep MAINTAINING.md
  # itself prescribes is run here, and every hit outside the allowlist of
  # non-restatement mentions must appear in the table.
  local maint table hits f rel
  maint="$(cat "$REPO_ROOT/MAINTAINING.md")"
  contains "$maint" 'restated in **seven** places'
  # Match inside the TABLE, not the whole document: `SKILL.md` and
  # `no-cluster-deploy.yml.tmpl` both occur elsewhere in this file (the prose at
  # the top, and the YQ_VERSION lockstep paragraphs), so a document-wide needle
  # lets those two rows be deleted with the suite green — the exact rot round 3
  # suffered, and what this test exists to catch.
  table="$(sed -n '/^| Site | Carries |/,/^$/p' "$REPO_ROOT/MAINTAINING.md")"
  [ -n "$table" ]
  # tie the PROSE count to the DERIVED one, or an eighth site keeps the suite
  # green while the table still says seven — the rot round 3 found, inverted
  local n
  n="$(restatement_sites | grep -c . )"
  [ "$n" -eq 6 ]   # six restatements + the authoritative header = seven
  hits="$(cd "$REPO_ROOT" && grep -rln 'no-cluster-deploy' \
    development/skills/bootstrap docs MAINTAINING.md ARCHITECTURE.md | sort)"
  [ -n "$hits" ]
  while IFS= read -r rel; do
    case "$rel" in
      # wiring and index sites, which carry no restatement of the rules
      development/skills/bootstrap/scripts/*|docs/how-to/index.md|MAINTAINING.md|ARCHITECTURE.md) continue ;;
      development/skills/bootstrap/templates/common/scripts/*) continue ;;  # the authoritative header
    esac
    contains "$table" "$(basename "$rel")"
  done < <(printf '%s\n' "$hits")
  # the table's data rows must equal the derived site count plus the
  # authoritative header row, so a site appended to neither reds here
  local rows
  rows="$(printf '%s\n' "$table" | grep -c '^| `')"
  [ "$rows" -eq "$(( $(restatement_sites | grep -c . ) + 1 ))" ]
}

@test "§3l names the pair among what the IaC path does NOT emit (#1206)" {
  # §3l's not-emitted table is the only prose site that says the gate is
  # withheld there; a model composing the IaC path from the skill would
  # otherwise render a required check that fails a GitOps repo for doing its job
  local section
  section="$(sed -n '/^### 3l\./,/^### Idempotency rules/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$section" ]
  contains "$section" 'check-no-cluster-deploy.zsh'
  contains "$section" 'no-cluster-deploy.yml'
}
