#!/usr/bin/env bats
#
# Behavioral tests for the bootstrap IaC emission templates (epic #1602, child
# #1604) — the one-job `templates/iac/.github/workflows/kubernetes-ci.yml.tmpl`,
# `templates/iac/Makefile.tmpl`, `templates/iac/hooks/pre-push.tmpl` and the
# `gate:` line of `templates/common/.maintenance.yml.tmpl` — plus the §3l
# bootstrap rules and `branch-protection.sh --iac-only` that #1154 introduced.
#
# The gate's MECHANISM is `templates/iac/scripts/k8s-gate.zsh.tmpl`, executed with
# real tools by tests/kubernetes-ci-fixtures.bats (#1603). This file owns the
# WIRING around it: every artifact a consumer gets must CALL that one command,
# never re-implement a check. So the assertions are made on what bootstrap
# actually emits — each template is rendered through `render.zsh`, the renderer
# bootstrap runs, and the rendered file is what is read.
#
#   * STRUCTURE is read with `yq`, not grepped: a substring sweep cannot tell a
#     step's `run:` from the same literal inside a comment.
#   * The hook and the Makefile are EXECUTED where that is cheap — a hook git
#     silently skips, or a recipe make cannot parse, passes every grep.
#
# `yq` and `yamllint` are called unguarded (the tests/ops-api-fragment.bats
# precedent) and are declared dependencies in .github/workflows/script-tests.yml
# and tests/Dockerfile: an absent one should fail these red rather than silently
# skip the only coverage the templates have.

bats_require_minimum_version 1.5.0

load assertions

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  TMPL="$TEMPLATES/iac/.github/workflows/kubernetes-ci.yml.tmpl"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  STAMP="$REPO_ROOT/development/skills/bootstrap/scripts/stamp-marker.zsh"
  SKILL="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  REVIEWER="$REPO_ROOT/development/agents/bootstrap-idempotency-reviewer.md"
  PROTECT="$REPO_ROOT/development/skills/bootstrap/scripts/branch-protection.sh"
  # The six contexts `branch-protection.sh --iac-only` STILL requires. The
  # one-job workflow reports only `gate`, and SKILL.md and SETUP.md name only
  # `gate` since #1605; moving the script onto it is #1606, so ONLY the
  # branch-protection tests below still read this list (a test at the end of
  # this file keeps it that way).
  EXPECTED_JOBS="render schema lint policy config-scan argocd"
  SETUP="$TEMPLATES/common/SETUP.md.tmpl"
  HOOKS_SCRIPT="$REPO_ROOT/development/skills/bootstrap/scripts/install-iac-hooks.zsh"
  # every tool the gate script requires, with the env key its install step pins
  TOOL_PINS="helm:HELM_VERSION kustomize:KUSTOMIZE_VERSION kubeconform:KUBECONFORM_VERSION"
  TOOL_PINS="$TOOL_PINS kube-linter:KUBE_LINTER_VERSION kyverno:KYVERNO_VERSION"
  TOOL_PINS="$TOOL_PINS trivy:TRIVY_VERSION yq:YQ_VERSION"
  OUT="$BATS_TEST_TMPDIR/out"
  WF="$OUT/iac/.github/workflows/kubernetes-ci.yml"
  HOOK="$OUT/iac/hooks/pre-push"
  MAKEFILE="$OUT/iac/Makefile"
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$OUT" "$STUB_BIN"
}

# Render templates through the real renderer into $OUT with the flags §3l passes;
# further flags and template relpaths follow.
render_iac() {
  zsh "$RENDER" --templates "$TEMPLATES" --out "$OUT" --primary kubernetes --languages "" "$@"
}

# The index of the rendered gate job's step with the given name — printed once
# per match, and nothing at all when no step carries the name.
step_index() {
  yq -r ".jobs.gate.steps | to_entries[] | select(.value.name == \"$1\") | .key" "$WF"
}

# The §3l section of SKILL.md, whitespace-normalised and END-ANCHORED.
#
# A sed range whose end address stops matching prints to EOF, and `[ -n ]` still
# passes — so the haystack silently widens to include Step 5's IaC block, which
# itself names all six checks. Every §3l needle below would then pass with §3l
# deleted outright. The terminator is asserted by its caller for that reason.
iac_section() {
  sed -n '/^### 3l\. Infrastructure-as-code repos/,/^### /p' "$SKILL" | tr -s '[:space:]' ' '
}

# ---------------------------------------------------------------------------
# The workflow
# ---------------------------------------------------------------------------

@test "the template lives at the nested .github/workflows path (#1154)" {
  # mirrors every other workflow template's layout (templates/public/.github/…),
  # which keeps the rendered destination obvious and the file inside the `.tmpl`
  # tree renovate.json's customManager (`/\.tmpl$/`) watches for action pins
  [ -f "$TMPL" ]
  case "$TMPL" in
  */templates/iac/.github/workflows/kubernetes-ci.yml.tmpl) : ;;
  *) return 1 ;;
  esac
}

@test "the UNRENDERED template is valid YAML, strict-yamllint clean, and GATE_COMMAND is its one placeholder (#1604)" {
  # tests/iac-tools.zsh and tests/no-cluster-deploy.bats read the .tmpl itself
  # with yq, so the placeholder must sit where YAML cannot misread it: a bare
  # `run: {{GATE_COMMAND}}` is a flow MAPPING, inside a `run: |` block it is text.
  # -c explicitly: yamllint discovers .yamllint relative to the CWD, and without
  # it would silently fall back to the default ruleset
  run yq -o=json -I=0 '.' "$TMPL"
  [ "$status" -eq 0 ]
  [ -f "$REPO_ROOT/.yamllint" ]
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$TMPL"
  [ "$status" -eq 0 ]
  local placeholders
  placeholders="$(grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' "$TMPL" | LC_ALL=C sort -u)"
  [ "$placeholders" = '{{GATE_COMMAND}}' ]
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$TMPL")" = '{{GATE_COMMAND}}' ]
}

@test "the rendered workflow is ONE job, id gate, with no name, matrix, needs or artifact machinery (#1604)" {
  run render_iac iac/.github/workflows/kubernetes-ci.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.jobs | keys | join(" ")' "$WF")" = "gate" ]
  # GitHub reports the check under a job's `name:` when present and suffixes a
  # matrix leg, so either would change the reported context while `.jobs | keys`
  # still read `gate`
  [ "$(yq -r '.jobs.gate | has("name")' "$WF")" = "false" ]
  [ "$(yq -r '.jobs.gate | has("strategy")' "$WF")" = "false" ]
  [ "$(yq -r '.jobs.gate | has("needs")' "$WF")" = "false" ]
  [ "$(yq -r 'has("env")' "$WF")" = "false" ]
  local uses
  uses="$(yq -r '.jobs.gate.steps[].uses // ""' "$WF" | tr '\n' ' ')"
  # the positive control: the extraction reached the steps at all
  contains "$uses" 'actions/checkout@'
  lacks "$uses" 'upload-artifact'
  lacks "$uses" 'download-artifact'
  lacks "$uses" 'trivy-action'
  run -1 grep -q 'RENDER_DIR' "$WF"
}

@test "the rendered workflow triggers on pull_request with default activity types and no filter (#1604)" {
  run render_iac iac/.github/workflows/kubernetes-ci.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.on | keys | join(" ")' "$WF")" = "pull_request" ]
  # a bare `pull_request:` — no `types:`, `paths:` or `branches:` under it. Any of
  # them keeps the key while a PR the filter excludes never reports the one
  # requirable context, so branch protection would block it forever
  [ "$(yq -r '.on.pull_request | tag' "$WF")" = '!!null' ]
  [ "$(yq -r '.permissions | to_entries | map(.key + "=" + .value) | join(",")' "$WF")" = "contents=read" ]
}

@test "the gate job's LAST step runs the resolved gate command, make lint by default (#1604)" {
  run render_iac iac/.github/workflows/kubernetes-ci.yml.tmpl
  [ "$status" -eq 0 ]
  # the command is the step's WHOLE body: anything beside it would be a check CI
  # runs that the local gate does not
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$WF")" = "make lint" ]
}

@test "an explicit --gate-command lands verbatim in the workflow, the hook and .maintenance.yml (#1604)" {
  run render_iac --gate-command 'make a && make b' \
    iac/.github/workflows/kubernetes-ci.yml.tmpl iac/hooks/pre-push.tmpl common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.jobs.gate.steps[-1].run' "$WF")" = 'make a && make b' ]
  [ "$(sed -n 2p "$HOOK")" = 'make a && make b' ]
  [ "$(yq -r '.gate' "$OUT/common/.maintenance.yml")" = 'make a && make b' ]
  run -1 grep -q 'make lint' "$WF" "$HOOK" "$OUT/common/.maintenance.yml"
}

