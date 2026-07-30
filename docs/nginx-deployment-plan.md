# nginx Reverse Proxy — Deployment Plan

**Status:** planned, not executed. Written 2026-07-30, held pending several
days of health-sampler data after commit `cd4787a`.

**Context:** see the "Incident: intermittent unresponsiveness (2026-07-30)"
section of `CLAUDE.md`. Short version — the dashboard became unreachable every
few days with no OOM, no crash, no `WORKER TIMEOUT` and 0.03% CPU. An external
request completed the TCP handshake in 115ms then received zero bytes for 30s,
which is request-slot starvation: the socket accepts into the listen backlog
but no worker thread services it. The concurrency budget was 4 in-flight
requests total, on a port 80 published straight to the public internet with
constant scanner traffic.

`cd4787a` raised the budget to 16 slots and added healthcheck + autoheal. That
raises the threshold and caps an outage at ~3 minutes. It does **not** stop
hostile traffic from consuming worker slots. This plan does.

---

## Decision gate — execute when any of these is true

Do not execute purely on schedule. Check the sampler first:

```bash
grep -B25 'http=000\|health=unhealthy' ~/dashboard-watch/health.log | tail -60
docker logs $(docker ps -qf name=autoheal) --tail 50
docker inspect $(docker ps -qf name=dashboard) --format '{{.RestartCount}}'
```

| Finding | Action |
|---|---|
| `conns` spikes into the dozens before a failure | **Confirms starvation.** Execute this plan now. |
| autoheal logged restarts; users stopped noticing | Diagnosis holds, mitigation is working. Execute at a comfortable pace. |
| No hang for 2+ weeks | Thread bump alone sufficed. Still execute eventually — a bare Python process on the open internet is not a position to stay in — but unhurried. |
| Hangs continue *and* `conns` stays low | **Diagnosis is wrong.** Stop. Capture `py-spy dump` against the baseline in `~/dashboard-watch/baseline-w*.txt` before changing anything else. |

**Update 2026-07-30, after execution:** the diagnosis was subsequently
confirmed and this plan was executed via `deploy/bootstrap.sh` (adoption
path). The health sampler caught six consecutive localhost probes timing out
at the full 20s with zero bytes, 21:32–21:42Z, self-recovering afterwards —
which excludes the network-path alternative noted below and establishes that
the `docker stats` reading of 819MB/5GB at 0.03% CPU was taken *during* the
hang. See the incident section of `CLAUDE.md`.

The plan is retained as the reversible, staged migration path for any future
instance that cannot tolerate the ~2-4 minutes of downtime that
`bootstrap.sh` adoption incurs.

The original caveat, now resolved: this plan assumed the starvation diagnosis,
which was well-supported but not proven — the gap being that the elapsed time
between the failed external `curl` and the healthy `docker stats` was never
established, so a transient network-path fault could not be fully excluded.

---

## Target architecture

```
internet ─→ nginx (host, :80 → :443, TLS)
          → 127.0.0.1:8050 → gunicorn container (otherwise unchanged)
```

nginx buffers each full request before handing it upstream, so a slow client
costs one event-driven nginx connection instead of one of 16 Python threads.
It also terminates TLS, serves `assets/` without waking Python, and drops
malformed scanner traffic before it reaches the app.

**Why host nginx rather than a third container:** certbot integration is
turnkey on the host, there is only ever one app instance on this box, and
keeping nginx outside the compose stack means an app redeploy cannot take the
proxy down with it.

**Not changing:** `mem_limit`, log caps, the read-only `/data` mount, the
healthcheck, autoheal, `cap_add: SYS_PTRACE`, and the gunicorn flags. The
container's internal healthcheck targets `127.0.0.1:8050` *inside* its own
network namespace, so the published-port change below does not affect it.

---

## Prerequisite decision: DNS name for TLS

**Let's Encrypt cannot issue a certificate for a bare IP address.** The
dashboard is currently reached at `http://149.165.155.71/`. TLS therefore
requires a hostname pointed at that IP, one of:

1. A subdomain of a domain you control (`phenology.example.org` → A record →
   `149.165.155.71`). Cleanest.
