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

# 4) Canonical supervisor: let gbrain's own autopilot installer decide how to
#    run the maintenance cycle. Autopilot detects Railway via
#    RAILWAY_ENVIRONMENT and installs the ephemeral-container target: it
#    writes ~/.gbrain/start-autopilot.sh, which backgrounds
#    `gbrain autopilot --repo <dir>` (sync + extract + embed + lint + dream).
#    Replaces the previous hand-rolled sync/dream/doctor loops.
gbrain autopilot --install --repo "$GBRAIN_BRAIN_DIR" || \
  echo "[gbrain] WARN: autopilot --install failed."

if [ -x "$HOME/.gbrain/start-autopilot.sh" ]; then
  bash "$HOME/.gbrain/start-autopilot.sh" && \
    echo "[gbrain] autopilot started via $HOME/.gbrain/start-autopilot.sh" || \
    echo "[gbrain] WARN: autopilot start script failed."
else
  echo "[gbrain] WARN: autopilot start script missing; falling back to inline autopilot."
  nohup gbrain autopilot --repo "$GBRAIN_BRAIN_DIR" > "$HOME/.gbrain/autopilot.log" 2>&1 &
fi

echo "[gbrain] Boot complete. Supervisor: gbrain autopilot (canonical)."

exec python /app/server.py
