# Container Diagram

The deployable units that make up **timos-claude-code-plugins** — the installed
**plugins** of the marketplace, plus the one Docker image the repo builds. Each
`Container(...)` entry follows the `c4/v1` declared-container shape
([ARCHITECTURE.md](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)),
so the maintenance pipeline can compare it against the code (`c4_drift`).

Every plugin is itself composed of **skills** (multi-step procedures the user
invokes as `/plugin:skill`) and **agents** (single-purpose sub-agents the skills
dispatch to) — the skills/agents split described in ARCHITECTURE.md. That split
is a Component-level concern; at Container level the deployable unit is the
plugin. The orchestrator (`development:maintenance`) dispatches a JSON payload to
the matching **language plugin** *and* to any **topic plugins** whose markers
fire; a topic plugin composes alongside the language plugin for that run.

> **Detection note — declared vs detected on a marketplace-shaped repo.**
> `c4/v1`'s detector (`detect-stack.sh`, #799) keys on Dockerfiles, compose
> services, and build images. Run here it finds exactly **one** container —
> `tests` (`tests/Dockerfile`, the bats-in-Docker test runner, #263) — which
> this diagram **declares**, so there is no `detected_not_declared` drift. The
> twelve **plugins**, by contrast, are the product's real deployable units but
> are not Docker/compose-detectable, so they read as `declared_not_detected` —
> a direction the pipeline **escalates for human judgement, never auto-removes**
> (removing a declared container is an architectural statement). That asymmetry
> is the expected, useful signal for the seeding (#791) and `c4_drift` (#793)
> machinery: it bounds what they can promise for a marketplace, which has no
> product-container surface for the detector to see. The capstone that exercises
> the detector on a real service is child (g) #796.

```mermaid
C4Container
    title Container diagram — timos-claude-code-plugins

    Person(developer, "Developer / Maintainer", "Invokes plugins from Claude Code")

    Container_Boundary(marketplace, "timos-claude-code-plugins marketplace") {
        Container(development, "development", "Claude Code plugin", "Orchestrator + core skills: bootstrap, maintenance, resolve-issue, open-pr, commit")

        Container_Boundary(langs, "Language plugins (dispatched per language)") {
            Container(development-python, "development-python", "Claude Code plugin", "Python pipeline")
            Container(development-java, "development-java", "Claude Code plugin", "Java / Gradle pipeline")
            Container(development-swift, "development-swift", "Claude Code plugin", "Swift pipeline")
            Container(development-go, "development-go", "Claude Code plugin", "Go pipeline (core loop)")
            Container(development-javascript, "development-javascript", "Claude Code plugin", "JavaScript / TypeScript pipeline")
        }

        Container_Boundary(topics, "Topic plugins (dispatched by marker)") {
            Container(development-spring, "development-spring", "Claude Code plugin", "Spring Boot overlay")
            Container(development-claude-plugin, "development-claude-plugin", "Claude Code plugin", "Plugin-repo overlay")
            Container(development-docs, "development-docs", "Claude Code plugin", "C4 docs topic — owns c4_drift")
            Container(development-react, "development-react", "Claude Code plugin", "React framework overlay")
            Container(development-kubernetes, "development-kubernetes", "Claude Code plugin", "Infrastructure-as-code topic — manifests, Helm, Kustomize, Argo CD; may be primary")
            Container(development-opentofu, "development-opentofu", "Claude Code plugin", "Infrastructure-as-code topic — cloud provisioning; OpenTofu + Terraform-compatible HCL; may be primary (skeleton, #1159)")
        }
    }

    Container(tests, "tests", "Docker image", "bats-in-Docker test runner (tests/Dockerfile, #263)")

    System_Ext(github, "GitHub", "Repos, PRs, Actions CI")
    System_Ext(maint_app, "Maintenance App", "GitHub App — writer tokens, bot PRs")

    Rel(developer, development, "Runs /development:* skills")
    Rel(development, development-python, "dispatches")
    Rel(development, development-java, "dispatches")
    Rel(development, development-swift, "dispatches")
    Rel(development, development-go, "dispatches")
    Rel(development, development-javascript, "dispatches")
    Rel(development, development-spring, "dispatches")
    Rel(development, development-claude-plugin, "dispatches")
    Rel(development, development-docs, "dispatches")
    Rel(development, development-react, "dispatches")
    Rel(development, development-kubernetes, "dispatches")
    Rel(development, development-opentofu, "dispatches (planned, #1160)")
    Rel(development-spring, development-java, "composes onto")
    Rel(development-react, development-javascript, "composes onto")
    Rel(development, maint_app, "mints token via")
    Rel(maint_app, github, "authors PRs on")
    Rel(github, tests, "builds + runs")

    UpdateLayoutConfig($c4ShapeInRow="2", $c4BoundaryInRow="2")
```

The **declared container set** is the thirteen `Container(...)` entries above —
the twelve installed plugins plus the `tests` runner image — recoverable by the
`c4/v1` parser (`extract-declared-containers.zsh`) without a Mermaid engine.
`github` and `maint_app` are `System_Ext` — outside the marketplace's container
boundary, so outside the system this diagram decomposes and therefore outside
the declared set (an external dependency is deliberately invisible to
`c4_drift`). For who invokes the marketplace and the external services it reads,
see the [System Context diagram](c4-context.md).
