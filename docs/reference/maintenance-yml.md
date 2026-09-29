# `.maintenance.yml`

`/development:bootstrap` writes `.maintenance.yml` at the root of the repository it
bootstraps. The file records decisions about the repository. Nothing else in the
repository encodes them, and every later bootstrap run and maintenance run reads them
from here instead of inferring them again.

A repository bootstrapped on the infrastructure-as-code path gets three keys:

```yaml
primary: kubernetes
approval: human
gate: make lint
```

Every other repository gets `primary:`, `approval:` and a `tools:` block instead of
`gate:`:

```yaml
primary: python
approval: approver
tools:
  static_analysis: sonarcloud
  vulnerabilities: snyk
  code_scanning: codeql
```

A single bootstrap run writes `gate:` or `tools:`, never both.

## Keys

| Key | Written on | Value | Read by |
| --- | --- | --- | --- |
| `primary:` | every bootstrap | the repository's primary type | `/development:maintenance`, bootstrap re-runs |
| `approval:` | every path except the composition path | who approves the repository's PRs: `human` or `approver` | bootstrap re-runs |
| `gate:` | the IaC path only (`primary: kubernetes`) | the repository's gate command; default `make lint` | bootstrap, which renders it into two files |
| `tools:` | every path except the IaC path | the quality toolchain, in three categories | bootstrap re-runs |

## `primary:`

The repository's **primary type**: its reason to exist. The value is a language
(`python`, `java`, `go`, `swift`, `javascript`) or a topic (`claude-plugin`,
`kubernetes`).

- **Effect.** `/development:maintenance` gives the primary type the full pipeline,
  including its app-grade gates such as the coverage floor and dependency upgrades.
  Every other language or topic it detects is **auxiliary** and gets lint-level
  treatment only. With no `.maintenance.yml`, every detected stack is treated as primary.
- **How bootstrap chooses it.** A Claude plugin repository gets `claude-plugin`. A
  repository with exactly one detected language gets that language. A repository with no
  language that you bootstrap as a GitOps repository gets `kubernetes`. When several
  languages are detected, bootstrap asks which one is primary. Bootstrap shows the value
  in its plan before writing it.
- **On a re-run.** A recorded value stands. Bootstrap does not overwrite a recorded
  `primary:` without asking. When the repository looks like a GitOps repository but
  records another primary, bootstrap reports the conflict and asks whether to change it.
- **`primary: kubernetes` alone does not select the IaC path.** Bootstrap selects that
  path from what it detects and from your answers in the current run. A recorded
  `primary:` with any other value takes the repository off the IaC path, unless you agree to
  change it when bootstrap reports the conflict.

## `approval:`

The repository's **approval model**: who supplies the approving review its pull
requests need.

| Value | Who approves | What bootstrap sets up |
| --- | --- | --- |
| `human` | a person reviews and approves; armed auto-merge then merges | the writer App only — no Approver policy |
| `approver` | the Claude Approver approves; armed auto-merge then merges | both Apps and `.claude/approver-policy.md` — only the writer App, and no policy, while no Approver-capable language (Python, Java, Swift) resolves |

The writer App opens the pull request under both models. On the
infrastructure-as-code path bootstrap offers to install it when it opens its pull
request, rather than during setup automation.

- **Written on every path except the composition path**, whose repository records
  no `approval:`.
- **How bootstrap chooses it.** `--claude-approver true` chooses `approver` and
  `--claude-approver false` chooses `human`. Without the flag, a language repository
  defaults to `approver` when both Claude Apps are registered on the machine for the
  repository's owner. Otherwise it defaults to `human`. Bootstrap shows the
  value and where it came from (`recorded`, `chosen` or `default`) in its plan, and
  names it in its final report.
- **Claude plugin and infrastructure-as-code repositories are always `human`.** A
  plugin repository admits no AI approval, and an infrastructure-as-code repository has
  no language the Approver reviews. Bootstrap refuses a recorded `approval: approver`
  on either, and ignores `--claude-approver true` with a warning.
- **On a re-run.** A recorded value wins over the flag and the default, so two people
  bootstrapping the same repository get the same model, whatever Apps their machines
  hold. A flag that disagrees with the recorded value is ignored, with a warning. To
  change the model, edit `approval:` and re-run bootstrap; switching an
  already-bootstrapped repository to `approver` this way does not yet render its
  Approver policy
  ([#1928](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1928)). When
  an existing `.maintenance.yml` has no `approval:` key, bootstrap appends one and
  leaves every other line as it is.
- **What counts as recorded.** An absent key, `null` and a blank value are **not**
  recorded values.
- **Current limits.** `/development:maintenance` does not read `approval:` yet.

## `gate:`

The repository's **gate command**: the one command that validates the repository,
locally and in CI.

- **Written only on the IaC path**, where bootstrap also records `primary: kubernetes`.
  Every other repository gets no `gate:` key.
- **Default:** `make lint`. The Makefile's `lint` target runs `scripts/k8s-gate.zsh`,
  which is documented under
  [Scripts bootstrap emits into a target repository](repo-scripts.md#scripts-bootstrap-emits-into-a-target-repository).
- **Where the value goes.** Bootstrap renders the value into two files: the last step of
  `.github/workflows/kubernetes-ci.yml`'s `gate` job, and `hooks/pre-push`. Neither file
  reads `.maintenance.yml` when it runs, so after changing `gate:` you must re-run
  bootstrap to update them.
- **On a re-run.** A recorded value is kept byte for byte and rendered into both files,
  so a command you renamed stays renamed. When an existing `.maintenance.yml` has no
  `gate:` key, bootstrap appends one with the default.
- **What counts as recorded.** An absent key, `null` and a blank value are **not**
  recorded values. In each of those cases bootstrap uses the default, `make lint`.

## `tools:`

The **quality toolchain** is recorded as three independent categories, each with its own
set of values:

| Category | Values | Public default | Private default |
| --- | --- | --- | --- |
| `static_analysis` | `sonarcloud`, `sonarqube` | `sonarcloud` | `sonarqube` |
| `vulnerabilities` | `snyk`, `trivy` | `snyk` | `trivy` |
| `code_scanning` | `codeql`, `none` | `codeql` | `none` |

- **Written on every path except the IaC path.** The IaC path renders none of the quality
  workflows these tools run in, so it records no `tools:` block.
- **Defaults** come from the repository's visibility. Bootstrap offers them and lets you
  choose differently where a category has a choice.
- **On a re-run.** A recorded value wins over the visibility default. Bootstrap appends a
  missing `tools:` block, adds only the keys missing from a partial block, and leaves a
  complete block byte-identical. An absent, empty or `null` `tools:` records nothing.
- **Two rejected combinations:** `static_analysis` set to `sonarqube` on a public
  repository — SonarQube runs on a self-hosted runner, and a public repository never gets
  one — and `code_scanning` set to `codeql` on a private repository, since CodeQL on a
  private repository needs GitHub Advanced Security. Every other combination is valid,
  and bootstrap composes the quality workflows from the tools you declare, running them
  on a self-hosted runner exactly when `static_analysis` is `sonarqube`.
- **Setup automation follows the declared tools too.** Branch protection, the setup
  preflight and the setup automation all follow `tools:`: bootstrap's Step 4.5 runs
  each tool's setup script under that tool's trigger rather than by visibility;
  only the GitHub security toggles still follow visibility
  ([#1769](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1769)).
- **Current limits.** `/development:maintenance` does not read `tools:` yet
  ([#1672](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1672)).