@test "zsh is installed before the gate command, and every gate tool at a step-level pin (#1604)" {
  run render_iac iac/.github/workflows/kubernetes-ci.yml.tmpl
  [ "$status" -eq 0 ]
  local last zsh_ix install pair tool key ix pin body url member args
  last="$(( $(yq -r '.jobs.gate.steps | length' "$WF") - 1 ))"
  # the gate script is `#!/usr/bin/env zsh`, and ubuntu-latest ships none
  zsh_ix="$(step_index 'install zsh')"
  [ -n "$zsh_ix" ]
  [ "$zsh_ix" -lt "$last" ]
  install="$(yq -r ".jobs.gate.steps[$zsh_ix].run" "$WF")"
  contains "$install" 'apt-get install'
  # the package named `zsh` itself — `zsh-common` ships no zsh binary
  printf '%s\n' "$install" | grep -qE '(^|[[:space:]])zsh([[:space:]]|$)'
  # the ONE directory every tool lands in reaches PATH before any install
  local path_ix path_run
  path_ix="$(step_index 'put the tool directory on PATH')"
  [ -n "$path_ix" ]
  path_run="$(yq -r ".jobs.gate.steps[$path_ix].run" "$WF")"
  contains "$path_run" 'mkdir -p "$RUNNER_TEMP/gate-bin"'
  contains "$path_run" 'echo "$RUNNER_TEMP/gate-bin" >> "$GITHUB_PATH"'
  # a curl that records its arguments and fails, so a step's body can be run to
  # learn the URL it really fetches without downloading anything
  args="$BATS_TEST_TMPDIR/curl-args"
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$CURL_ARGS"
exit 22
EOF
  chmod +x "$STUB_BIN/curl"
  for pair in $TOOL_PINS; do
    tool="${pair%%:*}"
    key="${pair#*:}"
    ix="$(step_index "install $tool")"
    # exactly ONE step by that name: the harness refuses a selector matching two
    [ "$(printf '%s\n' "$ix" | grep -c .)" -eq 1 ]
    [ "$path_ix" -lt "$ix" ]
    [ "$ix" -lt "$last" ]
    pin="$(yq -r ".jobs.gate.steps[$ix].env.$key" "$WF")"
    matches "$pin" '^[0-9]+\.[0-9]+\.[0-9]+$'
    # the pin is what the download interpolates — a version hardcoded in the URL
    # would leave the env key a decoration the harness still trusts
    body="$(yq -r ".jobs.gate.steps[$ix].run" "$WF")"
    contains "$body" "\${$key}"
    # the linux/amd64 release URL the runner can execute — the same one
    # tests/iac-tools.zsh downloads — and the member that lands in the directory
    # on PATH; each tool spells both its own way
    case "$tool" in
    helm) url="https://get.helm.sh/helm-v$pin-linux-amd64.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" --strip-components=1 linux-amd64/helm' ;;
    kustomize)
      url="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv$pin"
      url="$url/kustomize_v${pin}_linux_amd64.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" kustomize' ;;
    kubeconform)
      url="https://github.com/yannh/kubeconform/releases/download/v$pin/kubeconform-linux-amd64.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" kubeconform' ;;
    kube-linter)
      url="https://github.com/stackrox/kube-linter/releases/download/v$pin/kube-linter-linux.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" kube-linter' ;;
    kyverno)
      url="https://github.com/kyverno/kyverno/releases/download/v$pin/kyverno-cli_v${pin}_linux_x86_64.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" kyverno' ;;
    trivy)
      url="https://github.com/aquasecurity/trivy/releases/download/v$pin/trivy_${pin}_Linux-64bit.tar.gz"
      member='-C "$RUNNER_TEMP/gate-bin" trivy' ;;
    yq) url="https://github.com/mikefarah/yq/releases/download/v$pin/yq_linux_amd64"
      member='chmod +x "$RUNNER_TEMP/gate-bin/yq"'
      contains "$body" 'curl -sSfLo "$RUNNER_TEMP/gate-bin/yq"' ;;
    *) return 1 ;;
    esac
    # the URL is what the body FETCHES — host, tag and asset, with the pin
    # interpolated — so it is read from a run of the body, never matched as text
    rm -f "$args"
    run env "$key=$pin" RUNNER_TEMP="$BATS_TEST_TMPDIR" CURL_ARGS="$args" PATH="$STUB_BIN:$PATH" \
      bash -c "$body"
    [ "$status" -ne 0 ]
    [ "$(grep '^https://' "$args")" = "$url" ]
    # the member closes the body: a bare substring would also pass a suffixed
    # name such as `kyverno-cli`
    ends_with "$body" "$member"
  done
  # step-level, never job-level: tests/no-cluster-deploy.bats reads YQ_VERSION
  # from steps, and the harness's selectors are per step
  [ "$(yq -r '.jobs.gate | has("env")' "$WF")" = "false" ]
}

@test "the workflow's pins are the harness's pins, read from the rendered file (#1604)" {
  run render_iac iac/.github/workflows/kubernetes-ci.yml.tmpl
  [ "$status" -eq 0 ]
  local shipped rendered pair tool key want
  # the harness reads the SHIPPED template, a consumer runs the RENDERED file:
  # both must yield the same seven, and each must be the value its install step
  # carries — derived here independently of iac-tools.zsh's own selectors
  shipped="$(zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins)"
  rendered="$(zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins --template "$WF")"
  [ "$(printf '%s\n' "$shipped" | grep -c .)" -eq 7 ]
  [ "$shipped" = "$rendered" ]
  for pair in $TOOL_PINS; do
    tool="${pair%%:*}"
    key="${pair#*:}"
    want="$(yq -r ".jobs.gate.steps[] | select(.name == \"install $tool\") | .env.$key" "$WF")"
    [ -n "$want" ]
    [ "$want" != "null" ]
    printf '%s\n' "$shipped" | grep -qxF "$tool $want"
  done
}

@test "every action is pinned to a full commit SHA with a version comment (#1154, #1604)" {
  # the semgrep gate bootstrap installs in downstream repos BLOCKS mutable tags,
  # so a template floating on @v6 would ship consumers a workflow their own
  # quality gate flags on arrival. POSIX class, not `\s`: BSD grep reads `\s` as
  # a literal `s`.
  local lines line
  lines="$(grep -nE '^[[:space:]]*-?[[:space:]]*uses:' "$TMPL")"
  [ -n "$lines" ]
  while read -r line; do
    matches "$line" 'uses: [^@]+@[0-9a-f]{40} # '
  done <<< "$lines"
}

@test "every env var a run: step interpolates is declared on that step (#1154, #1604)" {
  # each install step's pin is read by the harness from THAT step's env, and a
  # reference the runner does not supply dies under `set -u` with "unbound
  # variable" — a required check that can never go green
  local n i script refs declared missing seen="" scanned=0
  n="$(yq -r '.jobs.gate.steps | length' "$TMPL")"
  for ((i = 0; i < n; i++)); do
    script="$(yq -r ".jobs.gate.steps[$i].run // \"\"" "$TMPL" | grep -vE '^[[:space:]]*#' || true)"
    [ -n "$script" ] || continue
    refs="$(printf '%s\n' "$script" | { grep -oE '\$\{?[A-Z_][A-Z0-9_]*\}?' || true; } \
      | tr -d '${}' | LC_ALL=C sort -u)"
    declared="$(yq -r ".jobs.gate.steps[$i].env // {} | keys | .[]" "$TMPL" | LC_ALL=C sort -u)"
    missing="$(LC_ALL=C comm -23 <(printf '%s\n' "$refs") <(printf '%s\n' "$declared") \
      | { grep -vE '^(RUNNER_TEMP|GITHUB_[A-Z_]*)?$' || true; })"
    [ -z "$missing" ] || {
      printf 'step %s: undeclared %s\n' "$i" "$missing" >&2
      return 1
    }
    seen="$seen $(echo $refs)"
    scanned=$((scanned + 1))
  done
  # POSITIVE CONTROL: an extraction that matched nothing satisfies every
  # emptiness check above, so each pin must actually have been seen
  local pair
  for pair in $TOOL_PINS; do
    contains "$seen" "${pair#*:}"
  done
  # COVERAGE CONTROL: every run: step was reached, the gate command's included
  [ "$scanned" -eq "$(yq -r '[.jobs.gate.steps[] | select(has("run"))] | length' "$TMPL")" ]
}

# ---------------------------------------------------------------------------
# The Makefile, the hook, .maintenance.yml
# ---------------------------------------------------------------------------

@test "the rendered Makefile's lint runs the gate script and hooks points git at hooks/ (#1604)" {
  run render_iac iac/Makefile.tmpl
  [ "$status" -eq 0 ]
  # make itself PARSES the file: a dry run of `lint` resolves to the gate script
  run make -n -f "$MAKEFILE" lint
  [ "$status" -eq 0 ]
  [ "$output" = 'zsh scripts/k8s-gate.zsh' ]
  # and `make hooks` really points git at the versioned hooks/ directory
  local repo="$BATS_TEST_TMPDIR/consumer"
  git init -q "$repo"
  # a real consumer HAS a hooks/ directory, so without `.PHONY` make would call
  # the target up to date and never run the recipe
  mkdir -p "$repo/hooks"
  run make -C "$repo" -f "$MAKEFILE" hooks
  [ "$status" -eq 0 ]
  [ "$(git -C "$repo" config core.hooksPath)" = "hooks" ]
  # and a real `make lint` fails when the gate fails: a recipe that ignores the
  # gate's status (a `-` prefix, `.IGNORE:`) prints the very same dry run
  mkdir -p "$repo/scripts"
  printf 'touch ran; exit 3\n' > "$repo/scripts/k8s-gate.zsh"
  run make -C "$repo" -f "$MAKEFILE" lint
  [ "$status" -ne 0 ]
  [ -f "$repo/ran" ]
}

@test "the rendered pre-push hook is exactly two lines, executable, and exits with the command's status (#1604)" {
  run render_iac iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  [ "$(cat "$HOOK")" = "$(printf '#!/bin/sh\nmake lint')" ]
  [ -x "$HOOK" ]
  rm -rf "$OUT"
  mkdir -p "$OUT"
  # no `exec`, so a compound command runs whole and its status is the hook's:
  # run BY PATH, so the shebang and the executable bit are what launch it
  run render_iac --gate-command 'true && exit 3' iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  run "$HOOK"
  [ "$status" -eq 3 ]
}

@test "git runs the hook on push: a red gate command blocks it, a green one lets it through (#1604)" {
  # the promise the hook exists for, end to end, with git itself deciding. A hook
  # git skipped — no exec bit, wrong path — passes every assertion above.
  local repo="$BATS_TEST_TMPDIR/consumer" remote="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$remote"
  git init -q "$repo"
  git -C "$repo" config core.hooksPath hooks
  git -C "$repo" -c user.name=ada -c user.email=ada@example.com commit -q --allow-empty -m init
  git -C "$repo" remote add origin "$remote"
  mkdir -p "$repo/hooks"
  run render_iac --gate-command 'exit 1' iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  cp -p "$HOOK" "$repo/hooks/pre-push"
  run git -C "$repo" push -q origin HEAD:refs/heads/main
  [ "$status" -ne 0 ]
  [ -z "$(git -C "$remote" for-each-ref)" ]
  run render_iac --gate-command 'true' iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  cp -p "$HOOK" "$repo/hooks/pre-push"
  run git -C "$repo" push -q origin HEAD:refs/heads/main
  [ "$status" -eq 0 ]
  [ -n "$(git -C "$remote" for-each-ref)" ]
}

