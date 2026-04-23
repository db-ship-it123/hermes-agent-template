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

# ── gbrain boot ───────────────────────────────────────────────────────────────
# This is the "On an agent platform (recommended)" path: gbrain lives inside
# the Hermes container. Brain content syncs from db-ship-it123/brain (private).
# PGLite DB + embeddings persist to /data (Railway volume). OPENAI_API_KEY,
# GBRAIN_HTTP_TOKEN, and GITHUB_TOKEN must be set in Railway env.
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
fi

# 2) Initialize PGLite DB on first boot.
if [ ! -f "$GBRAIN_DB_DIR/brain.pglite" ]; then
  echo "[gbrain] Initializing PGLite DB at $GBRAIN_DB_DIR ..."
  gbrain init --yes || echo "[gbrain] WARN: init failed — check logs."
fi

# 3) Import + embed. Only meaningful if brain was cloned and OPENAI_API_KEY set.
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

# The MCP server runs as a subprocess spawned by server.py (lifespan hook),
# bridged over /gbrain/mcp HTTP endpoint with Bearer auth (GBRAIN_HTTP_TOKEN).
echo "[gbrain] Boot complete. MCP bridge will start with Hermes server."

exec python /app/server.py
