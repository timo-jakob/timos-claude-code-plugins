# Architecture

This repo's structure is documented as **[C4](https://c4model.com/) diagrams** —
Mermaid `C4Context` / `C4Container` blocks in Markdown that render natively on
GitHub and through the docs site. They are authored by hand against the `c4/v1`
contract and kept true alongside the code (the maintenance pipeline compares the
declared containers against reality and flags drift).

- [**System Context**](c4-context.md) — who uses timos-claude-code-plugins and
  the systems it talks to: the plugins, both GitHub Apps (Maintenance and
  Approver), the target repositories, the external services (GitHub, SonarCloud,
  Snyk), and the planned reporting repo.
- [**Container Diagram**](c4-container.md) — the deployable units: the
  orchestrator, the language plugins, the topic plugins, and the JSON dispatch
  payload flow between them.

The diagrams cover the **Context** and **Container** levels (Component is
optional and not yet authored; Code-level C4 is never authored). Deeper,
prose-level architecture and the schema contracts live in the repo-root
references:

- [`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md)
  — the authoritative contributor/Claude-facing architecture & schema contract
  (maintenance dispatch schema, plugin composition model, scripting conventions,
  and the `c4/v1` contract these diagrams follow).
- [`MAINTAINING.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/MAINTAINING.md)
  — quarterly template-refresh procedure (repo root).
- [Why per-language plugins?](../explanation/why-per-language-plugins.md) — the
  composition rationale.