@test "the hook and gate-script templates are committed executable, and render executable (#1604)" {
  local tpl
  for tpl in iac/hooks/pre-push.tmpl iac/scripts/k8s-gate.zsh.tmpl; do
    # the mode git RECORDS, which is what a clone of this repository gets — the
    # working-tree bit alone is a local accident
    run git -C "$REPO_ROOT" ls-files -s -- "development/skills/bootstrap/templates/$tpl"
    [ "$status" -eq 0 ]
    starts_with "$output" '100755 '
  done
  run render_iac iac/hooks/pre-push.tmpl iac/scripts/k8s-gate.zsh.tmpl
  [ "$status" -eq 0 ]
  [ -x "$HOOK" ]
  [ -x "$OUT/iac/scripts/k8s-gate.zsh" ]
}

@test "stamping the rendered hook keeps its shebang first and its executable bit (#1604)" {
  # Step 3.6 stamps hooks/pre-push. A marker inserted ABOVE the shebang, or a
  # rewrite that drops the mode, leaves a hook git cannot launch or skips
  run render_iac iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  run zsh "$STAMP" --repo "$OUT/iac" --target hooks/pre-push --template iac/hooks/pre-push.tmpl
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$HOOK")" = '#!/bin/sh' ]
  starts_with "$(sed -n 2p "$HOOK")" '# claude-bootstrap: rendered from iac/hooks/pre-push.tmpl'
  # the marker's comment lines sit between the shebang and the command, which
  # stays the hook's last line
  [ "$(tail -n 1 "$HOOK")" = 'make lint' ]
  [ -x "$HOOK" ]
}

@test "the rendered .maintenance.yml records the gate command beside primary: kubernetes (#1604)" {
  run render_iac common/.maintenance.yml.tmpl
  [ "$status" -eq 0 ]
  [ "$(yq -r '.primary' "$OUT/common/.maintenance.yml")" = "kubernetes" ]
  [ "$(yq -r '.gate' "$OUT/common/.maintenance.yml")" = "make lint" ]
}

# ---------------------------------------------------------------------------
# The idempotency rules that keep the four artifacts right on a re-run (§3.8)
# ---------------------------------------------------------------------------

@test "SKILL.md states the gate command's resolution, its block rule and the gate: keep-rule (#1604)" {
  local row bullet
  row="$(grep -F '| `{{GATE_COMMAND}}` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'the **recorded** `gate:` value'
  contains "$row" 'else `make lint`'
  row="$(grep -F '| `KUBERNETES` |' "$SKILL")"
  contains "$row" '`--primary kubernetes`'
  # END-ANCHORED by length: a range whose end address stopped matching would run
  # to EOF and let unrelated prose satisfy the needles
  [ "$(sed -n '/^- `\.maintenance\.yml` (render/,/^- `LICENSE`/p' "$SKILL" | wc -l | tr -d ' ')" -le 8 ]
  bullet="$(sed -n '/^- `\.maintenance\.yml` (render/,/^- `LICENSE`/p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$bullet" '**without** a `gate:` key gets the line appended'
  contains "$bullet" 'value is **left alone** byte-for-byte'
  contains "$bullet" 'is the `--gate-command` value'
  # State D's not-blind IaC set, the two present files it reconciles, and §3a's
  # pre-commit hold-out on the IaC path
  local skill
  skill="$(tr -s '[:space:]' ' ' < "$SKILL")"
  contains "$skill" '`scripts/k8s-gate.zsh`, `hooks/pre-push` or `Makefile`, they are there because'
  contains "$skill" 'Ask Q4 (IaC wording) **first** and render them only on the confirmed "none" answer; a language answer drops all of them from the gap-fill. Render the workflow and the hook with `--gate-command` resolved per the Step 3 placeholder table, and leave `Makefile` unstamped (Step 3.6).'
  contains "$skill" 'a `Makefile` already on disk goes to the idempotency reviewer against the rendered `iac/Makefile.tmpl` (its `lint`/`hooks` merge strategy) before the hook is written, or `make lint` has no target to run'
  contains "$skill" 'an existing `.maintenance.yml` gets §3a'"'"'s `gate:` rule — append `gate: <the value you passed to --gate-command>` when the key is absent, and leave a present value alone'
  contains "$skill" '**not on the §3l IaC path**, whose hook is the version-controlled `hooks/pre-push`'
}

@test "Step 3.6 stamps the gate script and the hook, and leaves the Makefile unstamped (#1604)" {
  local row
  row="$(grep -F '| `scripts/k8s-gate.zsh` |' "$SKILL")"
  contains "$row" '`iac/scripts/k8s-gate.zsh.tmpl`'
  row="$(grep -F '| `hooks/pre-push` |' "$SKILL")"
  contains "$row" '`iac/hooks/pre-push.tmpl`'
  # consumer-owned: a stamped Makefile would report drift on every edit
  run -1 grep -F '| `Makefile` |' "$SKILL"
  contains "$(tr -s '[:space:]' ' ' < "$SKILL")" 'the §3l IaC `Makefile`, the Approver policy'
}

@test "the idempotency reviewer overwrites the plugin-owned gate files and merges a Makefile (#1604)" {
  local overwrite merge
  overwrite="$(sed -n '/^### Recommend `overwrite` when/,/^### Recommend `merge` when/p' "$REVIEWER" \
    | tr -s '[:space:]' ' ')"
  merge="$(sed -n '/^### Recommend `merge` when/,/^### Recommend `delete` when/p' "$REVIEWER" \
    | tr -s '[:space:]' ' ')"
  ends_with "$overwrite" '### Recommend `merge` when '
  ends_with "$merge" '### Recommend `delete` when '
  contains "$overwrite" '`scripts/k8s-gate.zsh`'
  contains "$overwrite" '`hooks/pre-push`'
  contains "$overwrite" "never the user's work"
  contains "$overwrite" '`.github/workflows/kubernetes-ci.yml`, `scripts/k8s-gate.zsh` or `hooks/pre-push` carrying a `# claude-bootstrap: rendered from iac/` provenance marker'
  contains "$merge" "IaC path's \`Makefile\`"
  contains "$merge" 'append the `lint` and `hooks` targets when absent; touch no other target'
  contains "$merge" 'name `git config core.hooksPath hooks` in the Why line as the manual step'
  # the "will not do" exception that lets the overwrite rule above apply at all
  contains "$(tr -s '[:space:]' ' ' < "$REVIEWER")" 'or a plugin-owned IaC gate artifact (both above)'
}

# ---------------------------------------------------------------------------
# branch-protection.sh --iac-only
# ---------------------------------------------------------------------------

protection_stubs() {
  CURL_DATA="$BATS_TEST_TMPDIR/curl-data.txt"
  : > "$CURL_DATA"
  export CURL_DATA
  cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "repo view") echo "acme/gitops" ;;
  "auth token") echo "stub-token" ;;
esac
exit 0
EOF
  # records the PUT/PATCH payloads so the applied rule can be asserted rather
  # than inferred from the script's own log output
  cat > "$STUB_BIN/curl" <<'EOF'
#!/bin/sh
prev=""
for a in "$@"; do
  if [ "$prev" = "--data" ]; then
    # compacted to a single line: the PUT payload is multi-line JSON, so an
    # as-is append makes "the Nth payload" unreadable by line
    printf '%s' "$a" | jq -c . >> "$CURL_DATA" 2>/dev/null || printf '%s\n' "$a" >> "$CURL_DATA"
  fi
  prev="$a"
done
# parameterised: a stub that only ever
# returns 200 leaves the 403 fallback — the one arm that exits 0 WITHOUT
# applying the rule — completely unexercised
echo "${CURL_HTTP_STATUS:-200}"
exit 0
EOF
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/curl"
}

@test "branch-protection --iac-only requires the six kubernetes-ci checks and nothing else (#1154)" {
  # the point of the whole slice: a GitOps repo's branch protection can require
  # something that BUILDS. Requiring the language-app contexts instead would pin
  # every PR on checks no rendered workflow reports.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts expected
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  # EXACT equality, derived from the same list the template is checked against: a
  # substring sweep accepts a context renamed to `render-manifests`, which branch
  # protection would then require and no job would ever report
  expected="$(printf '%s\n' $EXPECTED_JOBS | LC_ALL=C sort | paste -sd, -)"
  [ "$contexts" = "$expected" ]
  lacks "$contexts" 'test-and-coverage'
  lacks "$contexts" 'sonarcloud'
  lacks "$contexts" 'license-fs'
}

@test "branch-protection --iac-only on a 403 prints the SIX contexts and exits 0 (#1154)" {
  # the only arm that exits 0 without applying the rule, and Step 5's IaC
  # checklist is keyed on it ("unless Step 4b hit its 403 fallback") — the suite
  # pinned that PROSE while nothing executed the branch. A regression that moved
  # the contexts rebuild after the PUT, or made this arm exit non-zero, would
  # keep every other test green while each no-admin IaC bootstrap either died
  # mid-run or told the user to hand-require the language-app set.
  protection_stubs
  CURL_HTTP_STATUS=403 run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  # a hand-applied rule is a legitimate outcome, so this must NOT be a failure
  [ "$status" -eq 0 ]
  contains "$output" '403'
  # ANCHOR on the fallback heredoc's own markers. The script prints
  # `Required checks:` plus the bulleted list UNCONDITIONALLY, before curl is
  # ever called, so a bare per-job needle over $output is green no matter what
  # the 403 arm does — delete the whole recipe and it would still pass. These
  # three strings exist only inside the heredoc.
  contains "$output" 'Required status checks:'
  contains "$output" 'Settings → Branches → Add rule'
  contains "$output" 'Allow auto-merge'
  # each job must appear TWICE — once in the pre-PUT list, once in the manual
  # recipe — so dropping the recipe's own enumeration reds this
  local job
  for job in $EXPECTED_JOBS; do
    [ "$(grep -c -- "• $job\$" <<< "$output")" -eq 2 ]
  done
  # the IaC set, not the language-app one — relaying the wrong bullets hands the
  # user a recipe for contexts their repo will never report
  lacks "$output" 'test-and-coverage'
  lacks "$output" 'sonarcloud'
}

@test "branch-protection --iac-only ignores every language-app context PRODUCER (#1154)" {
  # the flag guards three of them — the visibility case, the `image` context and
  # the CodeQL matrix — but a test passing --has-dockerfile false --has-codeql
  # false only discriminates the first. Hoisting either of the others outside the
  # guard would add contexts no kubernetes-ci job reports, and the six-name
  # equality above would never see it.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile true --has-ko true --has-codeql true \
    --codeql-languages "python javascript" --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  [ "$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | length')" -eq 6 ]
  lacks "$contexts" 'image'
  lacks "$contexts" 'analyze ('
}

