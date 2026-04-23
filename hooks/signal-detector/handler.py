"""
signal-detector hook — canonical gbrain ambient capture for Hermes.

Fires on agent:start. Spawns a *detached* background task (asyncio.create_task)
that appends the raw inbound message to today's signal-capture page in the
brain via `gbrain put`. This is the infrastructure half of the signal-detector
contract (skills/signal-detector/SKILL.md): the LLM-driven entity/idea
extraction half happens later during the nightly dream cycle's Phase 1
"Entity Sweep" (docs/guides/cron-schedule.md), which reads today's
conversations and enriches thin pages.

Why this shape:
  - The SKILL.md contract says "spawned, never blocks main response".
  - No gbrain CLI subcommand invokes signal-detector directly (verified 2026-04-23:
    `gbrain --help` has no `signal`/`capture`/`detect` command).
  - We can't spawn an LLM sub-agent from a Python hook in this container, so the
    pragmatic verbatim-compatible path is: persist the raw turn into the brain
    immediately (never-block guarantee) as a well-known slug, and let `gbrain
    dream` do the heavy lift overnight per the canonical schedule.
  - Page slug: `inbox/signals-YYYY-MM-DD` — one append-only page per UTC day.

Design:
  - asyncio.create_task → fire-and-forget; the agent:start coroutine returns
    immediately so the reply pipeline is not delayed.
  - Child subprocess is detached (start_new_session=True) so it survives even
    if the parent hook task is cancelled.
  - All errors are swallowed (logged at WARNING). A failed capture MUST NOT
    prevent the reply.
  - MIN_MESSAGE_CHARS filter skips trivial operational messages per the skill
    anti-pattern ("don't run on 'ok' / 'thanks' / 'do it'").
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import logging
import os

logger = logging.getLogger("hooks.signal-detector")

# Skip trivial operational turns per SKILL.md Anti-Patterns.
MIN_MESSAGE_CHARS = 8
# Hard cap so a megabyte paste doesn't blow out the page.
MAX_CAPTURE_CHARS = 20_000


def _today_slug() -> str:
    return "inbox/signals-" + _dt.datetime.utcnow().strftime("%Y-%m-%d")


def _format_entry(message: str, platform: str, user_id: str, session_id: str) -> str:
    ts = _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    # Fenced code block preserves the user's EXACT phrasing (SKILL.md: "Capture
    # exact phrasing. The user's language IS the insight. Don't paraphrase.")
    return (
        f"\n### {ts} | {platform} | user={user_id} | session={session_id}\n\n"
        f"```\n{message[:MAX_CAPTURE_CHARS]}\n```\n"
    )


async def _capture(message: str, platform: str, user_id: str, session_id: str) -> None:
    """Append an entry to today's signals page via `gbrain put` (append mode).

    gbrain has no native append, so we fetch-then-put: read the existing page
    (if any), concatenate, write back. Collisions across parallel calls are
    accepted — last-writer-wins is fine for an inbox. The dream cycle does
    the dedup + enrichment.
    """
    slug = _today_slug()
    entry = _format_entry(message, platform, user_id, session_id)

    # Read existing body (may be empty / missing).
    existing = ""
    try:
        get_proc = await asyncio.create_subprocess_exec(
            "gbrain", "get", slug,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        out, _ = await asyncio.wait_for(get_proc.communicate(), timeout=3.0)
        if get_proc.returncode == 0:
            existing = out.decode("utf-8", errors="replace")
    except (asyncio.TimeoutError, FileNotFoundError, Exception):
        existing = ""

    # Build full content. If the page is new, seed frontmatter + header.
    if not existing.strip():
        header = (
            "---\n"
            f"title: Signal Capture — {_dt.datetime.utcnow().strftime('%Y-%m-%d')}\n"
            "tags: [signal-capture, inbox, dream-input]\n"
            "type: inbox\n"
            "---\n\n"
            "# Signal Capture\n\n"
            "Raw inbound messages captured by the signal-detector hook. The\n"
            "nightly dream cycle (Phase 1: Entity Sweep) processes these to\n"
            "extract originals, entities, and facts per\n"
            "`skills/signal-detector/SKILL.md`.\n"
        )
        body = header + entry
    else:
        body = existing.rstrip() + "\n" + entry

    # Write back via `gbrain put <slug> --content <body>`. Some gbrain versions
    # also accept stdin; we use --content for portability.
    try:
        put_proc = await asyncio.create_subprocess_exec(
            "gbrain", "put", slug, "--content", body,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,  # detach from hook task lifecycle
        )
        _, err = await asyncio.wait_for(put_proc.communicate(), timeout=5.0)
        if put_proc.returncode != 0:
            logger.warning(
                "[signal-detector] gbrain put failed rc=%d slug=%s err=%s",
                put_proc.returncode, slug,
                err.decode("utf-8", errors="replace")[:200],
            )
    except asyncio.TimeoutError:
        logger.warning("[signal-detector] gbrain put timeout slug=%s", slug)
    except FileNotFoundError:
        logger.warning("[signal-detector] gbrain CLI not on PATH; capture disabled")
    except Exception as e:
        logger.warning("[signal-detector] capture error=%s slug=%s",
                       type(e).__name__, slug)


async def handle(event_type: str, context: dict) -> None:
    """agent:start handler — non-blocking ambient capture.

    Spawns _capture as a detached task and returns immediately. The reply
    pipeline does NOT wait for the capture to complete. This honors the
    SKILL.md contract: "Runs in parallel (spawned, never blocks main response)".
    """
    if event_type != "agent:start":
        return

    message = (context.get("message_full") or context.get("message") or "").strip()
    if len(message) < MIN_MESSAGE_CHARS:
        logger.info("[signal-detector] spawned=false message_len=%d reason=too_short",
                    len(message))
        return

    platform = str(context.get("platform") or "unknown")
    user_id = str(context.get("user_id") or "unknown")
    session_id = str(context.get("session_id") or "unknown")

    # Fire-and-forget. We intentionally don't await or keep a reference —
    # asyncio.create_task schedules it, and the hook returns so the agent:start
    # emit completes and the reply proceeds.
    try:
        asyncio.create_task(_capture(message, platform, user_id, session_id))
        logger.info("[signal-detector] spawned=true message_len=%d", len(message))
    except RuntimeError:
        # No running loop? Shouldn't happen inside an async hook, but fail-open.
        logger.warning("[signal-detector] spawned=false message_len=%d reason=no_loop",
                       len(message))
