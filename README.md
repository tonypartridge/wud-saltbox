# WUD (What's up Docker?)

Watches the Saltbox Docker daemon for image updates and shows them at `https://wud.$DOMAIN` behind Authelia.

This is a **custom Compose app**, not a Saltbox catalog role. `sb install` will not create Traefik routers for it. Saltbox already ships [Diun](https://docs.saltbox.dev/apps/diun/) for email-only update alerts; WUD adds a UI and per-container labels.

Watcher options: [Docker Watchers](https://getwud.app/docs/configuration/watchers/).

## What this stack does

- Joins the external `saltbox` network so Traefik can reach `http://wud:3000`
- Mounts `/var/run/docker.sock` **read-only** (discover and scan only — no auto-recreate)
- Watcher `local` scans running containers daily at 01:00 (host TZ), with 60s jitter to spread Docker Hub calls
- Does **not** publish host port 3000
- Does **not** set `WATCHDIGESTDEFAULT` (WUD 8.4.0 rejects it and then registers **no** Docker watcher)

Auto-updating Saltbox catalog containers from WUD is a bad idea — Ansible owns those. Use the UI as a report, then `sb install <app>` (or recreate your own Compose apps) when you want the new image.

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
docker compose up -d --force-recreate

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

Opt a container **out** with label `wud.watch=false`. Pin a tag pattern with `wud.tag.include` (see [container labels](https://getwud.app/docs/configuration/watchers/)).

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
