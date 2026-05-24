# SonarQube CE — self-hosted

A Docker Compose stack that runs SonarQube Community Edition + a Postgres
backend. Used by the private-repo CI workflow.

## Start

```sh
# Optional: change the DB password before first start.
echo "SONARQUBE_DB_PASSWORD=$(openssl rand -base64 24)" > .env

docker compose up -d
```

First boot takes 30–60 seconds. Open <http://localhost:9000>.

## First-time setup

1. Log in: `admin` / `admin`. You'll be forced to change the password — pick
   something strong and store it in your password manager.
2. Create the project (key matches `sonar.projectKey` in
   `sonar-project.properties`).
3. Generate a **Project Analysis Token** under My Account → Security.
4. Store the token + this host's URL as GitHub Actions secrets (`SONAR_TOKEN`,
   `SONAR_HOST_URL`) — see `../../SETUP.md`.

## Requirements

- 2 GB RAM minimum (4 GB comfortable).
- On Linux:
  ```sh
  sudo sysctl -w vm.max_map_count=524288
  sudo sysctl -w fs.file-max=131072
  ```
  Make persistent via `/etc/sysctl.conf`.
- macOS / Windows Docker Desktop handles these tunables automatically.

## Backup

State lives in named Docker volumes:
- `sonarqube_data` (configuration + indexes)
- `sonarqube_extensions` (installed plugins)
- `sonarqube_db` (Postgres data — the analysis history)

Back up `sonarqube_db` if you want to preserve historical metrics across
host rebuilds.

## Stop

```sh
docker compose down       # keeps volumes
docker compose down -v    # removes volumes (destroys all SonarQube data)
```

## Upgrade

1. `docker compose pull`
2. `docker compose up -d`
3. Visit <http://localhost:9000/setup> if SonarQube prompts for a DB upgrade.
