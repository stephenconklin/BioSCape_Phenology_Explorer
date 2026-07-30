# Deploying on a fresh Jetstream2 instance

One-command provisioning of the dashboard on a clean Ubuntu instance: Docker,
swap, the app container, an nginx reverse proxy, TLS, a firewall, and the
health sampler.

```bash
git clone https://github.com/stephenconklin/BioSCape_Phenology_Explorer.git
cd BioSCape_Phenology_Explorer
cp deploy/deploy.env.example deploy/deploy.env
${EDITOR:-nano} deploy/deploy.env          # at minimum, check DATA_ROOT
sudo ./deploy/bootstrap.sh
```

The script is **idempotent** — re-running it is the normal way to apply a
config change. Every step detects existing state and skips.

---

## What it does not do: the data

The datacubes are tens of GB and are **not** provisioned by the script. It
verifies `DATA_ROOT` and stops with instructions if the directory is missing
or contains no `.nc` / `.npz` / `.zarr` files, rather than starting an app that
would fail on every interaction.

On a fresh instance, before running bootstrap:

1. Create/attach a volume in the Jetstream2 web console (Exosphere). Allow
   ~30GB; the current dataset is ~20GB.
2. Confirm the mount: `lsblk && df -h /media/volume/*`
3. Copy the data in — datacubes, `*_pixel_metrics.nc`, and the basemap `.npz`
   caches:
   ```bash
   rsync -avh --progress \
     /path/to/phenology_data/ \
     exouser@<NEW_IP>:/media/volume/Bioscape_Dashboard_Data/phenology_data/
   ```
4. Set `DATA_ROOT` in `deploy/deploy.env` if the path differs.

Regenerating rather than copying the derived files is also viable — see
`tools/cache_basemaps.py` and `tools/pixel_phenology_extract.py` — but it is
substantially slower than an rsync.

---

## Running this on an instance that is already deployed

This script assumes a *fresh* instance. On a host already running the
dashboard, `APP_DIR` **must** point at the existing checkout:

```ini
APP_DIR="/home/exouser/bioscape_phenology_explorer"   # the real path
```

Otherwise the script clones a second copy, starts a second container against
the same data, and then fails at the nginx step because the original container
still holds port 80. Bootstrap detects this and refuses — it compares the
`com.docker.compose.project.working_dir` label of any running dashboard
container against `APP_DIR` — but set the path correctly rather than relying
on the guard.

With `APP_DIR` pointed at the existing checkout, the script **adopts** the
deployment: it pulls, rewrites the compose `.env` to bind loopback, recreates
the container (which frees port 80), then installs nginx in front. Expect
**~2-4 minutes of downtime** during the rebuild and cutover.

Two prerequisites:

- The checkout must have **no uncommitted changes** — the script stops if
  `git status --porcelain` is non-empty, since `--ff-only` would otherwise
  fail after the compose config had already been rewritten.
- Port 80 must end up free before the nginx step. The recreate handles this
  automatically; the script verifies it and stops with instructions if not.

**Rollback:** set `APP_BIND=0.0.0.0:80` in `<APP_DIR>/.env`, run
`docker compose --project-directory <APP_DIR> up -d`, then
`sudo systemctl stop nginx`.

If you would rather migrate in reversible stages with a validation gate at
each step — staging nginx on port 8080 and testing it before touching port 80
— use `docs/nginx-deployment-plan.md` instead. That plan exists specifically
for the running production instance; this script is the greenfield path.

## Instance sizing

Baseline is `m3.small` (2 vCPU, 6GB RAM, 20GB root), which is what production
runs on. Two constraints are worth knowing before choosing smaller:

- **RAM.** `mem_limit` defaults to `5g`, leaving ~1GB for the host. Below 6GB
  total, lower `MEM_LIMIT` in `deploy.env` — an uncapped container lets the
  *host* kernel pick an OOM victim, which could be sshd.
- **Root disk.** 20GB is adequate but not generous; Docker images plus build
  cache reach ~5GB and production has hit 90%. The script reclaims build cache
  automatically when free space drops under 3GB.

