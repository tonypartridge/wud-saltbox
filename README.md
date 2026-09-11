# WUD (What's up Docker?)

Watches the Saltbox Docker daemon for image updates and shows them at `https://wud.$DOMAIN` behind Authelia.

This is a **custom Compose app**, not a Saltbox catalog role. `sb install` will not create Traefik routers for it. Saltbox already ships [Diun](https://docs.saltbox.dev/apps/diun/) for email-only update alerts; WUD adds a UI and per-container labels.

Watcher options: [Docker Watchers](https://getwud.app/docs/configuration/watchers/).

## What this stack does

- Joins the external `saltbox` network so Traefik can reach `http://wud:3000`
- Mounts `/var/run/docker.sock` **read-only** (WUD itself does not recreate containers)
- Watcher `local` scans running containers daily at 01:00 (host TZ), with 60s jitter to spread Docker Hub calls
- When an update is found **between 01:00 and 03:00**, a command trigger runs host `sb install` as the Saltbox user (`media`): core roles use the container name, sandbox roles use `sandbox-<name>`
- Does **not** publish host port 3000
- Does **not** set `WATCHDIGESTDEFAULT` (WUD 8.4.0 rejects it and then registers **no** Docker watcher)

Custom Compose apps with no matching `sb` role (this stack, Arbor, …) are skipped. Outside 01:00–03:00 the trigger no-ops so a daytime WUD restart does not start Ansible.

## Deploy

On the Saltbox host:

```sh
sudo mkdir -p /opt/wud
sudo chown "$USER:$USER" /opt/wud
git clone git@github.com:tonypartridge/wud-saltbox.git /opt/wud
cd /opt/wud
cp .env.example .env          # set DOMAIN to your Saltbox domain
mkdir -p data/store

docker network inspect saltbox >/dev/null
docker compose up -d --build --force-recreate

# File provider — this is what actually creates the Traefik router
./scripts/saltbox-publish.sh

docker compose logs -f --tail=80 wud
```

`dash.$DOMAIN` should list `wud@file`. If that router is red, middleware names do not match this box — re-run `./scripts/saltbox-publish.sh` (it copies the chain from sonarr/radarr/plex if present) or edit `/opt/traefik/wud.yml`.

DNS: add a `wud` A/CNAME, keep a `*.$DOMAIN` wildcard, or let Saltbox DDNS create it from Traefik routes (`sb install ddns`). Custom compose does not create Cloudflare records by itself.

Open `https://wud.$DOMAIN` (Authelia first). The first scan runs at startup (`WATCHATSTART`).

## Watcher

Configured on the WUD container (not on each app):

| Variable | Default here | Meaning |
| --- | --- | --- |
| `WUD_WATCHER_LOCAL_SOCKET` | `/var/run/docker.sock` | Host Docker daemon |
| `WUD_WATCHER_LOCAL_CRON` | `0 1 * * *` | Daily 01:00 |
| `WUD_WATCHER_LOCAL_WATCHBYDEFAULT` | `true` | Watch every discovered container |
| `WUD_WATCHER_LOCAL_WATCHALL` | `false` | Running containers only |
| `WUD_WATCHER_LOCAL_WATCHEVENTS` | `true` | Pick up start/stop immediately |

Opt a container **out** of watching with label `wud.watch=false`. Pin a tag pattern with `wud.tag.include` (see [container labels](https://getwud.app/docs/configuration/watchers/)).

## Nightly `sb install` (01:00–03:00)

WUD cannot run Ansible inside its own container. The image is built from `getwud/wud` plus `nsenter`, Compose uses `pid: host` and `privileged: true`, and the [command trigger](https://getwud.app/docs/configuration/triggers/command/) executes `scripts/sb-install.sh`.

Flow:

1. 01:00 — watcher scan (`WUD_WATCHER_LOCAL_CRON`)
2. For each container with an update, WUD runs the script (env var `name`)
3. Script exits 0 without doing anything unless the hour is 1 or 2
4. Script skips names in `SB_INSTALL_SKIP` and names with no role under `/srv/git/saltbox/roles` or `/opt/sandbox/roles`
5. Core role → `runuser -u media -- sb install <name>`. Sandbox role → `sb install sandbox-<name>` (the CLI tag is not the folder name)
6. Installs are serialized with `flock` (`TIMEOUT=0` because a role can take many minutes)

Turn it off with `SB_INSTALL_ENABLED=false` in `.env`, then `docker compose up -d`. Widen the window with `SB_INSTALL_HOUR_START` / `SB_INSTALL_HOUR_END` (end is exclusive: `3` means stop at 03:00).

Logs: `docker compose logs -f wud` and look for `sb-install:`.

### Apply pending updates now (do not wait until 01:00)

The nightly trigger refuses to run `sb` outside 01:00–03:00. To drain the WUD queue as the Saltbox user:

```sh
cd /opt/wud
git pull
chmod +x scripts/apply-now.sh
# 24 roles can take hours — use tmux/screen
./scripts/apply-now.sh
```

That reads `GET /api/containers` from the `wud` container and runs `sb install` (with `sandbox-` for Sandbox apps) one at a time. Custom Compose names with no role are skipped.

This is **not** a Docker recreate. Traefik/Plex/etc. go through the same Ansible path you would run by hand. Extra instances whose container name is not the role directory (uncommon) are skipped until you add a matching role folder or install them yourself.

## Email (optional)

Uncomment the `WUD_TRIGGER_SMTP_MAIL_*` block in `.env` and `docker compose up -d`. Batch mode sends one mail per scan instead of one per container.

## Per-container labels (on other Compose apps)

```yaml
labels:
  wud.watch: "true"
  wud.tag.include: "^latest$$"
  wud.watch.digest: "true"
```

Leave locally built images unwatched:

```yaml
labels:
  wud.watch: "false"
```
