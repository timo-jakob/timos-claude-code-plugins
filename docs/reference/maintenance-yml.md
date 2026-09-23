# `.maintenance.yml`

`/development:bootstrap` writes `.maintenance.yml` at the root of the repository it
bootstraps. The file records decisions about the repository. Nothing else in the
repository encodes them, and every later bootstrap run and maintenance run reads them
from here instead of inferring them again.

A repository bootstrapped on the infrastructure-as-code path gets two keys:

```yaml
primary: kubernetes
gate: make lint
```

Every other repository gets `primary:` and a `tools:` block instead of `gate:`:

```yaml
primary: python
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
- **Current limits.** Bootstrap finishes only the visibility default today: for any other
  toolchain it shows its plan and stops, because branch protection and the setup
  automation still follow visibility
  ([#1671](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1671)).
  `/development:maintenance` does not read `tools:` yet
  ([#1672](https://github.com/timo-jakob/timos-claude-code-plugins/issues/1672)).
