# System Context

The system context for **timos-claude-code-plugins** — who uses it and the
systems it talks to. This repo is not a service; it is a **Claude Code plugin
marketplace** whose skills and agents act on *other* repositories, so its
landscape is the plugins, the two GitHub App identities they operate under, the
target repositories they maintain, and the external services the pipelines read.

Authored by hand against the `c4/v1` contract
([ARCHITECTURE.md](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)).
Refine the actors and external systems as the architecture settles.

```mermaid
C4Context
    title System Context — timos-claude-code-plugins

    Person(developer, "Developer / Maintainer", "Invokes the plugins from Claude Code")

    Enterprise_Boundary(family, "Claude Code plugin family") {
        System(plugins, "timos-claude-code-plugins", "Plugin marketplace: bootstrap, maintenance, review, resolve-issue, open-pr")
        System(maint_app, "Maintenance App", "GitHub App — writer tokens, bot PRs, auto-merge")
        System(approver_app, "Approver App", "GitHub App — PR review + approval")
    }

    System_Boundary(saas, "External services the pipelines read") {
        System_Ext(github, "GitHub", "Repos, PRs, Actions CI")
        System_Ext(sonar, "SonarCloud", "Static analysis / quality gate")
        System_Ext(snyk, "Snyk", "Dependency + container CVEs")
    }

    System_Ext(target_repos, "Target repositories", "ai-doc-organizer, tick-client-snapper, … — bootstrapped + maintained")
    System_Ext(reporting, "Reporting repo (planned, #740)", "Telemetry → Grafana")

    Rel(developer, plugins, "runs /development:* skills")
    Rel(plugins, target_repos, "bootstraps + maintains")
    Rel(plugins, github, "opens PRs, reads CI")
    Rel(plugins, sonar, "reads findings")
    Rel(plugins, snyk, "reads findings")
    Rel(plugins, reporting, "emits telemetry (planned)")
    Rel(plugins, maint_app, "mints writer token via")
    Rel(plugins, approver_app, "mints approver token via")
    Rel(maint_app, github, "authors bot PRs on")
    Rel(approver_app, github, "posts reviews on")

    UpdateLayoutConfig($c4ShapeInRow="2", $c4BoundaryInRow="2")
```

The diagram renders natively on GitHub and through the MkDocs Material +
`superfences` pipeline (client-side Mermaid). No build gate validates the Mermaid
body — see the [Container diagram](c4-container.md) for the machine-checkable
declared-container set.
