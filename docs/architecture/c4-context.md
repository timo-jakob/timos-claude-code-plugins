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
        System(plugins, "timos-claude-code-plugins", "Plugin marketplace: bootstrap, maintenance, review, resolve-issue, and open-pr pipelines")
        System(maint_app, "Maintenance App", "GitHub App identity — mints writer tokens, authors bot PRs, arms auto-merge")
        System(approver_app, "Approver App", "GitHub App identity — synthesis-layer PR review and approval")
    }

    System_Ext(github, "GitHub", "Repositories, pull requests, Actions CI, branch protection")
    System_Ext(sonar, "SonarCloud", "Static analysis and quality gate")
    System_Ext(snyk, "Snyk", "Dependency and container CVE scanning")
    System_Ext(target_repos, "Target repositories", "ai-doc-organizer, tick-client-snapper, … — the repos the pipelines bootstrap and maintain")
    System_Ext(reporting, "Reporting repo (planned, #740)", "Telemetry hand-off to a Grafana dashboard")

    Rel(developer, plugins, "Runs /development:* skills in Claude Code")
    Rel(plugins, target_repos, "Bootstraps and maintains")
    Rel(plugins, maint_app, "Mints writer tokens via")
    Rel(plugins, approver_app, "Mints Approver token via /development-<lang>:approve")
    Rel(maint_app, github, "Authors bot PRs, arms auto-merge on")
    Rel(approver_app, github, "Posts reviews, approves PRs on")
    Rel(plugins, github, "Reads CI status, opens PRs on")
    Rel(plugins, sonar, "Reads findings from")
    Rel(plugins, snyk, "Reads findings from")
    Rel(plugins, reporting, "Emits telemetry to (planned, #740)")

    UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="2")
```

The diagram renders natively on GitHub and through the MkDocs Material +
`superfences` pipeline (client-side Mermaid). No build gate validates the Mermaid
body — see the [Container diagram](c4-container.md) for the machine-checkable
declared-container set.