@test "branch-protection --iac-only on the PRIVATE path drops Sonar and Trivy too (#1154)" {
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility private --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | sort | join(",")')"
  [ "$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | length')" -eq 6 ]
  lacks "$contexts" 'sonarqube'
  lacks "$contexts" 'trivy-fs'
}

@test "branch-protection with an explicit --iac-only false is the language path (#1154)" {
  # the arm Step 4b's invocation block actually renders on a language repo — the
  # other test omits the flag entirely, so a guard keying on the flag's PRESENCE
  # rather than its value would pass both
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'test-and-coverage'
  contains "$contexts" 'sonarcloud'
  lacks "$contexts" 'render'
  lacks "$contexts" 'config-scan'
}

@test "branch-protection rejects an --iac-only value that is neither true nor false (#1154)" {
  # unvalidated, `--iac-only True` silently takes the language-app path — the
  # exact permanent-`expected` failure the flag exists to prevent, with no
  # diagnostic. --visibility is validated for the same reason.
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only True --default-branch main
  [ "$status" -ne 0 ]
  contains "$output" '--iac-only must be true or false'
  [ ! -s "$CURL_DATA" ]
}

@test "branch-protection --iac-only still applies the rule AND the merge settings (#1154)" {
  # skipping the script wholesale on this path would leave the default branch
  # unprotected and — because allow_auto_merge lives here — put every IaC
  # bootstrap into Step 4e's "arming failed" branch
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false \
    --iac-only true --default-branch main
  [ "$status" -eq 0 ]
  local rule
  rule="$(head -1 "$CURL_DATA")"
  [ "$(jq -r '.required_linear_history' <<< "$rule")" = "true" ]
  [ "$(jq -r '.allow_force_pushes' <<< "$rule")" = "false" ]
  [ "$(jq -r '.allow_deletions' <<< "$rule")" = "false" ]
  [ "$(jq -r '.required_pull_request_reviews.required_approving_review_count' <<< "$rule")" -eq 1 ]
  contains "$(cat "$CURL_DATA")" '"allow_auto_merge":true'
  contains "$(cat "$CURL_DATA")" '"delete_branch_on_merge":true'
}

@test "branch-protection without --iac-only is unchanged (#1154)" {
  # the flag must be additive: every existing repo keeps the language-app set
  protection_stubs
  run env PATH="$STUB_BIN:$PATH" bash "$PROTECT" \
    --visibility public --has-dockerfile false --has-codeql false --default-branch main
  [ "$status" -eq 0 ]
  local contexts
  contexts="$(head -1 "$CURL_DATA" | jq -r '.required_status_checks.contexts | join(",")')"
  contains "$contexts" 'test-and-coverage'
  contains "$contexts" 'sonarcloud'
  lacks "$contexts" 'render'
  lacks "$contexts" 'config-scan'
}

# ---------------------------------------------------------------------------
# bootstrap SKILL.md — the rules that emit all of the above
# ---------------------------------------------------------------------------

@test "bootstrap's §3l emits the template and declares primary: kubernetes (#1154)" {
  # the template is inert unless bootstrap knows when to write it; §3l is the
  # only site that says so, and nothing mechanical would notice its deletion
  local section
  section="$(iac_section)"
  [ -n "$section" ]
  # END-ANCHOR: without it a stopped end address prints to EOF and every needle
  # below could be satisfied by Step 5's IaC block instead
  ends_with "$section" '### Idempotency rules (apply for every file write) '
  contains "$section" 'templates/iac/.github/workflows/kubernetes-ci.yml.tmpl'
  contains "$section" '`.github/workflows/kubernetes-ci.yml`'
  contains "$section" 'primary: kubernetes'
  # the template carries {{GATE_COMMAND}}: a static copy runs the literal as a command
  contains "$section" 'render it with `render.zsh --gate-command` resolved per the Step 3 placeholder table, never as a static copy'
  # the whole clause: a bare "language" needle is satisfied by prose that still
  # requires one, which is the acceptance criterion this section exists to meet
  contains "$section" 'Do **not** require an application language before bootstrapping'
  # RESOLVED, not detected: keyed on detection alone, a language the user names
  # in Q4 would not bind and a language repo would take the IaC path
  contains "$section" 'the resolved language set is empty'
  contains "$section" 'resolved meaning *after* Q4'
  # …and the NARROWING that detect-stack.sh implements: a detected language
  # takes the repo off this path whatever `.maintenance.yml` records, so the
  # record can veto but never grant. Unpinned, the mixed repo creeps back in and
  # every detection-keyed section fires for a pipeline this path never generates.
  contains "$section" 'does not override a detected'
  contains "$section" 'the **mixed repo**'
  contains "$section" '#1193'
  contains "$section" 'in the **negative** direction'
  contains "$section" 'any *other* value (a language, `claude-plugin`) means not this path'
  # the retired capability asserted GONE, so it cannot be silently reinstated
  lacks "$section" 'does not un-resolve it'
  # the conflict handling the {{PRIMARY}} row's parenthetical delegates here —
  # unpinned, that cross-reference could dangle while bootstrap silently
  # overwrote a recorded `primary: python` with `kubernetes`
  contains "$section" 'Surface that conflict rather than resolving it silently'
  contains "$section" 'never let Q4'
  contains "$section" 'the recorded value stands'
  # …and the rule's OPERATIVE CONSEQUENCE, not just its statement. The needles
  # above pin *that* a conflict is surfaced; this pins that the emission is
  # confined to this path. Drop the qualifier and the emission sentence reads
  # unconditionally — bootstrap would write `primary: kubernetes` over the
  # recorded `primary: python` it was just told to leave alone.
  contains "$section" 'and only here, never on the conflict path'
  # the charter boundary — bootstrap seeding policies would put the plugin in the
  # opinion business the whole design keeps it out of
  contains "$section" 'Do not create `policies/kyverno/`'
  # the exclusion, restated as ONE rule when case 1 was removed: a non-empty
  # resolved language set is decisive on its own, so the record cannot revive
  # the path. The retired two-case phrasing is asserted gone with it.
  contains "$section" 'the repo is not on this path, **whatever `.maintenance.yml` records**'
  contains "$section" 'the record vetoes, never grants'
  lacks "$section" 'When neither case above holds'
  # the exclusion's CONSEQUENCE, not only its condition. Pinning the condition
  # alone leaves the forbidden actions rewordable — a language repo could be
  # made to require six IaC contexts from a workflow this path never emitted,
  # which is the permanent-`expected` state --iac-only exists to prevent.
  contains "$section" 'do not emit this template, write `primary: kubernetes`, or'
  contains "$section" 'pass `--iac-only true`'
  # and the two-arm split itself: collapse it and the on-disk arm below (the
  # Known limitation) loses the branch it hangs off
  contains "$section" 'depends on whether'
  contains "$section" '`kubernetes-ci.yml` is already on disk'
  # the Known-limitation arm must carry the FULL guard inline — it is a
  # cross-reference target read standalone, and without the middle clause its
  # own condition describes the case-1 repo whose handling is the opposite
  # the Known-limitation arm, now stated without the retired middle clause
  contains "$section" 'since the record vetoes but never grants'
}

@test "bootstrap's §3l names the gate check and runs branch protection in IaC mode (#1154, #1605)" {
  # skipping branch-protection.sh entirely was the earlier design and it silently
  # dropped the merge settings auto-merge arming depends on; the retired
  # instruction is asserted gone so the flip cannot be reverted
  local section
  section="$(iac_section)"
  [ -n "$section" ]
  contains "$section" '**One requirable check — `gate`.**'
  contains "$section" 'for the single `gate` context above'
  lacks "$section" 'Six separately requirable checks'
  contains "$section" '--iac-only true'
  contains "$section" 'Never skip the script on this path'
  # the pointer at Step 4.5 — the step that would otherwise UNDO the rule three
  # steps later, and the one clause tying the two sites together
  contains "$section" 'do not let Step 4.5 undo it'
  lacks "$section" 'do not run Step 4b'
  # the emitted set, stated rather than left to inference — 3b/3c select by
  # visibility with no language condition, so nothing else stops a model
  # rendering a quality workflow whose sonarcloud job needs a job that does not exist
  # POLARITY, not tokens: `contains 'quality-public.yml'` alone is satisfied by
  # the exact opposite instruction ("emit quality-public.yml"), which is the
  # regression this test exists to catch
  contains "$section" 'It does **not** emit any of'
  contains "$section" 'a workflow GitHub refuses to run'
  contains "$section" 'quality-public.yml'
  contains "$section" 'needs: test-and-coverage'
  # §3l's own statement of the outgrown-repo limitation: the fresh-bootstrap arm
  # reads this copy, and without a needle it could be deleted while State D's
  # pointer at it survived
  contains "$section" 'Known limitation — a repo that outgrows this slice'
  contains "$section" 'more contradiction surface than protection'
  # the two artifact classes review found missing from the first draft
  contains "$section" 'codeql-noop.yml'
  contains "$section" 'infra/sonarqube'
}

@test "Step 4b passes --iac-only through to branch-protection.sh (#1154)" {
  # §3l's instruction is only executable if the invocation block carries the flag
  local block
  block="$(sed -n '/^### 4b\. Branch protection/,/^### 4b\.5/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED like iac_section: a renumbered `### 4b.5` would run the range to
  # EOF and silently widen the haystack
  ends_with "$block" '### 4b.5. Workflow labels (`blocked`) '
  # the VALUE and the condition, not just the flag name — the block could
  # otherwise document `--iac-only false` on the IaC path and still pass
  contains "$block" '--iac-only "<true on the §3l IaC path'
  contains "$block" 'it requires the `kubernetes-ci.yml` `gate` context **instead of**'
  # the no-other-primary qualifier the sibling sites carry. This is the site a
  # model reads when COMPOSING the invocation, so without it here the conflict
  # repo yields `--iac-only true` and requires six contexts from a workflow §3l
  # never rendered — every PR pinned on a permanent `expected`.
  contains "$block" 'no other `primary:` recorded'
  contains "$block" 'settles it `false` whatever the marker says'
  # RESOLVED, and the detected-language veto — the two halves of the narrowing
  contains "$block" 'empty RESOLVED language set (after Q4)'
  contains "$block" 'A detected language, or a recorded language'
}

