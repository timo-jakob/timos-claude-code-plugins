#!/usr/bin/env bats
#
# The quality workflows composed from the RESOLVED toolchain (#1670) instead of
# two whole visibility paths. Every one of the 8 renderable combinations (the
# D4 table below — public + sonarqube and private + codeql are rejected at the
# plan, resolve-tools.zsh step 4) is rendered for a python + Dockerfile repo,
# through the same selector bootstrap uses (toolchain-templates.zsh), and pinned
# against FIXED oracles written out here, never read back from a render:
#
#   D1/D4  the required-context set per row (AC1)
#   D5     the tool-scoped artifacts per row, files and jobs (AC2)
#   AC3    rows 1 and 5 against golden fixtures captured from the pre-#1670
#          templates (tests/fixtures/bootstrap-toolchain-golden/)
#   D6     SETUP.md's composition per row (AC4)
#   D3     the runner rule per row, the Swift leg included (AC5)

bats_require_minimum_version 1.5.0
load assertions

# row: number visibility static_analysis vulnerabilities code_scanning
ROWS=(
  "1 public sonarcloud snyk codeql"
  "2 public sonarcloud snyk none"
  "3 public sonarcloud trivy codeql"
  "4 public sonarcloud trivy none"
  "5 private sonarqube trivy none"
  "6 private sonarqube snyk none"
  "7 private sonarcloud trivy none"
  "8 private sonarcloud snyk none"
)

# D4: each row's context set is B plus these (| separated). B is fixed by D1:
# the always-contexts, plus `image` because the fixture has a Dockerfile.
B="test-and-coverage|semgrep|pre-commit|license-fs|image"
D4=(""
  "sonarcloud|analyze (python)"
  "sonarcloud"
  "sonarcloud|trivy-fs|analyze (python)"
  "sonarcloud|trivy-fs"
  "sonarqube|trivy-fs"
  "sonarqube"
  "sonarcloud|trivy-fs"
  "sonarcloud"
)

# D5, file level: the tool-scoped files each row renders (render-out relative;
# everything under common/ renders for every row and is checked separately)
PUBW=public/.github/workflows
PRIW=private/.github/workflows
D5=(""
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml $PUBW/codeql.yml $PUBW/codeql-noop.yml public/sonar-project.properties public/.snyk"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml public/sonar-project.properties public/.snyk"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml $PUBW/codeql.yml $PUBW/codeql-noop.yml public/sonar-project.properties"
  "$PUBW/quality-public.yml $PUBW/quality-public-noop.yml $PUBW/scorecard.yml public/sonar-project.properties"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml private/sonar-project.properties private/infra/sonarqube/docker-compose.yml private/infra/sonarqube/README.md private/infra/github-runner/README.md"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml private/sonar-project.properties private/infra/sonarqube/docker-compose.yml private/infra/sonarqube/README.md private/infra/github-runner/README.md public/.snyk"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml public/sonar-project.properties"
  "$PRIW/quality-private.yml $PRIW/quality-private-noop.yml public/sonar-project.properties public/.snyk"
)

COMMON=(common/trivy.yaml.tmpl common/.pre-commit-config.yaml.tmpl common/SETUP.md.tmpl)

# render one row with the given languages/docker into <out>, through the selector
render_row() { # <out> <languages> <docker> <vis> <sa> <v> <cs> [extra templates...]
  local out="$1" langs="$2" docker="$3" vis="$4" sa="$5" v="$6" cs="$7"
  shift 7
  local -a sel=()
  local t sel_out
  sel_out="$(zsh "$SEL" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" \
    --code-scanning "$cs")"
  while IFS= read -r t; do sel+=("$t"); done <<<"$sel_out"
  zsh "$RENDER" --templates "$TEMPLATES" --out "$out" --project-name demo \
    --project-slug acme/demo --project-key acme_demo --org-key acme --languages "$langs" \
    --docker "$docker" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" \
    --code-scanning "$cs" "${sel[@]}" "$@" >/dev/null
}

setup_file() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SEL="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local row n vis sa v cs
  for row in "${ROWS[@]}"; do
    read -r n vis sa v cs <<<"$row"
    render_row "$BATS_FILE_TMPDIR/row$n" python true "$vis" "$sa" "$v" "$cs" "${COMMON[@]}"
    # the Swift leg only renders for a Swift repo
    render_row "$BATS_FILE_TMPDIR/swift$n" swift false "$vis" "$sa" "$v" "$cs"
  done
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GOLDEN="$REPO_ROOT/tests/fixtures/bootstrap-toolchain-golden"
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
}