---

## Modes

| Command | Effect |
|---|---|
| `sudo ./deploy/bootstrap.sh` | Full provision — host packages, Docker, swap, app, nginx, TLS, ufw, sampler |
| `sudo ./deploy/bootstrap.sh --app-only` | Pull, rebuild, restart, wait for healthy. Skips all host setup. The routine redeploy. |
| `sudo ./deploy/bootstrap.sh --check` | Read-only status snapshot; changes nothing |

---

## TLS

Let's Encrypt **cannot issue a certificate for a bare IP address**. TLS
therefore requires a DNS name pointed at the instance's floating IP:

```ini
SERVER_NAME="phenology.example.org"
CERTBOT_EMAIL="you@example.org"
```

With `SERVER_NAME` empty, or set to an IP, the script warns and serves plain
HTTP — everything else still works. Add the name later and re-run bootstrap to
obtain a certificate; nothing else needs changing.

---

## What the deployment looks like when finished

```
internet ─→ nginx (host, :80/:443, TLS, rate limiting, gzip)
          → 127.0.0.1:8050 → gunicorn container
                              ├─ 2 workers x 8 gthread threads
                              ├─ mem_limit 5g, log caps
                              ├─ /data mounted read-only
                              └─ healthcheck → autoheal sidecar
```

**gunicorn is never published to the internet.** `bootstrap.sh` writes
`APP_BIND=127.0.0.1:8050` into the compose `.env`, so the container publishes
only on loopback and nginx is the sole public listener. This is the core fix
for the 2026-07-30 incident — see `CLAUDE.md`. Verify after any change:

```bash
sudo ss -tlnp | grep -E ':80|:8050'
# nginx on 0.0.0.0:80, docker-proxy on 127.0.0.1:8050 ONLY.
# Any 0.0.0.0:8050 means gunicorn is publicly exposed.
```

---

## Generated vs. committed files

The script never edits tracked files, so `git pull` never conflicts:

| Path | Tracked | Purpose |
|---|---|---|
| `deploy/deploy.env` | no (gitignored) | Your host-specific config |
| `<APP_DIR>/.env` | no | `APP_BIND`, `VI_DATACUBE_ROOT` — read automatically by compose |
| `<APP_DIR>/docker-compose.override.yml` | no | `DATA_ROOT` bind mount and `MEM_LIMIT` |
| `/etc/nginx/sites-available/phenology` | no | Rendered from `deploy/nginx/*.template` |

Edit `deploy/nginx/phenology.conf.template` rather than the installed nginx
config — the next bootstrap run overwrites the installed copy.

---

## Firewall warning

`ENABLE_UFW="yes"` activates ufw allowing only SSH and nginx. **Confirm SSH
access from a second terminal before closing the one that ran the script.** A
firewall mistake on a remote instance is otherwise unrecoverable without
console access (Jetstream2 does provide web console access via Exosphere, but
avoid needing it).

---

## After deployment

The health sampler runs every 2 minutes into `~/dashboard-watch/health.log`,
recording memory, CPU, container health, disk, **established connection
counts**, and a `/health` probe. The connection census is there deliberately:
the 2026-07-30 hang was invisible to every resource metric, and connection
count is what distinguishes request-slot starvation from other failures.

```bash
sudo ./deploy/bootstrap.sh --check
grep -B25 'http=000\|health=unhealthy' ~/dashboard-watch/health.log | tail -60
docker logs $(docker ps -qf name=autoheal) --tail 30
sudo tail -f /var/log/nginx/phenology.error.log
```

The log self-truncates at 10MB (keeping the last 5000 lines), since it writes
720 times a day onto a disk that has reached 90%.

---

## Related documents

- `CLAUDE.md` — incident write-up and the reasoning behind each gunicorn flag
- `docs/nginx-deployment-plan.md` — phased, reversible plan for retrofitting
  nginx onto the **existing** production instance without a rebuild. This
  script is the greenfield path; that document is the migration path.
