#!/usr/bin/env bash
#
# Health sampler — installed to ~/dashboard-watch/sample.sh by bootstrap.sh
# and run every 2 minutes by cron.
#
# Exists because the 2026-07-30 hang was invisible to every resource metric:
# the container sat at 819MB/5GB and 0.03% CPU while unreachable from outside.
# What distinguishes that failure is the established-connection count, so this
# records connections alongside the usual resource lines.
#
# Read it after an incident with:
#   grep -B25 'http=000\|health=unhealthy' ~/dashboard-watch/health.log | tail -60
#
LOG="$HOME/dashboard-watch/health.log"
C=$(docker ps -qf name=dashboard 2>/dev/null)

{
  date -Is
  if [[ -n "$C" ]]; then
    docker stats --no-stream --format '{{.MemUsage}} {{.CPUPerc}}' "$C" 2>&1
    echo "health=$(docker inspect "$C" --format '{{.State.Health.Status}}' 2>&1)"
    echo "restarts=$(docker inspect "$C" --format '{{.RestartCount}}' 2>&1)"
  else
    echo "CONTAINER NOT RUNNING"
  fi

  free -m | awk '/Mem:/{print "host_mem_used="$3"MB free="$4"MB"}'
  echo "swap_used=$(free -m | awk '/Swap:/{print $3}')MB"
  df -h / | awk 'NR==2{print "root_disk="$5}'

  # The signal that separates request-slot starvation from everything else.
  echo "conns=$(ss -tn state established '( sport = :80 or sport = :443 )' 2>/dev/null | tail -n +2 | wc -l)"
  ss -tn state established '( sport = :80 or sport = :443 )' 2>/dev/null | tail -n +2 \
    | awk '{split($4,a,":"); print a[1]}' | sort | uniq -c | sort -rn | head -5

  curl -sS -o /dev/null -w 'http=%{http_code} t=%{time_total}s\n' \
       --max-time 20 http://127.0.0.1/health 2>&1
  echo "---"
} >> "$LOG" 2>&1

# Keep the log bounded — this runs 720x/day on a disk that has hit 90%.
if [[ -f "$LOG" ]] && [[ $(stat -c%s "$LOG" 2>/dev/null || echo 0) -gt 10485760 ]]; then
  tail -n 5000 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
