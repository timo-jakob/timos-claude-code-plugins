# Requirements

The plugins are written for **macOS** and assume **Homebrew** is the package
manager. Other platforms may work for some skills but are not tested.

The `/development:bootstrap` skill specifically depends on macOS + Homebrew for
its automation scripts — it offers to `brew install` any missing tooling
(`gh`, `jq`, `pre-commit`, `gitleaks`, `semgrep`, `sonar-scanner`,
`snyk-cli` or `trivy`, plus language-specific linters). The manual setup
documented in the generated `SETUP.md` remains usable on any platform if you
install the equivalent tools by hand.

## Additional runtime dependencies

- `gh` CLI authenticated (`gh auth login`) — for repo metadata, secret storage,
  branch protection, and self-hosted runner registration.
- Docker (private-repo bootstrap only) — runs SonarQube CE locally via
  `docker compose`. The preflight script detects three setups:
  - **Docker Desktop** — recommended for most users; offered as a brew cask
    (`brew install --cask docker`). Bundles the compose v2 plugin. Free for
    personal use; check Docker's license at companies >250 employees /
    >$10M revenue.
  - **CLI-only (Colima / OrbStack / Rancher Desktop / Podman)** — preflight
    accepts any setup that provides a working `docker` CLI + daemon. If the
    `docker compose` plugin is missing, preflight offers
    `brew install docker-compose`.
  - **Absent** — preflight prompts: install Docker Desktop via brew, install
    manually from docker.com, or set up an alternative yourself.