@test "the --iac-only qualifier is stated identically at every restatement (#1154)" {
  # ONE rule, four sites: the value spec a model composes from, the script's own
  # header, the SETUP.md bullet the user reads, and Step 5's IaC preamble. Round
  # 8 reached State D but not these, which is how the sites drifted apart in the
  # first place — sweep the whole class rather than one instance per round.
  local protect setup step5
  # comment markers stripped BEFORE normalising: the header wraps mid-sentence,
  # so a `# ` lands inside every multi-line needle and no prose assertion could
  # ever match — the shape that makes a "pinned" rule silently unpinned
  protect="$(sed -E 's/^[[:space:]]*#[[:space:]]?//' "$PROTECT" | tr -s '[:space:]' ' ')"
  contains "$protect" 'no other `primary:` recorded'
  contains "$protect" 'settles it false whatever the marker says'
  setup="$(tr -s '[:space:]' ' ' \
    < "$REPO_ROOT/development/skills/bootstrap/templates/common/SETUP.md.tmpl")"
  contains "$setup" 'no application language and no other `primary:` recorded'
  # …and the context NAME. A rename of the workflow's job would otherwise leave
  # SETUP.md handing a no-admin user (the 403 path) a recipe for a context no
  # workflow reports — and the retired six-name list is asserted gone (#1605)
  contains "$setup" '`branch-protection.sh --iac-only true`): `gate`. This single context **replaces**'
  lacks "$setup" '`render`, `schema`, `lint`, `policy`, `config-scan`, `argocd`'
  step5="$(sed -n '/^For the \*\*IaC path\*\*/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$step5" 'no other `primary:` recorded'
}

@test "Step 3.6 stamps kubernetes-ci.yml with the template the drift detector expects (#1154)" {
  # the PRODUCER half of the provenance coupling. tests/template-drift-fixes.bats
  # pins the consumer (the `tracked` entry in detect-template-drift.zsh); this
  # pins the stamp that feeds it. Delete or mistype this row and every IaC
  # bootstrap ships an unstamped kubernetes-ci.yml, so the tracked entry is fed
  # a file with no marker forever. §3l names the template for the RENDER, never
  # for the STAMP, so this row is the only site that states the pairing.
  local row
  row="$(grep -F '| `.github/workflows/kubernetes-ci.yml` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" '`iac/.github/workflows/kubernetes-ci.yml.tmpl`'
}

@test "Step 5's IaC checklist exists and states what the path did NOT generate (#1154)" {
  # §3l delegates to it; without the block the user is pointed at a checklist
  # item that does not exist
  local block
  block="$(sed -n '/^For the \*\*IaC path\*\*/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED like every sibling section test: a renamed terminating heading
  # runs the range to EOF, and the bare-token needles this test used to carry
  # (`render` matches "rendered", `lint` matches "yamllint", `policy` matches
  # "approver-policy") would then be satisfied by unrelated prose with the block
  # deleted outright
  ends_with "$block" '## Important Rules '
  # the LIST as written, not the bare names
  contains "$block" 'The required `gate` check shows as "expected" in Settings'
  contains "$block" 'no CodeQL'
  # the local gate is the hook's command, and a failed wiring is an outstanding item
  contains "$block" 'The local gate is `make lint`, the same command CI'"'"'s `gate` runs'
  contains "$block" '(unless Step 4a'"'"'s install-iac-hooks.zsh ran and exited 0, or found the hook already wired) The pre-push hook is NOT wired: run `make hooks`'
  # a hook an earlier run wired stays wired when Step 4a skips the script
  contains "$block" '(only when Step 4a found core.hooksPath already `hooks` and the gate failing) The pre-push hook IS wired and rejects every push until the gate command passes in this clone.'
  # the confirmed empty repo is asked again until a marker lands (#1605)
  contains "$block" 'every bootstrap re-run asks Q4 and the empty-repo confirmation again'
  # the 403 caveat: branch-protection.sh degrades to printed instructions and
  # exits 0, so an unconditional "not outstanding" claim leaves a no-admin repo
  # unprotected with no TODO
  contains "$block" 'unless Step 4b hit its 403 fallback'
  # the Dockerfile case the Step 2 IaC plan variant delegates here
  contains "$block" 'That image is NOT scanned in CI'
  # the re-run promise, which §3l case 1 makes FALSE: every §3l bootstrap records
  # `primary: kubernetes`, and case 1 honours that record over any language
  # detected later — so "add a language and re-run" picks up nothing. The retired
  # wording is asserted GONE, not merely replaced, since both could coexist.
  # true again under the narrowing: a detected language takes the repo off this
  # path, so a re-run DOES pick the language gates up — but say what it costs
  contains "$block" 'Add a language later and re-run bootstrap'
  contains "$block" 'takes the repo off this path'
  contains "$block" 'REPLACE the `gate` context'
}

@test "Step 4.5 skips the per-path automation that would UNDO --iac-only (#1154)" {
  # the highest-leverage prose gap in the change: automate-public.sh /
  # automate-private.sh re-invoke branch-protection.sh WITHOUT the flag, and
  # that PUT *replaces* the rule — so deleting this block leaves every IaC
  # bootstrap ending with the language-app contexts required again, three steps
  # after the code this suite otherwise covers.
  local block
  block="$(sed -n '/^### Per-path automation/,/^## Step 5/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  ends_with "$block" '## Step 5: Print the Manual-Setup Checklist '
  contains "$block" 'The §3l IaC path skips this section entirely'
  contains "$block" 'automate-public.sh'
  contains "$block" 'without `--iac-only`'
  contains "$block" 'run no `automate-*.sh`'
  # the scope of the skip, or a model cannot tell whether the preflight runs
  contains "$block" 'Scope: this section only'
  # the hardcoded --has-codeql "true" contradicted §3l, which emits no codeql.yml
  lacks "$block" '--has-codeql "true"'
}

@test "Q4 offers the IaC answer, and without the marker asks the empty-repo confirmation (#1154, #1605)" {
  # the only door into §3l. Delete the positive half and no question ever
  # produces the empty resolved language set the path keys on; delete the
  # confirmation's outcomes and a language-less repo with no marker is either
  # refused outright or bootstrapped without anyone having confirmed it.
  local row
  row="$(grep -F '| **Q4: Languages** |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'none — this is a GitOps/IaC repo'
  contains "$row" '**"None" is a valid answer for an IaC repo**'
  contains "$row" 'takes §3l, not a halt'
  # no marker: the confirmation and all three of its outcomes (#1605)
  contains "$row" '**"None" with `is_kubernetes=false`** asks the **empty-repo confirmation** instead of halting'
  contains "$row" '**confirmed** → §3l, and `primary: kubernetes` is written'
  contains "$row" '**declined** → halt'
  contains "$row" '**another `primary:` already recorded** in `.maintenance.yml` → §3l'"'"'s conflict branch — the confirmation is never granted over a recorded primary'
  # the retired unconditional refusal, asserted gone
  lacks "$row" 'is *not*: explain that only a repo carrying the kubernetes topic marker can bootstrap language-free'
  # …and a recorded `primary: kubernetes` must NOT skip the question: the record
  # vetoes this path but never grants it, so skipping would resolve a mixed repo
  # onto the IaC path without ever asking (#1193)
  contains "$row" 'does **not** skip it'
  lacks "$row" 'Skip it entirely when'
  # RESOLVED, the rule §3l and the {{PRIMARY}} table both depend on
  contains "$row" 'resolves the language set'
}

@test "Step 1's State-D gap-fill resolves the IaC condition before branch protection (#1154)" {
  # the re-bootstrap mirror of the Step 4.5 guard, and previously the one prose
  # site of this change with zero coverage. Deleting its branch-protection rule
  # reproduces the same unflagged PUT — six live contexts swapped for language-app
  # contexts nothing reports — just on the re-bootstrap path.
  local block
  # the end address must FOLLOW the start: `#### State D` sits ABOVE this
  # blockquote and occurs once, so using it printed to EOF — and two of the
  # needles below are satisfied by §3l and Step 4 inside that widened haystack,
  # which would have let the very instruction this test guards be deleted green
  # terminated on the first bullet AFTER the blockquote, not on a heading 250
  # lines further down: a wider haystack lets a needle be satisfied by unrelated
  # prose, which is how the earlier run-to-EOF version could not discriminate
  block="$(sed -n '/^   > \*\*The IaC set is NOT blind-renderable/,/^   - `branch_protection.state == "missing"`/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  ends_with "$block" '- `branch_protection.state == "missing"` → offer "Apply branch protection '
  # NOT the sed start address (that literal is in the haystack by construction and
  # could not fail) — the paragraph's substantive rules
  contains "$block" 'render it only on the confirmed "none" answer'
  contains "$block" 'Rendering it blind would commit the §3l shape'
  contains "$block" 'ask Q4 (IaC wording) **first**'
  # the condition, with the qualifier's binding made explicit
  contains "$block" '`kubernetes-ci.yml` is present **AND**'
  # …and the MARKER as the condition, not the rendered workflow alone (#1432).
  # The workflow's presence is evidence the repo already took the §3l path; the
  # rule detect-stack.sh and §3l actually state keys on the marker, and this
  # site is swept for that clause by tests/iac-selection-rule.bats.
  contains "$block" 'the repo carries the **kubernetes topic marker** (or, marker-less, its Q4'
  contains "$block" 'empty-repo confirmation was accepted — §3l), so `kubernetes-ci.yml` is present **AND**'
  contains "$block" 'a recorded `primary: kubernetes` grants nothing on its own'
  # RESOLVED, not merely detected — and the ORDERING that makes it achievable.
  # This tree is ordered and step 3 runs before Q4 is asked in step 6, so keying
  # on detected languages PUTs the six IaC contexts and only then lets the user
  # name a language: a language repo whose rule requires none of its own checks.
  contains "$block" 'the **resolved** language set is empty'
  contains "$block" '**Resolved means after Q4**'
  contains "$block" 'ask Q4 (IaC wording) BEFORE invoking the script'
  contains "$block" 'A language answer settles `--iac-only false`'
  lacks "$block" 'no language is detected **AND**'
  # the third precedence arm, which the condition previously dropped
  contains "$block" 'no other `primary:` is recorded'
  # the block's OWN clause, not the bare flag — that occurs at five other lines
  contains "$block" 'invoke `branch-protection.sh` with **`--iac-only true`**'
  # and the genuinely-mixed case, which §3l excludes rather than claims
  # needles kept WITHIN a source line: the block is a markdown blockquote, so
  # whitespace-normalising leaves the `>` markers in place and any needle
  # spanning a line break would never match
  # a detected language takes the repo OFF this path whatever the record says —
  # the record vetoes but never grants. The repo that has genuinely outgrown the
  # slice is DELEGATED to §3l's Known limitation rather than given a special case
  # here, so the two cannot drift apart, and the mixed repo proper is #1193.
  # Needles kept WITHIN a source line — this is a markdown blockquote, so
  # whitespace-normalising leaves the `>` markers between wrapped lines.
  contains "$block" 'takes the repo OFF this path'
  contains "$block" 'can only veto, never grant'
  contains "$block" 'has outgrown this slice'
  contains "$block" 'adds no'
  # the retired grant-arm asserted GONE, so the mixed repo cannot creep back
  lacks "$block" 'PLUS a language now detected is still the'
}