2. A Jetstream2-provided hostname, if the allocation offers one.
3. **Skip TLS for now.** Phases 1–3 below are independently valuable and work
   over plain HTTP; Phase 4 can follow whenever a name exists.

Resolve this before Phase 4, not before Phase 1.

---

## Phase 1 — Publish on loopback alongside the existing port

Docker permits multiple published ports for one container port, so the new
binding can be added *before* the old one is removed. Nothing breaks and every
step stays reversible.

In `docker-compose.yml`:

```yaml
    ports:
      - "80:8050"              # existing — removed in Phase 3
      - "127.0.0.1:8050:8050"  # new — nginx will target this
```

```bash
cd ~/bioscape_phenology_explorer
docker compose up -d
curl -sS -w '\n%{http_code}\n' http://127.0.0.1:8050/health   # → ok / 200
curl -sS -w '\n%{http_code}\n' http://127.0.0.1/health        # → still 200
```

Both must answer before continuing.

---

## Phase 2 — Install and validate nginx on a temporary port

Port 80 is still held by Docker, so stage nginx on 8080 and prove it works
before it takes over anything.

```bash
sudo apt-get update && sudo apt-get install -y nginx
sudo rm -f /etc/nginx/sites-enabled/default
```

Write `/etc/nginx/sites-available/phenology`:

```nginx
# Rate limit keyed by client IP. 10r/s with burst 40 is far above what a
# human driving the dashboard produces (a page load is a burst of callback
# POSTs, hence the generous burst) and far below a scanner sweep.
limit_req_zone $binary_remote_addr zone=phen:10m rate=10r/s;

# Connection cap per IP — the direct defence against the slow-client
# starvation this whole plan exists to fix.
limit_conn_zone $binary_remote_addr zone=phenconn:10m;

upstream phenology_app {
    server 127.0.0.1:8050 fail_timeout=0s;
    keepalive 16;
}

server {
    listen 8080;              # → 80 in Phase 3
    server_name _;

    # Scanners address the bare IP or a junk Host header. Once a real
    # hostname exists (Phase 4), set server_name to it and this default
    # server returns 444 (close without response) for everything else.
    # Keep permissive until then.

    client_max_body_size 2m;  # no uploads; callback POSTs are small
    client_body_timeout 15s;
    client_header_timeout 15s;

    # Buffer the whole request before touching gunicorn. This is the point
    # of the exercise — a slow client must never occupy a Python thread.
    proxy_request_buffering on;
    proxy_buffering on;
    proxy_buffers 16 16k;
    proxy_busy_buffers_size 64k;

    # Must exceed gunicorn's --timeout 120 so a legitimately slow basemap
    # compute is not cut off by the proxy before the app itself gives up.
    proxy_connect_timeout 10s;
    proxy_send_timeout 130s;
    proxy_read_timeout 130s;

    gzip on;
    gzip_proxied any;
    gzip_min_length 1024;
    gzip_comp_level 5;
    # Dash callback responses are JSON and compress extremely well.
    gzip_types application/json application/javascript text/css text/plain
               image/svg+xml application/manifest+json;

    access_log /var/log/nginx/phenology.access.log;
    error_log  /var/log/nginx/phenology.error.log;

    # Healthcheck probe — excluded from rate limiting and from the access
    # log, since the sampler hits it every 2 minutes.
    location = /health {
        access_log off;
        proxy_pass http://phenology_app;
        proxy_set_header Host $host;
    }

    location / {
        limit_req zone=phen burst=40 nodelay;
        limit_conn phenconn 24;

        proxy_pass http://phenology_app;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Harmless over plain HTTP; required if Dash dev-tools websockets
        # are ever enabled.
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

```bash
sudo ln -sf /etc/nginx/sites-available/phenology /etc/nginx/sites-enabled/phenology
sudo nginx -t          # must pass before reloading
sudo systemctl reload nginx
```

Validate through the proxy — port 80 is still serving the app directly, so
this is a free comparison:

```bash
curl -sS -w '\n%{http_code}\n' http://127.0.0.1:8080/health
curl -sS -o /dev/null -w 'status=%{http_code} t=%{time_total}s\n' http://127.0.0.1:8080/
```

Then open `http://149.165.155.71:8080/` in a browser (open the Jetstream2
security group for 8080 temporarily if needed) and **exercise the app fully**:
click a pixel, switch every chart tab, drag the map/chart divider, change
metrics and opacity. Watch `/var/log/nginx/phenology.error.log` throughout.
Callback POSTs to `/_dash-update-component` are the traffic that matters —
confirm they return 200 and that charts populate.

