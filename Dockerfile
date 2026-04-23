FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Node.js is required only at build time to compile the Hermes React dashboard.
# We strip the source + apt lists afterwards to keep the image lean.
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git unzip && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install hermes-agent (provides the `hermes` CLI) and pre-build its React
# dashboard so `hermes dashboard` has nothing to build at runtime.
# Deleting web/ afterwards makes hermes's internal _build_web_ui skip the
# rebuild step (it early-returns when package.json is absent), so container
# startup is fast and no runtime npm dependency is needed.
# Use our fork (db-ship-it123/hermes-agent) so the gateway agent:start hook
# extension (context_prompt_additions) is available — required by the
# brain-query hook installed below.
RUN git clone --depth 1 https://github.com/db-ship-it123/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

COPY requirements.txt /app/requirements.txt
RUN uv pip install --system --no-cache -r /app/requirements.txt

# ── gbrain: the "On an agent platform (recommended)" path ─────────────────────
# Install bun, clone db-ship-it123/gbrain, run bun install, and symlink the CLI
# so `gbrain` is on PATH. `gbrain init` runs at runtime in start.sh (needs
# the /data volume). Brain content is cloned from the private db-ship-it123/brain
# repo at boot using GITHUB_TOKEN (set via Railway env vars).
RUN curl -fsSL https://bun.sh/install | bash && \
    ln -sf /root/.bun/bin/bun /usr/local/bin/bun && \
    git clone --depth 1 https://github.com/db-ship-it123/gbrain.git /opt/gbrain && \
    cd /opt/gbrain && \
    bun install --frozen-lockfile && \
    ln -sf /opt/gbrain/src/cli.ts /usr/local/bin/gbrain && \
    chmod +x /opt/gbrain/src/cli.ts
ENV PATH="/root/.bun/bin:${PATH}"

RUN mkdir -p /data/.hermes /data/brain /data/.gbrain

COPY server.py /app/server.py
COPY templates/ /app/templates/
COPY hooks/ /app/hooks/
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

CMD ["/app/start.sh"]