@test "the {{PRIMARY}} table resolves the zero-language kubernetes case to kubernetes (#1154)" {
  # without the branch the placeholder cannot resolve to `kubernetes` however
  # clearly §3l states the rule — and the RESULT is the half a needle on
  # `is_kubernetes` alone would not pin
  local row
  row="$(grep -F '| `{{PRIMARY}}` |' "$SKILL")"
  [ -n "$row" ]
  contains "$row" 'is_kubernetes'
  # branch (2)'s target, now carrying its no-conflicting-primary qualifier
  contains "$row" 'records no other `primary:`'
  contains "$row" '→ `kubernetes`'
  contains "$row" 'Resolved, not detected'
  # branch (1) is UNQUALIFIED: a detected language wins over the marker whatever
  # the record says, which is the narrowing detect-stack.sh implements. The
  # retired grant-branch is asserted gone so it cannot be silently reinstated —
  # it is what made every detection-keyed section fire on a mixed repo (#1193).
  contains "$row" 'a detected language takes precedence over the kubernetes marker'
  contains "$row" '#1193'
  lacks "$row" 'whatever languages detection found'
  # ORDERING: branch (2) must follow the single-language branch, or a language
  # repo carrying manifests would be hijacked onto the IaC path
  matches "$row" '\(1\).*exactly one language.*\(2\).*is_kubernetes.*\(3\)'
}

@test "the decision-tree post-condition admits the IaC path's empty language list (#1154)" {
  # the gate that would otherwise halt the run before Step 3 ever reaches §3l
  local block
  block="$(sed -n '/^### After the decision tree/,/^## Step 2/p' "$SKILL" | tr -s '[:space:]' ' ')"
  [ -n "$block" ]
  # END-ANCHORED: this is the one range in the file with no sibling test pinning
  # the same addresses, so a renumbered `## Step 2` would print to EOF and leave
  # every needle below judging the rest of SKILL.md
  ends_with "$block" '## Step 2: Show the Plan and Get Confirmation '
  lacks "$block" '- A non-empty languages list.'
  contains "$block" 'There an empty list is the answer, not a missing value'
  contains "$block" 'halting there would make §3l unreachable'
}

@test "this suite's own trees are listed in the PR path filter (#1154)" {
  # a tree a suite READS but the filter does not LIST runs no bats leg at PR
  # time — the defect tests/kubernetes-plugin-skeleton.bats already polices for
  # its own trees
  local wf
  wf="$REPO_ROOT/.github/workflows/script-tests.yml"
  [ -f "$wf" ]
  contains "$(cat "$wf")" "'development/skills/bootstrap/templates/**'"
  contains "$(cat "$wf")" "'development/skills/**/SKILL.md'"
  # (the "declared on both legs" claim is made by the SCOPED assertions below.
  # A file-wide `contains 'yamllint'` was satisfied by this workflow's own
  # explanatory comment block — and by tests/Dockerfile's — so it could never
  # have caught a package being dropped: the bare-token-satisfied-by-prose
  # failure this suite names as its concern.)
  # yq must come from mikefarah, never Debian's python-yq: the two are different
  # query languages, and under python-yq `on:` parses as the boolean true and
  # `-o=json` is rejected — so the same assertions would mean different things on
  # the two CI legs. Pinned by URL rather than left to the image's PATH order.
  contains "$(cat "$wf")" 'mikefarah/yq/releases/download'
  contains "$(cat "$REPO_ROOT/tests/Dockerfile")" 'mikefarah/yq/releases/download'
  # whitespace-normalised, because both install lists are written across
  # CONTINUATION lines — a per-line grep anchored on `sudo apt-get install`
  # could never match a re-added `yq` and would pass forever. `[[:space:]]`,
  # never `\s`: BSD grep reads the latter as a literal `s`.
  local apt_pkgs docker_pkgs
  # scoped to the apt PACKAGE LIST — brew's `yq` IS mikefarah's, so a
  # file-wide needle would flag the correct macOS line. Cut at the first `#`
  # (the comment explaining the exclusion) and, for the Dockerfile, at `&&`.
  apt_pkgs="$(tr -s '[:space:]' ' ' < "$wf")"
  apt_pkgs="${apt_pkgs#*apt-get install}"
  apt_pkgs="${apt_pkgs%%#*}"
  [ -n "$apt_pkgs" ]
  contains "$apt_pkgs" ' yamllint'
  lacks "$apt_pkgs" ' yq '
  docker_pkgs="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/tests/Dockerfile")"
  docker_pkgs="${docker_pkgs#*apt-get install}"
  docker_pkgs="${docker_pkgs%%&&*}"
  [ -n "$docker_pkgs" ]
  contains "$docker_pkgs" ' yamllint'
  lacks "$docker_pkgs" ' yq '
  # the macOS leg, scoped the same way — and it is this repo's PRIMARY platform,
  # so leaving it to a file-wide needle meant dropping yamllint or yq from
  # `brew install` kept this test green while the macOS bats leg lost the only
  # tools bootstrap-iac-pipeline.bats calls unguarded
  local brew_pkgs
  brew_pkgs="$(tr -s '[:space:]' ' ' < "$wf")"
  brew_pkgs="${brew_pkgs#*brew install}"
  brew_pkgs="${brew_pkgs%%#*}"
  [ -n "$brew_pkgs" ]
  contains "$brew_pkgs" ' yamllint'
  contains "$brew_pkgs" ' yq'
}

@test "the yq on PATH is mikefarah's, the dialect every structural assertion assumes (#1154)" {
  # one legible failure instead of twenty confusing ones: python-yq would red the
  # trigger test (PyYAML resolves `on:` to true) and the argocd tests (`-o=json`
  # is not its flag), with nothing saying why
  run yq --version
  [ "$status" -eq 0 ]
  # BOTH accepted spellings, matching tests/iac-tools.zsh's probe exactly. The
  # `mikefarah` URL only appears in ~v4.24 and later; older 4.x prints a bare
  # `yq version 4.20.2` and speaks the same dialect. Keying on the URL alone
  # would red this suite on a binary the resolver deliberately accepts — telling
  # the developer to replace something that works.
  matches "$output" '([Mm]ikefarah|^yq version 4\.)'
}

# ---------------------------------------------------------------------------
# The §3l skill flow on the gate model (#1605)
# ---------------------------------------------------------------------------

@test "§3l emits the gate artifacts, holds out .pre-commit-config.yaml, and handles the confirmed empty repo (#1605)" {
  local section
  section="$(iac_section)"
  ends_with "$section" '### Idempotency rules (apply for every file write) '
  # the emitted enumeration as ONE list: four names scattered through §3l would
  # pass while the list itself still named only the workflow
  contains "$section" 'plus the gate artifacts — `.github/workflows/kubernetes-ci.yml`, `scripts/k8s-gate.zsh`, `hooks/pre-push` and `Makefile` — plus the §3h'
  # …each rendered from its own template
  contains "$section" '`templates/iac/scripts/k8s-gate.zsh.tmpl` as `scripts/k8s-gate.zsh`'
  contains "$section" '`templates/iac/hooks/pre-push.tmpl` as `hooks/pre-push`'
  contains "$section" '`templates/iac/Makefile.tmpl` as `Makefile`'
  # the whole pre-commit config is a not-emitted ROW, not a clause of another row
  contains "$section" '| `.pre-commit-config.yaml` — the whole file, not only its per-language hook blocks |'
  # SETUP.md.tmpl is unchanged, so this row IS the fix for its §1/§6 pre-commit steps
  contains "$section" '| `SETUP.md`'"'"'s §3h section and its §1/§6 pre-commit steps'
  contains "$section" 'SETUP.md'"'"'s §1 `pre-commit` install lines, its §1 cross-language `gitleaks`/`semgrep` installs, its §6 all-files `pre-commit` step and its §6 SonarCloud/Snyk first-run note with them, since this path emits neither a pre-commit config nor a quality workflow'
  contains "$section" '**Local tools are Homebrew-current; CI and the harness run the pins.**'
  # the confirmed empty repo: the exception, what the skill leaves out itself,
  # the recorded-primary limit and the re-ask
  contains "$section" 'confirmed Q4'"'"'s empty-repo question'
  contains "$section" '**the skill renders the IaC set itself**'
  contains "$section" '**leaves out every row of the not-emitted table below** — on a marker-less repo `detect-stack.sh` holds none of them out, so `quality-*.yml`, `codeql.yml`, `.pre-commit-config.yaml`, `scripts/check-no-cluster-deploy.zsh` and `.github/workflows/no-cluster-deploy.yml` can all reach `missing_artifacts`'
  contains "$section" 'the confirmation is never granted over it'
  contains "$section" '**until a marker exists, every re-run asks Q4 and the confirmation again**'
}

