# Quillnote charter

An invented charter for the validator's tests (#3205). Quillnote is not a real
product. The tests copy this file to `docs/product/charter.md` in a throwaway
repo, beside `docs/personas.md` and `docs/principles.md`.

<!-- charter:prose:start -->
## Summary

Quillnote is a note-taking app for people who write in short bursts on a phone
and read back on a laptop. It stays quiet, works offline and keeps every note.

## Purpose and background

Most note apps grew into project tools. Quillnote exists for the moment an idea
arrives on a train platform: open, type, done.

## Who it serves

Commuters who capture on the move and tidy up later at a desk
(`priya-commuter` in the [persona registry](../personas.md)).

## Values

- **V-1** [Calm by default](../principles.md#calm-by-default).
- **V-2** A note is never lost, even offline.
- **V-3** Plain text first; formatting is a convenience, not a format.

## What we build

- **S-1** Fast capture on the phone, offline first.
- **S-2** Sync to a laptop reader.

## What we deliberately don't build

- **NG-1** *(retired by DC-2026-11-1)* No sharing of notes.
- **NG-2** No team workspaces. Quillnote is for one writer.

## Direction changes

- **DC-2026-11-1** (2026-11-12): read-only share links are now in scope, so
  NG-1 is retired. Writers asked to send a single note to a friend.
<!-- charter:prose:end -->

<details>
<summary>machine-readable charter (<code>charter/v1</code>) — generated, do not hand-edit</summary>

```json
{
  "schema": "charter/v1",
  "provenance": {
    "generated_by": "charter-definer via /product:define-charter",
    "generated_at": "2026-11-12T10:00:00Z",
    "prose_sha256": "d1a0041accf84bff49edeba5d8617db59f46c562b423e25b66aa77e2c63237e1"
  },
  "title": "Quillnote charter",
  "appendices": ["docs/principles.md"],
  "purpose": "A note-taking app for the moment an idea arrives: open, type, done.",
  "background": "Most note apps grew into project tools; Quillnote stays small.",
  "serves": ["priya-commuter"],
  "values": [
    {
      "id": "V-1",
      "status": "active",
      "ref": { "path": "docs/principles.md", "anchor": "calm-by-default", "title": "Calm by default" }
    },
    { "id": "V-2", "status": "active", "statement": "A note is never lost, even offline." },
    { "id": "V-3", "status": "active", "statement": "Plain text first; formatting is a convenience, not a format." }
  ],
  "scope": [
    { "id": "S-1", "status": "active", "statement": "Fast capture on the phone, offline first." },
    { "id": "S-2", "status": "active", "statement": "Sync to a laptop reader." }
  ],
  "non_goals": [
    {
      "id": "NG-1",
      "status": "retired",
      "statement": "No sharing of notes.",
      "rationale": "Sharing pulls the app toward collaboration features."
    },
    {
      "id": "NG-2",
      "status": "active",
      "statement": "No team workspaces.",
      "rationale": "Quillnote is for one writer."
    }
  ],
  "direction_changes": [
    {
      "id": "DC-2026-11-1",
      "date": "2026-11-12",
      "from": "Notes are never shared.",
      "to": "A single note can be sent as a read-only link.",
      "rationale": "Writers asked to send a single note to a friend.",
      "affects": ["NG-1"],
      "evidence": ["#42"]
    }
  ]
}
```

</details>
