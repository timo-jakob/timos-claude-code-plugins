# Claude Apps — registration and identity

Reference for the two GitHub App identities used by the Claude Approver and Maintenance pipelines.

**⚠️ Architecture Change (Epic #476):** The **Claude Approver App** is no
longer CI-driven via GitHub Actions. It is now **user-invoked locally** via
`/development-python:approve` (and the other language plugins' `approve`
skills), with tokens minted by `mint-approver-token.zsh`. This eliminates
platform lock-in and lets users work with any AI coding assistant. Full
design: [APPROVER-APP.md](APPROVER-APP.md).

## The two App identities

| Identity | GitHub App slug pattern | Invocation | Purpose |
| --- | --- | --- | --- |
| **Claude Approver** | `claude-approver-<github-login>` | User skill (`/approve`) | Posts pull-request reviews (`APPROVE` / `REQUEST_CHANGES` / commenting). Invoked locally by user when ready to review, never by GitHub Actions. Its `pull_request_review` calls satisfy branch protection's one-approval requirement. |
| **Claude Maintenance** | `claude-maintenance-<github-login>` | Orchestrator (`/development:maintenance`) | Opens pull requests + pushes commits on behalf of `/development:maintenance`. Distinct identity so the Approver's anti-rubber-stamp gate (*PR author ≠ Approver identity*) fires correctly on machine-authored PRs. |

The two identities are not a stylistic split — they are **load-bearing
for the Approver's anti-rubber-stamp gate**. If both maintenance and
review ran under one bot, the Approver could end up reviewing PRs the
same bot authored, and the gate that prevents self-approval would
either misfire or have to be turned off. Keeping the identities
distinct removes the question entirely.

## Permissions

Permissions are minimal-by-default. Both Apps register with
**webhook deactivated** — Approver and Maintenance are both driven by
locally minted installation tokens at runtime, not by webhook events;
turning the webhook on would add a delivery destination we don't use.

### Claude Approver

| Scope | Level | Why |
| --- | --- | --- |
| `pull_requests` | write | Post reviews. |
| `contents` | **write** | **Makes the App's `APPROVE` *count*.** GitHub tallies an approval toward a branch's `required_approving_review_count` only from a reviewer who **can push to the repo**, and push access *is* the Contents permission — not Pull requests. With `contents:read` the review posts but `authorCanPushToRepository=false`, so a green + approved PR stays `reviewDecision=REVIEW_REQUIRED` / `mergeStateStatus=BLOCKED` and never auto-merges (#418). Also reads the PR diff. The Approver never pushes — `main` stays PR-protected, so the bot can't write to a protected branch; the grant only confers the "counts as an approval" property. |
| `issues` | read | Read the linked issue body for `feat:` PRs (per the Approver's per-PR-type criteria). |
| `actions` | read | Read GitHub Actions workflow runs and their conclusions (the "everything green" gate). |
| `checks` | read | Read check runs from third-party integrations (Sonar, Snyk, CodeQL) that don't post via Actions. |
| `metadata` | read | Required default for every App. |

> **Upgrading an existing Approver install to `contents:write` (#418).** A
> permission *increase* on an already-installed App is **not** applied by
> re-running `register-claude-apps.zsh` — GitHub requires the user to
> **re-accept** the new grant per installation. On a repo whose Approver
> predates this change: App settings → **Permissions → Contents: Read &
> write → Save**, then **github.com/settings/installations → Claude Approver →
> Configure → accept the permission update**, and re-trigger the Approver on a
> fresh head SHA. `install-claude-apps.zsh --verify` flags an Approver still on
> the old read-only grant.

### Claude Maintenance

| Scope | Level | Why |
| --- | --- | --- |
| `contents` | write | Push commits and create branches. |
| `pull_requests` | write | Open and edit PRs. |
| `issues` | write | Close issues from PR descriptions (`Closes #N` is the convention codified in repo memory). |
| `actions` | read | Check workflow status before merging. |
| `checks` | read | Same as Approver — third-party check runs. |
| `metadata` | read | Required default. |

Explicitly **not granted**:

- `workflows: write` on Claude Maintenance. The maintenance pipeline
  is not authorised to modify `.github/workflows/*.yml` autonomously.
  Bootstrap-template-drift PRs that need this run as the user, not as
  the bot, until a deliberate review process for workflow changes is
  designed.
- Org administration scopes (members, secrets, settings) on either App.

## Registration

### Manifest flow (primary)

`register-claude-apps.zsh` uses the [GitHub App Manifest
flow](https://docs.github.com/en/apps/sharing-github-apps/registering-a-github-app-from-a-manifest):

1. The script generates a manifest JSON describing each App
   (name, URL, permissions, no webhook).
2. The script writes a tiny HTML page to a temp file containing
   an auto-submitting form POSTing the manifest to
   `https://github.com/settings/apps/new?state=<state>`.
3. The script starts a one-shot Python HTTP listener on
   `127.0.0.1:18923` to catch the redirect.
4. The script opens the HTML page in the browser (`open <file>`).
5. The browser auto-submits the form. GitHub shows a confirmation
   page; the user clicks **Create GitHub App**.
6. GitHub redirects to `http://localhost:18923/callback?code=<temp>&state=<state>`.
7. The listener captures `code` + `state`, returns a small "App
   created — return to your terminal" HTML, and exits.
8. The script POSTs the code to `POST /app-manifests/<code>/conversions`,
   which returns the App ID, slug, private key (PEM), and webhook
   secret. We store the ID + slug; we keep the PEM in Keychain; we
   discard the webhook secret (no webhooks).

This runs once per App. Re-running the script with both Apps already
present is a no-op (prints status). If only one App is present, the
script only walks the flow for the missing one.

The redirect listener has a **5-minute timeout** — if the user takes
longer than that to click Create, the script exits cleanly with a
"timeout; re-run when ready" message. No state survives on disk.

### Manual fallback

When the manifest flow can't run (browser sandbox issues, restricted
network, you prefer to see the App creation page directly), use the
manual flow:

1. Open `https://github.com/settings/apps/new` in your browser.
2. Fill in the App name (use `claude-approver-<github-login>` or
   `claude-maintenance-<github-login>` so it matches the manifest's
   convention).
3. Homepage URL: any URL you control (the App's profile page link;
   we don't use it functionally).
4. **Uncheck "Webhook → Active".**
5. Set the permissions from the table above.
6. Click **Create GitHub App**.
7. On the App's settings page, scroll to **Private keys** and click
   **Generate a private key** — a `.pem` file downloads.
8. Note the **App ID** at the top of the settings page.
9. Hand the credentials to the script:

   ```sh
   register-claude-apps.zsh --import claude-approver \
     --app-id 123456 --pem ~/Downloads/claude-approver.private-key.pem
   ```

   The `--import` mode skips the manifest flow entirely and just
   stores credentials the user already obtained.

### Re-running the script

The script is idempotent:

- If both Apps are registered (entries present in
  `~/.config/claude-plugins/apps.json` *and* their private keys are
  in Keychain), it prints the current state and exits.
- If only one is registered, it walks the manifest flow for the
  other.
- `--reset <name>` clears a single App's entries (config + Keychain)
  so it can be re-registered. Useful after a name collision or a
  key rotation.

## Credential storage

### Schema: `~/.config/claude-plugins/apps.json`

Created with mode `0700` on the directory, `0600` on the file.

```json
{
  "schema_version": 1,
  "claude_approver": {
    "app_id": 123456,
    "client_id": "Iv1.abcdef0123456789",
    "slug": "claude-approver-timo-jakob",
    "owner_login": "timo-jakob",
    "owner_scope": "user",
    "registered_at": "2026-06-06T12:34:56Z"
  },
  "claude_maintenance": {
    "app_id": 123457,
    "client_id": "Iv1.9876543210fedcba",
    "slug": "claude-maintenance-timo-jakob",
    "owner_login": "timo-jakob",
    "owner_scope": "user",
    "registered_at": "2026-06-06T12:35:42Z"
  }
}
```

App IDs, Client IDs, and slugs are not secrets. The file is mode `0600`
anyway to keep all per-user config in one consistent posture.

`client_id` (#223) may be empty or absent on entries created by the
`--import` flow or by older versions; `install-claude-apps.zsh`
backfills it (together with `slug`) from `GET /app` when it has to
resolve a missing slug. Nothing consumes it yet — the numeric
`app_id` remains a valid JWT issuer and a valid `client-id` input for
`actions/create-github-app-token@v3` — it is captured so no manual
lookup is needed if GitHub ever drops numeric-ID acceptance.

### Private keys: macOS Keychain

Each PEM is stored as a generic password:

- Service: `claude-plugins.claude-approver` (or `claude-plugins.claude-maintenance`)
- Account: `private-key`
- Password: the full PEM contents, including the
  `-----BEGIN/END RSA PRIVATE KEY-----` lines

This matches the pattern `automate-private.sh` already uses for the
SonarQube admin password. Retrieval:

```sh
security find-generic-password \
  -s claude-plugins.claude-approver \
  -a private-key -w
```

(`-w` prints the password to stdout; the script consumes it directly
when minting App tokens, never writing it to a disk file.)

### Why not keep the PEM on disk

A `.pem` file on disk is a plaintext private key. Even with `0600`
permissions, every backup, every `tar`, every developer-tools sweep
can see it. Keychain encrypts at rest, integrates with the login
session, and matches how the bootstrap already handles the Sonar
admin password. One pattern, one place to look.

## Per-repo installation

Once registered, each App is *installed* on individual repos via
`/development:bootstrap --claude-approver true` (which delegates to
`install-claude-apps.zsh`). That flow:

1. Reads App IDs from `apps.json`.
2. Installs both Apps on the current repo via the browser install flow.
3. Stores **no repo secrets or variables** (#476/#498). Both identities
   mint their installation tokens locally from the Keychain
   (`mint-approver-token.zsh` / `mint-maintenance-token.zsh`), so the
   private keys never leave the machine and nothing repo-side holds
   credentials.

**Repos installed before epic #476** may still carry the CI-era
config (`CLAUDE_*_PRIVATE_KEY` / `ANTHROPIC_API_KEY` secrets,
`CLAUDE_*_APP_ID` / `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` variables).
Nothing consumes them anymore; `install-claude-apps.zsh --verify --fix`
deletes the unambiguous ones (it skips any name a workflow file still
references, and never auto-deletes `ANTHROPIC_API_KEY`).

## Rotation

GitHub Apps can have multiple active private keys at once, so
rotation is non-disruptive:

1. Generate a new key in the App's settings page.
2. Run `register-claude-apps.zsh --rotate <name> --pem <new-pem-path>`.
   The script replaces the Keychain entry and updates `registered_at`.
3. There is nothing repo-side to update (#498): tokens are minted from
   the Keychain, so every subsequent mint uses the new key immediately.
4. Delete the old key from the App's settings page.

Old keys keep working until they're revoked, so there is no
narrow rollover window.

## Writer identity for plugin repos (`/development:open-pr`)

A Claude-plugin repo is the origin of every other repo, so it has **no
AI Approver** — a human reviews. But GitHub blocks you from approving a
PR you authored, so Claude's PRs in these repos must be authored by a
*machine* identity that you can then approve.

That writer is the **Claude Maintenance App, reused** — it already has
`contents:write` + `pull_requests:write` and a local token-minting path
(`mint-maintenance-token.zsh` → Keychain key → 1-hour installation
token), so no new App is registered. Install it on a plugin repo with:

```bash
install-claude-apps.zsh --writer-only   # Maintenance App only; no Approver, no ANTHROPIC_API_KEY, no repo secrets
```

Then `/development:open-pr` mints the writer token, pushes the branch as
the bot, opens the PR as `claude-maintenance-<login>[bot]`, and arms
squash auto-merge with branch deletion. You review and approve; GitHub
merges it. The repo's merge settings (squash-only, `allow_auto_merge`,
`delete_branch_on_merge`) are configured by `branch-protection.sh`
during bootstrap.

## Testing the registration flow

End-to-end testing genuinely creates GitHub Apps under your account,
so it has side effects. The script supports a few non-destructive
testing modes:

- `register-claude-apps.zsh --print-manifest claude-approver` — emits
  the manifest JSON for inspection without making any HTTP calls or
  opening any browser tab.
- `register-claude-apps.zsh --list` — prints whichever Apps are
  registered locally with their IDs and slugs; no network calls.
- `register-claude-apps.zsh --dry-run` — runs the manifest flow up to
  but not including the browser open + listener spawn, printing what
  it *would* do. Useful for verifying state.

Manual end-to-end test:

1. Ensure no entries in `apps.json` (`mv ~/.config/claude-plugins/apps.json{,.bak}`).
2. Run the script.
3. Confirm both browser tabs open, click through both flows.
4. Verify `apps.json` shows both entries.
5. Verify `security find-generic-password -s claude-plugins.claude-approver -a private-key -w` prints a PEM.
6. Visit `https://github.com/settings/apps` and confirm both Apps exist with the expected permissions.

For routine development, prefer `--print-manifest` plus the `--import`
fallback — it lets you verify the script's storage and config-handling
without burning two real Apps each iteration.
