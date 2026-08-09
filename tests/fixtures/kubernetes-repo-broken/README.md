# kubernetes-repo-broken fixture — the broken variant

Every deliberate defect for the `development-kubernetes` machinery lives here.
Each manifest under `broken/` is the clean variant's
`charts/app/templates/deployment.yaml` (or its `argocd/app-of-apps.yaml`) with
**exactly one guarantee removed** and everything else retained, so no default
check fires incidentally and every finding stays attributable to one file and one
named check.

A regression therefore reads as "`no-limits.yaml` stopped firing
`unset-cpu-requirements`", not "the fixture went red".

## What each file is for

| file | removed guarantee | owning job | check id(s) |
| --- | --- | --- | --- |
| `broken/no-probe.yaml` | readiness probe | `lint` | `no-readiness-probe` |
| `broken/no-limits.yaml` | resource requests/limits | `lint` | `unset-cpu-requirements`, `unset-memory-requirements` |
| `broken/latest-tag.yaml` | pinned image tag | `lint` | `latest-tag` |
| `broken/bad-registry.yaml` | allowed registry | `policy` | kyverno `require-registry` / `autogen-images-from-allowed-registry` |
| `broken/argocd/dangling-app.yaml` | app path exists | `argocd` | `app-of-apps references missing path: charts/does-not-exist` |
| `broken/argocd/dangling-multisource.yaml` | app path exists, via `.spec.sources[]` | `argocd` | `app-of-apps references missing path: charts/also-missing` |

`broken/no-limits.yaml` deliberately stays **one file carrying two check ids**:
one removed guarantee, two ways kube-linter names it.

The Kyverno rule id is the **autogen** one. The policy matches `kinds: [Pod]`
and these resources are Deployments, so Kyverno generates
`autogen-images-from-allowed-registry` from the authored
`images-from-allowed-registry` — and that generated name is what tool output
actually carries, as this variant's own `kyverno-test.yaml` asserts.

**Assert the `autogen-` prefixed name.** The authored name is a literal
*substring* of the generated one, so a harness grepping for it matches by
accident and proves nothing about autogen — the assertion would still pass if
the rule had never been generated at all.

Two separations keep every row one-to-one: `latest-tag.yaml` stays on the
**allowed** registry (`registry.example.com/app:latest`), so only `latest-tag`
fires and the Kyverno rule keeps passing; and `bad-registry.yaml` is **pinned**
(`other-registry.example.com/nginx:1.27.0`), so `latest-tag` does not also fire
and the only finding is the policy one.

The two `argocd` rows share a message template, so each row names the **path** its
red carries — that path is what keeps them individually attributable.

`dangling-multisource.yaml` differs from `dangling-app.yaml` in one respect only:
it declares its source in the multi-source `.spec.sources[]` shape. The argocd
job reads four source shapes and every other Application here uses the singular
one, so without this file a regression dropping the `sources[]` leg would change
nothing observable.

## Which jobs own nothing

`render` and `schema` are expected **green even here**, and a red in either is a
**regression**, not the fixture doing its job.

`config-scan` is a third case, and deliberately not part of that rule. It is
thresholded at `HIGH,CRITICAL` and none of these defects reaches that band, so it
*should* be green — but the job is **unasserted** (see below), so a red there is
not a fixture regression and must not be "fixed" by editing these manifests.

