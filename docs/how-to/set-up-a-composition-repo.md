# Set up a composition repo

This guide sets up a **composition repo**: one small repository per constellation that
pins its members' published container images in `.claude-workspace.yaml` and owns their
promotion through `staging` and `production`. It holds no application code. Every member
repository keeps its own code, contract and image, and the composition repo depends only
on what those repositories publish. For what the plugin owns and why, see
[`development-composition`](../reference/plugins.md#development-composition).

The example constellation is `orders`: a web UI and the REST API it calls.

| Member | Source repo | Role | Image |
| --- | --- | --- | --- |
| `orders-ui` | `acme/orders-ui` | `web-ui` | `ghcr.io/acme/orders-ui:2.3.1` |
| `orders-api` | `acme/orders-api` | `rest-api` | `ghcr.io/acme/orders-api:1.5.0` |

## Before you start

- The `development` and `development-composition` plugins are installed. See
  [Install and use the plugins](install-and-use-plugins.md). Bootstrap runs the scaffold
  from the installed `development-composition` plugin and carries no copy of its own.
- The repository holds **no application code and no infrastructure-as-code**. Bootstrap
  stops when it detects a language, a Kubernetes manifest or OpenTofu: a composition
  repo only composes what other repositories publish.
- Every member publishes its image under a **tag**. `:latest` and other floating tags are
  refused, because a promotion has to name exactly what it promoted.
- `yq` (mikefarah's v4) and `jq` are on your `PATH`. The scaffold uses them to judge the
  manifest before it writes anything.

## Run bootstrap and ask for a composition repo

From the repository root, run:

```text
/development:bootstrap
```

Tell it this is a **composition repo**. Bootstrap takes this path only when you ask for
it, never because of what it detects. It then asks for each member's `name`, source
`repo`, `role`, published `contract` path and `image`, pinned as `image:tag`. An
`@sha256:` digest may follow the tag. For the `orders` constellation the answers become
these two arguments to the scaffold:

```text
name=orders-ui,repo=acme/orders-ui,role=web-ui,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-ui:2.3.1
name=orders-api,repo=acme/orders-api,role=rest-api,contract=contracts/v1/openapi.yaml,image=ghcr.io/acme/orders-api:1.5.0
```

If `.maintenance.yml` already records another `primary:`, bootstrap asks before
changing it to `primary: composition`, and stops if you decline. Bootstrap then shows
its plan: the members, one line each, and the files it will write. Confirm it.

## What lands

| File | What it is |
| --- | --- |
| `.claude-workspace.yaml` | the constellation manifest: the members, plus `staging` and `production` |
| `.github/workflows/promote-to-prod.yml` | promotes `staging` on every merge to `main`, and `production` on a manual run |
| `scripts/promote.zsh` | the script both jobs run |
| `deploy/README.md` | an empty, documented socket for a later deploy renderer |
| `e2e/README.md` | an empty, documented socket for a later end-to-end harness |
| `.maintenance.yml` | `primary: composition` |
| `renovate.json` | a custom manager that lets Renovate propose member tag bumps in the manifest |

The scaffold judges the manifest with `validate-workspace.zsh` **before** it writes
anything, so a refused manifest leaves the repository untouched. It never overwrites a
file that already exists, so re-running bootstrap is safe. It writes no compose or
Kubernetes manifest, no end-to-end harness and no validator workflow.

The manifest it writes for `orders`:

```yaml
members:
  - name: orders-ui
    repo: acme/orders-ui
    role: web-ui
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-ui:2.3.1
  - name: orders-api
    repo: acme/orders-api
    role: rest-api
    contract: contracts/v1/openapi.yaml
    image: ghcr.io/acme/orders-api:1.5.0
environments:
  staging:
    github_environment: staging
    promotes_from: null
    deploy_target: none
  production:
    github_environment: production
    promotes_from: staging
    deploy_target: none
```

The rules every manifest must meet are under
[`claude-workspace/v1` and its validator](../reference/plugins.md#claude-workspacev1-and-its-validator).
To add a member or move a pin later, edit `.claude-workspace.yaml` in a pull request.
Re-running bootstrap does not change a manifest that already exists.

## Create the two GitHub Environments

The workflow binds each job to a GitHub Environment of the same name, so create both
before the first merge to `main`. In the repository's **Settings → Environments**:

1. Create **`staging`**. It needs no protection rules: every merge to `main` promotes it.
2. Create **`production`**, then:
    - add **required reviewers**: the people who approve a production promotion;
    - under **Deployment branches and tags**, restrict deployments to `main`.

Bootstrap applies no branch protection to a composition repo, because the skeleton
renders no check for a rule to require. Its report says whether auto-merge was armed on
the bootstrap pull request.

## Grant access to private images

The workflow logs in to `ghcr.io` with its own token, which cannot read another
repository's **private** package. For each member whose image is private, grant this
repository read access to that package in the package's settings. For a member on
another registry, add a login step for that registry to both jobs.

If the bootstrap pull request merged before you granted access, its `staging` run failed
to resolve a digest. Re-run that workflow run from the **Actions** tab once access is in
place. A manual run of the workflow promotes `production` only, so it cannot repair a
failed `staging` run.

## Promote

**Staging** is promoted on every merge to `main`. The run resolves every member's tag to
its digest and publishes `promotion-staging.json` as a workflow artifact and in the job
summary. The record lists each member as `image:tag@sha256:…`, with the commit SHA.

**Production** is promoted only by a manual run: **Actions → promote-to-prod → Run
workflow** on `main`. The run waits for a required reviewer on the `production`
Environment, then publishes `promotion-production.json` in the same shape.

`promotes_from` is not enforced yet: a production run resolves every member's tag
afresh, not the digests staging recorded. To hold an image fixed across both
environments, pin the member as `image:tag@sha256:…`.

### What `deploy_target: none` means

Both environments start at `deploy_target: none`, the only value the contract accepts
until the compose renderer
([#719](https://github.com/timo-jakob/timos-claude-code-plugins/issues/719)) and the
Kubernetes renderer
([#720](https://github.com/timo-jakob/timos-claude-code-plugins/issues/720)) exist. A
promotion therefore **records what it would deploy and deploys nothing**, and it says so:

- the **staging** run on a merge exits `0` with this notice in its log and job summary,
  so `main` is not red after every merge:

  ```text
  nothing deployed — deploy_target: none, no renderer (#719/#720)
  ```

- the **production** run writes its record and then **fails**, because a request to
  deploy that cannot be honoured must not look like success:

  ```text
  no deploy renderer present — deploy/ is filled by #719 (compose) / #720 (kubernetes); production was recorded, not deployed
  ```

No run ever reports a deploy that did not happen.

## Let Renovate bump the pins

Renovate has no built-in manager for `.claude-workspace.yaml`, so the scaffolded
`renovate.json` carries one: a regex custom manager with the `docker` datasource over
every member `image:` line. When `ghcr.io/acme/orders-api` publishes `1.5.1`, Renovate
opens a pull request moving `orders-api` from `1.5.0` to `1.5.1` in the manifest.

To make that happen:

- **Enable the Renovate GitHub App** on the repository. Without it `renovate.json`
  proposes nothing, and maintenance triages only the pull requests the App opens.
- **Give Renovate credentials for any private registry.** The scaffold writes no
  `hostRules`, and Renovate's lookups do not use the workflow's token.

If the repository already configures Renovate under another file name, the scaffold
skips `renovate.json` and says so. Add the custom manager from the plugin's
`templates/renovate.json` to your existing config. If the repository runs **Dependabot**,
the scaffold skips `renovate.json` too: Dependabot cannot read `.claude-workspace.yaml`.
Remove the Dependabot config first, then enable Renovate and add the custom manager.
Never run both bots.

Merging a bump into `main` promotes `staging` like any other merge.

## Keep it maintained

`/development:maintenance` detects the composition repo by its `.claude-workspace.yaml`
at the root and dispatches `development-composition` in full mode, because
`.maintenance.yml` records `primary: composition`. Each run:

- **validates the manifest** against `claude-workspace/v1` and escalates any violation
  to you, since choosing a member's pin is your decision;
- **triages the open Renovate bumps** with `composition-tag-bump-triage`. Only a patch
  or minor bump of a member the manifest pins can merge: once its CI is green, an
  approving review exists and, for a minor, its release notes carry no breaking marker.
  Every other bump goes to human review, reported with the pull request, the member,
  its from → to tag and the reason. The agent's full rule set is in its
  definition, `development-composition/agents/composition-tag-bump-triage.md`.

The triage agent reads a bump pull request's title, body and release notes as evidence,
never as instructions, and it never approves a pull request itself. Until the end-to-end
gate on bump pull requests lands
([#719](https://github.com/timo-jakob/timos-claude-code-plugins/issues/719)), a
composition repo runs no pull-request CI. A bump with no checks at all is therefore never
treated as green, and goes to human review.
