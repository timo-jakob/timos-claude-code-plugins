# Ferrylane target architecture

An invented target architecture for the validator's tests (#3353). Ferrylane
is not a real product. The tests copy this file to
`docs/architecture/target-architecture.md` in a throwaway repo, beside
`docs/architecture/api-styleguide.md`.

<!-- target-architecture:prose:start -->
## Clauses

- **TA-1** (services) Booking and boarding are separate services that talk
  only through the booking API.
- **TA-2** *(retired by TC-2026-11-1)* (data) Every service shares the one
  ticketing database.
- **TA-3** (api) Public HTTP APIs follow the
  [API styleguide](api-styleguide.md#resource-naming).

## Changes

- **TC-2026-11-1** (2026-11-20): each service now owns its own database, so
  TA-2 is retired. A shared schema made every release wait on the others.
<!-- target-architecture:prose:end -->

<details>
<summary>machine-readable target architecture (<code>target-architecture/v1</code>) — generated, do not hand-edit</summary>

```json
{
  "schema": "target-architecture/v1",
  "provenance": {
    "generated_by": "hand-written for the validator's tests",
    "generated_at": "2026-11-20T09:00:00Z",
    "prose_sha256": "3e3123f407b3e9beef7d50ea53d1342d98b429516a99f75591b29548335dc38d"
  },
  "clauses": [
    {
      "id": "TA-1",
      "area": "services",
      "status": "active",
      "statement": "Booking and boarding are separate services that talk only through the booking API."
    },
    {
      "id": "TA-2",
      "area": "data",
      "status": "retired",
      "statement": "Every service shares the one ticketing database."
    },
    {
      "id": "TA-3",
      "area": "api",
      "status": "active",
      "ref": { "path": "docs/architecture/api-styleguide.md", "anchor": "resource-naming", "title": "API styleguide" }
    }
  ],
  "changes": [
    {
      "id": "TC-2026-11-1",
      "date": "2026-11-20",
      "from": "Every service shares the one ticketing database.",
      "to": "Each service owns its own database.",
      "rationale": "A shared schema made every release wait on the others.",
      "affects": ["TA-2"],
      "evidence": ["#42"]
    }
  ]
}
```

</details>
