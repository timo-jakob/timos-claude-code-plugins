# Claude Code Plugins

A collection of plugins for [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
that **bootstrap new projects with a quality + security toolchain baked in**,
then **maintain, review, and ship** changes with maximum safe automation —
pulling a human into the loop only when human judgment is genuinely required.

## Why

Bootstrap projects fast, ship high-quality and secure-by-default software, and
use Claude for maximum automation — building the seams, gates, and policies
today so that as the model gets stronger, the share of work it can safely close
out without a human grows automatically.

Read more: [Motivation & current gaps](docs/explanation/motivation.md) ·
[Why per-language plugins?](docs/explanation/why-per-language-plugins.md) ·
[The Claude Approver](docs/explanation/claude-approver.md).

## What's in the box

| Plugin | Purpose |
| --- | --- |
| **development** | Language-agnostic workflow tooling — bootstrap, maintenance orchestrator, commit, resolve-issue, refine-issue, define-personas, open-pr, branch naming |
| **development-python** | Full Python maintenance tier — triage, autonomous upgrades, coverage, review, Approver |
| **development-java** | Full Java/Gradle maintenance tier (Gradle + Kotlin DSL only) |
| **development-swift** | Full Swift maintenance tier — incl. Swift 6 migration |
| **development-go** | Full Go maintenance tier — triage, coverage, autonomous upgrades, review, Approver, proto-first advisors |
| **development-spring** | Topic plugin for Spring Boot 4+ (composes alongside development-java) |
| **development-claude-plugin** | Topic plugin for repos that *are* Claude Code plugins — validators + test harness |
| **development-docs** | Topic plugin for documentation (C4 architecture docs; marker `docs/architecture/`) — dispatch path only in v1 |
| **development-react** | Topic plugin for React (composes alongside development-javascript; marker `react` in a `package.json`'s runtime deps) — composition wiring only in v0.1 |
| **development-kubernetes** | Topic plugin for infrastructure-as-code (Kubernetes manifests, Helm, Kustomize, Argo CD; may be *primary* for a repo with no application language) — ownership boundary, maintenance dispatch, and the agents and review panel in v0.3; its CI pipeline ships as a `development` bootstrap template (six requirable checks over *rendered* output); test fixtures still to come |
| **development-opentofu** | Topic plugin for cloud provisioning (OpenTofu + Terraform-compatible HCL; may be *primary* for a repo with no application language) — ownership boundary and marketplace registration only in v0.1; no approver agent, because a provisioning change can destroy state no rollback recovers |

Full command + agent inventory: **[docs/reference/plugins.md](docs/reference/plugins.md)**.

## Install & use

```sh
claude --plugin-dir ./development --plugin-dir ./development-python
```

```bash
/development:bootstrap        # install the quality + security toolchain
/development:maintenance      # fix everything safely fixable on this project
/development:resolve-issue 42 # drive an issue (or epic) to a merge-ready PR
```

New here? Start with the **[Getting started tutorial](docs/tutorials/getting-started.md)**.
Prerequisites (macOS + Homebrew, `gh`): **[Requirements](docs/reference/requirements.md)**.

## Documentation

Full documentation lives under **[`docs/`](docs/index.md)** and follows the
[Diátaxis](https://diataxis.fr/) framework:

- 📚 **[Tutorials](docs/tutorials/index.md)** — learning-oriented
- 🔧 **[How-to guides](docs/how-to/index.md)** — task-oriented
- 📖 **[Reference](docs/reference/index.md)** — lookup
- 💡 **[Explanation](docs/explanation/index.md)** — concepts & rationale
- 🏗 **[Architecture](docs/architecture/index.md)** — C4 System Context + Container diagrams

Contributor-facing contracts stay at the repo root:
[`ARCHITECTURE.md`](ARCHITECTURE.md) (architecture & schema) and
[`MAINTAINING.md`](MAINTAINING.md) (quarterly template refresh).

## Contributing

`main` is protected: PRs only, 1 approving review, all required checks green, and
**cryptographically signed commits required**. See
**[How-to: contribute](docs/how-to/contributing.md)** for the SSH-signing setup.

## License

MIT