# the reported check names (D2) of a workflow's PR-triggered jobs: `name:` else
# the job key, one `<name> (<lang>)` per matrix language; a job gated to
# push/release (push-and-sign) never reports on a pull request
reported() { # <workflow file>
  yq -o=json . "$1" | jq -r '.jobs | to_entries[]
    | select(((.value.if // "") | test("event_name == .push.")) and
             (((.value.if // "") | test("pull_request")) | not) | not)
    | (.value.name // .key) as $n
    | if ((.value.strategy.matrix.language // null) | type) == "array"
      then (.value.strategy.matrix.language[] | "\($n) (\(.))") else $n end' | LC_ALL=C sort
}

expected_set() { # <row> [minus-analyze]
  local s="$B|${D4[$1]}"
  if [ "${2:-}" = minus-analyze ]; then
    printf '%s\n' "$s" | tr '|' '\n' | grep -v '^analyze (' | LC_ALL=C sort
  else
    printf '%s\n' "$s" | tr '|' '\n' | LC_ALL=C sort
  fi
}

row_fields() { # <row> -> sets vis sa v cs
  read -r _ vis sa v cs <<<"${ROWS[$(($1 - 1))]}"
}

quality() { # <out> <vis> [noop]
  if [ "${3:-}" = noop ]; then
    printf '%s' "$1/$2/.github/workflows/quality-$2-noop.yml"
  else
    printf '%s' "$1/$2/.github/workflows/quality-$2.yml"
  fi
}

# --- AC1: reported names = the D4 context set ---------------------------------------

@test "toolchain render: AC1 — every row's PR jobs report exactly its D4 context set" {
  local n out actual
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(
      reported "$(quality "$out" "$vis")"
      [ ! -f "$out/public/.github/workflows/codeql.yml" ] || reported "$out/public/.github/workflows/codeql.yml"
    )"
    actual="$(printf '%s\n' "$actual" | LC_ALL=C sort)"
    [ "$actual" = "$(expected_set "$n")" ] || {
      echo "row $n: got [$actual] want [$(expected_set "$n")]"
      return 1
    }
  done
}

@test "toolchain render: AC1 — every noop reports the D4 set minus the analyze legs; codeql-noop mirrors codeql's matrix" {
  local n out actual
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(reported "$(quality "$out" "$vis" noop)")"
    [ "$actual" = "$(expected_set "$n" minus-analyze)" ] || {
      echo "row $n noop: got [$actual]"
      return 1
    }
    if [ -f "$out/public/.github/workflows/codeql.yml" ]; then
      [ "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql-noop.yml")" = \
        "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql.yml")" ]
      [ "$(yq -o=json -I=0 '.jobs.analyze.strategy.matrix.language' "$out/public/.github/workflows/codeql.yml")" = '["python"]' ]
    fi
  done
}

# --- AC2: the D5 artifact map --------------------------------------------------------

@test "toolchain render: AC2 — each row renders exactly its D5 tool-scoped files, no more and no fewer" {
  local n out actual want
  for n in 1 2 3 4 5 6 7 8; do
    out="$BATS_FILE_TMPDIR/row$n"
    actual="$(cd "$out" && find . -type f ! -path './common/*' | sed 's#^\./##' | LC_ALL=C sort)"
    want="$(printf '%s\n' ${D5[$n]} | LC_ALL=C sort)"
    [ "$actual" = "$want" ] || {
      echo "row $n: got [$actual]"
      return 1
    }
    # every row renders the three common files too
    [ -f "$out/common/trivy.yaml" ]
    [ -f "$out/common/.pre-commit-config.yaml" ]
    [ -f "$out/common/SETUP.md" ]
  done
  # the example the story names: row 8 has no infra/**, no codeql*.yml, no
  # scorecard.yml and no trivy-fs job
  [ -z "$(cd "$BATS_FILE_TMPDIR/row8" && find . -path '*infra*' -o -name 'codeql*' -o -name 'scorecard.yml')" ]
  run ! grep -q 'trivy-fs:' "$BATS_FILE_TMPDIR/row8/$PRIW/quality-private.yml"
}

@test "toolchain render: AC2 — the job-level artifacts follow the tools: image scanner, pre-commit hook, Sonar config" {
  local n out q steps hook
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    out="$BATS_FILE_TMPDIR/row$n"
    q="$(quality "$out" "$vis")"
    steps="$(yq -o=json '.jobs.image.steps' "$q" | jq -r '.[].name // empty')"
    hook="$(yq -o=json '.repos' "$out/common/.pre-commit-config.yaml" | jq -r '.[].hooks[].id' | grep -cx trivy-fs || true)"
    if [ "$v" = snyk ]; then
      contains "$steps" "Snyk container scan"
      contains "$steps" "Upload Snyk container scan (for maintenance ingestion)"
      lacks "$steps" "Trivy image vulnerability scan"
      [ "$hook" -eq 0 ]
    else
      contains "$steps" "Trivy image vulnerability scan"
      lacks "$steps" "Snyk container scan"
      [ "$hook" -eq 1 ]
    fi
    # the container-change regex watches the resolved scanner's policy file only
    if [ "$v" = snyk ]; then
      grep -q "(\^|/)\\\\.snyk\\$'" "$q"
      run ! grep -q 'trivy\\.ya?ml' "$q"
    else
      grep -q 'trivy\\.ya?ml\$' "$q"
      run ! grep -qF '\.snyk$' "$q"
    fi
    # the Sonar config is the resolved analyser's own
    if [ "$sa" = sonarcloud ]; then
      grep -q '^sonar.organization=' "$out/public/sonar-project.properties"
    else
      grep -qx 'sonar.projectKey=acme_demo' "$out/private/sonar-project.properties"
      run ! grep -q '^sonar.organization=' "$out/private/sonar-project.properties"
    fi
  done
}

# a job's body with its runner removed — the runner is AC5's, the rest is pinned here
job_body() { # <workflow> <job>
  yq -o=json -I=0 ".jobs[\"$2\"] | del(.[\"runs-on\"])" "$1"
}

@test "toolchain render: AC2 — the jobs only non-golden rows render match their golden-pinned twins" {
  local r1="$BATS_FILE_TMPDIR/row1/$PUBW/quality-public.yml" r5="$BATS_FILE_TMPDIR/row5/$PRIW/quality-private.yml"
  local n f
  # trivy-fs on the public workflow (rows 3/4) and on a hosted private one (row 7)
  # is row 5's job, runner aside
  for f in "$BATS_FILE_TMPDIR/row3/$PUBW/quality-public.yml" "$BATS_FILE_TMPDIR/row4/$PUBW/quality-public.yml" \
    "$BATS_FILE_TMPDIR/row7/$PRIW/quality-private.yml"; do
    [ "$(job_body "$f" trivy-fs)" = "$(job_body "$r5" trivy-fs)" ] || { echo "trivy-fs differs in $f"; return 1; }
  done
  # the private workflow's sonarcloud and hosted semgrep jobs (rows 7/8) are row 1's
  for n in 7 8; do
    f="$BATS_FILE_TMPDIR/row$n/$PRIW/quality-private.yml"
    [ "$(yq -o=json -I=0 '.jobs.sonarcloud' "$f")" = "$(yq -o=json -I=0 '.jobs.sonarcloud' "$r1")" ] ||
      { echo "row $n sonarcloud differs"; return 1; }
    [ "$(yq -o=json -I=0 '.jobs.semgrep' "$f")" = "$(yq -o=json -I=0 '.jobs.semgrep' "$r1")" ] ||
      { echo "row $n semgrep differs"; return 1; }
  done
  # the image job's scanner steps and its container-change regex, on the rows no
  # golden renders: Trivy on the public workflow (rows 3/4) is row 5's, Snyk on
  # the private one (rows 6/8) is row 1's
  local trivy_step='.jobs.image.steps[] | select(.name == "Trivy image vulnerability scan")'
  local snyk_steps='[.jobs.image.steps[] | select(((.name // "") | test("Snyk")) or ((.run // "") | test("snyk container test")))]'
  container_re() { yq -r '.jobs.image.steps[] | select(.id == "scan_decision") | .run' "$1" | grep '^container_re='; }
  for n in 3 4; do
    f="$BATS_FILE_TMPDIR/row$n/$PUBW/quality-public.yml"
    [ "$(yq -o=json -I=0 "$trivy_step" "$f")" = "$(yq -o=json -I=0 "$trivy_step" "$r5")" ] ||
      { echo "row $n Trivy image step differs"; return 1; }
    [ "$(container_re "$f")" = "$(container_re "$r5")" ] || { echo "row $n container_re differs"; return 1; }
  done
  [ "$(yq -o=json -I=0 "$snyk_steps" "$r1" | jq length)" -eq 3 ]
  for n in 6 8; do
    f="$BATS_FILE_TMPDIR/row$n/$PRIW/quality-private.yml"
    [ "$(yq -o=json -I=0 "$snyk_steps" "$f")" = "$(yq -o=json -I=0 "$snyk_steps" "$r1")" ] ||
      { echo "row $n Snyk image steps differ"; return 1; }
    [ "$(container_re "$f")" = "$(container_re "$r1")" ] || { echo "row $n container_re differs"; return 1; }
  done
  # the self-hosted semgrep (row 6) is row 5's: no container
  [ "$(yq -o=json -I=0 '.jobs.semgrep' "$BATS_FILE_TMPDIR/row6/$PRIW/quality-private.yml")" = \
    "$(yq -o=json -I=0 '.jobs.semgrep' "$r5")" ]
  [ "$(yq -r '.jobs.semgrep.container' "$r5")" = null ]
  # every row's Sonar scan keeps the semgrep suppression its SHA pin needs
  # (the AC3 normaliser deletes full-line comments, so it is checked here)
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    grep -qF '# nosemgrep: generic.secrets.security.detected-sonarqube-docs-api-key' \
      "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")" || { echo "row $n lost the nosemgrep line"; return 1; }
    # the local trivy-fs hook is skipped in CI exactly where no trivy binary exists:
    # a GitHub-hosted runner on a trivy toolchain
    f="$(yq -r '.jobs["pre-commit"].steps[-1].env.SKIP // ""' "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")")"
    if [ "$v" = trivy ] && [ "$sa" = sonarcloud ]; then
      [ "$f" = trivy-fs ] || { echo "row $n: pre-commit SKIP is '$f'"; return 1; }
    else
      [ -z "$f" ] || { echo "row $n: unexpected pre-commit SKIP '$f'"; return 1; }
    fi
  done
}

# --- the selector's own contract ----------------------------------------------------------

@test "toolchain render: toolchain-templates.zsh prints each row's set exactly — one per line, sorted, no repeats" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  run --separate-stderr zsh "$sel" --visibility public --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    public/.github/workflows/codeql-noop.yml.tmpl \
    public/.github/workflows/codeql.yml.tmpl \
    public/.github/workflows/quality-public-noop.yml.tmpl \
    public/.github/workflows/quality-public.yml.tmpl \
    public/.github/workflows/scorecard.yml.tmpl \
    public/.snyk.tmpl \
    public/sonar-project.properties.tmpl)" ]
  run --separate-stderr zsh "$sel" --visibility private --static-analysis sonarqube --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    private/.github/workflows/quality-private-noop.yml.tmpl \
    private/.github/workflows/quality-private.yml.tmpl \
    private/infra/github-runner/README.md \
    private/infra/sonarqube/README.md \
    private/infra/sonarqube/docker-compose.yml.tmpl \
    private/sonar-project.properties.tmpl)" ]
}

@test "toolchain render: across the 8 rows the selector covers every template under public/ and private/" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local row n vis sa v cs union
  union="$(for row in "${ROWS[@]}"; do
    read -r n vis sa v cs <<<"$row"
    zsh "$sel" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs"
  done | LC_ALL=C sort -u)"
  [ -n "$union" ]
  [ "$union" = "$(cd "$TEMPLATES" && find public private -type f | LC_ALL=C sort)" ]
}


@test "toolchain render: toolchain-templates.zsh refuses the two rejected combinations (exit 1, no set)" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  run --separate-stderr zsh "$sel" --visibility public --static-analysis sonarqube --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "public + sonarqube is never rendered"
  run --separate-stderr zsh "$sel" --visibility private --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  contains "$stderr" "private + codeql is never rendered"
}

@test "toolchain render: toolchain-templates.zsh usage errors exit 2 with nothing on stdout" {
  local sel="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
  local -a ok=(--visibility public --static-analysis sonarcloud --vulnerabilities snyk --code-scanning codeql)
  local i flag bad set
  for i in 0 2 4 6; do
    flag="${ok[i]}"
    run --separate-stderr zsh "$sel" "${ok[@]:0:i}" "${ok[@]:i+2}"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    contains "$stderr" "$flag is required"
    case "$flag" in
    --visibility) bad=internal set="public | private" ;;
    --static-analysis) bad=sonarcube set="sonarcloud | sonarqube | none" ;;
    --vulnerabilities) bad=snik set="snyk | trivy | none" ;;
    --code-scanning) bad=cdoeql set="codeql | none" ;;
    esac
    run --separate-stderr zsh "$sel" "${ok[@]}" "$flag" "$bad"
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    contains "$stderr" "$flag: $bad is not one of: $set"
  done
  run --separate-stderr zsh "$sel" "${ok[@]}" --frobnicate
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --frobnicate"
  run --separate-stderr zsh "$sel" "${ok[@]}" --code-scanning
  [ "$status" -eq 2 ]
  contains "$stderr" "--code-scanning needs a value"
  run --separate-stderr zsh "$sel" --help
  [ "$status" -eq 2 ]
  contains "$stderr" "usage: toolchain-templates.zsh"
}

# --- AC3: rows 1 and 5 against the pre-change golden fixtures -------------------------

# The one normaliser, applied identically to both sides: it deletes block-marker
# lines, full-line `#` comments in non-.md files (a shebang included), and
# blank lines — and changes nothing else. Trailing inline comments stay.
normalise() { # <file>
  case "$1" in
  *.md) grep -Ev '^[[:space:]]*(#|<!--) --- [A-Z_-]+-(START|END)' "$1" | grep -Ev '^[[:space:]]*$' || true ;;
  *) grep -Ev '^[[:space:]]*(#|<!--) --- [A-Z_-]+-(START|END)' "$1" | grep -Ev '^[[:space:]]*#' |
    grep -Ev '^[[:space:]]*$' || true ;;
  esac
}