@test "§3l's final-report instruction names the gate command, the gate context and the skipped artifacts (#1605)" {
  local section
  section="$(iac_section)"
  ends_with "$section" '### Idempotency rules (apply for every file write) '
  contains "$section" '**The final report names** the gate command (the resolved `{{GATE_COMMAND}}`, `make lint` unless one is recorded), the single required `gate` context, and every artifact above that was skipped and why'
  contains "$section" 'every artifact above that was skipped and why, on a confirmed empty repo too'
  contains "$section" 'Unless Step 4a'"'"'s `install-iac-hooks.zsh` ran and exited 0, it also says the pre-push hook is **not wired** and names `make hooks` as the remedy'
}

# Step 4a's IaC branch, whitespace-normalised and end-anchored by its caller.
step4a_iac() {
  sed -n '/^\*\*The §3l IaC path wires its hook differently\.\*\*/,/^\*\*Every other path:\*\*/p' "$SKILL" \
    | tr -s '[:space:]' ' '
}

@test "Step 4a's IaC branch wires install-iac-hooks.zsh, offers no pre-commit, and continues on failure (#1605)" {
  local block step4a
  block="$(step4a_iac)"
  ends_with "$block" '**Every other path:** if `pre-commit` is installed on the user'"'"'s machine, run: '
  # the branch belongs to 4a, not to some later section that reuses the words
  step4a="$(sed -n '/^### 4a\. Install git hooks/,/^### 4a\.5\./p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$step4a" '**The §3l IaC path wires its hook differently.**'
  contains "$block" '"<skill-base-dir>/scripts/install-iac-hooks.zsh" --repo "<repo-path>"'
  # wired only once the gate itself passes, or the hook rejects Step 4e's bot push —
  # the whole precondition, skip clause included
  contains "$block" '**Run it only once the gate already passes here:** run the resolved gate command (`make lint` unless `.maintenance.yml` records another) in `<repo-path>` first. The hook runs that same command on every push, so wiring it while the gate fails — a gate tool not yet installed (Step 4.5 installs them only after Step 4e'"'"'s push), a `yq` the gate refuses, or findings in manifests the repo already has — would reject Step 4e'"'"'s bot push. When it fails, skip the script and show the gate'"'"'s first failure; the final report then names `make hooks` for once the gate command passes — or, when the `Makefile` merge was declined and it has no `hooks` target, merging `iac/Makefile.tmpl`'"'"'s `lint` and `hooks` targets into it first.'
  lacks "$block" 'install-precommit-hooks'
  lacks "$block" 'brew install pre-commit'
  contains "$block" '**On a non-zero exit, surface its stderr and continue**'
  contains "$block" 'the final report says the pre-push hook is not wired and names `make hooks` as the remedy'
  # exit 5 is a missing hooks target — a declined Makefile merge — which `make hooks` cannot fix
  contains "$block" 'or, on exit 5 for a missing `hooks` target (a declined `Makefile` merge), merging `iac/Makefile.tmpl`'"'"'s `lint` and `hooks` targets first'
  # skipping the script does not unwire a hook an earlier run wired
  contains "$block" 'skipping the script leaves that hook in place: the final report then says the hook **is wired** and rejects every push, Step 4e'"'"'s included, until the gate command passes, instead of naming `make hooks`.'
  contains "$block" '**Step 4a.5 does not run on this path.**'
  # the language path keeps its installer, so the lacks above are not vacuous
  contains "$step4a" '"<skill-base-dir>/scripts/install-precommit-hooks.zsh"'
}

@test "Step 4.5 runs the preflight with --iac-only true on the IaC path (#1605)" {
  local block quote
  block="$(sed -n '/^### Preflight check/,/^### Per-path automation/p' "$SKILL" | tr -s '[:space:]' ' ')"
  ends_with "$block" '### Per-path automation '
  contains "$block" '--iac-only "<true on the §3l IaC path, else false>"'
  contains "$block" 'With `--iac-only true` the list is `gh`, `jq`, `git` and the gate'"'"'s tools'
  quote="$(sed -n '/^> \*\*The §3l IaC path skips this section entirely/,/^\*\*Public path:\*\*/p' "$SKILL" \
    | tr -s '[:space:]' ' ')"
  ends_with "$quote" '**Public path:** '
  contains "$quote" 'still runs, **with `--iac-only true`**'
}

@test "no IaC-path section describes the pre-commit framework as installed or enforced (#1605)" {
  # the phrasings the retired text used to promise the framework on this path
  local -a needles=(
    'install-precommit-hooks' 'brew install pre-commit' 'pre-commit install'
    'pre-commit run' 'pre-commit is enforced' '`pre-commit` runs locally'
    'the Step 4a hooks' 'pre-commit` rescue' '`pre-commit` like'
    'jq, pre-commit' 'the pre-commit rescue' 'its install rescue' 'run 4a/4a.5 by hand'
  )
  local -a sections=()
  sections+=("$(iac_section)")
  sections+=("$(sed -n '/^   > \*\*The IaC set is NOT blind-renderable/,/^   - `branch_protection.state == "missing"`/p' "$SKILL" | tr -s '[:space:]' ' ')")
  sections+=("$(sed -n '/^   \*\*The IaC set (#1154, #1604) is the third not-blind set\.\*\*/,/^   \*\*The ops-major migration/p' "$SKILL" | tr -s '[:space:]' ' ')")
  sections+=("$(sed -n '/^\*\*On the §3l IaC path the plan takes a different shape\*\*/,/^A GitOps repo may still carry a Dockerfile/p' "$SKILL" | tr -s '[:space:]' ' ')")
  sections+=("$(step4a_iac)")
  sections+=("$(sed -n '/^> \*\*The §3l IaC path skips this section entirely/,/^\*\*Public path:\*\*/p' "$SKILL" | tr -s '[:space:]' ' ')")
  sections+=("$(sed -n '/^For the \*\*IaC path\*\*/,/^## /p' "$SKILL" | tr -s '[:space:]' ' ')")
  # END-ANCHORS, one per section, so no range silently ran to EOF — which would
  # judge the rest of SKILL.md (where the language path's pre-commit prose
  # legitimately lives) and red, or be emptied and pass nothing
  ends_with "${sections[0]}" '### Idempotency rules (apply for every file write) '
  ends_with "${sections[1]}" '- `branch_protection.state == "missing"` → offer "Apply branch protection '
  starts_with "${sections[2]}" ' **The IaC set (#1154, #1604) is the third not-blind set.**'
  ends_with "${sections[2]}" '**The ops-major migration (#1330) is the fourth not-blind set.** When '
  # the marker-less, language-less repo asks Q4 BEFORE rendering, then reaches step 3
  contains "${sections[2]}" 'So when `is_kubernetes` is `false` and `languages` is empty, ask Q4 and its empty-repo confirmation **here, before rendering anything** from `missing_artifacts`: on a confirmed "none", drop every §3l not-emitted artifact from the list, render the IaC set, and then take step 3'"'"'s `github_state` gap-fill with `--iac-only true`, which the drops have made reachable; on a language answer, render the list as usual; on a declined confirmation, render nothing and halt as Q4 directs.'
  ends_with "${sections[3]}" 'A GitOps repo may still carry a Dockerfile (a tooling image, say). On this path '
  contains "${sections[3]}" 'Setup automation: preflight only (--iac-only true) — verifies and batch-installs gh, jq, git and the gate'"'"'s tools'
  ends_with "${sections[4]}" '**Every other path:** if `pre-commit` is installed on the user'"'"'s machine, run: '
  ends_with "${sections[5]}" '**Public path:** '
  ends_with "${sections[6]}" '## Important Rules '
  local s n
  for s in "${sections[@]}"; do
    for n in "${needles[@]}"; do
      lacks "$s" "$n"
    done
  done
  # NON-VACUITY: the needles are live phrasings — the language path's 4a carries
  # two of them, so a needle list that matched nothing anywhere would red here
  local lang
  lang="$(sed -n '/^\*\*Every other path:\*\*/,/^### 4a\.5\./p' "$SKILL" | tr -s '[:space:]' ' ')"
  contains "$lang" 'install-precommit-hooks'
  contains "$lang" 'brew install pre-commit'
}

@test "SKILL.md and SETUP.md.tmpl name the single gate context, never six IaC contexts (#1605)" {
  local -a retired=(
    'Six separately requirable checks' 'six required' 'six IaC contexts'
    'six live IaC contexts' 'six `kubernetes-ci.yml`' '`kubernetes-ci.yml`'"'"'s six'
    'six-context' 'six jobs'
  )
  local skill setup n
  skill="$(tr -s '[:space:]' ' ' < "$SKILL")"
  setup="$(tr -s '[:space:]' ' ' < "$SETUP")"
  for n in "${retired[@]}"; do
    lacks "$skill" "$n"
    lacks "$setup" "$n"
  done
  # …and every IaC required-context statement names `gate`
  contains "$skill" '**One requirable check — `gate`.**'
  contains "$skill" 'single `gate` context `kubernetes-ci.yml` reports, never the language-app set'
  contains "$skill" 'for the single `gate` context above'
  contains "$skill" 'replaces the live `gate` context with the language-app set'
  contains "$skill" 'it requires the `kubernetes-ci.yml` `gate` context **instead of**'
  contains "$skill" 'the single `kubernetes-ci.yml` context, `gate`, which is also what'
  contains "$skill" 'its one job, `gate`, is a *required context* with no `-noop` companion'
  contains "$skill" 'Step 4b already required the `kubernetes-ci.yml` `gate` check'
  contains "$skill" 'the `--iac-only` checks array (the single `gate` context)'
  contains "$setup" 'your required check is `kubernetes-ci.yml`'"'"'s single `gate`'
  contains "$setup" 'its own required check is `kubernetes-ci.yml`'"'"'s `gate` job instead'
  contains "$setup" '`branch-protection.sh --iac-only true`): `gate`.'
}

@test "EXPECTED_JOBS is read only by the branch-protection.sh --iac-only tests (#1605)" {
  # SKILL.md and SETUP.md moved to `gate`; only the script still requires six
  # (#1606). The regex is bracketed so this test's own line does not match it.
  local users t
  users="$(awk '/^@test /{ name = $0 } /[$]EXPECTED_JOB[S]/ && name != "" { print name }' "$BATS_TEST_FILENAME" | sort -u)"
  [ -n "$users" ]
  while IFS= read -r t; do
    starts_with "$t" '@test "branch-protection'
  done <<< "$users"
}

# ---------------------------------------------------------------------------
# install-iac-hooks.zsh (#1605) — Step 4a's hook wiring on the IaC path
# ---------------------------------------------------------------------------

