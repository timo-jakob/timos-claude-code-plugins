# Claude Apps — registration and identity

Reference for the two GitHub App identities the Claude Approver
infrastructure depends on. Phase 0 of #89 ships the registration
script (`register-claude-apps.sh`) and this document; Phase 1 wires
the resulting credentials into `/development:bootstrap` per-repo.

## The two App identities

| Identity | GitHub App slug pattern | Purpose |
|---|---|---|
| **Claude Approver** | `claude-approver-<github-login>` | Posts pull-request reviews (`APPROVE` / `REQUEST_CHANGES` / commenting). Its `pull_request_review` calls satisfy branch protection's one-approval requirement. |
| **Claude Maintenance** | `claude-maintenance-<github-login>` | Opens pull requests + pushes commits on behalf of `/development:maintenance`. Distinct identity so the Approver's anti-rubber-stamp gate (*PR author ≠ Approver identity*) fires correctly on machine-authored PRs. |

The two identities are not a stylistic split — they are **load-bearing
for the Approver's anti-rubber-stamp gate**. If both maintenance and
review ran under one bot, the Approver could end up reviewing PRs the
same bot authored, and the gate that prevents self-approval would
either misfire or have to be turned off. Keeping the identities
distinct removes the question entirely.

## Permissions

Permissions are minimal-by-default. Both Apps register with
**webhook deactivated** — Approver and Maintenance are both driven by
workflow tokens at runtime, not by webhook events; turning the webhook
on would add a delivery destination we don't use.

### Claude Approver

| Scope | Level | Why |
|---|---|---|
| `pull_requests` | write | Post reviews. |
| `contents` | read | Read the PR diff. |
| `issues` | read | Read the linked issue body for `feat:` PRs (per the Approver's per-PR-type criteria). |
| `actions` | read | Read GitHub Actions workflow runs and their conclusions (the "everything green" gate). |
| `checks` | read | Read check runs from third-party integrations (Sonar, Snyk, CodeQL) that don't post via Actions. |
| `metadata` | read | Required default for every App. |

### Claude Maintenance

| Scope | Level | Why |
|---|---|---|
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

`register-claude-apps.sh` uses the [GitHub App Manifest
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
   register-claude-apps.sh --import claude-approver \
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
    "slug": "claude-approver-timo-jakob",
    "owner_login": "timo-jakob",
    "owner_scope": "user",
    "registered_at": "2026-06-06T12:34:56Z"
  },
  "claude_maintenance": {
    "app_id": 123457,
    "slug": "claude-maintenance-timo-jakob",
    "owner_login": "timo-jakob",
    "owner_scope": "user",
    "registered_at": "2026-06-06T12:35:42Z"
  }
}
```

App IDs and slugs are not secrets. The file is mode `0600` anyway to
keep all per-user config in one consistent posture.

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

## Per-repo installation (Phase 1 — not in this PR)

Once registered, each App is *installed* on individual repos via
`/development:bootstrap --claude-approver true`. That flow will:

1. Read App IDs from `apps.json`.
2. Install both Apps on the current repo via the GitHub API.
3. Store as repo-level secrets:
   - `CLAUDE_APPROVER_APP_ID` (variable)
   - `CLAUDE_APPROVER_PRIVATE_KEY` (secret — PEM contents)
   - `CLAUDE_MAINTENANCE_APP_ID` (variable)
   - `CLAUDE_MAINTENANCE_PRIVATE_KEY` (secret — PEM contents)
   - `CLAUDE_APPROVER_AUTHOR_ALLOWLIST` (variable — defaults to
     the machine-only list).

Phase 1 is tracked under #89 and is **not** part of this PR.

## Rotation

GitHub Apps can have multiple active private keys at once, so
rotation is non-disruptive:

1. Generate a new key in the App's settings page.
2. Run `register-claude-apps.sh --rotate <name> --pem <new-pem-path>`.
   The script replaces the Keychain entry and updates `registered_at`.
3. Re-run `/development:bootstrap --claude-approver true` on every
   repo using the App (or extend bootstrap's Phase 1 with a `--rotate`
   mode that pushes the new key as a repo secret without redoing the
   rest of the flow). The latter is a Phase 1 nice-to-have, not
   shipped here.
4. After confirming all consumers have switched, delete the old key
   from the App's settings page.

Old keys keep working until they're revoked, so there is no
narrow rollover window.

## Testing the registration flow

End-to-end testing genuinely creates GitHub Apps under your account,
so it has side effects. The script supports a few non-destructive
testing modes:

- `register-claude-apps.sh --print-manifest claude-approver` — emits
  the manifest JSON for inspection without making any HTTP calls or
  opening any browser tab.
- `register-claude-apps.sh --list` — prints whichever Apps are
  registered locally with their IDs and slugs; no network calls.
- `register-claude-apps.sh --dry-run` — runs the manifest flow up to
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