@test "toolchain render: AC3 — rows 1 and 5 render the golden file set, byte-identical after normalisation (SETUP.md exempt)" {
  local n f checked=0
  for n in 1 5; do
    [ "$(cd "$GOLDEN/row$n" && find . -type f | LC_ALL=C sort)" = \
      "$(cd "$BATS_FILE_TMPDIR/row$n" && find . -type f | LC_ALL=C sort)" ]
    while IFS= read -r f; do
      [ "${f##*/}" = SETUP.md ] && continue
      cmp <(normalise "$GOLDEN/row$n/$f") <(normalise "$BATS_FILE_TMPDIR/row$n/$f") || {
        echo "row $n: $f differs"
        diff <(normalise "$GOLDEN/row$n/$f") <(normalise "$BATS_FILE_TMPDIR/row$n/$f") | head -20
        return 1
      }
      checked=$((checked + 1))
    done < <(cd "$GOLDEN/row$n" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
  done
  # 9 + 8 files beside the two SETUP.md: a comparison that matched nothing fails
  [ "$checked" -eq 17 ]
}

@test "toolchain render: AC3 — the normaliser deletes only markers, full-line comments (not in .md) and blank lines" {
  local d="$BATS_TEST_TMPDIR"
  printf '#!/bin/sh\n  # --- TRIVY-START ---\n  key: v # inline\n\n   \n  # full\n<!-- --- PUBLIC-END --- -->\n' > "$d/a.yml"
  [ "$(normalise "$d/a.yml")" = "  key: v # inline" ]
  printf '# Heading\n<!-- --- SNYK-START --- -->\n\ntext\n' > "$d/b.md"
  [ "$(normalise "$d/b.md")" = "$(printf '# Heading\ntext')" ]
}

# --- AC4: SETUP.md composed per D6 ------------------------------------------------------

# the part a row must (1) or must not (0) contain, by its tools and visibility
setup_parts() { # <vis> <sa> <v> <cs> -> "needle<TAB>0|1" lines
  local pub=0 cloud=0 qube=0 snyk=0 trivy=0
  [ "$1" = public ] && pub=1
  [ "$2" = sonarcloud ] && cloud=1
  [ "$2" = sonarqube ] && qube=1
  [ "$3" = snyk ] && snyk=1
  [ "$3" = trivy ] && trivy=1
  printf '%s\t%s\n' \
    'brew install trivy           # for local container scanning' "$trivy" \
    '## 2. SonarCloud setup' "$cloud" \
    '### 2.3 Create the Zero Tolerance Quality Gate' "$cloud" \
    '| `SNYK_TOKEN` | Yes | from step 2b.1 below |' "$((cloud && snyk))" \
    '`<skill-base-dir>/scripts/setup-sonarcloud.sh`' "$cloud" \
    '`<skill-base-dir>/scripts/setup-snyk.sh` runs' "$snyk" \
    '`<skill-base-dir>/scripts/setup-sonarqube.sh`' "$qube" \
    '`<skill-base-dir>/scripts/register-runner.sh`' "$qube" \
    '## 2a. OpenSSF Scorecard — supply-chain health badge' "$pub" \
    '## 2b. Snyk setup' "$snyk" \
    '### 2b.1 Sign up for Snyk, import the repo, configure PR checks' "$snyk" \
    '### 2b.2 Enable Snyk auto-Fix-PRs (manual UI step)' "$snyk" \
    'Import while the repo is **public**' "$((snyk && pub))" \
    '## 3. SonarQube setup (self-hosted)' "$qube" \
    '### 3.5 Create the Zero Tolerance Quality Gate' "$qube" \
    '### 3.3 Register a self-hosted runner' "$qube" \
    '| `SONAR_TOKEN` | Yes | from step 2.1 |' "$cloud" \
    "**Not required either — Snyk's checks:**" "$snyk" \
    'SonarCloud needs to index the project.' "$cloud" \
    'SonarQube needs to index the project.' "$qube" \
    "Snyk also pulls the imported project's dependency graphs" "$snyk"
}

@test "toolchain render: AC4 — every row's SETUP.md holds exactly the D6 parts of its tools and visibility" {
  local n s needle want have
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    while IFS=$'\t' read -r needle want; do
      have=0
      grep -qF -- "$needle" "$s" && have=1
      [ "$have" = "$want" ] || {
        echo "row $n: '$needle' present=$have want=$want"
        return 1
      }
    done < <(setup_parts "$vis" "$sa" "$v" "$cs")
    # no heading carries a visibility marker, and no tool choice is pinned on one
    run ! grep -nE '\*\*PUBLIC\*\*|\*\*PRIVATE\*\*|PRIVATE only|Sections marked|Snyk container for public repos' "$s"
    run ! grep -qE '\{\{[A-Z_][A-Z0-9_]*\}\}' "$s"
  done
  # the story's examples: row 7 has §2 but no §2a/§2b/§3; row 6 has §2b and §3 but no §2
  grep -q '^## 2\. SonarCloud setup' "$BATS_FILE_TMPDIR/row7/common/SETUP.md"
  run ! grep -qE '^## (2a|2b|3)\. ' "$BATS_FILE_TMPDIR/row7/common/SETUP.md"
  grep -q '^## 2b\. Snyk setup' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
  grep -q '^## 3\. SonarQube setup' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
  run ! grep -q '^## 2\. ' "$BATS_FILE_TMPDIR/row6/common/SETUP.md"
}

@test "toolchain render: AC4 — §4's required-context list is the row's D4 set plus no-cluster-deploy" {
  local n s list
  for n in 1 2 3 4 5 6 7 8; do
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    # the composed bullets sit between the status-checks item and the no-cluster-deploy note
    list="$(awk '/Require status checks to pass before merging/{on=1; next}
      /\*\*`no-cluster-deploy` \(§3h\)\*\*/{on=0}
      on && /^  - `[^`]*`$/ { sub(/^  - `/, ""); sub(/`$/, ""); print }' "$s" | LC_ALL=C sort)"
    [ "$list" = "$(printf '%s\n' "$(expected_set "$n")" no-cluster-deploy | LC_ALL=C sort)" ] || {
      echo "row $n §4: [$list]"
      return 1
    }
  done
}

@test "toolchain render: #2616 a sole-Go SETUP.md §4 lists exactly the sole-Go set; non-Go and mixed-Go lists are unchanged" {
  sole_go_setup
  local out="$BATS_TEST_TMPDIR/s4" row langs vis sa v cs docker list want
  # §4's composed bullets: from the status-checks item to the first non-bullet note
  s4_list() {
    awk '/Require status checks to pass before merging/{on=1; next}
      on && /^  - \*\*/{on=0}
      on && /^  - `[^`]*`$/ { sub(/^  - `/, ""); sub(/`$/, ""); print }' "$1" | LC_ALL=C sort
  }
  for row in "go public sonarcloud trivy codeql true" "go private sonarqube trivy none false" \
    "go public none snyk none false" "go_swift public sonarcloud snyk codeql false"; do
    read -r langs vis sa v cs docker <<< "$row"
    rm -rf "$out"
    zsh "$RENDER" --templates "$TEMPLATES" --out "$out" --project-name demo --project-slug acme/demo \
      --project-key acme_demo --org-key acme --primary go --languages "${langs//_/ }" --docker "$docker" \
      --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs" \
      --security-contact-email "" common/SETUP.md.tmpl >/dev/null
    list="$(s4_list "$out/common/SETUP.md")"
    want="$({
      echo gate
      [ "$sa" = none ] || echo "$sa"
      [ "$cs" = none ] || { echo "analyze (go)"; [ "$langs" = go_swift ] && echo "analyze (swift)"; }
      [ "$docker" = true ] && echo image
    } | LC_ALL=C sort)"
    [ "$list" = "$want" ] || { echo "row [$row] §4: [$list] want [$want]"; return 1; }
    grep -qF '**Sole-Go (#2616):**' "$out/common/SETUP.md"
    run ! grep -qF '**`no-cluster-deploy` (§3h)**, listed above' "$out/common/SETUP.md"
    run ! grep -qE 'SOLE_GO-(START|END)' "$out/common/SETUP.md"
  done
  # mixed-Go: the full language-app list, and the no-cluster-deploy note, as before
  rm -rf "$out"
  zsh "$RENDER" --templates "$TEMPLATES" --out "$out" --project-name demo --project-slug acme/demo \
    --project-key acme_demo --org-key acme --primary go --languages "go python" --docker true \
    --visibility public --static-analysis sonarcloud --vulnerabilities trivy --code-scanning none \
    --security-contact-email "" common/SETUP.md.tmpl >/dev/null
  [ "$(s4_list "$out/common/SETUP.md")" = "$(printf '%s\n' test-and-coverage sonarcloud trivy-fs semgrep license-fs pre-commit no-cluster-deploy image | LC_ALL=C sort)" ]
  grep -qF '**`no-cluster-deploy` (§3h)**, listed above' "$out/common/SETUP.md"
  run ! grep -qF '**Sole-Go (#2616):**' "$out/common/SETUP.md"
  # non-Go: rows 1-8 keep their D4 lists (the AC4 test above), and the note
  grep -qF '**`no-cluster-deploy` (§3h)**, listed above' "$BATS_FILE_TMPDIR/row1/common/SETUP.md"
  run ! grep -qF '**Sole-Go (#2616):**' "$BATS_FILE_TMPDIR/row1/common/SETUP.md"
}

@test "toolchain render: AC4 — §5's image scanner and 2b.1's SAST gate follow the tools" {
  local n s sast
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    s="$BATS_FILE_TMPDIR/row$n/common/SETUP.md"
    if [ "$v" = snyk ]; then
      grep -q "^The \`image\` job's scanner is \*\*Snyk container\*\*" "$s"
      run ! grep -q "scanner is \*\*Trivy\*\*" "$s"
      # the SAST gate 2b.1 names: CodeQL iff codeql, the semgrep check otherwise
      sast="$(sed -n '/^### 2b\.1 /,/^### 2b\.2 /p' "$s" | tr -s '[:space:]' ' ')"
      if [ "$cs" = codeql ]; then
        contains "$sast" "already covered by CodeQL's required \`analyze (<lang>)\` checks"
        lacks "$sast" "semgrep"
      else
        contains "$sast" "already covered by the required \`semgrep\` check"
        lacks "$sast" "CodeQL"
      fi
    else
      grep -q "^The \`image\` job's scanner is \*\*Trivy\*\*" "$s"
      run ! grep -q "Snyk container" "$s"
    fi
  done
}

@test "toolchain render: AC4 — no tracked file outside the history dirs cites SETUP.md's renumbered Snyk and Scorecard sections by their old numbers" {
  local hits
  # positive control: the sweep has a real file list to scan
  [ "$(git -C "$REPO_ROOT" ls-files | wc -l)" -gt 100 ]
  hits="$(git -C "$REPO_ROOT" ls-files | grep -v '^docs/superpowers/' | grep -v '^tests/fixtures/' |
    (cd "$REPO_ROOT" && tr '\n' '\0' | xargs -0 grep -nE '(section|step|§) ?2\.[456]([^0-9]|$)' 2>/dev/null) || true)"
  [ -z "$hits" ] || {
    echo "$hits"
    return 1
  }
}

# --- AC5: the runner rule (D3) ---------------------------------------------------------

