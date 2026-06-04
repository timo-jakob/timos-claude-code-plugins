# Shift-left checks (added by /development:bootstrap)

This repository enforces the Zero Tolerance standard on new code (≥90% coverage,
0 smells, all A ratings). The standard is carried by three layers — a CI
`coverage-floor` step that fails the build below 90% on new lines, a
`diff-cover` pre-push hook that runs the same check locally, and the
configured Sonar Quality Gate (custom on paid plans / self-hosted; `Sonar way`
fallback on SonarCloud free). To keep the loop tight and avoid CI ping-pong,
run the same checks **locally during implementation** before declaring a task
complete.

## After editing code

1. Run the language linter for the file you touched:
   - Swift: `swiftlint lint --strict`
   - TypeScript / JavaScript: `npx eslint <path>`
   - Python: `ruff check <path>` and `ruff format --check <path>`
   - Go: `golangci-lint run ./...`
2. Run any tests that exercise the changed code.
3. If the file is in a security-sensitive area (auth, request handling, file
   I/O, deserialization), run `semgrep --config=auto` on it.

## Before declaring a task done

1. `pre-commit run --all-files` — must pass.
2. The full test suite for the changed language must pass with coverage ≥ 90%
   on the new code.
3. Surface any Sonar / Snyk / Trivy findings as part of your response — don't
   wait for CI to surface them.
4. If you introduced any code smell, bug, vulnerability, or security hotspot —
   fix it before declaring done. The Zero Tolerance standard is 0; CI will
   block the PR anyway via the Sonar gate and `coverage-floor` step.

## What CI runs (so you don't surprise yourself)

- Sonar scanner with the configured Sonar Quality Gate (custom "Zero Tolerance"
  gate on paid plans / self-hosted; `Sonar way` fallback on SonarCloud free).
- `coverage-floor` step: `diff-cover` against new lines, fails below 90%.
  This is the load-bearing 90% gate on SonarCloud free.
- Security scans (Snyk if public repo; Trivy if private).
- Language-specific tests + coverage report.
- Semgrep + secret scanning.
- CodeQL (public repos only).
