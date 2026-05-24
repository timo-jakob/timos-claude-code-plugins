# Self-hosted GitHub Actions runner

A self-hosted runner lets your CI workflow reach a local SonarQube instance
(http://localhost:9000) that GitHub-hosted runners can't see.

## Safety constraint

**Self-hosted runners may only be used on private repositories.** GitHub
explicitly warns against running self-hosted runners on public repos — anyone
who opens a fork PR could execute arbitrary code on your runner host.

## One-time setup

1. In GitHub, open the repo → Settings → Actions → Runners → New self-hosted
   runner. Select your OS.
2. GitHub will show you copy-pasteable commands. Run them on the same machine
   that hosts SonarQube (so the runner can reach `http://localhost:9000`):

   ```sh
   # macOS example — pick a sensible install location
   mkdir -p ~/actions-runner && cd ~/actions-runner
   curl -o actions-runner.tar.gz -L <url-from-github>
   tar xzf ./actions-runner.tar.gz

   # Configure (GitHub shows you the URL + token)
   ./config.sh --url https://github.com/<owner>/<repo> --token <token>
   ```

3. Install as a service so it survives reboots:

   **macOS:**
   ```sh
   ./svc.sh install
   ./svc.sh start
   ./svc.sh status
   ```

   **Linux:**
   ```sh
   sudo ./svc.sh install
   sudo ./svc.sh start
   sudo ./svc.sh status
   ```

4. In GitHub → Settings → Actions → Runners, confirm the runner shows as
   **Idle**.

## Hardening

- Restrict the runner to this repo only (set in `config.sh` — repository-level
  runner, not org-level).
- Run the runner as a dedicated, non-admin user.
- Lock down the host firewall — only GitHub's outbound calls + access to
  `localhost:9000` are needed.
- Keep the runner host up to date; `./run.sh` auto-updates the runner binary,
  but the OS is your responsibility.
- Periodically re-mint the registration token if the runner becomes
  unreachable.

## What runs on it

Only jobs in `.github/workflows/quality-private.yml` target `runs-on:
self-hosted`. Everything else (if you add more workflows) should stay on
`ubuntu-latest` / `macos-latest` unless they specifically need SonarQube access.

## Removing the runner

```sh
./svc.sh stop
./svc.sh uninstall
./config.sh remove --token <token-from-github-settings>
```