@test "toolchain render: AC5 — every quality and noop job follows self_hosted_runner, the Swift leg on its macOS label" {
  local n f want swift_want runners
  for n in 1 2 3 4 5 6 7 8; do
    row_fields "$n"
    if [ "$sa" = sonarqube ]; then
      want='"self-hosted"' swift_want='["self-hosted","macos"]'
    else
      want='"ubuntu-latest"' swift_want='"macos-latest"'
    fi
    for f in "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis")" "$(quality "$BATS_FILE_TMPDIR/row$n" "$vis" noop)" \
      "$(quality "$BATS_FILE_TMPDIR/swift$n" "$vis" noop)"; do
      runners="$(yq -o=json '.jobs' "$f" | jq -c '[.[]."runs-on"] | unique')"
      [ "$runners" = "[$want]" ] || {
        echo "row $n $f: $runners"
        return 1
      }
    done
    f="$(quality "$BATS_FILE_TMPDIR/swift$n" "$vis")"
    [ "$(yq -o=json -I=0 '.jobs["test-and-coverage-swift"]["runs-on"]' "$f")" = "$swift_want" ]
    [ "$(yq -r '.jobs["test-and-coverage-swift"].name' "$f")" = test-and-coverage ]
    # the Swift repo's other jobs follow the Linux rule
    [ "$(yq -o=json '.jobs | del(.["test-and-coverage-swift"])' "$f" | jq -c '[.[]."runs-on"] | unique')" = "[$want]" ]
    # CodeQL keeps its hard-coded GitHub-hosted runner, public rows 1 and 3 only
    if [ "$n" = 1 ] || [ "$n" = 3 ]; then
      for f in codeql.yml codeql-noop.yml; do
        [ "$(yq -r '.jobs.analyze["runs-on"]' "$BATS_FILE_TMPDIR/row$n/$PUBW/$f")" = ubuntu-latest ]
      done
    else
      [ -z "$(find "$BATS_FILE_TMPDIR/row$n" -name 'codeql*')" ]
    fi
  done
}

# --- AC6: the tags ---------------------------------------------------------------------

@test "toolchain render: AC6 — render.zsh has the seven D5 tags and no PRIVATE; only SETUP.md.tmpl has PUBLIC markers" {
  local r="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local tag
  run ! grep -n 'PRIVATE' "$r"
  for tag in SONARCLOUD SONARQUBE SNYK TRIVY CODEQL SELF_HOSTED PUBLIC; do
    grep -qE "^[[:space:]]*$tag\) " "$r"
    grep -qF "| \`$tag\` |" "$skill"
    # the header's --visibility line lists every one of them
    sed -n '/--visibility public|private/,/--docker/p' "$r" | grep -qw "$tag"
  done
  run ! grep -qF '| `PRIVATE` |' "$skill"
  run ! grep -rlE -- '--- PRIVATE-(START|END)' "$TEMPLATES"
  [ "$(grep -rlE -- '--- PUBLIC-(START|END)' "$TEMPLATES" | sed "s#^$TEMPLATES/##")" = common/SETUP.md.tmpl ]
}

# --- AC9 / AC10: no guard left, and the docs name both rejections ------------------------

@test "toolchain render: AC9/AC10 — no temporary-guard text survives; the docs state both rejected combinations" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md"
  local arch="$REPO_ROOT/ARCHITECTURE.md" ref="$REPO_ROOT/docs/reference/maintenance-yml.md"
  local f
  for f in "$skill" "$arch" "$ref" "$REPO_ROOT/development/skills/bootstrap/scripts/resolve-tools.zsh"; do
    run ! grep -niE 'temporary guard|temporary-guard|cannot be rendered yet|renders? only the visibility default' "$f"
  done
  run ! grep -q 'the one combination' "$skill"
  run ! grep -q 'a toolchain the guard' "$skill"
  # both rejections, stated where the story names them
  for f in "$skill" "$arch" "$ref"; do
    grep -q 'code_scanning: codeql' "$f" || grep -q '`code_scanning` set to `codeql`' "$f"
    grep -q 'GitHub Advanced Security' "$f"
  done
  grep -q 'on a private repo Code scan, which has only `none` there' "$skill"
  # #1671 lifted the non-default-toolchain stop: every exit 0 is resolved, and
  # no doc still promises a finish "until #1671" / "once #1671"
  sed -n '/^### Resolve the toolchain (#1651)/,/^## Step 2:/p' "$skill" |
    grep -qF -- '- **exit 0** → resolved, whether or not it is the visibility default'
  run ! grep -qF 'stop before rendering — write nothing' "$skill"
  run ! grep -qF -- '- **exit 0, any other toolchain**' "$skill"
  for f in "$skill" "$arch" "$ref" "$REPO_ROOT/docs/reference/plugins.md"; do
    run ! grep -nE '(until|once) \[?#1671' "$f"
  done
  run ! grep -qF "skips this step, and Step" "$skill"
}

# --- #2121: every tools: category accepts none --------------------------------------------

# none rows: number visibility static_analysis vulnerabilities code_scanning, each with
# its literal context set beyond B and its literal tool-scoped files
NONE_ROWS=(
  "n1 private none trivy none"
  "n2 private sonarcloud none none"
  "n3 public none snyk codeql"
  "n4 public none none none"
  "n5 private none none none"
)
none_contexts() { # <row> -> the extra contexts beyond B, one per line
  case "$1" in
  n1) echo trivy-fs ;;
  n2) echo sonarcloud ;;
  n3) echo "analyze (python)" ;;
  n4 | n5) : ;;
  esac
}
none_files() { # <row> -> the tool-scoped files, render-out relative
  case "$1" in
  n1 | n5) printf '%s\n' "$PRIW/quality-private.yml" "$PRIW/quality-private-noop.yml" ;;
  n2) printf '%s\n' "$PRIW/quality-private.yml" "$PRIW/quality-private-noop.yml" public/sonar-project.properties ;;
  n3) printf '%s\n' "$PUBW/quality-public.yml" "$PUBW/quality-public-noop.yml" "$PUBW/scorecard.yml" \
    "$PUBW/codeql.yml" "$PUBW/codeql-noop.yml" public/.snyk ;;
  n4) printf '%s\n' "$PUBW/quality-public.yml" "$PUBW/quality-public-noop.yml" "$PUBW/scorecard.yml" ;;
  esac
}
none_row() { # <row> -> sets out vis sa v cs, rendering once per test
  local r n
  for r in "${NONE_ROWS[@]}"; do
    read -r n vis sa v cs <<<"$r"
    [ "$n" = "$1" ] && break
  done
  out="$BATS_TEST_TMPDIR/$1"
  [ -d "$out" ] || render_row "$out" python true "$vis" "$sa" "$v" "$cs" "${COMMON[@]}"
}
none_render_setup() {
  TEMPLATES="$REPO_ROOT/development/skills/bootstrap/templates"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
  SEL="$REPO_ROOT/development/skills/bootstrap/scripts/toolchain-templates.zsh"
}

@test "toolchain render: #2121 each none row renders exactly its tool-scoped files; trivy.yaml stays common" {
  none_render_setup
  local r n actual
  for r in "${NONE_ROWS[@]}"; do
    read -r n _ <<<"$r"
    none_row "$n"
    actual="$(cd "$out" && find . -type f ! -path './common/*' | sed 's#^\./##' | LC_ALL=C sort)"
    [ "$actual" = "$(none_files "$n" | LC_ALL=C sort)" ] || { echo "$n: got [$actual]"; return 1; }
    # no Sonar config, no SonarQube or runner infra for static_analysis none
    if [ "$sa" = none ]; then
      [ -z "$(cd "$out" && find . -name 'sonar-project.properties' -o -path '*infra*')" ]
    fi
    # trivy.yaml drives the license/secret/misconfig scanners too: rendered for every row
    [ -f "$out/common/trivy.yaml" ]
    [ -f "$out/common/SETUP.md" ]
  done
}

