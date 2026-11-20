# Personas

An invented registry for the charter validator's tests (#3205): the people who
use Quillnote, a small note-taking app. Nothing here describes a real product.

<!-- personas:prose:start -->
## Priya, the commuting note-taker (`priya-commuter`)

- **Kind:** end-user
- **Role:** captures ideas on a phone between train stops, offline half the time
- **Goals:** jot a note in under ten seconds; find it again on the laptop
- **Failure costs:** a lost note is a lost idea she cannot reconstruct
- **Proficiency:** fluent with phones, not technical
- **Context:** iOS, patchy signal underground, one thumb
- **Data traits:** short notes with emoji; titles like `Ideas – Q3`
- **Primary for:** mobile-capture
<!-- personas:prose:end -->

<details>
<summary>machine-readable personas (<code>personas/v1</code>) — generated, do not hand-edit</summary>

```json
{
  "schema": "personas/v1",
  "provenance": {
    "generated_by": "persona-definer via /product:define-personas",
    "generated_at": "2026-11-20T09:00:00Z",
    "prose_sha256": "0000000000000000000000000000000000000000000000000000000000000000"
  },
  "personas": [
    {
      "id": "priya-commuter",
      "name": "Priya, the commuting note-taker",
      "kind": "end-user",
      "role": "captures ideas on a phone between train stops, offline half the time",
      "goals": ["jot a note in under ten seconds", "find it again on the laptop"],
      "failure_costs": ["a lost note is a lost idea she cannot reconstruct"],
      "proficiency": "fluent with phones, not technical",
      "context": "iOS, patchy signal underground, one thumb",
      "data_traits": [
        { "field": "note_title", "shape": "short title with an en dash", "example": "Ideas – Q3" }
      ],
      "primary_for": ["mobile-capture"]
    }
  ]
}
```

</details>
