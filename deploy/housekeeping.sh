#!/usr/bin/env bash
#
# Root-disk housekeeping — installed to /usr/local/sbin/phenology-housekeeping
# by bootstrap.sh and run weekly from /etc/cron.d/phenology-housekeeping.
#
# Exists because of the 2026-09-25 root-disk fill.  The Jetstream2 base image
# (GNOME desktop, Firefox, NVIDIA driver, two kernel lines) leaves only ~1.3GB
# free on the 20GB root.  Unattended-upgrades then installed a kernel without
# removing old ones; each kernel costs ~350-450MB plus a DKMS driver build, so
# the install ran the disk to 100% and died half-configured.  Nothing on the
# host reclaims space on its own:
#
#   - old kernels       only removed by `apt-get autoremove`, and only after
#                       any half-configured package is finished
#   - apt archives      .deb downloads are kept indefinitely
#   - snap revisions    the previous revision of every snap stays "disabled"
#   - Docker            superseded images and build cache from each rebuild
#
# Every action below removes only things nothing is using: never the running
# kernel, never an image backing a container.  Safe to run by hand any time:
#   sudo /usr/local/sbin/phenology-housekeeping
#
set -uo pipefail

LOG=/var/log/phenology-housekeeping.log
APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=600)
export DEBIAN_FRONTEND=noninteractive

free_mb() { df -BM --output=avail / | tail -1 | tr -dc '0-9'; }
before=$(free_mb)
notes=()

# A package left half-configured (as on 2026-09-25) blocks autoremove, so
# finish it first.  Needs free space, which is why apt-get clean runs before.
apt-get clean
if [[ -n "$(dpkg --audit 2>/dev/null)" ]]; then
  if dpkg --configure -a >/dev/null 2>&1; then
    notes+=("finished half-configured packages")
  else
    notes+=("WARN dpkg --configure -a failed; see dpkg --audit")
  fi
fi
apt-get autoremove --purge "${APT_OPTS[@]}" >/dev/null 2>&1 \
  || notes+=("WARN autoremove failed")
apt-get clean

if command -v snap >/dev/null 2>&1; then
  snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' \
    | while read -r name rev; do snap remove "$name" --revision="$rev" >/dev/null 2>&1; done
fi

if command -v docker >/dev/null 2>&1; then
  docker builder prune -af >/dev/null 2>&1
  docker image prune -f >/dev/null 2>&1   # dangling only — keeps tagged images
fi

# journald is capped by /etc/systemd/journald.conf.d/50-disk-cap.conf; this
# just enforces the cap immediately rather than at the next rotation.
journalctl --vacuum-size=200M >/dev/null 2>&1

after=$(free_mb)
used=$(df --output=pcent / | tail -1 | tr -dc '0-9')
line="$(date -Is) freed=$((after - before))MB free=${after}MB used=${used}%"
(( used >= 90 )) && notes+=("DISK WARNING: still ${used}% after cleanup — investigate with du")
(( ${#notes[@]} )) && line+=" | $(IFS=';'; echo "${notes[*]}")"
echo "$line" >> "$LOG"

# One line per week; trim anyway so this file can never become the problem.
tail -n 200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