@test "toolchain render: #2121 each none row's PR jobs and noop report exactly B plus its tools' contexts" {
  none_render_setup
  local r n want actual
  for r in "${NONE_ROWS[@]}"; do
    read -r n _ <<<"$r"
    none_row "$n"
    want="$({ printf '%s\n' "$B" | tr '|' '\n'; none_contexts "$n"; } | awk 'NF' | LC_ALL=C sort)"
    actual="$({
      reported "$(quality "$out" "$vis")"
      [ ! -f "$out/$PUBW/codeql.yml" ] || reported "$out/$PUBW/codeql.yml"
    } | LC_ALL=C sort)"
    [ "$actual" = "$want" ] || { echo "$n: got [$actual] want [$want]"; return 1; }
    [ "$(reported "$(quality "$out" "$vis" noop)")" = "$(printf '%s\n' "$want" | grep -v '^analyze (')" ] ||
      { echo "$n noop: $(reported "$(quality "$out" "$vis" noop)")"; return 1; }
    # SETUP.md §4 lists the same set plus no-cluster-deploy
    [ "$(awk '/Require status checks to pass before merging/{on=1; next}
      /\*\*`no-cluster-deploy` \(§3h\)\*\*/{on=0}
      on && /^  - `[^`]*`$/ { sub(/^  - `/, ""); sub(/`$/, ""); print }' "$out/common/SETUP.md" | LC_ALL=C sort)" = \
      "$(printf '%s\n' "$want" no-cluster-deploy | LC_ALL=C sort)" ] || { echo "$n §4 differs"; return 1; }
    # a GitHub-hosted runner for every none row: none never asks for a self-hosted one
    [ "$(yq -o=json '.jobs' "$(quality "$out" "$vis")" | jq -c '[.[]."runs-on"] | unique')" = '["ubuntu-latest"]' ]
  done
}

@test "toolchain render: #2121 static_analysis none still runs semgrep on the hosted runner, and a trivy row still skips the local trivy-fs hook in CI" {
  none_render_setup
  local q
  # n1: private, none/trivy/none — the motivating repo
  none_row n1
  q="$(quality "$out" private)"
  [ "$(yq -r '.jobs.semgrep.container.image' "$q")" = "returntocorp/semgrep:1.163.0" ]
  [ "$(yq -r '.jobs.semgrep.steps[-1].run' "$q")" = "semgrep ci --config=auto" ]
  [ "$(yq -r '.jobs["pre-commit"].steps[-1].env.SKIP' "$q")" = trivy-fs ]
  # it does get trivy-fs, the image job's Trivy scan and the pre-commit trivy-fs hook
  yq -e '.jobs["trivy-fs"]' "$q" >/dev/null
  yq -o=json '.jobs.image.steps' "$q" | jq -e 'map(.name // "") | index("Trivy image vulnerability scan")' >/dev/null
  [ "$(yq -o=json '.repos' "$out/common/.pre-commit-config.yaml" | jq -r '.[].hooks[].id' | grep -cx trivy-fs)" -eq 1 ]
  # and no Sonar job, secret or token anywhere in its workflows (comments aside: the
  # header describes every analyser the template can compose)
  run ! grep -qiE 'sonar' < <(cat "$q" "$(quality "$out" private noop)" | grep -v '^[[:space:]]*#')
  # the hosted semgrep matches the sonarcloud-hosted private row's, so none changes nothing but the analyser
  [ "$(yq -o=json -I=0 '.jobs.semgrep' "$q")" = "$(yq -o=json -I=0 '.jobs.semgrep' "$BATS_FILE_TMPDIR/row7/$PRIW/quality-private.yml")" ]
}

@test "toolchain render: #2121 vulnerabilities none renders nothing TRIVY or SNYK gate; the image job still builds and decides" {
  none_render_setup
  local n q
  for n in n2 n4 n5; do
    none_row "$n"
    q="$(quality "$out" "$vis")"
    run ! yq -e '.jobs["trivy-fs"]' "$q"
    run ! grep -qE 'Trivy image vulnerability scan|Snyk container scan|snyk container test' < <(grep -v '^[[:space:]]*#' "$q")
    [ "$(yq -o=json '.repos' "$out/common/.pre-commit-config.yaml" | jq -r '.[].hooks[].id' | grep -cx trivy-fs || true)" -eq 0 ]
    run ! grep -qF 'brew install trivy' "$out/common/SETUP.md"
    run ! grep -qE '^## 2b\. Snyk setup' "$out/common/SETUP.md"
    [ ! -e "$out/public/.snyk" ]
    # the image job still decides on container files — the regex watches no scanner policy file
    yq -r '.jobs.image.steps[] | select(.id == "scan_decision") | .run' "$q" | grep -qxF \
      "container_re='(^|/)Dockerfile|\.dockerfile\$|(^|/)\.dockerignore\$|(^|/)(docker-compose|compose)\.ya?ml\$'"
    [ -f "$out/common/trivy.yaml" ]
  done
  # n2 (sonarcloud + none) still lists SONAR_TOKEN in its secrets table, without SNYK_TOKEN
  none_row n2
  grep -qF '| `SONAR_TOKEN` | Yes | from step 2.1 |' "$out/common/SETUP.md"
  run ! grep -qF 'SNYK_TOKEN' "$out/common/SETUP.md"
}

@test "toolchain render: #2121 all three none still renders the quality workflow and noop with the non-toolchain jobs" {
  none_render_setup
  local n q
  for n in n4 n5; do
    none_row "$n"
    q="$(quality "$out" "$vis")"
    [ "$(yq -r '.jobs | keys | .[]' "$q" | LC_ALL=C sort | paste -sd' ' -)" = \
      "image license-fs pre-commit push-and-sign semgrep test-and-coverage" ]
    [ "$(yq -r '.jobs | keys | .[]' "$(quality "$out" "$vis" noop)" | LC_ALL=C sort | paste -sd' ' -)" = \
      "image license-fs pre-commit semgrep test-and-coverage" ]
    run ! grep -qiE 'sonar|snyk|codeql' < <(grep -v '^[[:space:]]*#' "$q")
    # SETUP.md: no Sonar, Snyk or SonarQube section
    run ! grep -qE '^## (2|2b|3)\. ' "$out/common/SETUP.md"
  done
  [ ! -e "$out/$PUBW/codeql.yml" ]
}

# the categories a SETUP.md's DEFERRED-TOOLS block lists, one per line
deferred_listed() { # <SETUP.md>
  sed -n '/<!-- --- DEFERRED-TOOLS-START --- -->/,/<!-- --- DEFERRED-TOOLS-END --- -->/p' "$1" |
    sed -n 's/^- \*\*[^*]*\*\* (`tools\.\([a-z_]*\): none`).*/\1/p'
}

@test "toolchain render: #2121 SETUP.md's DEFERRED-TOOLS block lists exactly the none categories, each with the enable instruction" {
  none_render_setup
  local r n want s c
  for r in "${NONE_ROWS[@]}"; do
    read -r n vis sa v cs <<<"$r"
    none_row "$n"
    s="$out/common/SETUP.md"
    want="$(for c in static_analysis:$sa vulnerabilities:$v code_scanning:$cs; do
      if [ "${c#*:}" = none ]; then echo "${c%%:*}"; fi
    done)"
    [ "$(deferred_listed "$s")" = "$want" ] || { echo "$n: [$(deferred_listed "$s")] want [$want]"; return 1; }
    [ "$(grep -c '<!-- --- DEFERRED-TOOLS-START --- -->' "$s")" -eq 1 ]
    [ "$(grep -c '<!-- --- DEFERRED-TOOLS-END --- -->' "$s")" -eq 1 ]
    # each entry carries the enable instruction: set the value, re-run bootstrap
    for c in $want; do
      sed -n "/(\`tools\.$c: none\`)/,/<!-- --- DEFERRED_/p" "$s" | tr -s '[:space:]' ' ' |
        grep -qF "set \`tools.$c\` in \`.maintenance.yml\` to" || { echo "$n: $c has no instruction"; return 1; }
      sed -n "/(\`tools\.$c: none\`)/,/<!-- --- DEFERRED_/p" "$s" | tr -s '[:space:]' ' ' |
        grep -qF 're-run `/development:bootstrap`' || { echo "$n: $c has no re-run"; return 1; }
    done
  done
  # omitted when nothing is deferred: row 1 (public sonarcloud/snyk/codeql)
  run ! grep -qE 'DEFERRED|## Deferred tools' "$BATS_FILE_TMPDIR/row1/common/SETUP.md"
  # and a private default row lists its code_scanning none, nothing else
  [ "$(deferred_listed "$BATS_FILE_TMPDIR/row5/common/SETUP.md")" = code_scanning ]
}

# --- #2121: the none -> tool re-run (refresh-toolchain-files.zsh) --------------------------

refresh_setup() {
  none_render_setup
  REFRESH="$REPO_ROOT/development/skills/bootstrap/scripts/refresh-toolchain-files.zsh"
  STAMP="$REPO_ROOT/development/skills/bootstrap/scripts/stamp-marker.zsh"
  # a mixed-Go repo (#2615): a sole-Go one's Sonar job is go-ci.yml's, not the quality workflow's
  FLAGS=(--project-name demo --project-slug acme/demo --project-key acme_demo --org-key acme
    --languages "go python" --docker true --security-contact-email "")
}

# a bootstrapped repo at <dir>, as Step 3 + 3.6 leave it, for one toolchain
bootstrapped_repo() { # <dir> <vis> <sa> <v> <cs>
  local d="$1" vis="$2" sa="$3" v="$4" cs="$5" f t
  local -a sel=()
  sel_out="$(zsh "$SEL" --visibility "$vis" --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs")"
  while IFS= read -r t; do sel+=("$t"); done <<<"$sel_out"
  zsh "$RENDER" --templates "$TEMPLATES" --out "$d.r" "${FLAGS[@]}" --visibility "$vis" --primary go \
    --approval human --static-analysis "$sa" --vulnerabilities "$v" --code-scanning "$cs" \
    "${sel[@]}" common/SETUP.md.tmpl common/.maintenance.yml.tmpl common/.pre-commit-config.yaml.tmpl >/dev/null
  mkdir -p "$d"
  # deploy at each file's tree-relative path, as Step 3 does
  (cd "$d.r" && for t in public private common; do [ -d "$t" ] && (cd "$t" && find . -type f) | while IFS= read -r f; do
    mkdir -p "$d/$(dirname "$f")" && cp "$t/$f" "$d/$f"; done; done)
  for f in quality-$vis quality-$vis-noop; do
    zsh "$STAMP" --repo "$d" --target ".github/workflows/$f.yml" --template "$vis/.github/workflows/$f.yml.tmpl"
  done
}

@test "toolchain render: #2121 flipping static_analysis none -> sonarqube changes only the (a)-(e) allow-list, plus the human's own edit" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo" fresh="$BATS_TEST_TMPDIR/fresh" q
  bootstrapped_repo "$repo" private none trivy none
  # the user's own SETUP.md edit, outside every tool block, must survive
  printf '\n## Team notes\n\nAsk the platform team before changing the runner.\n' >> "$repo/SETUP.md"
  cp -R "$repo" "$BATS_TEST_TMPDIR/before"
  # the human's one-line edit
  sed -i.bak 's/^  static_analysis: none$/  static_analysis: sonarqube/' "$repo/.maintenance.yml" && rm "$repo/.maintenance.yml.bak"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility private \
    --static-analysis sonarqube --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | jq -r '"\(.file) \(.status) \(.base)"')" = "$(printf '%s\n' \
    '.github/workflows/quality-private.yml refreshed none/trivy/none' \
    '.github/workflows/quality-private-noop.yml refreshed none/trivy/none' \
    '.pre-commit-config.yaml current sonarcloud/trivy/none' \
    'SETUP.md refreshed none/trivy/none')" ]
  # (c) the new files are exactly the four the selector adds for sonarqube
  [ "$(comm -13 <(zsh "$SEL" --visibility private --static-analysis none --vulnerabilities trivy --code-scanning none) \
    <(zsh "$SEL" --visibility private --static-analysis sonarqube --vulnerabilities trivy --code-scanning none) | paste -sd' ' -)" = \
    "private/infra/github-runner/README.md private/infra/sonarqube/README.md private/infra/sonarqube/docker-compose.yml.tmpl private/sonar-project.properties.tmpl" ]
  # every changed file is one of the allow-list's — no other file moved
  [ "$(diff -rq "$BATS_TEST_TMPDIR/before" "$repo" | sed "s#$BATS_TEST_TMPDIR/before/##; s#$repo/##" |
    awk '{print $2}' | LC_ALL=C sort | paste -sd' ' -)" = \
    ".github/workflows/quality-private-noop.yml .github/workflows/quality-private.yml .maintenance.yml SETUP.md" ]
  # (a)+(b): each workflow is now exactly a fresh sonarqube render, marker kept byte for byte —
  # so its delta is the toolchain's and nothing else
  bootstrapped_repo "$fresh" private sonarqube trivy none
  for q in quality-private quality-private-noop; do
    [ "$(sed -n 1,2p "$repo/.github/workflows/$q.yml")" = "$(sed -n 1,2p "$BATS_TEST_TMPDIR/before/.github/workflows/$q.yml")" ]
    cmp <(sed 1,2d "$repo/.github/workflows/$q.yml") <(sed 1,2d "$fresh/.github/workflows/$q.yml")
  done
  q="$repo/.github/workflows/quality-private.yml"
  [ "$(comm -13 <(yq -r '.jobs | keys | .[]' "$BATS_TEST_TMPDIR/before/.github/workflows/quality-private.yml" | LC_ALL=C sort) \
    <(yq -r '.jobs | keys | .[]' "$q" | LC_ALL=C sort))" = sonarqube ]
  [ "$(yq -o=json '.jobs' "$q" | jq -c '[.[]."runs-on"] | unique')" = '["self-hosted"]' ]
  yq -e '.jobs.sonarqube' "$repo/.github/workflows/quality-private-noop.yml" >/dev/null
  # (d) SETUP.md gains the SonarQube and self-hosted-runner sections, and static_analysis
  # leaves the deferred block; the user's section is still there
  grep -q '^## 3\. SonarQube setup (self-hosted)' "$repo/SETUP.md"
  grep -q '^### 3\.3 Register a self-hosted runner' "$repo/SETUP.md"
  [ "$(deferred_listed "$repo/SETUP.md")" = code_scanning ]
  grep -qx 'Ask the platform team before changing the runner.' "$repo/SETUP.md"
  # SETUP.md minus the user's section is a fresh render's
  cmp <(sed '/^## Team notes$/,$d' "$repo/SETUP.md" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}') \
    <(sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$fresh/SETUP.md")
  # (e) is branch protection's: its sonarqube context is pinned in bootstrap-toolchain-protection.bats
  # the human's edit is the only .maintenance.yml change
  [ "$(diff "$BATS_TEST_TMPDIR/before/.maintenance.yml" "$repo/.maintenance.yml" | grep -c '^[<>]')" -eq 2 ]
}

@test "toolchain render: #2121 refresh is idempotent — a second run reports current and writes nothing" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo"
  bootstrapped_repo "$repo" private none trivy none
  run zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis sonarcloud \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 0 ]
  cp -R "$repo" "$BATS_TEST_TMPDIR/after-first"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis sonarcloud \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r .status | sort -u)" = current ]
  diff -r "$BATS_TEST_TMPDIR/after-first" "$repo"
}

@test "toolchain render: #2121 refresh rewrites a hand-edited DEFERRED-TOOLS block, and --dry-run writes nothing" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo"
  bootstrapped_repo "$repo" private none trivy none
  cp "$repo/SETUP.md" "$BATS_TEST_TMPDIR/pristine"
  # a stale block: someone deleted the static_analysis entry by hand
  awk '/DEFERRED_STATIC_ANALYSIS-START/{s=1} !s{print} /DEFERRED_STATIC_ANALYSIS-END/{s=0}' \
    "$BATS_TEST_TMPDIR/pristine" > "$repo/SETUP.md"
  [ "$(deferred_listed "$repo/SETUP.md")" = code_scanning ]
  cp "$repo/SETUP.md" "$BATS_TEST_TMPDIR/stale"
  run zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis none \
    --vulnerabilities trivy --code-scanning none --dry-run -- "${FLAGS[@]}"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.file == "SETUP.md") | .status')" = refreshed ]
  cmp "$repo/SETUP.md" "$BATS_TEST_TMPDIR/stale"
  run zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis none \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 0 ]
  cmp "$repo/SETUP.md" "$BATS_TEST_TMPDIR/pristine"
  # a removed block is re-inserted after the line it follows in the render
  awk '/DEFERRED-TOOLS-START/{s=1} !s{print} /DEFERRED-TOOLS-END/{s=0}' "$BATS_TEST_TMPDIR/pristine" > "$repo/SETUP.md"
  run zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis none \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 0 ]
  cmp "$repo/SETUP.md" "$BATS_TEST_TMPDIR/pristine"
}

@test "toolchain render: #2121 refresh leaves a conflicting file untouched and exits 3; an absent file is reported, not created" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo" q
  bootstrapped_repo "$repo" private none trivy none
  q="$repo/.github/workflows/quality-private.yml"
  # a user edit on the very line the flip must change: the runner of the first job
  awk '!done && /runs-on: ubuntu-latest/ { sub(/ubuntu-latest/, "ubuntu-24.04"); done = 1 } { print }' "$q" > "$q.new"
  mv "$q.new" "$q"
  cp "$q" "$BATS_TEST_TMPDIR/edited"
  rm "$repo/.github/workflows/quality-private-noop.yml"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis sonarqube \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.file == ".github/workflows/quality-private.yml") | .status')" = conflict ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.file == ".github/workflows/quality-private-noop.yml") | .status')" = absent ]
  cmp "$q" "$BATS_TEST_TMPDIR/edited"
  [ ! -e "$repo/.github/workflows/quality-private-noop.yml" ]
}

@test "toolchain render: #2121 refresh leaves a file equidistant from two different renders untouched as ambiguous" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo" tv="$BATS_TEST_TMPDIR/trivy" n t hunk at from to half
  bootstrapped_repo "$repo" private sonarcloud none none
  bootstrapped_repo "$tv" private sonarcloud trivy none
  n="$repo/.github/workflows/quality-private-noop.yml" t="$tv/.github/workflows/quality-private-noop.yml"
  # trivy's noop is the none one plus a single inserted block; keep half of it
  hunk="$(diff "$n" "$t" | head -1)"
  grep -qxE '[0-9]+a[0-9]+,[0-9]+' <<< "$hunk"
  at="${hunk%%a*}" to="${hunk#*,}" from="${hunk#*a}"
  from="${from%%,*}"
  [ $(( (to - from + 1) % 2 )) -eq 0 ]
  half=$(( (to - from + 1) / 2 ))
  { sed -n "1,${at}p" "$n"; sed -n "${from},$((from + half - 1))p" "$t"; sed -n "$((at + 1)),\$p" "$n"; } > "$n.new"
  mv "$n.new" "$n"
  cp "$n" "$BATS_TEST_TMPDIR/tied"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility private --static-analysis sonarcloud \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}"
  [ "$status" -eq 3 ]
  [ "$(printf '%s\n' "$output" | jq -c 'select(.file == ".github/workflows/quality-private-noop.yml") | {status, base}')" = \
    '{"status":"ambiguous","base":null}' ]
  [ "$(printf '%s\n' "$output" | jq -rs 'map("\(.file) \(.status)") | sort | join(", ")')" = \
    '.github/workflows/quality-private-noop.yml ambiguous, .github/workflows/quality-private.yml refreshed, .pre-commit-config.yaml refreshed, SETUP.md refreshed' ]
  cmp "$n" "$BATS_TEST_TMPDIR/tied"
}

@test "toolchain render: #2121 refresh on a public repo flips static_analysis none -> sonarcloud" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo" fresh="$BATS_TEST_TMPDIR/fresh"
  bootstrapped_repo "$repo" public none snyk codeql
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility public --static-analysis sonarcloud \
    --vulnerabilities snyk --code-scanning codeql -- "${FLAGS[@]}"
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | jq -r '"\(.file) \(.status) \(.base)"')" = "$(printf '%s\n' \
    '.github/workflows/quality-public.yml refreshed none/snyk/codeql' \
    '.github/workflows/quality-public-noop.yml refreshed none/snyk/codeql' \
    '.pre-commit-config.yaml current sonarcloud/snyk/codeql' \
    'SETUP.md refreshed none/snyk/codeql')" ]
  bootstrapped_repo "$fresh" public sonarcloud snyk codeql
  cmp <(sed 1,2d "$repo/.github/workflows/quality-public.yml") <(sed 1,2d "$fresh/.github/workflows/quality-public.yml")
  run ! grep -qF 'DEFERRED-TOOLS-START' "$repo/SETUP.md"
  cmp "$repo/SETUP.md" "$fresh/SETUP.md"
}

@test "toolchain render: #2121 refresh usage errors exit 2 with nothing on stdout" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  local -a ok=(--repo "$repo" --visibility private --static-analysis none --vulnerabilities trivy --code-scanning none)
  run --separate-stderr zsh "$REFRESH" "${ok[@]:2}"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "--repo is required"
  run --separate-stderr zsh "$REFRESH" "${ok[@]}" --static-analysis sonarcube
  [ "$status" -eq 2 ]
  contains "$stderr" "--static-analysis must be one of sonarcloud | sonarqube | none"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility public --static-analysis sonarqube \
    --vulnerabilities trivy --code-scanning none
  [ "$status" -eq 2 ]
  contains "$stderr" "a combination resolve-tools.zsh rejects"
  run --separate-stderr zsh "$REFRESH" "${ok[@]}" -- --out /tmp/x
  [ "$status" -eq 2 ]
  contains "$stderr" "--out is set by this script"
  run --separate-stderr zsh "$REFRESH" "${ok[@]}" --frobnicate
  [ "$status" -eq 2 ]
  contains "$stderr" "unknown argument: --frobnicate"
}

@test "toolchain render: #2121 SKILL.md and ARCHITECTURE.md state that every tools: category accepts none" {
  local skill="$REPO_ROOT/development/skills/bootstrap/SKILL.md" arch="$REPO_ROOT/ARCHITECTURE.md"
  tr -s '[:space:]' ' ' < "$skill" | grep -qF '**Every `tools:` category accepts `none`** (#2121), and a category added later ships with it too'
  tr -s '[:space:]' ' ' < "$arch" | grep -qF 'Every `tools:` category accepts `none` (#2121)'
  # the refresh is wired into State D, and the Q3a picker offers none last
  grep -qF 'refresh-toolchain-files.zsh' "$skill"
  grep -qF '*none (add later)* is always the **last** option on its tab' "$skill"
}

@test "toolchain render: #2121 SKILL.md pins the none prose at each site that acts on it" {
  local joined
  joined="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/bootstrap/SKILL.md")"
  local -a needles=(
    # Q3a picker
    '**Analysis** (`sonarcloud` \| `sonarqube` \| *none (add later)*), **Vulns** (`snyk` \| `trivy` \| *none (add later)*), **Code scan** (`codeql` \| *none (add later)*)'
    'A tab offers only the values this visibility allows: on a public repo Analysis offers `sonarcloud` and *none (add later)*.'
    # Resolve the toolchain
    'A `none` category renders no job or noop, no config file of its own, no setup section, secret, preflight requirement or required context;'
    '`none` is never a default except private `code_scanning`'"'"'s.'
    # Step 2 plan
    'A deferred category shows `none` like any other value — for example `static analysis none (recorded)` (#2121) — and with `static_analysis: none` the `Sonar gate:` line is omitted'
    # Block stripping, §3b, §3c
    'A category resolved to `none` keeps **none** of its tool blocks (#2121): no job or noop, no config file, no setup section.'
    '| `none` (any category, #2121) | no file of its own — the quality workflow and its noop still render, all three `none` included |'
    'the analyser'"'"'s job — `sonarcloud` or `sonarqube` — and its noop; none for `static_analysis: none`;'
    'so `snyk` adds none, and neither does `none`;'
    'no scan step for `vulnerabilities: none` (the job still builds the image and reports `image`);'
    # State D: secrets, the refresh, and step 5's hand-off to it
    '`SONAR_TOKEN` iff `static_analysis` is not `none`, `SONAR_HOST_URL` iff `static_analysis` is `sonarqube`, `SNYK_TOKEN` iff `vulnerabilities` is `snyk` — a `none` category expects no secret (#2121).'
    'and the drift detector never sees a toolchain change, since it compares template hashes.'
    'Its `refreshed` rows join the Step 2 plan as *Will update (toolchain changed)*; on confirmation, run it again without `--dry-run`.'
    'It also rewrites `SETUP.md`'"'"'s bootstrap-owned `DEFERRED-TOOLS` block on every run.'
    '`conflict` or `ambiguous` (exit 3) → that file was left untouched, so hand it to the `bootstrap-idempotency-reviewer`'
    '**When the required contexts changed** — a quality workflow refreshed (a tool added or removed), a sole-Go repo'"'"'s `go-ci.yml` refreshed (its Sonar job added or removed), a `conflict` or `ambiguous` one the reviewer'"'"'s approved overwrite changed, or a gap-fill render of `codeql.yml` — re-apply Step 4b'"'"'s branch protection with its full invocation for the new toolchain, which adds the new tool'"'"'s context (`sonarqube`, say) and drops a removed one'"'"'s, and run the Step 4.5 setup script whose trigger the new toolchain meets. A refresh that only rewrote the deferred block needs neither.'
    'On a Swift repo, a refreshed quality workflow'"'"'s new analyser job still reads `needs: test-and-coverage`, so apply *Swift job wiring* to it;'
    'A tool changed to `none` leaves only these files; its own files (`codeql.yml`, `sonar-project.properties`, `.snyk`) stay — removing them is #2126'"'"'s scope.'
    'So off the §3l path, once the gate above resolved, run the refresh — in whichever of steps 3, 4 and 5 this run reaches first, and once per run:'
    '--code-scanning <v> --dry-run -- <the value flags this run renders with>'
    'It never overwrites a file wholesale: it three-way merges the toolchain delta into the file against the closest render, so only the per-tool blocks the change touches move, a user edit outside them stays, and the provenance marker is kept byte-for-byte.'
    'they do NOT touch files in the working tree — except the toolchain refresh above, whose `refreshed` files are a committable delta,'
    'and each of these writes rides Step 4d/4e as the bot PR.'
    'Per row: `refreshed` → done (a committable delta); `current` → nothing to do; `absent` → the gap-fill above renders it;'
    'Exit 1 → relay stderr and render nothing more; exit 2 → your own invocation, fix it and re-run.'
    'never re-derived from visibility; then run step 4'"'"'s *toolchain refresh* (#2121) before any `branch-protection.sh` call, unless this run already did.'
    'On an exit 0, run step 4'"'"'s *toolchain refresh* (#2121) first, unless this run already did — a refresh whose dry run reported a `refreshed`, `conflict` or `ambiguous` row is a committable delta, which the no-drift stop below never swallows.'
    'So does a pending toolchain refresh: when its dry run reported any `refreshed`, `conflict` or `ambiguous` row, do not stop — continue to the Step 2 plan, and on confirmation its run without `--dry-run` is the delta.)'
    # Step 4b, 4.5, Step 5
    'the `static_analysis` job unless it is `none` (#2121)'
    'per resolved tool: `sonar-scanner` for either analyser, `snyk` for `snyk`, `trivy` for `trivy` — whatever the visibility or Dockerfile; a `none` category requires nothing, #2121'
    'A `none` category meets no trigger, so it runs no setup script (#2121): a private repo with `static_analysis: none` and `vulnerabilities: trivy` runs `enable-github-security.sh` alone.'
    'A `none` category contributes **no** item (#2121) — nothing is outstanding for a deferred tool;'
  )
  local n
  for n in "${needles[@]}"; do
    contains "$joined" "$n" || { echo "missing: $n"; return 1; }
  done
}

# --- #2615: a sole-Go repo's Sonar job is go-ci.yml's ------------------------------------

GOCI=languages/go/.github/workflows/go-ci.yml.tmpl

# render a row's quality workflow, its noop and go-ci.yml into <out>, from <templates>
sole_go_render() { # <out> <templates> <primary> <languages> <vis> <sa>
  zsh "$RENDER" --templates "$2" --out "$1" --project-name demo --project-slug acme/demo \
    --project-key acme_demo --org-key acme --primary "$3" --languages "$4" --docker false \
    --visibility "$5" --static-analysis "$6" --vulnerabilities trivy --code-scanning none \
    "$5/.github/workflows/quality-$5.yml.tmpl" "$5/.github/workflows/quality-$5-noop.yml.tmpl" "$GOCI" >/dev/null
}

sole_go_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RENDER="$REPO_ROOT/development/skills/bootstrap/scripts/render.zsh"
}

# each render row: go-ci.yml keeps its push trigger, and no rendered file carries the pair's markers
sole_go_row_common() { # <out>
  [ "$(yq -r '.on.push.branches | join(",")' "$1/languages/go/.github/workflows/go-ci.yml")" = main ]
  run ! grep -rqE 'SOLE_GO-(START|END)' "$1"
}

@test "toolchain render: #2615 SKILL.md and ARCHITECTURE.md state where a sole-Go repo's Sonar job lives" {
  local joined arch n
  joined="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/bootstrap/SKILL.md")"
  arch="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/ARCHITECTURE.md")"
  local -a needles=(
    'Kept blocks retain their marker lines, except `SOLE_GO`'"'"'s and `NOT_SOLE_GO`'"'"'s.'
    '| `SOLE_GO` | the repo is **sole-Go** — `is-sole-go.zsh --primary <p> --languages "<l>"` exits 0: primary `go` and none of `javascript`, `python` or `java` (Swift does not count)'
    'Wraps `go-ci.yml`'"'"'s Sonar jobs. **Its marker lines are never emitted, kept or stripped** |'
    '| `NOT_SOLE_GO` | its complement (#2615) — wraps the quality workflows'"'"' and noops'"'"' Sonar jobs'
    'for a **sole-Go** repo (#2615) the job is `go-ci.yml`'"'"'s instead, and neither the quality workflow nor its noop carries one'
    'it also carries the Sonar job — `sonarcloud` or `sonarqube`, unchanged except `needs: gate`, downloading that same-workflow `coverage-reports` artifact — inside its `SONARCLOUD` / `SONARQUBE` markers'
    'So render `go-ci.yml` with this run'"'"'s `--languages`, `--visibility` and toolchain flags too: without them its Sonar job strips silently.'
    'plus `.github/workflows/go-ci.yml` on a sole-Go repo, whose Sonar job lives there (#2615;'
    'a sole-Go repo'"'"'s `go-ci.yml` refreshed (its Sonar job added or removed)'
    'a sole-Go repo'"'"'s, in `go-ci.yml`, reads `needs: gate` and needs no wiring.'
    '**Swift + another test-lane language** (rare): keep both jobs, rename the Swift job'"'"'s uploaded artifact (e.g. `coverage-reports-swift`) — two uploads must not share one artifact name — and, unless the repo is sole-Go (whose analyser job is `go-ci.yml`'"'"'s and takes no wiring), extend the analyser'"'"'s `needs:` to both jobs and add a matching second download step.'
    'read from render.zsh'"'"'s own `--primary` and `--languages` (#2615); a render without `--languages` is not sole-Go.'
    'passed after `--`, and a passthrough without `--languages` is not sole-Go)'
    'Known limitation: a sole-Go repo bootstrapped before #2615 keeps its old Sonar job in the quality workflow, which the refresh reports `current`; #2617'"'"'s re-run leftovers report tracks removing it.'
  )
  for n in "${needles[@]}"; do
    contains "$joined" "$n" || { echo "missing: $n"; return 1; }
  done
  contains "$arch" 'plus `go-ci.yml` on a sole-Go repo (`development/skills/bootstrap/scripts/is-sole-go.zsh`), where its Sonar job lives (#2615)'
  local goci
  goci="$(tr -s '[:space:]' ' ' < "$REPO_ROOT/development/skills/bootstrap/templates/$GOCI")"
  contains "$goci" '# Known limitation: on a Go+Swift repo it sees no Swift coverage, which stays in the quality # workflow (#2718).'
}

@test "toolchain render: #2615 sole-Go public sonarcloud — the sonarcloud job is go-ci.yml's, needs gate, reads coverage-reports" {
  sole_go_setup
  local out="$BATS_TEST_TMPDIR/out" wf="$BATS_TEST_TMPDIR/out/languages/go/.github/workflows/go-ci.yml" q
  sole_go_render "$out" "$TEMPLATES" go go public sonarcloud
  sole_go_row_common "$out"
  [ "$(yq -r '.jobs | keys | join(",")' "$wf")" = gate,sonarcloud ]
  [ "$(yq -r '.jobs.sonarcloud.needs' "$wf")" = gate ]
  # the artifact it downloads is the one the gate job uploads in the same workflow
  [ "$(yq -r '.jobs.gate.steps[] | select(.with.name == "coverage-reports") | .with.path' "$wf")" = \
    "$(printf 'coverage.out\ncoverage.xml')" ]
  # inside its SONARCLOUD markers, so static_analysis none still strips it
  grep -qF '# --- SONARCLOUD-START' "$wf"
  # the quality workflow and noop lose the Sonar job and nothing else: their jobs are the mixed row's minus it
  sole_go_render "$BATS_TEST_TMPDIR/mixed" "$TEMPLATES" go "go python" public sonarcloud
  # the job is the mixed row's quality-public.yml sonarcloud job, unchanged except needs
  [ "$(yq -o=json -I0 '.jobs.sonarcloud | del(.needs)' "$wf")" = "$(yq -o=json -I0 '.jobs.sonarcloud | del(.needs)' "$BATS_TEST_TMPDIR/mixed/public/.github/workflows/quality-public.yml")" ]
  for q in quality-public quality-public-noop; do
    [ "$(yq -r '.jobs | keys | join(",")' "$out/public/.github/workflows/$q.yml")" = "$(yq -r '.jobs | del(.sonarcloud, .sonarqube) | keys | join(",")' "$BATS_TEST_TMPDIR/mixed/public/.github/workflows/$q.yml")" ]
  done
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$wf"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "toolchain render: #2615 sole-Go private sonarqube — the sonarqube job is go-ci.yml's, on the self-hosted runner" {
  sole_go_setup
  local out="$BATS_TEST_TMPDIR/out" wf="$BATS_TEST_TMPDIR/out/languages/go/.github/workflows/go-ci.yml" q
  sole_go_render "$out" "$TEMPLATES" go "go swift" private sonarqube
  sole_go_row_common "$out"
  [ "$(yq -r '.jobs | keys | join(",")' "$wf")" = gate,sonarqube ]
  [ "$(yq -r '.jobs.sonarqube.needs' "$wf")" = gate ]
  sole_go_render "$BATS_TEST_TMPDIR/mixed" "$TEMPLATES" go "go swift python" private sonarqube
  # the job is the mixed row's quality-private.yml sonarqube job, unchanged except needs
  [ "$(yq -o=json -I0 '.jobs.sonarqube | del(.needs)' "$wf")" = "$(yq -o=json -I0 '.jobs.sonarqube | del(.needs)' "$BATS_TEST_TMPDIR/mixed/private/.github/workflows/quality-private.yml")" ]
  for q in quality-private quality-private-noop; do
    [ "$(yq -r '.jobs | keys | join(",")' "$out/private/.github/workflows/$q.yml")" = "$(yq -r '.jobs | del(.sonarcloud, .sonarqube) | keys | join(",")' "$BATS_TEST_TMPDIR/mixed/private/.github/workflows/$q.yml")" ]
  done
  run yamllint -c "$REPO_ROOT/.yamllint" --strict "$wf"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "toolchain render: #2615 sole-Go static_analysis none renders no Sonar job anywhere, and the coverage upload stays" {
  sole_go_setup
  local out="$BATS_TEST_TMPDIR/out" mixed="$BATS_TEST_TMPDIR/mixed" vis f
  for vis in public private; do
    rm -rf "$out" "$mixed"
    sole_go_render "$out" "$TEMPLATES" go go "$vis" none
    sole_go_render "$mixed" "$TEMPLATES" go "go python" "$vis" none
    sole_go_row_common "$out"
    for f in languages/go/.github/workflows/go-ci.yml "$vis/.github/workflows/quality-$vis.yml" \
      "$vis/.github/workflows/quality-$vis-noop.yml"; do
      [ "$(yq -r '.jobs | keys | join(",")' "$out/$f")" = "$(yq -r '.jobs | del(.sonarcloud, .sonarqube) | keys | join(",")' "$mixed/$f")" ]
    done
    f="$out/languages/go/.github/workflows/go-ci.yml"
    [ "$(yq -r '.jobs | keys | join(",")' "$f")" = gate ]
    [ "$(yq -r '.jobs.gate.steps[] | select(.with.name == "coverage-reports") | .if' "$f")" = 'always()' ]
  done
}

@test "toolchain render: #2615 Go+python and python-only render byte-identically to the pre-story templates" {
  sole_go_setup
  local pre="$BATS_TEST_TMPDIR/pre" f row primary langs vis sa
  # the pre-story templates are these minus the SOLE_GO blocks and the NOT_SOLE_GO marker lines —
  # the story added nothing else to them
  for f in public/.github/workflows/quality-public.yml.tmpl public/.github/workflows/quality-public-noop.yml.tmpl \
    private/.github/workflows/quality-private.yml.tmpl private/.github/workflows/quality-private-noop.yml.tmpl "$GOCI"; do
    mkdir -p "$pre/$(dirname "$f")"
    awk '/--- SOLE_GO-START/{s=1} !s && !/--- NOT_SOLE_GO-(START|END)/{print} /--- SOLE_GO-END/{s=0}' \
      "$TEMPLATES/$f" > "$pre/$f"
    # the derivation removed something, so a row never compares a template with itself
    run ! cmp -s "$TEMPLATES/$f" "$pre/$f"
  done
  for row in "go go_python public sonarcloud" "go go_python private sonarqube" "go go_java public none" \
    "python python public sonarcloud" "python python private sonarqube" "javascript javascript private sonarcloud"; do
    read -r primary langs vis sa <<< "$row"
    rm -rf "$BATS_TEST_TMPDIR/new" "$BATS_TEST_TMPDIR/old"
    sole_go_render "$BATS_TEST_TMPDIR/new" "$TEMPLATES" "$primary" "${langs//_/ }" "$vis" "$sa"
    sole_go_render "$BATS_TEST_TMPDIR/old" "$pre" "$primary" "${langs//_/ }" "$vis" "$sa"
    diff -r "$BATS_TEST_TMPDIR/old" "$BATS_TEST_TMPDIR/new" || { echo "row: $row"; return 1; }
    sole_go_row_common "$BATS_TEST_TMPDIR/new"
    # and the quality workflow still carries its Sonar job, where one is resolved
    if [ "$sa" != none ]; then
      [ "$(yq -r ".jobs | has(\"$sa\")" "$BATS_TEST_TMPDIR/new/$vis/.github/workflows/quality-$vis.yml")" = true ]
    fi
  done
}

@test "toolchain render: #2615 refresh on a sole-Go repo re-composes go-ci.yml — none -> sonarcloud adds the job there, not to quality" {
  refresh_setup
  local repo="$BATS_TEST_TMPDIR/repo" fresh="$BATS_TEST_TMPDIR/fresh" q
  # this fixture is sole-Go: Go alone
  FLAGS=(--project-name demo --project-slug acme/demo --project-key acme_demo --org-key acme
    --languages go --docker true --security-contact-email "")
  bootstrapped_repo "$repo" public none trivy none
  zsh "$RENDER" --templates "$TEMPLATES" --out "$BATS_TEST_TMPDIR/goci" "${FLAGS[@]}" --primary go --visibility public \
    --static-analysis none --vulnerabilities trivy --code-scanning none "$GOCI" >/dev/null
  cp "$BATS_TEST_TMPDIR/goci/languages/go/.github/workflows/go-ci.yml" "$repo/.github/workflows/go-ci.yml"
  cp -R "$repo" "$BATS_TEST_TMPDIR/before"
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility public --static-analysis sonarcloud \
    --vulnerabilities trivy --code-scanning none -- "${FLAGS[@]}" --primary go
  [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
  [ "$(printf '%s\n' "$output" | jq -r 'select(.file == ".github/workflows/go-ci.yml") | "\(.status) \(.base)"')" = \
    "refreshed none/snyk/codeql" ]
  [ "$(printf '%s\n' "$output" | jq -r 'select(.file | startswith(".github/workflows/quality")) | .status' | sort -u)" = current ]
  # the job moved to go-ci.yml, and only there: it is now a fresh sonarcloud render
  q="$repo/.github/workflows/go-ci.yml"
  [ "$(yq -r '.jobs | keys | join(",")' "$q")" = gate,sonarcloud ]
  [ "$(yq -r '.jobs.sonarcloud.needs' "$q")" = gate ]
  zsh "$RENDER" --templates "$TEMPLATES" --out "$fresh" "${FLAGS[@]}" --primary go --visibility public \
    --static-analysis sonarcloud --vulnerabilities trivy --code-scanning none "$GOCI" >/dev/null
  cmp "$q" "$fresh/languages/go/.github/workflows/go-ci.yml"
  for q in quality-public quality-public-noop; do
    [ "$(yq -r '.jobs | has("sonarcloud")' "$repo/.github/workflows/$q.yml")" = false ]
    cmp "$repo/.github/workflows/$q.yml" "$BATS_TEST_TMPDIR/before/.github/workflows/$q.yml"
  done
  # a mixed-Go refresh composes only the four files, never go-ci.yml (its verdicts on this
  # sole-Go tree are beside the point, so only the roster is read)
  local -a mixed=(--project-name demo --project-slug acme/demo --project-key acme_demo --org-key acme
    --languages "go python" --docker true --security-contact-email "" --primary go)
  run --separate-stderr zsh "$REFRESH" --repo "$repo" --visibility public --static-analysis sonarcloud \
    --vulnerabilities trivy --code-scanning none --dry-run -- "${mixed[@]}"
  [ "$(printf '%s\n' "$output" | jq -r .file | paste -sd' ' -)" = \
    ".github/workflows/quality-public.yml .github/workflows/quality-public-noop.yml .pre-commit-config.yaml SETUP.md" ] ||
    { echo "$status $output $stderr"; return 1; }
  # a passthrough with no --languages is not sole-Go: the refresh never asks is-sole-go.zsh,
  # so go-ci.yml is not composed (a stub that answers sole-Go records any call)
  local bs="$BATS_TEST_TMPDIR/bs"
  mkdir -p "$bs/scripts"
  ln -s "$TEMPLATES" "$bs/templates"
  cp "$REFRESH" "$RENDER" "$bs/scripts/"
  printf '#!/usr/bin/env zsh\ntouch "${0:A:h}/called"\nexit 0\n' > "$bs/scripts/is-sole-go.zsh"
  local -a nolangs=(--project-name demo --project-slug acme/demo --project-key acme_demo --org-key acme
    --docker true --security-contact-email "" --primary go)
  run --separate-stderr zsh "$bs/scripts/refresh-toolchain-files.zsh" --repo "$repo" --visibility public \
    --static-analysis sonarcloud --vulnerabilities trivy --code-scanning none --dry-run -- "${nolangs[@]}"
  [ ! -e "$bs/scripts/called" ] || { echo "$status $output $stderr"; return 1; }
  run ! grep -q go-ci.yml <<< "$output"
  # a failing is-sole-go.zsh fails the refresh loudly, never as "not sole-Go" (the refresh's
  # own prefix: render.zsh would die on the same stub with its own)
  printf '#!/usr/bin/env zsh\nexit 3\n' > "$bs/scripts/is-sole-go.zsh"
  run --separate-stderr zsh "$bs/scripts/refresh-toolchain-files.zsh" --repo "$repo" --visibility public \
    --static-analysis sonarcloud --vulnerabilities trivy --code-scanning none --dry-run -- "${mixed[@]}"
  [ "$status" -eq 1 ] || { echo "$status $output $stderr"; return 1; }
  contains "$stderr" "refresh-toolchain-files: is-sole-go.zsh failed (exit 3)"
  [ -z "$output" ]
}
