#!/usr/bin/env bash
#
# BioSCape Phenology Explorer — fresh-instance provisioning
#
#   sudo ./deploy/bootstrap.sh              # full provision
#   sudo ./deploy/bootstrap.sh --app-only   # skip host setup; rebuild+restart app
#   sudo ./deploy/bootstrap.sh --check      # verify an existing deployment
#
# Target: fresh Ubuntu 22.04/24.04 Jetstream2 instance (m3.small or larger).
# Idempotent — safe to re-run. Each step detects existing state and skips.
#
# What it does NOT do: provision the datacube data. That is tens of GB on an
# attached volume and must be copied in separately; the script verifies the
# path and stops if it is missing. See deploy/README.md.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="full"
case "${1:-}" in
  --app-only) MODE="app" ;;
  --check)    MODE="check" ;;
  --help|-h)  sed -n '2,20p' "$0"; exit 0 ;;
  "")         ;;
  *)          echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
  C_HEAD=$'\033[1;36m'; C_OFF=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_HEAD=""; C_OFF=""
fi
step() { echo -e "\n${C_HEAD}==> $*${C_OFF}"; }
ok()   { echo -e "    ${C_OK}OK${C_OFF}   $*"; }
skip() { echo -e "    ---  $* (already present, skipping)"; }
warn() { echo -e "    ${C_WARN}WARN${C_OFF} $*"; }
die()  { echo -e "\n${C_ERR}FAILED${C_OFF} $*\n" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
step "Preflight"

[[ $EUID -eq 0 ]] || die "Must run as root:  sudo $0 ${1:-}"

# The invoking (non-root) user owns the checkout and the sampler cron.
REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || die "Cannot resolve home directory for user '$REAL_USER'"
ok "running as root on behalf of '$REAL_USER'"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "Tested on Ubuntu; found '${ID:-unknown}'. Continuing."
  ok "OS: ${PRETTY_NAME:-unknown}"
fi

ENV_FILE="$SCRIPT_DIR/deploy.env"
if [[ ! -f "$ENV_FILE" ]]; then
  die "Missing $ENV_FILE
       Copy the template and edit it first:
         cp $SCRIPT_DIR/deploy.env.example $ENV_FILE
         \${EDITOR:-nano} $ENV_FILE"
fi
# shellcheck source=deploy.env.example
set -a; . "$ENV_FILE"; set +a
ok "loaded $ENV_FILE"

: "${DATA_ROOT:?DATA_ROOT must be set in deploy.env}"
: "${APP_DIR:?APP_DIR must be set in deploy.env}"
: "${REPO_URL:?REPO_URL must be set in deploy.env}"
REPO_BRANCH="${REPO_BRANCH:-main}"
MEM_LIMIT="${MEM_LIMIT:-5g}"
SERVER_NAME="${SERVER_NAME:-}"
ENABLE_TLS="${ENABLE_TLS:-yes}"
ENABLE_UFW="${ENABLE_UFW:-yes}"
ENABLE_HEALTH_SAMPLER="${ENABLE_HEALTH_SAMPLER:-yes}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

# Let's Encrypt cannot issue for a bare IP. Detect and disable TLS rather than
# letting certbot fail midway through an otherwise-successful provision.
TLS_OK="no"
if [[ -n "$SERVER_NAME" && "$ENABLE_TLS" == "yes" ]]; then
  if [[ "$SERVER_NAME" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "SERVER_NAME is a bare IP — Let's Encrypt cannot issue for IPs. TLS skipped."
  elif [[ -z "${CERTBOT_EMAIL:-}" ]]; then
    warn "CERTBOT_EMAIL is empty — TLS skipped."
  else
    TLS_OK="yes"
  fi
fi

# ---------------------------------------------------------------------------
# Data volume — verified, never created
# ---------------------------------------------------------------------------
step "Data volume: $DATA_ROOT"

if [[ ! -d "$DATA_ROOT" ]]; then
  die "Data directory not found: $DATA_ROOT

       The datacubes are not provisioned by this script. On a fresh instance:
         1. Attach the data volume in the Jetstream2 web console (Exosphere).
         2. Confirm the mount:            lsblk; df -h $DATA_ROOT
         3. Copy or rsync the datacubes, pixel_metrics.nc and .npz caches in.
         4. Re-run this script.

       If the data lives elsewhere, set DATA_ROOT in deploy/deploy.env."
fi

DATA_FILES=$(find "$DATA_ROOT" -maxdepth 2 \( -name '*.nc' -o -name '*.npz' -o -name '*.zarr' \) 2>/dev/null | wc -l)
if [[ "$DATA_FILES" -eq 0 ]]; then
  die "No .nc / .npz / .zarr files found under $DATA_ROOT

       The directory exists but appears empty. The dashboard will start and
       then fail on every interaction. Populate it before continuing."
fi
ok "$DATA_FILES data file(s) found"

if ! mountpoint -q "$DATA_ROOT" 2>/dev/null; then
  warn "$DATA_ROOT is not a mountpoint — data may be on the small root disk."
fi
df -h "$DATA_ROOT" | awk 'NR==2 {printf "    ---  volume: %s used of %s (%s)\n", $3, $2, $5}'

# ---------------------------------------------------------------------------
# --check mode stops here after reporting live state
# ---------------------------------------------------------------------------
if [[ "$MODE" == "check" ]]; then
  step "Deployment check"
  for c in docker nginx; do
    command -v "$c" >/dev/null 2>&1 && ok "$c installed" || warn "$c NOT installed"
  done
  if command -v docker >/dev/null 2>&1; then
    docker ps --format '    ---  {{.Names}}  {{.Status}}' || true
  fi
  echo "    ---  swap: $(swapon --show=SIZE --noheadings 2>/dev/null | tr '\n' ' ' || echo none)"
  echo "    ---  root disk: $(df -h / | awk 'NR==2{print $5" used, "$4" free"}')"
  probe=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1/health 2>&1 || echo "unreachable")
  [[ "$probe" == "200" ]] && ok "http://127.0.0.1/health → 200" || warn "health probe → $probe"
  exit 0
fi

# ---------------------------------------------------------------------------
# Host packages
# ---------------------------------------------------------------------------
if [[ "$MODE" == "full" ]]; then
  step "Base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # iproute2 provides `ss`, which the health sampler uses for the connection
  # census — the one metric that distinguishes slot starvation from a hang.
  apt-get install -y -qq ca-certificates curl git gnupg lsb-release ufw \
                         iproute2 cron >/dev/null
  ok "base packages present"

  step "Docker Engine"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    skip "docker + compose plugin"
  else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin >/dev/null
    ok "Docker installed"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  if ! id -nG "$REAL_USER" | grep -qw docker; then
    usermod -aG docker "$REAL_USER"
    warn "added '$REAL_USER' to the docker group — log out and back in for it to apply"
  fi
  ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

  # -------------------------------------------------------------------------
  step "Swapfile (${SWAP_SIZE})"
  if [[ "$SWAP_SIZE" == "0" ]]; then
    skip "disabled in deploy.env"
  elif swapon --show | grep -q '/swapfile'; then
    skip "/swapfile active"
  else
    fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "swap enabled and persisted in /etc/fstab"
  fi
fi

# ---------------------------------------------------------------------------
# Application checkout
# ---------------------------------------------------------------------------
step "Application checkout: $APP_DIR"
if [[ -d "$APP_DIR/.git" ]]; then
  git -C "$APP_DIR" fetch --quiet origin "$REPO_BRANCH"
  git -C "$APP_DIR" checkout --quiet "$REPO_BRANCH"
  git -C "$APP_DIR" pull --quiet --ff-only origin "$REPO_BRANCH"
  ok "updated to $(git -C "$APP_DIR" rev-parse --short HEAD)"
else
  mkdir -p "$(dirname "$APP_DIR")"
  git clone --quiet --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  ok "cloned at $(git -C "$APP_DIR" rev-parse --short HEAD)"
fi
chown -R "$REAL_USER":"$REAL_USER" "$APP_DIR"

# Compose reads this .env automatically. Loopback binding means gunicorn is
# never reachable from the internet — nginx is the only public listener.
step "Compose environment"
cat > "$APP_DIR/.env" <<EOF
# Generated by deploy/bootstrap.sh — edit deploy/deploy.env and re-run instead.
APP_BIND=127.0.0.1:8050
VI_DATACUBE_ROOT=/data
EOF
chown "$REAL_USER":"$REAL_USER" "$APP_DIR/.env"
ok "APP_BIND=127.0.0.1:8050 (loopback only)"

# Honour DATA_ROOT / MEM_LIMIT without editing the committed compose file.
COMPOSE_OVERRIDE="$APP_DIR/docker-compose.override.yml"
cat > "$COMPOSE_OVERRIDE" <<EOF
# Generated by deploy/bootstrap.sh — do not edit by hand.
services:
  dashboard:
    volumes:
      - ${DATA_ROOT}:/data:ro
    mem_limit: ${MEM_LIMIT}
EOF
chown "$REAL_USER":"$REAL_USER" "$COMPOSE_OVERRIDE"
ok "override written (DATA_ROOT, MEM_LIMIT)"

# ---------------------------------------------------------------------------
# Build and start
# ---------------------------------------------------------------------------
step "Build and start containers"
FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [[ "$FREE_GB" -lt 3 ]]; then
  warn "only ${FREE_GB}GB free on / — reclaiming Docker build cache"
  docker builder prune -af >/dev/null 2>&1 || true
fi
docker compose -f "$APP_DIR/docker-compose.yml" -f "$COMPOSE_OVERRIDE" \
  --project-directory "$APP_DIR" up -d --build
ok "compose up complete"

step "Waiting for container health"
HEALTHY="no"
for i in $(seq 1 30); do   # 30 x 10s = 5 min ceiling
  status=$(docker inspect "$(docker compose --project-directory "$APP_DIR" ps -q dashboard 2>/dev/null)" \
           --format '{{.State.Health.Status}}' 2>/dev/null || echo "unknown")
  if [[ "$status" == "healthy" ]]; then HEALTHY="yes"; ok "container healthy after ~$((i*10))s"; break; fi
  [[ "$status" == "unhealthy" ]] && break
  sleep 10
done
if [[ "$HEALTHY" != "yes" ]]; then
  warn "container did not become healthy — recent logs follow"
  docker compose --project-directory "$APP_DIR" logs --tail 40 dashboard || true
  die "Aborting before nginx configuration. Fix the app, then re-run with --app-only."
fi

curl -fsS --max-time 15 http://127.0.0.1:8050/health >/dev/null \
  && ok "http://127.0.0.1:8050/health responds" \
  || die "Loopback health probe failed despite a healthy container."

[[ "$MODE" == "app" ]] && { step "Done (--app-only)"; exit 0; }

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
step "nginx reverse proxy"
command -v nginx >/dev/null 2>&1 || { apt-get install -y -qq nginx >/dev/null; ok "nginx installed"; }

rm -f /etc/nginx/sites-enabled/default
sed "s|__SERVER_NAME__|${SERVER_NAME:-_}|g" \
  "$SCRIPT_DIR/nginx/phenology.conf.template" > /etc/nginx/sites-available/phenology
ln -sf /etc/nginx/sites-available/phenology /etc/nginx/sites-enabled/phenology

nginx -t 2>/dev/null || { nginx -t; die "nginx config test failed — not reloading."; }
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx
ok "nginx serving :80 → 127.0.0.1:8050"

sleep 2
probe=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1/health || echo "000")
[[ "$probe" == "200" ]] && ok "http://127.0.0.1/health → 200 (through nginx)" \
                        || warn "health probe through nginx → $probe (check /var/log/nginx/phenology.error.log)"

# ---------------------------------------------------------------------------
# TLS
# ---------------------------------------------------------------------------
step "TLS"
if [[ "$TLS_OK" == "yes" ]]; then
  apt-get install -y -qq certbot python3-certbot-nginx >/dev/null
  if certbot certificates 2>/dev/null | grep -q "$SERVER_NAME"; then
    skip "certificate for $SERVER_NAME already issued"
  else
    certbot --nginx -d "$SERVER_NAME" --non-interactive --agree-tos \
            -m "$CERTBOT_EMAIL" --redirect \
      && ok "certificate issued; HTTP→HTTPS redirect enabled" \
      || warn "certbot failed — the site remains available over plain HTTP.
         Most common cause: DNS for $SERVER_NAME does not yet resolve to this
         instance's floating IP, or port 80 is closed in the Jetstream2
         security group. Fix, then re-run bootstrap.sh."
  fi
else
  warn "skipped — set SERVER_NAME (a real DNS name) and CERTBOT_EMAIL in deploy.env"
fi

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------
step "Firewall"
if [[ "$ENABLE_UFW" == "yes" ]]; then
  ufw allow OpenSSH >/dev/null
  ufw allow 'Nginx Full' >/dev/null
  if ufw status | grep -q "Status: active"; then
    skip "ufw already active (rules refreshed)"
  else
    ufw --force enable >/dev/null
    ok "ufw enabled (SSH + nginx only)"
    warn "CONFIRM SSH ACCESS FROM A SECOND TERMINAL before closing this one."
  fi
else
  skip "disabled in deploy.env"
fi

# ---------------------------------------------------------------------------
# Health sampler
# ---------------------------------------------------------------------------
step "Health sampler"
if [[ "$ENABLE_HEALTH_SAMPLER" == "yes" ]]; then
  install -d -o "$REAL_USER" -g "$REAL_USER" "$REAL_HOME/dashboard-watch"
  install -m 0755 -o "$REAL_USER" -g "$REAL_USER" \
    "$SCRIPT_DIR/health-sample.sh" "$REAL_HOME/dashboard-watch/sample.sh"
  CRON_LINE="*/2 * * * * $REAL_HOME/dashboard-watch/sample.sh"
  if crontab -u "$REAL_USER" -l 2>/dev/null | grep -qF "dashboard-watch/sample.sh"; then
    skip "cron entry present"
  else
    { crontab -u "$REAL_USER" -l 2>/dev/null || true; echo "$CRON_LINE"; } | crontab -u "$REAL_USER" -
    ok "sampling every 2 min → $REAL_HOME/dashboard-watch/health.log"
  fi
else
  skip "disabled in deploy.env"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
step "Deployment complete"
cat <<EOF

    URL             $( [[ "$TLS_OK" == "yes" ]] && echo "https://$SERVER_NAME" || echo "http://${SERVER_NAME:-$IP}/" )
    App checkout    $APP_DIR
    Data (ro)       $DATA_ROOT → /data
    Exposure        gunicorn on 127.0.0.1:8050 only; nginx is the sole public listener
    Health          http://127.0.0.1/health

    Verify public exposure is correctly closed:
      sudo ss -tlnp | grep -E ':80|:8050'
      # expect nginx on 0.0.0.0:80 and docker-proxy on 127.0.0.1:8050 ONLY

    Routine operations:
      sudo $SCRIPT_DIR/bootstrap.sh --check       # status snapshot
      sudo $SCRIPT_DIR/bootstrap.sh --app-only    # pull + rebuild + restart
      docker compose --project-directory $APP_DIR logs -f dashboard

EOF