# A consumer repository at $HOOK_REPO holding the RENDERED Makefile and hook.
# Git's global and system config are masked so a developer's own core.hooksPath
# can neither leak into the "unset" cases nor be rewritten by them.
hook_repo() {
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  HOOK_REPO="$BATS_TEST_TMPDIR/gitops"
  render_iac iac/Makefile.tmpl iac/hooks/pre-push.tmpl
  git init -q "$HOOK_REPO"
  mkdir -p "$HOOK_REPO/hooks"
  cp "$MAKEFILE" "$HOOK_REPO/Makefile"
  cp -p "$HOOK" "$HOOK_REPO/hooks/pre-push"
}

# core.hooksPath as git resolves it, or nothing when it is unset.
hooks_path() {
  git -C "$1" config --get core.hooksPath || true
}

# A refusal: exit $1, EMPTY stdout, a stderr line under the script's prefix, and
# $HOOK_REPO's core.hooksPath still exactly $2. Every refusal before `make hooks`
# (exits 2-5) must also stay silent about "replacing core.hooksPath", which the
# script prints only once every check has passed; exit 1 comes after that point.
assert_hooks_refused() {
  [ "$status" -eq "$1" ]
  [ -z "$output" ]
  if [ "$1" -ne 1 ]; then
    lacks "$stderr" 'replacing core.hooksPath'
  fi
  starts_with "$(printf '%s\n' "$stderr" | grep '^install-iac-hooks: ' | head -n 1)" 'install-iac-hooks: '
  [ "$(hooks_path "$HOOK_REPO")" = "$2" ]
}

@test "install-iac-hooks.zsh is committed executable and its header states the contract (#1605)" {
  run git -C "$REPO_ROOT" ls-files -s -- development/skills/bootstrap/scripts/install-iac-hooks.zsh
  [ "$status" -eq 0 ]
  starts_with "$output" '100755 '
  run --separate-stderr zsh "$HOOKS_SCRIPT" --help
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  contains "$output" 'install-iac-hooks.zsh [--repo <path>]'
  contains "$output" 'install-iac-hooks.zsh -h|--help'
  local help="$output"
  run --separate-stderr zsh "$HOOKS_SCRIPT" -h
  [ "$status" -eq 0 ]
  [ "$output" = "$help" ]
  local code
  for code in 0 1 2 3 4 5; do
    matches "$output" "(^|"$'\n'")  $code  "
  done
  contains "$output" 'Stdout is exactly `install-iac-hooks: core.hooksPath=hooks`'
  contains "$output" "prints \`install-iac-hooks: replacing core.hooksPath '<old>'\` to stderr"
  contains "$output" 'On every non-zero exit, stdout is empty and stderr carries one or more lines'
}

@test "install-iac-hooks wires core.hooksPath through the rendered Makefile, and a re-run is idempotent (#1605)" {
  hook_repo
  [ -z "$(hooks_path "$HOOK_REPO")" ]
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
  [ "$(hooks_path "$HOOK_REPO")" = hooks ]
  # an unset prior value is not a replacement either
  lacks "$stderr" 'replacing'
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
  [ "$(hooks_path "$HOOK_REPO")" = hooks ]
  # its own value is not a replacement
  lacks "$stderr" 'replacing'
  # a hooks rule that lists other targets too, with a space before the colon, is
  # still a hooks rule — the target list is split into words
  printf '.PHONY: lint hooks\nlint hooks :\n\tgit config core.hooksPath hooks\n' > "$HOOK_REPO/Makefile"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
}

@test "install-iac-hooks defaults --repo to the current directory (#1605)" {
  hook_repo
  cd "$HOOK_REPO"
  run --separate-stderr zsh "$HOOKS_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
  [ "$(hooks_path "$HOOK_REPO")" = hooks ]
}

@test "install-iac-hooks replaces a different core.hooksPath with a warning and exits 0 (#1605)" {
  hook_repo
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  [ "$status" -eq 0 ]
  [ "$output" = 'install-iac-hooks: core.hooksPath=hooks' ]
  contains "$stderr" "install-iac-hooks: replacing core.hooksPath '.githooks'"
  [ "$(hooks_path "$HOOK_REPO")" = hooks ]
}

@test "install-iac-hooks refuses a missing gate artifact with exit 5 (#1605)" {
  hook_repo
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  mv "$HOOK_REPO/Makefile" "$BATS_TEST_TMPDIR/Makefile.kept"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 5 .githooks
  contains "$stderr" 'no Makefile'
  # a Makefile with only a lint target — `.PHONY` naming hooks is not a rule
  printf '.PHONY: lint hooks\nlint:\n\tzsh scripts/k8s-gate.zsh\n' > "$HOOK_REPO/Makefile"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 5 .githooks
  contains "$stderr" 'has no hooks target'
  # nor is a comment, an assignment, or an indented recipe line that says `hooks:`
  local mk
  # …nor a target that merely contains the word (`install-hooks:`), a plain `=`
  # assignment whose value has a colon, or a colonless `define hooks` block
  for mk in '# hooks: wire git\nlint:\n\ttrue\n' 'hooks := x\nlint:\n\ttrue\n' 'lint:\n\t@echo hooks: done\n' \
    'install-hooks:\n\ttrue\n' 'hooks = a:b\nlint:\n\ttrue\n' 'define hooks\nendef\nlint:\n\ttrue\n'; do
    printf '%b' "$mk" > "$HOOK_REPO/Makefile"
    run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
    assert_hooks_refused 5 .githooks
    contains "$stderr" 'has no hooks target'
  done
  cp "$BATS_TEST_TMPDIR/Makefile.kept" "$HOOK_REPO/Makefile"
  chmod -x "$HOOK_REPO/hooks/pre-push"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 5 .githooks
  contains "$stderr" 'hooks/pre-push is not executable'
  rm "$HOOK_REPO/hooks/pre-push"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 5 .githooks
  contains "$stderr" 'hooks/pre-push is missing'
}

@test "install-iac-hooks refuses a directory that is not a work-tree root with exit 3 (#1605)" {
  hook_repo
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO/hooks"
  assert_hooks_refused 3 .githooks
  contains "$stderr" 'not the root of its git work tree'
  # outside any work tree: the ceiling stops discovery at the test's own tmpdir,
  # and the directory carries every gate artifact, so only the git check can refuse
  local loose="$BATS_TEST_TMPDIR/loose"
  mkdir -p "$loose/hooks"
  cp "$MAKEFILE" "$loose/Makefile"
  cp -p "$HOOK" "$loose/hooks/pre-push"
  run --separate-stderr env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" zsh "$HOOKS_SCRIPT" --repo "$loose"
  assert_hooks_refused 3 .githooks
  contains "$stderr" 'not inside a git work tree'
  [ ! -e "$loose/.git" ]
}

@test "install-iac-hooks refuses with exit 4 when git or make is not on PATH, after usage and before the repo checks (#1605)" {
  hook_repo
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  local nomake="$BATS_TEST_TMPDIR/no-make-bin" nogit="$BATS_TEST_TMPDIR/no-git-bin"
  mkdir -p "$nomake" "$nogit"
  ln -s "$(command -v git)" "$nomake/git"
  ln -s "$(command -v zsh)" "$nomake/zsh"
  ln -s "$(command -v make)" "$nogit/make"
  ln -s "$(command -v zsh)" "$nogit/zsh"
  # `zsh -f`: a ~/.zshenv that rebuilds PATH would otherwise put make back
  run --separate-stderr env PATH="$nomake" zsh -f "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 4 .githooks
  contains "$stderr" 'make is not on PATH'
  run --separate-stderr env PATH="$nogit" zsh -f "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 4 .githooks
  contains "$stderr" 'git is not on PATH'
  # ORDER: the tool check wins over a directory outside any work tree (3)…
  local loose="$BATS_TEST_TMPDIR/loose"
  mkdir -p "$loose"
  run --separate-stderr env PATH="$nomake" GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" zsh -f "$HOOKS_SCRIPT" --repo "$loose"
  assert_hooks_refused 4 .githooks
  # …and loses to a usage error (2)
  printf 'not a directory\n' > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr env PATH="$nomake" zsh -f "$HOOKS_SCRIPT" --repo "$BATS_TEST_TMPDIR/a-file"
  assert_hooks_refused 2 .githooks
}

@test "install-iac-hooks exits 1 when make hooks fails or leaves core.hooksPath unset (#1605)" {
  hook_repo
  printf '.PHONY: hooks\nhooks:\n\t@true\n' > "$HOOK_REPO/Makefile"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 1 ''
  contains "$stderr" "core.hooksPath is '' after make hooks, expected 'hooks'"
  # …and a no-op hooks target over a DIFFERENT prior value is not "hooks" either
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 1 .githooks
  contains "$stderr" "core.hooksPath is '.githooks' after make hooks, expected 'hooks'"
  git -C "$HOOK_REPO" config --unset core.hooksPath
  printf '.PHONY: hooks\nhooks:\n\t@echo recipe-out-marker; echo recipe-err-marker >&2; false\n' > "$HOOK_REPO/Makefile"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO"
  assert_hooks_refused 1 ''
  contains "$stderr" 'install-iac-hooks: make hooks exited'
  # make's own output on BOTH streams is forwarded, not discarded…
  contains "$stderr" 'install-iac-hooks: recipe-out-marker'
  contains "$stderr" 'install-iac-hooks: recipe-err-marker'
  # …and every line of it carries the prefix
  [ -z "$(printf '%s\n' "$stderr" | grep -v '^install-iac-hooks: ')" ]
}

@test "install-iac-hooks refuses a usage error with exit 2 (#1605)" {
  hook_repo
  git -C "$HOOK_REPO" config core.hooksPath .githooks
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$HOOK_REPO" --bogus
  assert_hooks_refused 2 .githooks
  contains "$stderr" 'unknown argument: --bogus'
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo
  assert_hooks_refused 2 .githooks
  contains "$stderr" '--repo needs a non-empty value'
  printf 'not a directory\n' > "$BATS_TEST_TMPDIR/a-file"
  run --separate-stderr zsh "$HOOKS_SCRIPT" --repo "$BATS_TEST_TMPDIR/a-file"
  assert_hooks_refused 2 .githooks
  contains "$stderr" '--repo is not a directory'
}
