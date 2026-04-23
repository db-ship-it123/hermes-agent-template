#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# ── Install Hermes hooks ──────────────────────────────────────────────────────
# Copy bundled hooks (brain-query, etc.) into the hermes runtime hooks dir on
# every boot. Overwrite is safe — these are source-of-truth, not user-edited.
if [ -d /app/hooks ]; then
  for hook_dir in /app/hooks/*/; do
    [ -d "$hook_dir" ] || continue
    hook_name=$(basename "$hook_dir")
    mkdir -p "/data/.hermes/hooks/$hook_name"
    cp -f "$hook_dir"HOOK.yaml "$hook_dir"handler.py \
      "/data/.hermes/hooks/$hook_name/" 2>/dev/null || true
    echo "[hooks] Installed $hook_name → /data/.hermes/hooks/$hook_name/"
  done
fi

# ── gbrain boot ───────────────────────────────────────────────────────────────
# Canonical gbrain deployment: local PGLite on this container, brain content
# synced from db-ship-it123/brain via git. No shared Postgres, no HTTP bridge.
# Jarvis (inside Hermes) calls `gbrain` CLI directly for brain access.
# Required env: OPENAI_API_KEY, GITHUB_TOKEN.
export GBRAIN_DB_DIR=/data/.gbrain
export GBRAIN_BRAIN_DIR=/data/brain
mkdir -p "$GBRAIN_DB_DIR" "$GBRAIN_BRAIN_DIR"

# 1) Clone the private brain if /data/brain is empty.
if [ -z "$(ls -A "$GBRAIN_BRAIN_DIR" 2>/dev/null)" ]; then
  if [ -n "$GITHUB_TOKEN" ]; then
    echo "[gbrain] Cloning db-ship-it123/brain into $GBRAIN_BRAIN_DIR ..."
    git clone "https://db-ship-it123:${GITHUB_TOKEN}@github.com/db-ship-it123/brain.git" "$GBRAIN_BRAIN_DIR" || \
      echo "[gbrain] WARN: brain clone failed — continuing with empty brain."
  else
    echo "[gbrain] WARN: GITHUB_TOKEN unset — cannot clone private brain repo. Set it in Railway env."
  fi
else
  # Repo already cloned — make sure it can pull later without prompting.
  if [ -n "$GITHUB_TOKEN" ] && [ -d "$GBRAIN_BRAIN_DIR/.git" ]; then
    git -C "$GBRAIN_BRAIN_DIR" remote set-url origin \
      "https://db-ship-it123:${GITHUB_TOKEN}@github.com/db-ship-it123/brain.git" || true
  fi
fi

# 2) Initialize PGLite DB on first boot (idempotent).
if [ ! -f "$GBRAIN_DB_DIR/brain.pglite" ]; then
  echo "[gbrain] Initializing PGLite DB at $GBRAIN_DB_DIR ..."
  gbrain init --yes || echo "[gbrain] WARN: init failed — check logs."
fi

# 3) Initial import + embed.
if [ -n "$(ls -A "$GBRAIN_BRAIN_DIR" 2>/dev/null)" ]; then
  echo "[gbrain] Importing $GBRAIN_BRAIN_DIR (no-embed) ..."
  gbrain import "$GBRAIN_BRAIN_DIR" --no-embed || echo "[gbrain] WARN: import failed."
  if [ -n "$OPENAI_API_KEY" ]; then
    echo "[gbrain] Embedding stale pages ..."
    gbrain embed --stale || echo "[gbrain] WARN: embed failed."
  else
    echo "[gbrain] WARN: OPENAI_API_KEY unset — skipping embed."
  fi
fi

# 4) Background sync loop: pull latest brain from git every 15 min and re-embed.
# Dale edits ~/brain on the laptop + pushes; this container picks it up.
(
  while true; do
    sleep 900
    if [ -d "$GBRAIN_BRAIN_DIR/.git" ]; then
      git -C "$GBRAIN_BRAIN_DIR" pull --quiet 2>/dev/null && \
        gbrain sync --repo "$GBRAIN_BRAIN_DIR" >/dev/null 2>&1 && \
        gbrain embed --stale >/dev/null 2>&1 && \
        echo "[gbrain-sync] $(date -u +%FT%TZ) pulled + synced + embedded" || \
        echo "[gbrain-sync] $(date -u +%FT%TZ) sync cycle had errors"
    fi
  done
) &

# 5) Nightly dream cycle — canonical gbrain maintenance per
#    docs/guides/cron-schedule.md ("Dream cycle — nightly at 2 AM").
#    No systemd/cron available in the Railway slim container; we use a
#    sleep-until-next-02:00-UTC loop. Logs to stderr so `railway logs`
#    captures every cycle. `gbrain dream` is documented cron-friendly
#    (exits when done).
(
  while true; do
    now_ts=$(date -u +%s)
    # Next 02:00 UTC. Use python for portability (BusyBox `date -d` is flaky
    # across base images).
    next_ts=$(python3 -c "
import datetime as d
now = d.datetime.utcnow()
target = now.replace(hour=2, minute=0, second=0, microsecond=0)
if target <= now:
    target = target + d.timedelta(days=1)
print(int(target.timestamp()))
")
    sleep_s=$(( next_ts - now_ts ))
    [ "$sleep_s" -lt 60 ] && sleep_s=60
    echo "[cron] next dream cycle at $(date -u -r "$next_ts" +%FT%TZ 2>/dev/null || echo "ts=$next_ts") (sleep ${sleep_s}s)" 1>&2
    sleep "$sleep_s"
    echo "[cron] $(date -u +%FT%TZ) dream cycle starting" 1>&2
    gbrain dream --json >> /tmp/dream.log 2>&1 && \
      echo "[cron] $(date -u +%FT%TZ) dream cycle complete" 1>&2 || \
      echo "[cron] $(date -u +%FT%TZ) dream cycle FAILED (see /tmp/dream.log)" 1>&2
  done
) &

# 6) Weekly doctor + embed — canonical gbrain health check per
#    docs/guides/cron-schedule.md ("Brain health — weekly Mondays at 6 AM").
#    We run Sundays 04:00 UTC per the mission spec. Same sleep-until-target
#    pattern. Summary to stdout so it's visible in railway logs.
(
  while true; do
    now_ts=$(date -u +%s)
    # Next Sunday 04:00 UTC.
    next_ts=$(python3 -c "
import datetime as d
now = d.datetime.utcnow()
# weekday(): Mon=0 .. Sun=6
days_ahead = (6 - now.weekday()) % 7
target = now.replace(hour=4, minute=0, second=0, microsecond=0) + d.timedelta(days=days_ahead)
if target <= now:
    target = target + d.timedelta(days=7)
print(int(target.timestamp()))
")
    sleep_s=$(( next_ts - now_ts ))
    [ "$sleep_s" -lt 60 ] && sleep_s=60
    echo "[cron] next doctor run at $(date -u -r "$next_ts" +%FT%TZ 2>/dev/null || echo "ts=$next_ts") (sleep ${sleep_s}s)" 1>&2
    sleep "$sleep_s"
    echo "[cron] $(date -u +%FT%TZ) doctor run starting"
    gbrain doctor --json > /tmp/doctor.json 2>&1
    rc=$?
    gbrain embed --stale >> /tmp/doctor.json 2>&1 || true
    if [ "$rc" -eq 0 ]; then
      # Emit a compact one-liner summary to stdout (railway logs).
      summary=$(python3 -c "
import json, sys
try:
    with open('/tmp/doctor.json') as f:
        # Only first JSON object — embed output may append non-JSON lines.
        raw = f.read()
    # Find first '{' and matching last '}' conservatively.
    start = raw.find('{')
    end = raw.rfind('}')
    obj = json.loads(raw[start:end+1]) if start != -1 and end != -1 else {}
    checks = obj.get('checks', [])
    ok = sum(1 for c in checks if c.get('status') == 'ok')
    warn = sum(1 for c in checks if c.get('status') == 'warn')
    fail = sum(1 for c in checks if c.get('status') in ('fail','error'))
    print(f'ok={ok} warn={warn} fail={fail}')
except Exception as e:
    print(f'parse_error={type(e).__name__}')
" 2>/dev/null || echo "parse_error=python_unavailable")
      echo "[cron] $(date -u +%FT%TZ) doctor complete: $summary"
    else
      echo "[cron] $(date -u +%FT%TZ) doctor FAILED rc=$rc (see /tmp/doctor.json)"
    fi
  done
) &

echo "[gbrain] Boot complete. Background loops: sync=15min, dream=nightly@02:00UTC, doctor=weekly@Sun04:00UTC."

exec python /app/server.py
