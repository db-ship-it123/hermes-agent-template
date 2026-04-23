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
GET_TIMEOUT_S = 2.0
MAX_RESULTS = 5
# Size of the full-page excerpt we fetch per hit via `gbrain get`. Needs to
# clear the frontmatter + exec summary + State block so cross-reference lines
# (e.g., "Current project: [[dbpersonal]]") land inside the injected context.
PAGE_CHARS = 1500
# Fallback when `gbrain get` is unavailable or slow — truncate the short
# query-snippet to this many chars.
SNIPPET_CHARS = 500
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
        "RELEVANT BRAIN CONTEXT (your persistent long-term memory):",
        "These pages are from Dale's own knowledge base and represent facts you know about him, his projects, his world, and his collaborators. Treat them as authoritative. Read them carefully BEFORE forming your reply.",
        "",
    ]
    for h in hits[:MAX_RESULTS]:
        body = h.get("body") or h.get("snippet") or ""
        body = body[:PAGE_CHARS].rstrip()
        lines.append(f"### [{h['slug']}] (score {h['score']:.2f})")
        lines.append(body)
        lines.append("")
    lines.append(
        "RULES for using this context:\n"
        "1. If the user's question is answered by ANY of these pages, cite the slug inline like [slug] and answer from it — do NOT say 'I don't know' or 'session history only goes back to…'.\n"
        "2. A page at score >= 0.40 is relevant; lower scores may still be relevant by topic.\n"
        "3. Only fall back to general knowledge if NONE of the pages are on-topic. In that case, say so explicitly ('the brain doesn't have info on X, so from general knowledge…').\n"
        "4. Never fabricate facts about Dale, his projects, or people in his world — if it's not above, say it's not in the brain."
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


async def _run_gbrain_get(slug: str) -> str | None:
    """Invoke `gbrain get <slug>` to fetch the full page. Returns body or None."""
    proc = await asyncio.create_subprocess_exec(
        "gbrain", "get", slug,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout_b, _ = await asyncio.wait_for(
            proc.communicate(), timeout=GET_TIMEOUT_S,
        )
    except asyncio.TimeoutError:
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        return None
    if proc.returncode and proc.returncode != 0:
        return None
    body = stdout_b.decode("utf-8", errors="replace")
    # Strip leading YAML frontmatter block if present, to save context budget.
    if body.startswith("---"):
        end = body.find("\n---\n", 3)
        if end != -1:
            body = body[end + 5:]
    return body.strip()


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

        # Enrich top hits with full page bodies (fetch in parallel, bounded by
        # MAX_RESULTS). If `gbrain get` fails or times out for a hit, we fall
        # back to the query snippet for that hit.
        top = hits[:MAX_RESULTS]
        bodies = await asyncio.gather(
            *(_run_gbrain_get(h["slug"]) for h in top),
            return_exceptions=True,
        )
        for h, body in zip(top, bodies):
            if isinstance(body, str) and body:
                h["body"] = body

        additions.append(_format_additions(top))

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
