# Amend a C4 diagram by hand

**Goal:** author or change a `docs/architecture/` diagram — whether you are
adding a container as part of a feature, refining a seeded diagram, or responding
to a `c4_drift` finding. These are the same job: edit the Mermaid diagram so it
matches reality.

## When you do this

- **You made a structural change** — added, removed, or renamed a service,
  container, datastore, broker, or external integration. Update
  `docs/architecture/c4-container.md` (and the Context diagram if the landscape
  changed) **in the same PR** as the code. The trigger is a working-tree
  structural change the pipeline detects from the code (a new Dockerfile or
  compose service, a changed build image) — not a risk label. Keeping the
  diagram true is part of the change, not a follow-up.
- **The pipeline reported drift** — maintenance opened a
  [`c4_drift` finding](../reference/c4-drift-findings.md). Reconcile the diagram
  with what the code now builds.

## Edit the Container diagram

The declared containers live inside the `C4Container` block of
`docs/architecture/c4-container.md`. To add or change one, edit its line — each
container is written on a single line of this form:

```text
Container(<alias>, "<label>", "<technology>")
```

Use the deployable unit's **real name** as the `<alias>` (its compose service,
image name, or build subproject) — that is the key the pipeline joins against
what the code actually builds, so it has to match reality. Then verify (below):
the strict build proves the page compiles, and the declared-container parse is
what confirms the entry is machine-readable.

That is enough to make an edit. The **complete, authoritative** shape — which
entry kinds count as containers, which are excluded, exactly how the alias is
matched, and the lexical constraints that keep the line machine-readable — is
defined once, in the contract. When you need the full rules, read them there
rather than trusting a paraphrase:
[`ARCHITECTURE.md`](https://github.com/timo-jakob/timos-claude-code-plugins/blob/main/ARCHITECTURE.md).

## Respond to a `c4_drift` finding

- **`detected_not_declared`** — the code builds a container the diagram omits.
  Usually you **add** the entry (the diagram was behind reality).
- **`declared_not_detected`** — the diagram declares a container detection can't
  find. This needs judgement: the container may have been removed or renamed (fix
  the entry), or it may be real but built by a mechanism detection doesn't resolve
  (leave it, and refine the build so it is detectable). See the [finding
  reference](../reference/c4-drift-findings.md) for what each type means.

## Verify

```bash
pip install -r requirements-docs.txt
mkdocs build --strict
```

The strict build confirms the page compiles and links resolve. It does **not**
check the Mermaid body; the machine-readable guarantee is that your
`Container(...)` entries parse against the declared-container shape. If you have
the family checked out, you can confirm that directly by extracting the declared
set with `extract-declared-containers.zsh` — a non-empty, error-free result means
the diagram is readable by the pipeline.
