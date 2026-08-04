## 8. Epic map and sequencing

Each epic is independently shippable.

1. **`development-javascript`** — the language foundation; largest epic;
   mirrors the existing language plugins.
2. **API lifecycle** — spec publish (npm + APIM), semver triangle gate,
   per-major `contracts/` layout + ACL pattern, deprecation
   headers/gates, Spectral socket. Overlaps/absorbs parts of #174.
3. **`development-react`** (first framework topic — see the 2026-07-22
   amendment in §2; the MFE app shape follow-up is #954).
4. **`development-angular`** + the bootstrap recommendation heuristic.
5. **`development-composition`** (composition repo type).
6. **Standardized ops surface** — the `ops-api` fragment + per-language
   canonical implementations + OTel defaults.
7. **API styleguide** — separate, later. The enforcement vehicle is a
   **Spectral ruleset** linting `contracts/` in CI; bootstrap installs
   Spectral with a minimal starter ruleset in epic 2, and the styleguide
   epic later replaces the ruleset content without touching the pipeline.

## 9. Considered and rejected
