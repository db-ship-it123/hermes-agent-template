"""
brain-query hook — canonical gbrain brain-first lookup for Hermes.

Fires on agent:start. Calls `gbrain query "<user_message>" --no-expand`,
parses the top-N ranked hits, and appends a "RELEVANT BRAIN CONTEXT" block
to the system prompt via ctx["context_prompt_additions"] (Hermes fork hook
extension — see gateway/run.py around the agent:start emit).

Design notes:
  - Pattern follows gbrain's skills/brain-ops/SKILL.md "Phase 1: Brain-First
    Lookup" convention verbatim — shell out to the `gbrain` CLI that's
    already installed in this container.
  - Fail-open: 3s timeout, any error / missing CLI / empty result → no-op,
    reply proceeds without brain context. Never block a Telegram reply.
  - Output format: textual lines `[score] slug -- chunk_text`. We enrich
    each top-N hit with a short page snippet via `gbrain get <slug>` when
    cheap; otherwise fall back to the chunk_text the query surfaced.
  - Logs every call as `[brain-query] latency_ms=... results=N query_preview=...`
    so we can verify from Railway logs that the hook actually fired.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time

logger = logging.getLogger("hooks.brain-query")

# Tunables — keep conservative. Brain lookup must not become a latency tax on
# every Telegram reply. 3s covers a cold pg-lite read; anything over budget
# gets dropped.
QUERY_TIMEOUT_S = 3.0
MAX_RESULTS = 5
SNIPPET_CHARS = 240
# Ignore extremely short / trivial messages — no point querying for "ok".
MIN_QUERY_CHARS = 4

_LINE_RE = re.compile(r"^\[([^\]]+)\]\s+(\S+)\s+--\s+(.*)$")


def _parse_query_output(stdout: str) -> list[dict]:
    """Parse `gbrain query` text output into structured hits.

    Each ranked line looks like:
        [0.8743] people/garry-tan -- Garry Tan is the CEO of Y Combinator...
    The trailing ` (stale)` marker (if present) is stripped.
    """
    hits: list[dict] = []
    for raw in stdout.splitlines():
        line = raw.strip()
        if not line or line.lower().startswith("no results"):
            continue
        m = _LINE_RE.match(line)
        if not m:
            continue
        score_s, slug, snippet = m.group(1), m.group(2), m.group(3)
        snippet = snippet.replace(" (stale)", "").strip()
        try:
            score = float(score_s)
        except ValueError:
            score = 0.0
        hits.append({"slug": slug, "score": score, "snippet": snippet})
    return hits


def _format_additions(hits: list[dict]) -> str:
    """Build the markdown block that gets appended to the system prompt."""
    lines = [
        "RELEVANT BRAIN CONTEXT (consulted before replying, per brain-ops skill):",
    ]
    for h in hits[:MAX_RESULTS]:
        snippet = h["snippet"][:SNIPPET_CHARS].rstrip()
        lines.append(f"- [{h['slug']}]: {snippet} (score: {h['score']:.2f})")
    lines.append(
        "Use these when relevant and cite the slug inline like [slug]. "
        "If none of these answer the question, say so and reply from general "
        "knowledge."
    )
    return "\n".join(lines)


async def _run_gbrain_query(query: str) -> tuple[str, int]:
    """Invoke `gbrain query <query> --no-expand`. Returns (stdout, returncode)."""
    proc = await asyncio.create_subprocess_exec(
        "gbrain", "query", query, "--no-expand",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout_b, _stderr_b = await asyncio.wait_for(
            proc.communicate(), timeout=QUERY_TIMEOUT_S,
        )
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        raise
    return stdout_b.decode("utf-8", errors="replace"), proc.returncode or 0


async def handle(event_type: str, context: dict) -> None:
    """agent:start handler — append brain context to the system prompt.

    ``context`` is the hook ctx built in gateway/run.py. We read
    ``message_full`` (the raw user message, no truncation) and append any
    formatted block to ``context_prompt_additions`` (a list the fork's
    hook dispatch concatenates into the system prompt before _run_agent).
    """
    if event_type != "agent:start":
        return

    query = (context.get("message_full") or context.get("message") or "").strip()
    if len(query) < MIN_QUERY_CHARS:
        return

    additions = context.get("context_prompt_additions")
    if additions is None:
        # Running against an older hermes that doesn't support the ctx
        # extension — nothing to do. Silent no-op keeps fail-open.
        return

    # gbrain query takes a single positional arg; cap at a sane length so we
    # don't blow out argv on megabyte pastes.
    q_arg = query[:2000]
    preview = query[:60].replace("\n", " ")

    t0 = time.monotonic()
    try:
        stdout, rc = await _run_gbrain_query(q_arg)
        latency_ms = int((time.monotonic() - t0) * 1000)

        if rc != 0:
            logger.info(
                "[brain-query] latency_ms=%d results=0 rc=%d query_preview=%r",
                latency_ms, rc, preview,
            )
            return

        hits = _parse_query_output(stdout)
        logger.info(
            "[brain-query] latency_ms=%d results=%d query_preview=%r",
            latency_ms, len(hits), preview,
        )
        if not hits:
            return

        additions.append(_format_additions(hits))

    except asyncio.TimeoutError:
        latency_ms = int((time.monotonic() - t0) * 1000)
        logger.info(
            "[brain-query] latency_ms=%d results=0 timeout=1 query_preview=%r",
            latency_ms, preview,
        )
    except FileNotFoundError:
        # gbrain CLI not on PATH — log once then keep quiet.
        logger.warning(
            "[brain-query] gbrain CLI not found on PATH; brain injection disabled",
        )
    except Exception as e:
        latency_ms = int((time.monotonic() - t0) * 1000)
        logger.warning(
            "[brain-query] latency_ms=%d error=%s query_preview=%r",
            latency_ms, type(e).__name__, preview,
        )