Do not proceed until the app is fully functional on 8080.

---

## Phase 3 — Cut over to port 80

Remove the direct publication so gunicorn is unreachable from the internet.

In `docker-compose.yml`, delete the `- "80:8050"` line, leaving only:

```yaml
    ports:
      - "127.0.0.1:8050:8050"
```

```bash
docker compose up -d                       # frees host port 80
sudo sed -i 's/listen 8080;/listen 80;/' /etc/nginx/sites-available/phenology
sudo nginx -t && sudo systemctl reload nginx

curl -sS -w '\n%{http_code}\n' http://127.0.0.1/health
```

Confirm gunicorn is no longer publicly bound — this is the whole objective:

```bash
sudo ss -tlnp | grep -E ':80|:8050'
# expect: nginx on 0.0.0.0:80, docker-proxy on 127.0.0.1:8050 ONLY.
# Any 0.0.0.0:8050 means the old mapping survived — recheck the compose file.
```

From your laptop, verify the app loads at `http://149.165.155.71/` and that
`http://149.165.155.71:8050/` refuses the connection.

Close port 8080 in the Jetstream2 security group if it was opened.

**Rollback:** restore `- "80:8050"` in the compose file, `docker compose up -d`,
`sudo systemctl stop nginx`. Back to the pre-plan state in under a minute.

---

## Phase 4 — TLS (requires the DNS name from the prerequisite above)

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d phenology.example.org      # substitute the real name
sudo certbot renew --dry-run
```

certbot rewrites the server block for :443 and adds an HTTP→HTTPS redirect.
Afterwards, tighten the scanner surface — with a real hostname, anything
addressing the bare IP is illegitimate. Add a catch-all *above* the main
server block:

```nginx
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;                # close without responding
}
```

and set `server_name phenology.example.org;` in the real block.

---

## Phase 5 — Host firewall

With nginx as the only public listener, close everything else:

```bash
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw --force enable
sudo ufw status verbose
```

Confirm SSH access from a **second terminal before closing the first** — a
firewall misstep on a remote box is otherwise unrecoverable without console
access.

---

## Post-deployment

**Point the sampler at the proxy.** It already probes `http://127.0.0.1/health`,
which now traverses nginx — correct as-is, and strictly better, since it
exercises the full path. No edit needed.

**Add nginx log rotation awareness.** Ubuntu's default logrotate handles
`/var/log/nginx/*.log`, but the root disk sits at ~86%; confirm with
`ls -la /etc/logrotate.d/nginx` and keep an eye on `df -h /`.

**New diagnostic surface.** nginx now records what gunicorn could not see:

```bash
# Upstream latency distribution — which requests are actually slow
sudo awk '{print $NF}' /var/log/nginx/phenology.access.log | sort -rn | head

# Rate-limited / rejected traffic
sudo grep -c 'limiting requests' /var/log/nginx/phenology.error.log

# Upstream failures — gunicorn refusing or timing out
sudo grep -E 'upstream (timed out|prematurely closed)' /var/log/nginx/phenology.error.log | tail
```

If starvation recurs *after* this plan, `upstream timed out` entries are the
signature, and the fix moves to the app tier: more workers, or addressing the
serialized netCDF4/HDF5 reads described in `CLAUDE.md`.

---

## Expected outcome

Scanner traffic terminates at nginx and never reaches a Python thread. The 16
gunicorn slots serve only buffered, complete, rate-limited requests from real
clients. Combined with the healthcheck and autoheal safety net already in
place, the every-few-days hang should stop entirely.

If it does not, the diagnosis was incomplete — and nginx's access/error logs
are exactly the instrumentation needed to find out why.
