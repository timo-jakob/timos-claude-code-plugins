# Bootstrap an OpenTofu repository

This guide sets up a repository of OpenTofu or Terraform code, with no application code,
so that one gate command validates it locally and in CI. No cloud credentials are needed.
For why the gate works this way, see [The IaC gate](../explanation/iac-gate.md).

## Before you start

- The `development` plugin is installed. See [Install and use the plugins](install-and-use-plugins.md).
- The repository holds at least one `.tf` file outside `.terraform/` and vendored trees,
  and **no application language**. A repository with `.tf` files **and** application code
  is bootstrapped as a language repository, and this path does not apply to it.
- The repository holds **no Kubernetes** chart, kustomization or Argo CD resource.
  Bootstrap stops on a repository with both kinds of infrastructure code; that case is
  [#1394](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1394).
- You are on macOS with Homebrew. Bootstrap's preflight uses `brew install` to install
  the gate's tools: `opentofu`, `tflint`, `trivy` and `conftest`.

## Run bootstrap and answer the language question

From the repository root, run:

```text
/development:bootstrap
```

Bootstrap finds no application language, recognises the `.tf` files and offers
**"none — this is a GitOps/IaC repo"**. Choose it.

If `.maintenance.yml` already records a different `primary:`, bootstrap does not
overwrite it. It reports the conflict and asks whether to change the record. See
[`.maintenance.yml`](../reference/maintenance-yml.md#primary).

Bootstrap then shows its plan. Confirm it to write the files.

## What lands

| File | What it is |
| --- | --- |
| `Makefile` | `make lint` runs the gate; `make hooks` wires the pre-push hook |
| `scripts/tofu-gate.zsh` | the gate's seven stages: fmt → validate → lint → config-scan → state-encryption → policy → plan-policy |
| `hooks/pre-push` | runs the gate command before every push, once wired |
| `.github/workflows/opentofu-ci.yml` | one job, `gate`, which installs the pinned tools and runs the gate command on every pull request |
| `.maintenance.yml` | `primary: opentofu` and `gate: make lint` |

Branch protection on `main` requires the single `gate` check. Bootstrap does not write any
of the application gates: coverage, Sonar, CodeQL or a `pre-commit` configuration.

## Run the gate

```sh
make lint
```

Each stage prints one verdict line, `gate: <stage> ok`, `gate: <stage> skipped — <reason>`
or `gate: <stage> FAILED`. A failing stage prints its tool's output directly above its line.
The gate stops at the first failure.

- `validate` runs `tofu init -backend=false` and `tofu validate` once per **root module**:
  every directory holding `.tf` or `.tf.json` files that no other directory calls as a
  local module. A module called through `source = "../../modules/network"` is validated
  through its caller.
- `state-encryption` never fails the gate. It warns when the repository owns state, through
  a `provider`, `backend` or `cloud` block, and nothing encrypts that state at rest. An
  OpenTofu `encryption` block, an S3 backend with `encrypt = true` or `kms_key_id`, a GCS
  `encryption_key`, an `azurerm` backend or a `cloud` block each clear it. A module
  library with no `provider` or `backend` block owns no state and gets no warning.
- The gate runs every stage on a scratch copy, so `tofu init` never writes `.terraform/`
  into your working tree.

## Wire the pre-push hook

```sh
make hooks
```

This sets git's `core.hooksPath` to the repository's `hooks/` directory, so
`hooks/pre-push` runs the gate command before every push. git does not carry that setting
in a clone, so **everyone who clones the repository runs `make hooks` once**.

## Add your own policies

The gate ships no policies. The `policy` stage prints a notice and skips until you declare
some.

1. Create `policies/conftest/hcl/` and add Rego policies there. They are evaluated against
   your `.tf` files, parsed as HCL. Every namespace is evaluated, not only `main`.
2. Add tests: a `*_test.rego` file, or `test_` rules, beside the policies. Without them the
   stage runs `conftest test` but skips `conftest verify` and prints a warning, because an
   untested policy usually matches nothing.
3. Run `make lint`.

Keep plan policies apart in `policies/conftest/plan/`. A rule written for one document
shape passes vacuously against the other, so the two stages never read each other's
directory. A `.rego` anywhere else under `policies/conftest/` fails the `policy` stage,
which names the file: move it into `hcl/` or `plan/`.

## Turn on the plan stage

`plan-policy` runs `tofu plan` per root module and evaluates `tofu show -json` against
`policies/conftest/plan/`. It needs your backend and provider credentials, so it is off
until you record, in `.maintenance.yml`:

```yaml
opentofu_plan_policy: true
```

The hook and CI read the same key. Then forward the credentials to the `run the gate` step
of `.github/workflows/opentofu-ci.yml` through its commented `env:` block. With the key
on and no usable credentials, the stage fails and names the key, so a half-enabled stage
never passes silently.
