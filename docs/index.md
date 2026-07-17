# Documentation — Claude Code Plugins

A collection of plugins for [Claude Code](https://docs.anthropic.com/en/docs/claude-code)
that bootstrap new projects with a quality + security toolchain baked in, and
then maintain, review, and ship changes with maximum safe automation.

This is the **Map of Content (MOC)**: every documentation page, grouped by what
you're trying to do. The docs follow the [Diátaxis](https://diataxis.fr/)
framework — learning, tasks, lookup, and understanding are kept deliberately
separate.

> **New here?** Start with [Getting started](tutorials/getting-started.md), then
> skim [Motivation](explanation/motivation.md) for the "why".

## 📚 Tutorials — learning-oriented

- [Tutorials overview](tutorials/index.md)
- [Getting started: bootstrap and maintain a project](tutorials/getting-started.md)

## 🔧 How-to guides — task-oriented

- [How-to overview](how-to/index.md)
- [Authoring guide — where docs go](how-to/authoring-guide.md)
- [Write docs in a bootstrapped repo](how-to/write-docs-in-a-target-repo.md)
- [Install and use the plugins](how-to/install-and-use-plugins.md)
- [Adopt the Claude Approver on your repo](how-to/adopt-the-approver.md)
- [Adopt C4 architecture docs on an existing repo](how-to/adopt-c4-architecture-docs.md)
- [Amend a C4 diagram by hand](how-to/amend-a-c4-diagram.md)
- [Maintain this repo (quarterly template refresh)](how-to/maintain-this-repo.md)
- [Contribute (signed commits, branch protection)](how-to/contributing.md)
- [Add support for a new language plugin](adding-a-language-plugin.md)

## 📖 Reference — lookup

- [Reference overview](reference/index.md)
- [Plugin & command inventory](reference/plugins.md)
- [`c4_drift` findings](reference/c4-drift-findings.md)
- [Repo scripts](reference/repo-scripts.md)
- [Requirements](reference/requirements.md)

## 💡 Explanation — concepts & rationale

- [Explanation overview](explanation/index.md)
- [Motivation & current gaps](explanation/motivation.md)
- [Why per-language plugins?](explanation/why-per-language-plugins.md)
- [The Claude Approver — design summary](explanation/claude-approver.md)
- [The C4 architecture docs](explanation/c4-architecture-docs.md)
- [The target-repo docs stack](explanation/target-repo-docs-stack.md)

## 🏗 Architecture

- [Architecture overview](architecture/index.md)
- [System Context (C4)](architecture/c4-context.md)
- [Container Diagram (C4)](architecture/c4-container.md)
- [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)
  — the authoritative contributor/Claude-facing architecture & schema contract
  (kept at repo root).
- [`MAINTAINING.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/MAINTAINING.md)
  — quarterly template-refresh procedure (repo root).

## Per-plugin & per-skill deep-dive docs

These live next to the code they document and are linked here so they are not
orphaned:

| Doc | Covers |
| --- | --- |
| [`development-claude-plugin/docs/test-harness.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-claude-plugin/docs/test-harness.md) | The plugin end-to-end test harness |
| [`development-java/docs/java-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-java/docs/java-approver.md) | Java Approver runtime spec |
| [`development-python/docs/api-stability.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/docs/api-stability.md) | Python library-exports API-stability gate |
| [`development-python/docs/python-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-python/docs/python-approver.md) | Python Approver runtime spec + findings schema |
| [`development-swift/docs/swift-approver.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development-swift/docs/swift-approver.md) | Swift Approver runtime spec |
| [`development/skills/bootstrap/docs/APPROVER.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER.md) | Operator-facing Approver adoption guide |
| [`development/skills/bootstrap/docs/APPROVER-APP.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/APPROVER-APP.md) | Decentralized Approver App design |
| [`development/skills/bootstrap/docs/CLAUDE-APPS.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/CLAUDE-APPS.md) | GitHub App registration & setup |
| [`development/skills/bootstrap/docs/ACCEPTANCE-CLI-VALIDATION.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/bootstrap/docs/ACCEPTANCE-CLI-VALIDATION.md) | Acceptance-test CLI validation |
| [`development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/docs/END-TO-END-WALKTHROUGH.md) | Issue-refinement end-to-end walkthrough |
| [`development/skills/refine-issue/docs/PERSONA-CONSUMPTION-VALIDATION.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/refine-issue/docs/PERSONA-CONSUMPTION-VALIDATION.md) | Persona-consumption validation |
| [`development/skills/resolve-issue/docs/VALIDATION.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/resolve-issue/docs/VALIDATION.md) | resolve-issue validation evidence |
| [`development/skills/resolve-issue/docs/DEPENDENCY-VALIDATION.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/development/skills/resolve-issue/docs/DEPENDENCY-VALIDATION.md) | Dependency-aware resolve-issue validation |

---

*This documentation tree is maintained under epic
[#744](https://github.com/timo-jakob/timos-claude-code-plugins/issues/744).
See [How-to: contribute](how-to/contributing.md) and the
[authoring guide](how-to/authoring-guide.md) for where new pages belong.*