`render` and `schema` are backed by the whole-`RENDER_DIR` block below, and by
[`../../kubernetes-ci-fixtures.bats`](../../kubernetes-ci-fixtures.bats)
(#1199), which executes the workflow's own `run:` blocks over a temp copy of this
variant with the pinned toolchain — including the per-file assertions that keep
the table above one-to-one.

**`config-scan` is not**: it runs a third-party `trivy-action` that no command
here executes, and trivy's severity assignments move between releases, so a
promoted check could red it on a fixture nothing else objects to. #1199 made the
call — the job is **unasserted**, neither green nor red is claimed — and pinned
it with a test that fails the moment `config-scan` grows a `run:` step.

## `kyverno test` is never reached in this variant under the pipeline

The `policy` job runs `kyverno apply` **before** `kyverno test`, and under
`set -euo pipefail` the non-zero exit of `kyverno apply` over
`broken/bad-registry.yaml` ends the step there. The expected-fail fixture in
`policies/kyverno/kyverno-test.yaml` is therefore verified by running
`kyverno test` **directly** against this variant, not through the pipeline.

That also means a red `policy` job here is only attributable once you read its
output: the step can equally red on a dereference failure, the empty-selection
gate, or a failed CLI install. The policy-violation red is the one carrying
`require-registry` and `bad-registry` in its message.

## Run against a copy, never the working tree

The `policy` job dereferences `policies/kyverno` **in place** — `rm -rf` followed
by a `mv` of a mirror — so copy the variant to a temp directory before pointing a
**pipeline run** at it. The direct tool commands below are non-destructive and
are meant to run from this directory.

## The fixture contract

The `argocd` job verifies `.spec.source.path` / `.spec.sources[].path` only for
Applications whose `repoURL` names the repository under test, comparing against
the runner's own `github.repository`. This variant declares:

```text
repoURL: https://example.com/fixture-org/kubernetes-repo-broken.git
```

so a harness must present the slug **`fixture-org/kubernetes-repo-broken`** to
that job. Note *how*: the workflow pins `REPO_SLUG: ${{ github.repository }}` at
step level, and a step-level `env:` beats an exported shell variable — so
exporting `REPO_SLUG` around an unmodified workflow run does nothing. The
contract is met by a harness that **executes the job's `run:` block** with
`REPO_SLUG` set (which is what
[`../../kubernetes-ci-fixtures.bats`](../../kubernetes-ci-fixtures.bats) does),
or by overriding `github.repository`. Get it wrong *with a non-empty but wrong
slug* and the filter selects nothing, the job passes **vacuously**, and this
fixture's most important reds silently do not happen. An **empty** slug is no
longer one of the ways to get it wrong: since #1199 the step refuses it outright
with `::error::REPO_SLUG is empty …`.

## Verifying it directly

Run from this directory, with the **pinned toolchain** in front of your PATH
(plus `jq`):

```bash
REPO_ROOT=/path/to/timos-claude-code-plugins          # <- replace with your checkout
IAC_BIN="$(zsh "$REPO_ROOT/tests/iac-tools.zsh")"
[ -n "$IAC_BIN" ] \
  && export PATH="$IAC_BIN:$PATH" \
  || echo 'FAIL: toolchain not resolved — no verdict below is trustworthy'
zsh "$REPO_ROOT/tests/iac-tools.zsh" --print-pins      # the authoritative six versions
```

(No `exit` in that block on purpose: it is the one snippet here you must run in
your **current** shell, since the `export` is the whole point.)

**Every block below must be run in a subshell, and the one above must not.**
They open with `set -euo pipefail` and report failures with `exit 1`, so pasting
one into the shell you just exported `PATH` into would leave errexit set in it
and close it on the first FAIL — and this variant's blocks are *expected* to hit
those arms. Run them as a unit — `bash <<'EOF' … EOF`, or wrap in `( … )`. The
exported `PATH` is inherited by the subshell.

The script **prints** its bin directory; it cannot modify your shell's PATH, so
the `export` is what actually pins the run — and the emptiness check is what
stops a failed resolve from silently leaving an empty leading PATH entry (the
cwd) with no pinned tool on it. The versions are deliberately **not restated
here** — `--print-pins` is the one authoritative list.

**At those versions a red is a regression.** On any other version, re-run pinned
before concluding anything: kube-linter's default check set moves between
releases, so a newer binary reports a different count on this very fixture — the
`found 4 lint errors` assertion below is the first thing that will disagree.

`kube-linter`
takes no `--config`, exactly as the pipeline invokes it: it auto-discovers
`./.kube-linter.yaml` from the working directory, and that discovery is what
makes the non-default `no-readiness-probe` check apply at all.

Note the shape of every assertion below. In this variant the tools are
**expected to fail** — `kube-linter` exits non-zero whenever it reports a
finding, which is exactly what reds the pipeline's `lint` job — so each expected
red is wrapped in an `if` that fails the recipe when the command *succeeds*. A
plain `set -e` block would abort on the first row and prove nothing about the
rest. And each row asserts its **check id**, not merely a non-zero exit: the exit
status is identical whichever check fired, so without the `grep` the table's
one-file-one-check contract would be verified by eye only.

```bash
set -euo pipefail
rm -rf /tmp/b && mkdir -p /tmp/b

# the three lint-owned rows: each MUST fail, and MUST name its own check id(s)
if kube-linter lint broken/no-probe.yaml > /tmp/b/no-probe.txt 2>&1; then
  echo 'FAIL: no-probe.yaml produced no lint finding'; exit 1
fi
grep -q 'no-readiness-probe' /tmp/b/no-probe.txt || { echo 'FAIL: wrong check id'; exit 1; }

if kube-linter lint broken/no-limits.yaml > /tmp/b/no-limits.txt 2>&1; then
  echo 'FAIL: no-limits.yaml produced no lint finding'; exit 1
fi
grep -q 'unset-cpu-requirements'    /tmp/b/no-limits.txt || { echo 'FAIL: missing cpu id'; exit 1; }
grep -q 'unset-memory-requirements' /tmp/b/no-limits.txt || { echo 'FAIL: missing memory id'; exit 1; }

if kube-linter lint broken/latest-tag.yaml > /tmp/b/latest-tag.txt 2>&1; then
  echo 'FAIL: latest-tag.yaml produced no lint finding'; exit 1
fi
grep -q 'latest-tag' /tmp/b/latest-tag.txt || { echo 'FAIL: wrong check id'; exit 1; }

# bad-registry is the ONE row kube-linter must stay silent on: its defect is the
# policy's to catch, so here exit 0 is the expected result and needs no negation
kube-linter lint broken/bad-registry.yaml

kyverno test policies/kyverno/                     # passes: the failure is EXPECTED

# the policy row. Assert the COUNTER, not just the non-zero exit: kyverno apply
# also exits non-zero on a bad path, an unloadable policy or a missing binary.
if kyverno apply policies/kyverno/require-registry.yaml \
     --resource broken/bad-registry.yaml > /tmp/b/apply.txt 2>&1; then
  echo 'FAIL: the policy did not reject bad-registry.yaml'; exit 1
fi
grep -q 'fail: 1' /tmp/b/apply.txt \
  || { echo 'FAIL: the non-zero exit came from something other than the rule'; exit 1; }
```

To check `schema`, and to prove the lint findings stay attributable when the
whole directory is linted at once, build the pipeline's whole `RENDER_DIR` — the
render job sweeps every standalone `kind:`-bearing manifest, so the two Argo CD
documents and both policy files land in it too:

```bash
set -euo pipefail
# /tmp/b too, not just the render dir: this block writes its lint output there
# and is meant to stand alone. Without it a standalone run fails the redirect,
# skips the "produced no finding" branch, and then greps a file that does not
# exist — printing "FAIL: no-readiness-probe stopped firing", a false regression
# verdict whose real cause is a missing scratch directory.
rm -rf /tmp/b && mkdir -p /tmp/b
rm -rf /tmp/broken-rendered && mkdir -p /tmp/broken-rendered
for m in broken/*.yaml broken/argocd/*.yaml policies/kyverno/*.yaml; do
  cp "$m" "/tmp/broken-rendered/plain_$(printf '%s' "$m" | tr / _)"
done

kubeconform -strict -summary -ignore-missing-schemas /tmp/broken-rendered/  # 0 invalid: schema owns nothing

if kube-linter lint /tmp/broken-rendered/ > /tmp/b/all.txt 2>&1; then
  echo 'FAIL: the whole-directory lint reported nothing'; exit 1
fi
for id in no-readiness-probe unset-cpu-requirements unset-memory-requirements latest-tag; do
  grep -q "$id" /tmp/b/all.txt || { echo "FAIL: $id stopped firing"; exit 1; }
done
# exactly four, so an EXTRA finding (a manifest firing a second file's check, or
# a finding from the Argo CD / policy documents) reds this recipe too
grep -q 'found 4 lint errors' /tmp/b/all.txt \
  || { echo 'FAIL: not exactly 4 findings — attributability has drifted'; exit 1; }
```

### Checking the argocd filter

The `argocd` job extracts paths with `yq` + `jq` rather than the tools above, so
its two rows need their own check. The expression is the job's own, inlined here
so this block stands alone:

```bash
set -euo pipefail
JQ_EXPR='select(type == "object")
  | select(.apiVersion == "argoproj.io/v1alpha1")
  | select(.kind == "Application" or .kind == "ApplicationSet")
  | [ .spec.source, .spec.template.spec.source,
      (.spec.sources // [])[], (.spec.template.spec.sources // [])[] ]
  | .[] | select(. != null)
  | select(((.repoURL // "") | sub("/$"; "") | sub("\\.git$"; "") | ascii_downcase) as $u
      | (env.REPO_SLUG | ascii_downcase) as $s
      | ($u | endswith("/" + $s)) or ($u | endswith(":" + $s)))
  | (.path // empty)'
export REPO_SLUG=fixture-org/kubernetes-repo-broken
paths="$(for f in broken/argocd/*.yaml; do yq -o=json '.' "$f" | jq -r "$JQ_EXPR"; done | sort | tr '\n' ' ')"
[ "$paths" = 'charts/also-missing charts/does-not-exist ' ] \
  || { echo "FAIL: expected both dangling paths, got: [$paths]"; exit 1; }
```

Both must appear: `charts/does-not-exist` comes from `dangling-app.yaml` via
`.spec.source`, and `charts/also-missing` from `dangling-multisource.yaml` via
`.spec.sources[]`. A run printing only the first means the multi-source leg has
regressed — and the job would still be red, which is exactly why this check is
needed to keep that file load-bearing.

## Sibling variants

| variant | expectation |
| --- | --- |
| [`../kubernetes-repo/`](../kubernetes-repo/) | fully green |
| `.` (this one) | red, every finding attributable to one file |
| [`../kubernetes-repo-untested-policy/`](../kubernetes-repo-untested-policy/) | green, with the untested-policy warning |

No network access, no private content, and no reference to any real deployment.

