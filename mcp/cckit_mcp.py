#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.0,<2"]
# ///

from __future__ import annotations

import fcntl
import functools
import hashlib
import json
import os
import re
import fnmatch
import shutil
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Any, Callable, Iterator

from mcp.server.fastmcp import FastMCP
from pydantic import Field


CCKIT = os.environ.get("CCKIT_BIN", "cckit")
DEFAULT_REPO = os.environ.get("CCKIT_REPO")
DEFAULT_TIMEOUT = int(os.environ.get("CCKIT_TIMEOUT", "120"))
# auto (default): incremental reindex when stale before serving; never: leave stale.
CCKIT_REFRESH = os.environ.get("CCKIT_REFRESH", "auto").strip().lower()
CCKIT_DEBUG_STDERR = os.environ.get("CCKIT_DEBUG_STDERR", "").strip().lower() in {
    "1",
    "true",
    "yes",
    "on",
}
# Provenance for action_history.jsonl — CLI reads CCKIT_CALLER.
_REFRESH_LOCK = threading.Lock()
_COMPACT_STAMP = "wax-compact-stamp.json"
# Soft-delete does not shrink repo.wax; only compact again after real growth.
_WAX_COMPACT_GROWTH_BYTES = 64 * 1024 * 1024
_WAX_COMPACT_GROWTH_RATIO = 1.5
# A compact stamp claiming more than this multiple of the live store's size is
# a latched artifact of the pre-cc164a8 stamper, not a real watermark.
_COMPACT_STAMP_MAX_LIVE_RATIO = 2
# Self-reload: long-lived MCP shims keep serving a stale cckit_mcp.py until a
# human reconnects every session. Watch this file and execv ourselves when it
# changes so `swift build`-side fixes deploy fleet-wide without manual action.
_SHIM_SELF_PATH = Path(__file__).resolve()
_SHIM_RELOAD_POLL_SECONDS = 5.0
ShimIdentity = tuple[int, int, int]  # (ino, size, mtime_ns)
# Suffixes that participate in find_symbol / index. Markdown/json/yaml edits
# do not trigger a refresh.
INDEXABLE_SUFFIXES = frozenset({
    ".swift", ".h", ".m", ".mm", ".c", ".cpp", ".hpp",
    ".kt", ".kts", ".java", ".js", ".ts",
    ".css", ".scss", ".less",
})


def _shim_identity(path: Path = _SHIM_SELF_PATH) -> ShimIdentity | None:
    try:
        st = path.stat()
    except OSError:
        return None
    return (st.st_ino, st.st_size, st.st_mtime_ns)


def _should_exec_reload(
    baseline: ShimIdentity | None,
    current: ShimIdentity | None,
    pending: ShimIdentity | None,
) -> bool:
    """True when the file changed vs startup AND is stable across two polls.

    The stability window avoids exec'ing a half-written file (editors that
    truncate-then-write change mtime mid-save).
    """
    if baseline is None or current is None or current == baseline:
        return False
    return pending == current


def shim_reload_disabled() -> bool:
    return os.environ.get("CCKIT_SHIM_RELOAD", "auto").strip().lower() in {
        "off",
        "never",
        "0",
        "false",
    }


_REQUEST_STATE_LOCK = threading.Lock()
# >0 while any tool request is mid-handler. The reload watcher refuses to
# execv until this drains: swapping the process image kills handler threads
# while stdio fds stay open, so the client's pending request never errors,
# never EOFs — it just hangs forever (observed: find_symbol stuck 4+ min).
_REQUESTS_INFLIGHT = 0


@contextmanager
def _request_inflight() -> Iterator[None]:
    global _REQUESTS_INFLIGHT
    with _REQUEST_STATE_LOCK:
        _REQUESTS_INFLIGHT += 1
    try:
        yield
    finally:
        with _REQUEST_STATE_LOCK:
            _REQUESTS_INFLIGHT -= 1


def track_inflight(func: Callable) -> Callable:
    """Mark a tool entrypoint as in-flight so reload defers to it."""
    @functools.wraps(func)
    def wrapper(*args: Any, **kwargs: Any):
        with _request_inflight():
            return func(*args, **kwargs)
    return wrapper


def start_self_reload_watcher() -> None:
    """Replace this process with a fresh run of cckit_mcp.py once the file on
    disk changes AND no request is mid-flight.

    execv keeps pid and stdio fds open, so a swap under load does NOT drop the
    connection — it strands the caller's unresolved request forever. Deferring
    until idle keeps every issued request answerable; the swap happens between
    turns instead.
    """
    if shim_reload_disabled():
        return
    baseline = _shim_identity()

    def watch() -> None:
        pending: ShimIdentity | None = None
        while True:
            time.sleep(_SHIM_RELOAD_POLL_SECONDS)
            action, pending = _reload_tick(baseline, pending)
            if action == "exec":
                sys.stderr.write(
                    f"cckit_mcp.py changed on disk; restarting in place "
                    f"(pid {os.getpid()}, identity {_shim_identity()})\n"
                )
                sys.stderr.flush()
                os.execv(sys.executable, [sys.executable, str(_SHIM_SELF_PATH), *sys.argv[1:]])

    threading.Thread(target=watch, name="cckit-shim-reload", daemon=True).start()


def _reload_tick(
    baseline: ShimIdentity | None,
    pending: ShimIdentity | None,
) -> tuple[str | None, ShimIdentity | None]:
    """One poll of the reload watcher.

    Returns ("exec", None) when safe to swap, else (None, next_pending).
    Two consecutive identical changed identities are required (write-stability),
    and at least one fully idle poll is required before executing — a request
    arriving during the stability window must not be decapitated.
    """
    current = _shim_identity()
    if current is None or current == baseline:
        return None, None
    if not _should_exec_reload(baseline, current, pending):
        return None, current
    if _REQUESTS_INFLIGHT > 0:
        return None, current
    return "exec", None


def cckit_subprocess_env() -> dict[str, str]:
    env = os.environ.copy()
    env["CCKIT_CALLER"] = "mcp"
    return env


def attach_stderr(payload: dict[str, Any], stderr: str, *, success: bool) -> dict[str, Any]:
    """Attach stderr only on errors, unless CCKIT_DEBUG_STDERR=1."""
    if not stderr:
        return payload
    if success and not CCKIT_DEBUG_STDERR:
        return payload
    payload["stderr"] = stderr
    return payload

SERVER_INSTRUCTIONS = """
Token-budgeted codebase tools over an indexed snapshot. gather_code_context and
symbol read disk; outline is a capped skeleton (no docs; huge nested types
collapsed). find_symbol, find_references, and map use the last index.

Routing: work shaped like a symptom, a change, more than one file, or a failure log -> gather_code_context(task) — even when names are visible; those names go in task. Treat the packet as starting context. Prefer gather over Grep/Read for source on the first retrieval. Want a cheap look first? gather_code_context(mode="preview") returns names, line ranges, and body sizes (~1500 token cap), then symbol(...) for each body you need. One known body -> symbol. find_symbol after gather, or when you only need a qualified name, not a packet. find_references wants Foo or Foo.bar. Literal strings/config/error text -> search_text (capped), not raw Grep. File structure -> outline. Names-only overview -> map.
After a gather or locator hit, do not Grep that name. Huge hits: nested name
or narrow Read — symbol will not dump the whole type. Pass repo= when unsure.
Successful responses carry a savings line (~delivered vs whole-file); use it to
stay surgical. MCP auto-refreshes; do not call index yourself.
""".strip()

FIND_SYMBOL_DESCRIPTION = (
    "Name lookup after gather, or when you only need a qualified name, not a "
    "packet. Compact grouped qualified names (no bodies). Exact type hits stay "
    "tiny at the default limit. Line ranges only for huge hits. `fragment` is "
    "an alias for `name`. symbol for a known body. Pass repo= when unsure."
)

GATHER_DESCRIPTION = (
    "Budgeted source packet for a coding task: a symptom, a change, more "
    "than one file, or a failure log. Put the work in task; names you "
    "know help matching and belong here, not in a first find_symbol. "
    "mode=preview returns just names/ranges/body-sizes (~1500 token cap) — "
    "cheap first look before committing to bodies. symbol for one known "
    "body. Pass repo= when unsure."
)

MAP_DESCRIPTION = (
    "Names-only budgeted repo map (no source bodies). Prefer "
    "gather_code_context when you need code for a task. Skip if the gather "
    "packet already included a repository map. Prefer over Glob/Read directory "
    "walks. Pass repo= when unsure."
)

# find-symbol grouped lines: "  struct FindSymbolCommand 9-97"
_FIND_SYMBOL_HIT = re.compile(
    r"^\s+\S+\s+(\S+)\s+(\d+-\d+(?:,\d+-\d+)*)\s*$"
)
_RANGE_PAIR = re.compile(r"(\d+)-(\d+)")
# Candidate tokens; filtered by is_identifier_like (CamelCase / snake_case).
_TASK_IDENT = re.compile(
    r"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\b"
)
_DIRTY_PATH_CAP = 8
_OUTLINE_ATTACH_CAP = 2
_OUTLINE_ATTACH_MAX_CHARS = 8000
_CANDIDATE_CAP = 5
_INLINE_BODY_MAX_LINES = 40
# Dumping a body this large is usually worse than a windowed Read.
# Keep in sync with SymbolSpanLimits.hugeLines.
_HUGE_SPAN_LINES = 200
_SYMBOL_QUERY = re.compile(
    r"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"
)
# Internal payload keys — stripped before returning to the agent.
_REFRESHED_KEY = "_refreshed_this_call"
_DIRTY_KEY = "_dirty_indexable"
_AFTER_REFRESH_KEY = "_miss_after_refresh"


@dataclass(frozen=True)
class LocatorHit:
    name: str
    start: int
    end: int
    file_path: str = ""
    span: int = 0

    def __post_init__(self) -> None:
        if self.span <= 0:
            object.__setattr__(self, "span", max(0, self.end - self.start + 1))

    @property
    def is_huge(self) -> bool:
        return self.span >= _HUGE_SPAN_LINES


def _leaf_name(qualified: str) -> str:
    return qualified.rsplit(".", 1)[-1]


def _span_from_range_label(label: str) -> tuple[int, int, int]:
    pairs = [(int(a), int(b)) for a, b in _RANGE_PAIR.findall(label)]
    if not pairs:
        return 0, 0, 0
    start = min(s for s, _ in pairs)
    end = max(e for _, e in pairs)
    span = sum(max(0, e - s + 1) for s, e in pairs)
    return start, end, span


def hits_from_find_symbol_block(results: str) -> list[LocatorHit]:
    hits: list[LocatorHit] = []
    current_file = ""
    seen: set[tuple[str, str]] = set()
    for line in results.splitlines():
        if not line or line.startswith("(+") or line.startswith("no symbols"):
            continue
        if not line[0].isspace():
            current_file = line.strip()
            continue
        match = _FIND_SYMBOL_HIT.match(line)
        if not match:
            continue
        qname, ranges = match.group(1), match.group(2)
        key = (current_file, qname)
        if key in seen:
            continue
        seen.add(key)
        start, end, span = _span_from_range_label(ranges)
        hits.append(
            LocatorHit(
                name=qname,
                start=start,
                end=end,
                file_path=current_file,
                span=span,
            )
        )
    return hits


def is_symbol_query(name: str) -> bool:
    """True for a symbol leaf or qualified name (Foo or Foo.bar), not a string."""
    return bool(_SYMBOL_QUERY.fullmatch(name.strip()))


def inline_singleton_body(
    payload: dict[str, Any],
    repo: str | None,
) -> dict[str, Any]:
    """Attach the body when find_symbol resolves exactly one small symbol.

    Saves the follow-up symbol() round trip (envelope + latency + the Read
    fallback it sometimes degenerates into). Skipped for huge spans — the
    member-list path handles those.
    """
    if payload.get("count") != 1 or payload.get("totalCount") != 1:
        return payload
    results = payload.get("results")
    if not isinstance(results, str):
        return payload
    hits = hits_from_find_symbol_block(results)
    if len(hits) != 1 or hits[0].is_huge or hits[0].span > _INLINE_BODY_MAX_LINES:
        return payload
    target = hits[0].name
    body_payload = run_cckit(
        ["symbol", target, "--json"],
        repo=repo,
        parse_json=True,
        skip_auto_refresh=True,
    )
    symbols = body_payload.get("symbols")
    if "error" in body_payload or not isinstance(symbols, list) or len(symbols) != 1:
        return payload
    item = symbols[0]
    if not isinstance(item, dict) or not isinstance(item.get("body"), str):
        return payload
    try:
        dedup_repo = str(resolve_repo(repo))
    except ValueError:
        dedup_repo = str(repo or "")
    deduped = apply_delivery_dedup({"symbols": [item]}, dedup_repo)
    payload["inlinedBody"] = deduped["symbols"][0]
    if isinstance(payload.get("results"), str):
        payload["results"] = (
            results.rstrip()
            + "\n(single exact hit — full body attached as 'inlinedBody')"
        )
    return payload


def hide_small_locator_ranges(results: str) -> str:
    """Drop path:L-L on small find_symbol hits so Read is not the next affordance."""
    hits = hits_from_find_symbol_block(results)
    if not hits:
        return results
    huge_keys = {(hit.file_path, hit.name) for hit in hits if hit.is_huge}
    current_file = ""
    out: list[str] = []
    for line in results.splitlines():
        if not line or line.startswith("(+") or line.startswith("no symbols"):
            out.append(line)
            continue
        if not line[0].isspace():
            current_file = line.strip()
            out.append(line)
            continue
        match = _FIND_SYMBOL_HIT.match(line)
        if not match:
            out.append(line)
            continue
        qname = match.group(1)
        if (current_file, qname) in huge_keys:
            out.append(line)
            continue
        out.append(line[: match.start(2)].rstrip())
    return "\n".join(out)


def rank_dirty_for_outline(
    dirty_paths: list[str],
    query: str | None,
) -> list[str]:
    """Dirty files lexically related to the query, best first.

    Only files whose stem/path contain the query leaf are attached. Attaching
    unrelated dirty-file outlines cost ~2k tokens per miss without answering
    anything; semantic candidate blocks now fill that anti-Grep role.
    """
    if not dirty_paths:
        return []
    leaf = _leaf_name(query).lower().strip() if query else ""
    if not leaf:
        return []

    scored: list[tuple[int, int, str]] = []
    for index, path in enumerate(dirty_paths):
        lower = path.lower()
        stem = Path(path).stem.lower()
        if stem == leaf:
            scored.append((0, index, path))
        elif leaf in stem:
            scored.append((1, index, path))
        elif leaf in lower:
            scored.append((2, index, path))
    return [path for _, _, path in sorted(scored)][: _OUTLINE_ATTACH_CAP]


def fetch_dirty_outlines(
    repo: str | None,
    dirty_paths: list[str],
    query: str | None,
) -> list[tuple[str, str]]:
    """Attach compact outlines of dirty files so a miss does not retire to Grep."""
    picked = rank_dirty_for_outline(dirty_paths, query)
    attached: list[tuple[str, str]] = []
    used = 0
    for path in picked:
        remaining = _OUTLINE_ATTACH_MAX_CHARS - used
        if remaining <= 200:
            break
        payload = run_cckit(
            ["outline", path],
            repo=repo,
            skip_auto_refresh=True,
        )
        text = payload.get("text") if isinstance(payload.get("text"), str) else ""
        if "error" in payload or not text.strip():
            continue
        if len(text) > remaining:
            text = text[:remaining].rstrip() + "\n…"
        attached.append((path, text))
        used += len(text)
    return attached


def semantic_candidates(
    repo: str | None,
    query: str | None,
    limit: int = _CANDIDATE_CAP,
) -> list[tuple[str, str]]:
    """Top vector matches (qualified name + file) so a miss resolves without Grep.

    Names only (~15 tokens each). Empty on any error — best-effort by design.
    """
    inner = (query or "").strip()
    if inner.startswith("semantic:"):
        inner = inner[len("semantic:") :].strip()
    if not inner:
        return []
    payload = run_cckit(
        ["search", inner, "--vector", "--json", "--limit", str(limit)],
        repo=repo,
        timeout=60,
        parse_json=True,
        skip_auto_refresh=True,
    )
    if "error" in payload:
        return []
    matches = payload.get("semanticMatches")
    if not isinstance(matches, list):
        return []
    out: list[tuple[str, str]] = []
    for match in matches[:limit]:
        if not isinstance(match, dict):
            continue
        name = match.get("symbol")
        if not isinstance(name, str) or not name:
            continue
        file = match.get("file")
        location = file if isinstance(file, str) else ""
        start = match.get("startLine")
        end = match.get("endLine")
        if isinstance(start, int) and isinstance(end, int) and location:
            location = f"{location}:{start}-{end}"
        out.append((name, location))
    return out


def format_candidates_block(candidates: list[tuple[str, str]]) -> str:
    """Compact names-only block appended to miss responses."""
    if not candidates:
        return ""
    lines = ["Nearest indexed symbols (semantic):"]
    for name, path in candidates[:_CANDIDATE_CAP]:
        lines.append(f"- {name} — {path}" if path else f"- {name}")
    lines.append("symbol() one of these by qualified name before any Grep.")
    return "\n".join(lines)


def miss_footer(
    *,
    dirty_paths: list[str],
    after_refresh: bool,
    outlined_paths: list[str] | None = None,
    for_gather: bool = False,
    has_candidates: bool = False,
) -> str:
    prefix = (
        "No indexed hit; indexing was triggered in the background — retry shortly."
        if after_refresh
        else "No indexed hit."
    )
    candidate_hint = (
        "Nearest indexed symbols below — symbol() one before Grep."
        if has_candidates
        else ""
    )
    if for_gather:
        retry = (
            "Retry gather_code_context with the symptom in prose "
            "(drop leftover names if they did not match). "
            "outline/symbol only if gather still has nothing."
        )
        if outlined_paths:
            return f"{prefix} {retry} Dirty-file outlines below."
        if dirty_paths:
            listed = ", ".join(dirty_paths[:_DIRTY_PATH_CAP])
            extra = len(dirty_paths) - _DIRTY_PATH_CAP
            if extra > 0:
                listed += f", +{extra} more"
            quoted = json.dumps(dirty_paths[0])
            more = f" Dirty files: {listed}." if len(dirty_paths) > 1 else ""
            return (
                f"{prefix} {retry} outline({quoted}) — dirty files read from "
                f"disk.{more}"
            )
        return f"{prefix} {retry}"
    if outlined_paths:
        tail = candidate_hint or (
            "symbol() a name from them. Grep only if outline lacks "
            "the name, then return to symbol(). Do not keep Reading the file."
        )
        return f"{prefix} Dirty-file outlines below. {tail}"
    if dirty_paths:
        listed = ", ".join(dirty_paths[:_DIRTY_PATH_CAP])
        extra = len(dirty_paths) - _DIRTY_PATH_CAP
        if extra > 0:
            listed += f", +{extra} more"
        quoted = json.dumps(dirty_paths[0])
        more = f" Dirty files: {listed}." if len(dirty_paths) > 1 else ""
        if has_candidates:
            return f"{prefix} {candidate_hint} Dirty files: {listed}.{more}"
        return (
            f"{prefix} outline({quoted}) — dirty files read from disk.{more} "
            "Grep only if outline lacks the name, then symbol() the hit. "
            "Do not keep Reading the file."
        )
    if has_candidates:
        return f"{prefix} {candidate_hint}"
    return "No indexed hit. Try a shorter fragment."


def attach_miss_response(
    payload: dict[str, Any],
    *,
    dirty_paths: list[str],
    after_refresh: bool,
    repo: str | None,
    query: str | None,
    replace_body: bool,
    for_gather: bool = False,
    extra_candidates: list[tuple[str, str]] | None = None,
) -> dict[str, Any]:
    """Short miss: outline invitation, semantic candidates, no filler packet."""
    if "error" in payload:
        return payload
    outlined = fetch_dirty_outlines(repo, dirty_paths, query)
    candidates = semantic_candidates(repo, query)
    seen_names = {name for name, _ in candidates}
    for name, path in extra_candidates or []:
        if isinstance(name, str) and name and name not in seen_names:
            candidates.append((name, path))
            seen_names.add(name)
    footer = miss_footer(
        dirty_paths=dirty_paths,
        after_refresh=after_refresh,
        outlined_paths=[path for path, _ in outlined],
        for_gather=for_gather,
        has_candidates=bool(candidates),
    )
    parts = [footer]
    if outlined:
        for path, text in outlined:
            parts.append(f"## outline({path})\n{text.rstrip()}")
    block = format_candidates_block(candidates)
    if block:
        parts.append(block)
    body = "\n\n".join(parts)
    out = dict(payload)
    if replace_body:
        out.pop("results", None)
        out["text"] = body
        return out
    if isinstance(out.get("results"), str):
        out["results"] = body
        return out
    if isinstance(out.get("text"), str):
        out["text"] = body
        return out
    out["hint"] = body
    return out


def strip_internal_keys(payload: dict[str, Any]) -> dict[str, Any]:
    out = dict(payload)
    out.pop(_REFRESHED_KEY, None)
    out.pop(_DIRTY_KEY, None)
    out.pop(_AFTER_REFRESH_KEY, None)
    return out


def format_tokens_short(n: int) -> str:
    sign = "-" if n < 0 else ""
    n = abs(n)
    if n >= 1000:
        value = n / 1000
        text = f"{value:.1f}k" if value < 100 else f"{round(value)}k"
        return f"{sign}{text}"
    return f"{sign}{n}"


def savings_footer(delivered: float | int | None, source: float | int | None) -> str | None:
    """One-line feedback: tokens delivered vs the whole-file read baseline.

    Attached to successful responses so the agent (and user) see the win
    immediately; ~15 tokens of overhead per call.
    """
    if delivered is None or delivered <= 0:
        return None
    delivered_i = int(delivered)
    if source is None or source <= 0:
        return f"~{format_tokens_short(delivered_i)} tokens delivered"
    source_i = int(source)
    saved = source_i - delivered_i
    delivered_text = f"~{format_tokens_short(delivered_i)} tokens delivered vs ~{format_tokens_short(source_i)} whole-file"
    if saved <= 0:
        return f"{delivered_text} · no savings (read was cheaper)"
    pct = saved / source_i * 100
    return f"{delivered_text} · saved ~{format_tokens_short(saved)} ({pct:.0f}%)"


_PACK_STATS_LINE = re.compile(r"^PACK_STATS (\{.*\})$")
_OUTLINE_STATS_LINE = re.compile(r"^OUTLINE_STATS (\{.*\})$")


def split_trailing_stats(text: str, pattern: re.Pattern[str]) -> tuple[str, dict[str, Any] | None]:
    """Strip a machine-readable trailing stats line the CLI appends for MCP calls.

    Returns (text_without_line, parsed) — parsed is None when absent/invalid.
    """
    lines = text.splitlines()
    for idx in range(len(lines) - 1, -1, -1):
        stripped = lines[idx].strip()
        if not stripped:
            continue
        match = pattern.match(stripped)
        if not match:
            return text, None
        try:
            data = json.loads(match.group(1))
        except json.JSONDecodeError:
            return text, None
        remaining = "\n".join(lines[:idx]).rstrip()
        return remaining, (data if isinstance(data, dict) else None)
    return text, None


_REPO_MAP_TOKENS = re.compile(r"# Repository Map \(Tokens:\s*(\d+)/")


def attach_savings(payload: dict[str, Any], footer: str | None) -> dict[str, Any]:
    if footer:
        payload["savings"] = footer
    return payload


def is_identifier_like(token: str) -> bool:
    """Match Swift SemanticIndexPolicy.isIdentifierLike: snake_case or CamelCase.

    Title-case English (Fix, Wire) is not an identifier.
    """
    if "_" in token:
        return True
    letters = [c for c in token if c.isalpha()]
    if len(letters) < 3:
        return False
    has_lower = any(c.islower() for c in letters)
    rest_has_upper = any(c.isupper() for c in letters[1:])
    return has_lower and rest_has_upper


def task_identifiers(task: str) -> list[str]:
    """CamelCase / qualified / snake_case names from a gather task string."""
    seen: set[str] = set()
    out: list[str] = []
    for match in _TASK_IDENT.finditer(task):
        token = match.group(0)
        parts = token.split(".")
        if not (
            is_identifier_like(token) or any(is_identifier_like(p) for p in parts)
        ):
            continue
        if token in seen:
            continue
        seen.add(token)
        out.append(token)
    return out


def gather_packet_is_miss(task: str, packet_text: str) -> bool:
    """True when the task named identifiers and the packet contains none of them."""
    idents = task_identifiers(task)
    if not idents:
        return False
    return not any(ident in packet_text for ident in idents)


def find_symbol_is_miss(payload: dict[str, Any]) -> bool:
    if "error" in payload:
        return False
    if payload.get("count") == 0:
        return True
    results = payload.get("results")
    return isinstance(results, str) and results.lstrip().startswith("no symbols matching")


def find_references_is_miss(payload: dict[str, Any]) -> bool:
    if "error" in payload:
        return False
    return int(payload.get("totalCount") or 0) == 0


def symbol_is_miss(payload: dict[str, Any]) -> bool:
    if "error" in payload:
        return False
    if payload.get("count") == 0:
        return True
    symbols = payload.get("symbols")
    return not isinstance(symbols, list) or len(symbols) == 0


def gather_is_miss(payload: dict[str, Any], task: str) -> bool:
    if "error" in payload:
        return False
    text = payload.get("text")
    if not isinstance(text, str):
        return False
    return gather_packet_is_miss(task, text)


# --- Session delivery ledger --------------------------------------------
# The shim process lives for a whole agent session. Re-sending an unchanged
# symbol body costs tokens without adding information. Bodies delivered this
# session are fingerprinted; identical re-deliveries become one-line stubs.
# Opt out with CCKIT_DEDUP=off; per-call refresh=true forces full bodies.

_DELIVERY_LEDGER_CAP = 512
_delivery_ledger: OrderedDict[tuple[str, str], str] = OrderedDict()
_dedup_saved_total = 0


def dedup_disabled() -> bool:
    return os.environ.get("CCKIT_DEDUP", "auto").strip().lower() in {
        "off",
        "never",
        "0",
        "false",
    }


def _body_fingerprint(body: str) -> str:
    return hashlib.sha1(body.encode("utf-8", "replace")).hexdigest()


def apply_delivery_dedup(
    payload: dict[str, Any],
    repo: str,
    *,
    refresh: bool = False,
) -> dict[str, Any]:
    """Stub symbol bodies already delivered unchanged earlier this session.

    Fingerprints are always updated (so a refreshed body becomes the new
    baseline); only the stubbing is skipped when `refresh` is true.
    """
    global _dedup_saved_total
    symbols = payload.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        return payload

    key_prefix = str(repo)
    saved = 0
    stubbed_any = False
    for item in symbols:
        if not isinstance(item, dict):
            continue
        name = item.get("qualifiedName")
        body = item.get("body")
        if not isinstance(name, str) or not name:
            continue
        if not isinstance(body, str) or not body:
            continue
        key = (key_prefix, name)
        fingerprint = _body_fingerprint(body)
        prior = _delivery_ledger.get(key)
        estimated = max(1, len(body) // 4)
        if (
            not refresh
            and not dedup_disabled()
            and prior is not None
            and prior == fingerprint
        ):
            item["originalBodyTokens"] = estimated
            location = f"{item.get('filePath', '')}:{item.get('startLine', '')}"
            item["body"] = (
                f"[unchanged since earlier this session — ~{estimated} tokens "
                f"delivered previously ({location}). Pass refresh=true to "
                "re-fetch.]"
            )
            item["deduplicated"] = True
            saved += estimated
            stubbed_any = True
        _delivery_ledger[key] = fingerprint
        _delivery_ledger.move_to_end(key)

    while len(_delivery_ledger) > _DELIVERY_LEDGER_CAP:
        _delivery_ledger.popitem(last=False)

    if saved:
        _dedup_saved_total += saved
        payload["deduplicated"] = True
        payload["dedupSavedTokens"] = saved
        record_dedup_saving(repo, "symbol", saved)
    save_delivery_ledger(repo)
    return payload


_GATHER_BODY_MIN_CHARS = 200
_GATHER_SECTION_RE = re.compile(
    r"(?ms)^### (?P<name>.+?) \(SYMBOL · (?P<location>[^\n)]+)\)\n"
    r"```(?P<fence>\w*)\n(?P<body>.*?)\n```$"
)
_DEDUP_STUB_LINE = (
    "[unchanged since earlier this session — ~{tokens} tokens delivered "
    "previously. Pass refresh=true to re-fetch.]"
)


def _ledger_path(repo: str) -> Path:
    return Path(repo) / ".cckit" / "delivery_ledger.json"


def load_delivery_ledger(repo: str | None) -> int:
    """Merge persisted fingerprints for `repo` into memory; returns count loaded.

    Survives shim self-reload (execv) and client reconnects.
    """
    if not repo:
        return 0
    try:
        raw = _ledger_path(repo).read_text(encoding="utf-8")
    except OSError:
        return 0
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return 0
    entries = data.get("entries") if isinstance(data, dict) else None
    loaded = 0
    for row in entries or []:
        if not isinstance(row, list) or len(row) != 3:
            continue
        scope, name, fingerprint = row
        if not all(isinstance(part, str) for part in row):
            continue
        key = (scope, name)
        if key not in _delivery_ledger:
            _delivery_ledger[key] = fingerprint
            loaded += 1
    return loaded


def save_delivery_ledger(repo: str | None) -> None:
    """Write this repo's fingerprints to .cckit/delivery_ledger.json."""
    if not repo:
        return
    prefix = str(repo)
    rows = [
        [scope, name, fingerprint]
        for (scope, name), fingerprint in _delivery_ledger.items()
        if scope == prefix or scope.startswith(f"outline:{prefix}") or scope.startswith(f"gather:{prefix}")
    ]
    if not rows:
        return
    path = _ledger_path(repo)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"version": 1, "entries": rows[-_DELIVERY_LEDGER_CAP:]}),
            encoding="utf-8",
        )
    except OSError:
        pass


def record_dedup_saving(repo: str | None, tool: str, saved_tokens: int) -> None:
    """Append one row to .cckit/dedup_savings.jsonl for pack-stats rollups."""
    if not repo or saved_tokens <= 0:
        return
    path = Path(repo) / ".cckit" / "dedup_savings.jsonl"
    row = json.dumps({
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "tool": tool,
        "savedTokens": saved_tokens,
    })
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(row + "\n")
    except OSError:
        pass


def _record_fingerprint(key: tuple[str, str], fingerprint: str) -> None:
    _delivery_ledger[key] = fingerprint
    _delivery_ledger.move_to_end(key)
    while len(_delivery_ledger) > _DELIVERY_LEDGER_CAP:
        _delivery_ledger.popitem(last=False)


def apply_packet_dedup(
    payload: dict[str, Any],
    repo: str,
    *,
    refresh: bool = False,
) -> dict[str, Any]:
    """Stub unchanged primary-symbol bodies inside a gather packet.

    Primary sections are '### NAME (SYMBOL · loc)' followed by a fenced body;
    only bodies >= _GATHER_BODY_MIN_CHARS participate (smaller ones cost more
    to stub than they save).
    """
    global _dedup_saved_total
    text = payload.get("text")
    if not isinstance(text, str) or "SYMBOL ·" not in text:
        return payload

    disabled = dedup_disabled()
    nonlocal_saved = [0]

    def replace(match: re.Match[str]) -> str:
        name = match.group("name").strip()
        location = match.group("location").strip()
        body = match.group("body")
        fence = match.group("fence")
        if len(body) < _GATHER_BODY_MIN_CHARS:
            return match.group(0)
        key = (f"gather:{repo}", f"{name}@{location}")
        fingerprint = _body_fingerprint(body)
        prior = _delivery_ledger.get(key)
        estimated = max(1, len(body) // 4)
        if (
            not refresh
            and not disabled
            and prior is not None
            and prior == fingerprint
        ):
            stub = _DEDUP_STUB_LINE.format(tokens=estimated)
            stubbed_tokens = max(1, len(stub) // 4)
            _record_fingerprint(key, fingerprint)
            nonlocal_saved[0] += max(0, estimated - stubbed_tokens)
            return (
                f"### {match.group('name')} (SYMBOL · {location})\n"
                f"```{fence}\n{stub}\n```"
            )
        _record_fingerprint(key, fingerprint)
        return match.group(0)

    new_text = _GATHER_SECTION_RE.sub(replace, text)
    saved = nonlocal_saved[0]
    if saved > 0:
        _dedup_saved_total += saved
        payload["text"] = new_text
        payload["deduplicated"] = True
        payload["dedupSavedTokens"] = saved
        record_dedup_saving(repo, "gather", saved)
        save_delivery_ledger(repo)
    return payload


def apply_outline_dedup(
    payload: dict[str, Any],
    repo: str,
    file_path: str,
    *,
    refresh: bool = False,
) -> dict[str, Any]:
    """Stub an identical outline re-delivered this session."""
    global _dedup_saved_total
    text = payload.get("text")
    if not isinstance(text, str) or len(text) < _GATHER_BODY_MIN_CHARS:
        return payload
    key = (f"outline:{repo}", file_path)
    fingerprint = _body_fingerprint(text)
    prior = _delivery_ledger.get(key)
    estimated = max(1, len(text) // 4)
    if (
        not refresh
        and not dedup_disabled()
        and prior is not None
        and prior == fingerprint
    ):
        stub = _DEDUP_STUB_LINE.format(tokens=estimated)
        saved = max(0, estimated - max(1, len(stub) // 4))
        _record_fingerprint(key, fingerprint)
        payload["text"] = stub
        payload["originalOutlineTokens"] = estimated
        _dedup_saved_total += saved
        payload["deduplicated"] = True
        payload["dedupSavedTokens"] = saved
        record_dedup_saving(repo, "outline", saved)
        save_delivery_ledger(repo)
        return payload
    _record_fingerprint(key, fingerprint)
    save_delivery_ledger(repo)
    return payload

server = FastMCP("cckit", instructions=SERVER_INSTRUCTIONS)

RepoPath = Annotated[
    str | None,
    Field(
        description=(
            "Repo root path. Pass when unsure. Falls back to CCKIT_REPO, then server cwd."
        ),
    ),
]


_TEXT_SEARCH_LINE_CHARS = 240
_TEXT_SEARCH_PER_FILE_CAP = 40
_TEXT_SEARCH_TIMEOUT = 30
_TEXT_SEARCH_SKIP_DIRS = frozenset({
    ".git", ".cckit", ".build", ".gradle", ".idea", ".venv", "venv",
    "__pycache__", "build", "dist", "DerivedData", "node_modules", "Pods",
})
_TEXT_FALLBACK_SUFFIXES = INDEXABLE_SUFFIXES | {
    ".py", ".json", ".yaml", ".yml", ".md", ".txt", ".xml",
    ".gradle", ".properties", ".sql", ".sh", ".html",
}


def _collapse_ranges(numbers: list[int]) -> str:
    """[1, 2, 3, 7, 9] -> '1-3, 7, 9' (find_references block style)."""
    if not numbers:
        return ""
    ordered = sorted(set(numbers))
    parts: list[str] = []
    start = prev = ordered[0]
    for value in ordered[1:]:
        if value == prev + 1:
            prev = value
            continue
        parts.append(str(start) if start == prev else f"{start}-{prev}")
        start = prev = value
    parts.append(str(start) if start == prev else f"{start}-{prev}")
    return ", ".join(parts)


def _parse_rg_line(line: str) -> tuple[str, int, str] | None:
    """'path:12:content' -> (path, 12, content); path may contain colons."""
    parts = line.rsplit(":", 2)
    if len(parts) != 3 or not parts[1].isdigit():
        return None
    head, num, content = parts
    return head, int(num), content


def _group_text_matches(
    query: str,
    matches: list[tuple[str, int, str]],
    *,
    total_matches: int,
    truncated: bool,
    previews_per_file: int = 1,
) -> str:
    """Compact grouped block: per-file line ranges + one trimmed preview each."""
    if not matches:
        return f"No text matches for {query!r}."
    by_file: dict[str, list[tuple[int, str]]] = {}
    for path, lineno, content in matches:
        by_file.setdefault(path, []).append((lineno, content))
    lines = [
        f"{query!r} — {total_matches} match(es) in {len(by_file)} file(s)"
        + (" (truncated)" if truncated else "")
    ]
    for path, hits in by_file.items():
        numbers = [lineno for lineno, _ in hits]
        lines.append(f"{path}: {_collapse_ranges(numbers)}")
        shown = 0
        seen_content: set[str] = set()
        for lineno, content in hits:
            trimmed = content.strip()[:_TEXT_SEARCH_LINE_CHARS]
            if not trimmed or trimmed in seen_content:
                continue
            if shown >= previews_per_file:
                break
            seen_content.add(trimmed)
            lines.append(f"  {lineno}: {trimmed}")
            shown += 1
    return "\n".join(lines)


def _rg_args(
    query: str,
    *,
    regex: bool,
    case_sensitive: bool,
    include: str | None,
    root: str,
) -> list[str]:
    args = [
        "rg",
        "--no-heading",
        "--line-number",
        "--color",
        "never",
        "--max-columns",
        str(_TEXT_SEARCH_LINE_CHARS),
        "--max-columns-preview",
        "--max-count",
        str(_TEXT_SEARCH_PER_FILE_CAP),
    ]
    if not regex:
        args.append("-F")
    if not case_sensitive:
        args.append("-i")
    if include:
        args.extend(["-g", include])
    args.extend(["-e", query, root])
    return args


def _stream_rg(
    args: list[str],
    cwd: str,
    stop_after: int,
) -> list[tuple[str, int, str]]:
    """Stream rg stdout, stopping at stop_after matches (bounds memory/tokens)."""
    import time

    matches: list[tuple[str, int, str]] = []
    deadline = time.monotonic() + _TEXT_SEARCH_TIMEOUT
    try:
        proc = subprocess.Popen(
            args,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
        )
    except OSError:
        return matches
    assert proc.stdout is not None
    try:
        for line in proc.stdout:
            parsed = _parse_rg_line(line.rstrip("\n"))
            if parsed is None:
                continue
            matches.append(parsed)
            if len(matches) >= stop_after or time.monotonic() > deadline:
                break
    finally:
        try:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    return matches


def _load_gitignore_patterns(root: Path) -> list[str]:
    """Non-negated .gitignore lines (comments/blanks/negations skipped).

    Limitation, documented: `!` re-includes are not honored by the fallback
    scanner — the rg path handles full semantics when ripgrep is installed.
    """
    patterns: list[str] = []
    try:
        raw = (root / ".gitignore").read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return patterns
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("!"):
            continue
        patterns.append(stripped.lstrip("/"))
    return patterns


def _is_gitignored(rel_path: str, patterns: list[str]) -> bool:
    parts = rel_path.split("/")
    for pattern in patterns:
        dir_pattern = pattern.endswith("/")
        clean = pattern.rstrip("/")
        if dir_pattern and clean in parts:
            return True
        if fnmatch.fnmatch(parts[-1], clean):
            return True
        if any(fnmatch.fnmatch(part, clean) for part in parts[:-1]):
            return True
    return False


def _python_text_search(
    root: Path,
    pattern: re.Pattern[str],
    stop_after: int,
) -> list[tuple[str, int, str]]:
    """Fallback scanner over indexable text suffixes honoring .gitignore."""
    ignore_patterns = _load_gitignore_patterns(root)
    matches: list[tuple[str, int, str]] = []
    files_seen = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in _TEXT_SEARCH_SKIP_DIRS)
        for filename in filenames:
            if not filename.lower().endswith(tuple(_TEXT_FALLBACK_SUFFIXES)):
                continue
            files_seen += 1
            if files_seen > 20000:
                return matches
            path = Path(dirpath) / filename
            try:
                rel = str(path.relative_to(root))
            except ValueError:
                continue
            if ignore_patterns and _is_gitignored(rel, ignore_patterns):
                continue
            try:
                text = path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for index, line in enumerate(text.splitlines(), start=1):
                if pattern.search(line):
                    matches.append((rel, index, line.strip()))
                    if len(matches) >= stop_after:
                        return matches
    return matches


@server.tool(
    name="search_text",
    title="Search literal text (budgeted)",
    description=(
        "Bounded literal text search over the working tree (strings, config "
        "keys, error text). Grouped per file with collapsed line ranges and "
        "one preview each — use instead of raw Grep/rg so output stays "
        "capped. outline(path)/symbol(name) for bodies. Pass repo= when unsure."
    ),
)
def search_text_tool(
    query: Annotated[
        str,
        Field(description="Literal string (default) or regex with regex=true."),
    ],
    repo: RepoPath = None,
    limit: Annotated[
        int,
        Field(description="Max matched lines shown (default 50, hard cap 200).", ge=1, le=200),
    ] = 50,
    regex: Annotated[
        bool,
        Field(description="Treat query as a regular expression."),
    ] = False,
    case_sensitive: Annotated[
        bool,
        Field(description="Match case exactly (default insensitive)."),
    ] = False,
    include: Annotated[
        str | None,
        Field(description="Optional ripgrep glob, e.g. '*.swift'."),
    ] = None,
) -> dict[str, Any]:
    """Budgeted literal text search over the working tree.

    Bounded replacement for raw Grep/rg: capped hits, per-file grouping,
    collapsed line ranges, one preview per file. Strings/config/error-text
    lookups stay inside cckit instead of spilling unbounded rg output.
    """
    pattern_text = query.strip()
    if not pattern_text:
        return {"error": "bad_args", "message": "pass a non-empty query"}
    try:
        cwd = resolve_repo(repo)
    except ValueError as error:
        return {"error": "bad_repo", "message": str(error)}

    stop_after = min(limit * 4, 800)
    if shutil.which("rg") is not None:
        args = _rg_args(
            pattern_text,
            regex=regex,
            case_sensitive=case_sensitive,
            include=include,
            root=str(cwd),
        )
        matches = _stream_rg(args, str(cwd), stop_after)
        total_matches = len(matches)
        truncated = len(matches) >= stop_after
    else:
        try:
            compiled = re.compile(
                pattern_text,
                0 if case_sensitive else re.IGNORECASE,
            )
        except re.error as error:
            return {"error": "bad_regex", "message": str(error)}
        matches = _python_text_search(cwd, compiled, stop_after)
        total_matches = len(matches)
        truncated = len(matches) >= stop_after

    shown = matches[:limit]
    payload: dict[str, Any] = {
        "text": _group_text_matches(
            pattern_text,
            shown,
            total_matches=total_matches,
            truncated=truncated,
        ),
        "totalMatches": total_matches,
        "shownMatches": len(shown),
        "truncated": truncated,
        "hint": (
            "Raise limit for more, or outline(path)/symbol(name) for bodies."
            if truncated
            else "outline(path)/symbol(name) for bodies."
        ),
    }
    try:
        return with_freshness(payload, cwd)
    except Exception:
        return payload


def attach_semantic_guess_hint(
    payload: dict[str, Any],
    repo: str | None,
    task: str,
) -> dict[str, Any]:
    """Tag packets whose primaries are pure semantic guesses (prose-only task).

    With no identifier-shaped tokens in the task, packOnce has zero lexical
    primaries — every delivered symbol came from Wax similarity. Agents that
    know this refine once via candidates instead of blindly re-gathering.
    """
    text = payload.get("text")
    if not isinstance(text, str) or "error" in payload:
        return payload
    if task_identifiers(task):
        return payload
    payload["semanticGuessOnly"] = True
    candidates = semantic_candidates(repo, task)
    block = format_candidates_block(candidates)
    if block:
        payload["candidatesBlock"] = block
        note = (
            "Note: the task named no identifiers, so these matches are "
            "semantic guesses. Candidate symbols attached — symbol() one of "
            "them instead of re-gathering."
        )
        payload["text"] = text.rstrip() + "\n\n" + note + "\n" + block + "\n"
    return payload


def resolve_repo(repo: str | None) -> Path:
    path = Path(repo or DEFAULT_REPO or os.getcwd()).expanduser()
    if not path.is_absolute():
        path = Path.cwd() / path
    path = path.resolve()
    if not path.exists():
        raise ValueError(f"Repository path does not exist: {path}")
    if not path.is_dir():
        raise ValueError(f"Repository path is not a directory: {path}")
    return path


def _git_output(repo: Path, args: list[str]) -> str | None:
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=str(repo),
            capture_output=True,
            text=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _git_nul_paths(repo: Path, args: list[str]) -> list[str]:
    try:
        proc = subprocess.run(
            ["git", *args],
            cwd=str(repo),
            capture_output=True,
            timeout=5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    return [
        part.decode("utf-8", "surrogateescape")
        for part in proc.stdout.split(b"\0")
        if part
    ]


def dirty_paths(repo: Path) -> list[str]:
    """Repo-relative paths that differ from HEAD or are untracked."""
    seen: set[str] = set()
    out: list[str] = []
    for rel in (
        _git_nul_paths(repo, ["diff", "-z", "--name-only", "HEAD"])
        + _git_nul_paths(repo, ["ls-files", "-z", "--others", "--exclude-standard"])
    ):
        if rel not in seen:
            seen.add(rel)
            out.append(rel)
    return out


def is_indexable_path(rel: str) -> bool:
    return Path(rel).suffix.lower() in INDEXABLE_SUFFIXES


def indexable_dirty_paths(repo: Path) -> list[str]:
    return [p for p in dirty_paths(repo) if is_indexable_path(p)]


def refresh_disabled() -> bool:
    return CCKIT_REFRESH in {"never", "off", "0", "false"}


_REFRESH_LOG_NAME = "refresh.log"
# Out-of-band runs append CLI stdout/stderr here; cap so a storm cannot grow it.
_REFRESH_LOG_MAX_BYTES = 512 * 1024
# How much of the log tail is scanned for WaxCompact telemetry per tool call.
_REFRESH_LOG_TAIL_BYTES = 64 * 1024
# Per-repo cooldown between detached refresh spawns. The lock probe is racy by
# design (fd released before Popen): a fresh tool call can win the lock from a
# just-spawned child still in Swift startup (~0.5s), starving older work into
# endless IndexSkipped drops. Once the compact convergence lands this only
# trims junk children during long builds' aftermath.
_SPAWN_COOLDOWN_SECONDS = float(os.environ.get("CCKIT_REFRESH_SPAWN_COOLDOWN", "60"))
_LAST_REFRESH_SPAWN: dict[str, float] = {}


def _refresh_log_path(repo: Path) -> Path:
    return repo / ".cckit" / _REFRESH_LOG_NAME


def _spawn_allowed(repo: Path) -> bool:
    """True outside the per-repo spawn cooldown window."""
    last = _LAST_REFRESH_SPAWN.get(str(repo))
    return last is None or (time.monotonic() - last) >= _SPAWN_COOLDOWN_SECONDS


def _cooldown_remaining(repo: Path) -> float:
    last = _LAST_REFRESH_SPAWN.get(str(repo))
    if last is None:
        return 0.0
    return max(0.0, _SPAWN_COOLDOWN_SECONDS - (time.monotonic() - last))


def refresh_lock_is_free(repo: Path) -> bool:
    """True when no indexer holds .cckit/refresh.lock right now.

    Non-blocking peek so the shim avoids spawning a child that would drop
    itself anyway. The fd (and lock) is released before any spawn — a race
    after the peek is harmless: the losing child self-drops via its own flock.
    """
    try:
        handle = open(repo / ".cckit" / "refresh.lock", "a+")
    except OSError:
        return True
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except OSError:
        return False
    finally:
        handle.close()


def spawn_detached_index(
    repo: Path,
    extra_args: list[str] | None = None,
) -> dict[str, Any]:
    """Launch `cckit index .` detached from this process; never wait in-turn.

    A cross-branch checkout can cost ~19 minutes of indexing. Running that
    synchronously inside a tool handler hits the subprocess timeout cap,
    SIGKILLs a half-written SQLite+Wax pair mid-rebuild, and then serves the
    wounded index. Detached runs survive MCP restarts, write their output to
    `.cckit/refresh.log`, and are serialized by the CLI's own refresh lock —
    concurrent triggers DROP instead of queueing another rebuild.
    """
    log_path = _refresh_log_path(repo)
    try:
        if log_path.stat().st_size > _REFRESH_LOG_MAX_BYTES:
            log_path.write_bytes(b"")
    except OSError:
        pass
    cmd = [CCKIT, "index", ".", *(extra_args or [])]
    try:
        with open(log_path, "ab") as log_handle:
            proc = subprocess.Popen(
                cmd,
                cwd=str(repo),
                stdin=subprocess.DEVNULL,
                stdout=log_handle,
                stderr=subprocess.STDOUT,
                start_new_session=True,
                env=cckit_subprocess_env(),
            )
    except (OSError, FileNotFoundError) as error:
        return {"triggered": False, "refreshError": str(error)}
    return {"triggered": True, "pid": proc.pid}


def _index_is_current(repo: Path) -> bool:
    freshness = index_freshness(repo)
    return not freshness.get("stale") and not working_tree_needs_index(repo)


_WAX_COMPACT_MARKER = "WaxCompact "


def parse_compact_result(stdout: str) -> dict[str, Any] | None:
    """Parse the machine-readable `WaxCompact {...}` line from cckit --compact."""
    for line in reversed((stdout or "").splitlines()):
        if line.startswith(_WAX_COMPACT_MARKER):
            try:
                payload = json.loads(line[len(_WAX_COMPACT_MARKER):])
            except json.JSONDecodeError:
                return None
            return payload if isinstance(payload, dict) else None
    return None


def wax_needs_compact(repo: Path) -> bool:
    """True when repo.wax exists and has never been compacted, or has grown since.

    Sizes are ALLOCATED bytes (st_blocks): repo.wax is sparse AND Wax keeps a
    huge logical length across rewrites (~278MB apparent / ~12MB materialized
    right now), so st_size both overstates today and lies after every reclaim.
    cckit's operating guidance is du, not ls/stat.
    """
    wax = repo / ".cckit" / "repo.wax"
    db = repo / ".cckit" / "index.sqlite"
    if not wax.is_file() or not db.is_file():
        return False
    stat_result = wax.stat()
    live = stat_result.st_blocks * 512
    if stat_result.st_size <= 0 and live <= 0:
        return False
    stamp_path = repo / ".cckit" / _COMPACT_STAMP
    if not stamp_path.is_file():
        return True
    try:
        stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
        last = int(stamp.get("waxBytes") or 0)
    except (OSError, TypeError, ValueError, json.JSONDecodeError):
        return True
    if last <= 0:
        return True
    # cc164a8 guarded new stamp writes but shipped no migration: repos indexed
    # before it can carry a latched watermark far above the live store
    # (observed: 275GB stamp over a 198MB-allocated file). Both growth branches
    # then stay false forever and auto-compaction is silently dead — exactly
    # the population the guard was written for. An impossible stamp is treated
    # as absent so the next run restamps from the CLI.
    if last > live * _COMPACT_STAMP_MAX_LIVE_RATIO:
        return True
    grown = live - last
    return grown >= _WAX_COMPACT_GROWTH_BYTES or live >= int(last * _WAX_COMPACT_GROWTH_RATIO)


def working_tree_needs_index(repo: Path) -> bool:
    """True when an indexable dirty path is missing from the DB or hash-mismatched."""
    paths = indexable_dirty_paths(repo)
    if not paths:
        return False
    db_path = repo / ".cckit" / "index.sqlite"
    if not db_path.is_file():
        return False
    try:
        conn = sqlite3.connect(str(db_path), timeout=2)
        try:
            placeholders = ",".join("?" * len(paths))
            rows = dict(
                conn.execute(
                    f"SELECT path, sha256 FROM fileRecord WHERE path IN ({placeholders})",
                    paths,
                ).fetchall()
            )
        finally:
            conn.close()
    except sqlite3.Error:
        return False
    for rel in paths:
        full = repo / rel
        if not full.is_file():
            if rel in rows:
                return True
            continue
        if rel not in rows:
            return True
        digest = hashlib.sha256(full.read_bytes()).hexdigest()
        if digest != rows[rel]:
            return True
    return False


def index_freshness(repo: Path) -> dict[str, Any]:
    """Compare .cckit/index-stamp.json to HEAD. stale=true when commits differ."""
    stamp_path = repo / ".cckit" / "index-stamp.json"
    head_commit = _git_output(repo, ["rev-parse", "HEAD"])
    head_branch = _git_output(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    indexed_commit = None
    indexed_branch = None
    if stamp_path.is_file():
        try:
            stamp = json.loads(stamp_path.read_text())
            indexed_commit = stamp.get("commit")
            indexed_branch = stamp.get("branch")
        except (OSError, json.JSONDecodeError):
            pass

    if indexed_commit and head_commit:
        stale = indexed_commit != head_commit
    elif head_commit and not indexed_commit:
        stale = True
    else:
        stale = False

    out: dict[str, Any] = {"stale": stale}
    if indexed_commit:
        out["indexedCommit"] = indexed_commit
    if indexed_branch:
        out["indexedBranch"] = indexed_branch
    if head_commit:
        out["headCommit"] = head_commit
    if head_branch:
        out["headBranch"] = head_branch
    return out


def _short_commit(value: str | None) -> str | None:
    if not value:
        return None
    return value[:8]


def with_freshness(payload: dict[str, Any], repo: Path) -> dict[str, Any]:
    freshness = index_freshness(repo)
    # Only attach freshness when stale or the payload is already an error.
    if not freshness.get("stale") and "error" not in payload:
        return payload

    compact: dict[str, Any] = {"stale": bool(freshness.get("stale"))}
    if ic := _short_commit(freshness.get("indexedCommit")):
        compact["indexedCommit"] = ic
    if hc := _short_commit(freshness.get("headCommit")):
        compact["headCommit"] = hc
    indexed_branch = freshness.get("indexedBranch")
    head_branch = freshness.get("headBranch")
    if indexed_branch != head_branch:
        if indexed_branch:
            compact["indexedBranch"] = indexed_branch
        if head_branch:
            compact["headBranch"] = head_branch
    for key, value in compact.items():
        payload.setdefault(key, value)
    return payload


def maybe_refresh_index(repo: Path, args: list[str]) -> dict[str, Any] | None:
    """Trigger an out-of-band index when HEAD drifted or dirty files hash-mismatch.

    Also auto-compacts a leaked Wax store even when the SQLite stamp is current.
    Never runs indexing in-turn: returns as soon as a detached `cckit index`
    has been spawned (or skipped because one already holds the refresh lock).
    """
    if refresh_disabled():
        return None
    if args and args[0] == "index":
        return None
    freshness = index_freshness(repo)
    if not (not _index_is_current(repo) or wax_needs_compact(repo)):
        return None

    with _REFRESH_LOCK:
        if not refresh_lock_is_free(repo):
            return {
                "refreshed": False,
                "skipped": True,
                "reason": "index_in_progress",
                **freshness,
            }
        # Recheck under the process mutex so parallel tool calls in this MCP
        # process spawn at most one indexer between the check and the spawn.
        needs_index = not _index_is_current(repo)
        needs_compact = wax_needs_compact(repo)
        if not needs_index and not needs_compact:
            return None
        if not _spawn_allowed(repo):
            return {
                "refreshed": False,
                "skipped": True,
                "reason": "spawn_cooldown",
                "cooldownRemainingSeconds": round(_cooldown_remaining(repo), 1),
                **freshness,
            }
        extra = ["--compact"] if (needs_compact and not needs_index) else None
        triggered = spawn_detached_index(repo, extra_args=extra)
        _LAST_REFRESH_SPAWN[str(repo)] = time.monotonic()
        return {
            "refreshed": False,
            **triggered,
            **freshness,
        }


def force_refresh_index(repo: Path) -> dict[str, Any]:
    """Trigger one out-of-band incremental index (miss-time retry). Honors CCKIT_REFRESH=never.

    Fire-and-forget: the immediate query retry runs against the existing index;
    results improve once the detached run lands.
    """
    if refresh_disabled():
        return {"refreshed": False, "skipped": True}
    with _REFRESH_LOCK:
        freshness = index_freshness(repo)
        if not refresh_lock_is_free(repo):
            return {
                "refreshed": False,
                "skipped": True,
                "reason": "index_in_progress",
                **freshness,
            }
        if _index_is_current(repo) and not wax_needs_compact(repo):
            return {"refreshed": False, "skipped": True, "reason": "already_fresh", **freshness}
        if not _spawn_allowed(repo):
            return {
                "refreshed": False,
                "skipped": True,
                "reason": "spawn_cooldown",
                "cooldownRemainingSeconds": round(_cooldown_remaining(repo), 1),
                **freshness,
            }
        needs_index = not _index_is_current(repo)
        needs_compact = wax_needs_compact(repo)
        extra = ["--compact"] if (needs_compact and not needs_index) else None
        triggered = spawn_detached_index(repo, extra_args=extra)
        _LAST_REFRESH_SPAWN[str(repo)] = time.monotonic()
        return {"refreshed": False, **triggered, **freshness}


def _wax_growth_warning(compact: dict[str, Any] | None) -> dict[str, Any] | None:
    """Flag arena growth reported by the CLI's WaxCompact telemetry.

    Growth on plain `index .` used to be completely silent (half a terabyte
    once accumulated). The CLI now emits bytesBefore/bytesAfter on every run;
    surface a warning when a single run moves the arena materially.
    """
    if not compact:
        return None
    try:
        before = int(compact.get("bytesBefore") or 0)
        after = int(compact.get("bytesAfter") or 0)
    except (TypeError, ValueError):
        return None
    if before <= 0 or after <= before:
        return None
    grown = after - before
    ratio_breached = before > 0 and after >= int(before * _WAX_COMPACT_GROWTH_RATIO)
    if grown < _WAX_COMPACT_GROWTH_BYTES and not ratio_breached:
        return None
    warning: dict[str, Any] = {
        "bytesBefore": before,
        "bytesAfter": after,
        "grownBytes": grown,
    }
    if ratio_breached:
        warning["ratioBreached"] = True
    return warning


_REFRESH_TELEMETRY_CACHE: dict[str, Any] = {}


def _recent_refresh_log_telemetry(repo: Path) -> dict[str, Any]:
    """Best-effort telemetry from detached index runs, parsed lazily.

    Out-of-band runs leave no captured stdout in this process, so their
    machine-readable lines are read back from `.cckit/refresh.log`: the last
    `WaxCompact {...}` line is surfaced as waxCompact/waxGrowthWarning on
    subsequent tool calls. Cached per (mtime_ns, size); a miss is just no data.
    """
    log_path = _refresh_log_path(repo)
    try:
        stat = log_path.stat()
        cache_key = f"{repo}:{stat.st_mtime_ns}:{stat.st_size}"
    except OSError:
        return {}
    if _REFRESH_TELEMETRY_CACHE.get("key") == cache_key:
        return _REFRESH_TELEMETRY_CACHE.get("payload", {})
    try:
        with open(log_path, "rb") as handle:
            handle.seek(max(0, stat.st_size - _REFRESH_LOG_TAIL_BYTES))
            tail = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return {}
    payload: dict[str, Any] = {}
    compact = parse_compact_result(tail)
    if compact is not None:
        payload["waxCompact"] = compact
        warning = _wax_growth_warning(compact)
        if warning is not None:
            payload["waxGrowthWarning"] = warning
    _REFRESH_TELEMETRY_CACHE["key"] = cache_key
    _REFRESH_TELEMETRY_CACHE["payload"] = payload
    return payload


@track_inflight
def run_cckit(
    args: list[str],
    repo: str | None = None,
    timeout: int = DEFAULT_TIMEOUT,
    parse_json: bool = False,
    skip_auto_refresh: bool = False,
) -> dict[str, Any]:
    try:
        cwd = resolve_repo(repo)
    except ValueError as error:
        return {"error": "bad_repo", "message": str(error)}

    refresh_meta = None if skip_auto_refresh else maybe_refresh_index(cwd, args)

    try:
        proc = subprocess.run(
            [CCKIT, *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
            env=cckit_subprocess_env(),
        )
    except FileNotFoundError:
        out = with_freshness(
            {
                "error": "cckit_not_found",
                "hint": f"Set CCKIT_BIN to the cckit executable. Current value: {CCKIT}",
            },
            cwd,
        )
        if refresh_meta:
            out["refresh"] = refresh_meta
        out[_REFRESHED_KEY] = bool(refresh_meta and refresh_meta.get("refreshed"))
        return out
    except subprocess.TimeoutExpired:
        out = with_freshness(
            {"error": "timeout", "after_seconds": timeout, "command": [CCKIT, *args]},
            cwd,
        )
        if refresh_meta:
            out["refresh"] = refresh_meta
        out[_REFRESHED_KEY] = bool(refresh_meta and refresh_meta.get("refreshed"))
        return out

    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()

    def finish(payload: dict[str, Any]) -> dict[str, Any]:
        out = with_freshness(payload, cwd)
        refreshed = bool(refresh_meta and refresh_meta.get("refreshed"))
        # Refresh triggers are fire-and-forget now: whenever one fired we know
        # the index WAS stale, so stale markers stay visible until the detached
        # run actually lands.
        if refresh_meta:
            out["refresh"] = refresh_meta
        # Surface telemetry from previously-detached runs (WaxCompact growth).
        telemetry = _recent_refresh_log_telemetry(cwd)
        for key in ("waxCompact", "waxGrowthWarning"):
            if key in telemetry:
                out.setdefault(key, telemetry[key])
        out[_REFRESHED_KEY] = refreshed
        return out

    if proc.returncode != 0:
        err_payload: dict[str, Any] = {
            "error": "cckit_failed",
            "returncode": proc.returncode,
            "command": [CCKIT, *args],
            "stdout": stdout,
        }
        if stderr:
            err_payload["stderr"] = stderr
        return finish(err_payload)

    if stdout.startswith("Error: Index not found"):
        no_index: dict[str, Any] = {
            "error": "no_index",
            "message": stdout,
            "hint": "Run the index tool for this repo, then retry.",
        }
        return finish(attach_stderr(no_index, stderr, success=False))

    if parse_json:
        try:
            data = json.loads(stdout)
            if isinstance(data, dict):
                payload = dict(data)
                return finish(attach_stderr(payload, stderr, success=True))
            payload = {"data": data}
            return finish(attach_stderr(payload, stderr, success=True))
        except json.JSONDecodeError:
            bad: dict[str, Any] = {"error": "bad_json", "stdout": stdout[:2000]}
            return finish(attach_stderr(bad, stderr, success=False))

    text_payload: dict[str, Any] = {"text": stdout}
    return finish(attach_stderr(text_payload, stderr, success=True))


@track_inflight
def run_cckit_with_miss_retry(
    args: list[str],
    repo: str | None = None,
    *,
    is_miss: Callable[[dict[str, Any]], bool],
    timeout: int = DEFAULT_TIMEOUT,
    parse_json: bool = False,
) -> dict[str, Any]:
    """Run cckit; on miss with dirty indexable files, force-index once and retry."""
    payload = run_cckit(args, repo=repo, timeout=timeout, parse_json=parse_json)
    refreshed = bool(payload.pop(_REFRESHED_KEY, False))

    if "error" in payload or not is_miss(payload):
        return strip_internal_keys(payload)

    try:
        cwd = resolve_repo(repo)
    except ValueError:
        return strip_internal_keys(payload)

    dirty = indexable_dirty_paths(cwd)
    after_refresh = refreshed

    if dirty and not refreshed and not refresh_disabled():
        force_refresh_index(cwd)
        after_refresh = True
        payload = run_cckit(
            args,
            repo=repo,
            timeout=timeout,
            parse_json=parse_json,
            skip_auto_refresh=True,
        )
        payload.pop(_REFRESHED_KEY, None)
        if not is_miss(payload):
            return strip_internal_keys(payload)

    payload[_DIRTY_KEY] = dirty
    payload[_AFTER_REFRESH_KEY] = after_refresh or bool(dirty)
    return payload


def append_repeated_option(args: list[str], option: str, values: list[str] | None) -> None:
    for value in values or []:
        if value:
            args.extend([option, value])


@server.tool(
    name="gather_code_context",
    title="Gather code context",
    description=GATHER_DESCRIPTION,
)
def gather_code_context(
    task: Annotated[
        str,
        Field(
            description=(
                "What you are about to do (e.g. '401 retry after token "
                "refresh'). Names you already know help matching."
            ),
        ),
    ],
    repo: RepoPath = None,
    budget: Annotated[
        int,
        Field(
            description="Max token ceiling (default 12000), not a fill target.",
            ge=512,
            le=200000,
        ),
    ] = 12000,
    failure: Annotated[
        str | None,
        Field(description="Optional build/test log path to anchor context."),
    ] = None,
    mode: Annotated[
        str,
        Field(
            description=(
                "auto (default)=smallest of surgical|full|raw; "
                "surgical=symbol slices when cheaper (tiny files whole); "
                "full=whole primary files; preview=names/ranges/body-sizes "
                "only (~1500 token cap) for a cheap first look. Requested "
                "modes: auto|surgical|full|preview (raw is delivered-only)."
            ),
        ),
    ] = "auto",
) -> dict[str, Any]:
    # MCP name is gather_code_context; CLI remains `cckit pack`.
    resolved = mode.strip().lower()
    if resolved not in {"auto", "surgical", "full", "preview"}:
        return {
            "error": "bad_mode",
            "message": f"mode must be auto|surgical|full|preview, got {mode!r}",
        }
    args = ["pack", "--task", task, "--budget", str(budget)]
    if failure:
        args.extend(["--failure", failure])
    if resolved == "full":
        args.append("--full")
    elif resolved == "surgical":
        args.append("--surgical")
    elif resolved == "preview":
        args.append("--preview")
    payload = run_cckit_with_miss_retry(
        args,
        repo=repo,
        is_miss=lambda p: gather_is_miss(p, task),
        timeout=180,
        parse_json=False,
    )
    if gather_is_miss(payload, task):
        dirty = list(payload.pop(_DIRTY_KEY, []) or [])
        after = bool(payload.pop(_AFTER_REFRESH_KEY, False))
        idents = task_identifiers(task)
        return attach_miss_response(
            strip_internal_keys(payload),
            dirty_paths=dirty,
            after_refresh=after,
            repo=repo,
            query=idents[0] if idents else None,
            replace_body=True,
            for_gather=True,
        )
    out = strip_internal_keys(payload)
    text, stats = split_trailing_stats(out.get("text", ""), _PACK_STATS_LINE)
    if stats is not None:
        out["text"] = text
    try:
        out = apply_packet_dedup(out, str(resolve_repo(repo)))
    except ValueError:
        pass
    out = attach_semantic_guess_hint(out, repo, task)
    if stats is not None:
        attach_savings(
            out,
            savings_footer(stats.get("deliveredTokens"), stats.get("sourceWholeFileTokens")),
        )
    return out


@server.tool(
    name="find_symbol",
    title="Look up a symbol name",
    description=FIND_SYMBOL_DESCRIPTION,
)
def find_symbol(
    name: Annotated[
        str | None,
        Field(description="Name fragment, e.g. 'gameStateLabel' or 'APIClient'."),
    ] = None,
    fragment: Annotated[
        str | None,
        Field(description="Alias for name."),
    ] = None,
    repo: RepoPath = None,
    limit: Annotated[
        int,
        Field(description="Max hits (default 20).", ge=1, le=100),
    ] = 20,
    strict: Annotated[
        bool,
        Field(description="Require every whitespace term to match (AND)."),
    ] = False,
) -> dict[str, Any]:
    resolved = (name or fragment or "").strip()
    if not resolved:
        return {"error": "bad_args", "message": "pass name or fragment"}
    args = ["find-symbol", resolved, "--json", "--limit", str(limit)]
    if strict:
        args.append("--strict")
    payload = run_cckit_with_miss_retry(
        args,
        repo=repo,
        is_miss=find_symbol_is_miss,
        parse_json=True,
    )
    dirty = list(payload.pop(_DIRTY_KEY, []) or [])
    after = bool(payload.pop(_AFTER_REFRESH_KEY, False))
    if find_symbol_is_miss(payload):
        return attach_miss_response(
            strip_internal_keys(payload),
            dirty_paths=dirty,
            after_refresh=after,
            repo=repo,
            query=resolved,
            replace_body=False,
        )
    out = strip_internal_keys(payload)
    if isinstance(out.get("results"), str):
        try:
            out = inline_singleton_body(out, repo)
        except ValueError:
            pass
        if not isinstance(out.get("inlinedBody"), dict):
            out["results"] = hide_small_locator_ranges(out["results"])
    return out


@server.tool(
    name="find_references",
    title="Find references to a symbol",
    description=(
        "Indexed references as a compact grouped text block (file + lines, no "
        "bodies). Batch several names via names=[...] in one call. Skips "
        "comments. Name must be a symbol leaf or qualified name "
        "(Foo or Foo.bar), not a string — search_text for literals/comments. "
        "Check truncated/totalCount and raise limit before concluding unused. "
        "On a miss, MCP indexes once and retries, then outlines dirty files. "
        "These lines are locations, not a Read list. Pass repo= when unsure."
    ),
)
def find_references(
    name: Annotated[
        str | None,
        Field(
            description=(
                "Symbol leaf name or qualified name "
                "(e.g. 'refresh' or 'AuthSession.refresh')."
            ),
        ),
    ] = None,
    names: Annotated[
        list[str] | None,
        Field(description="Batch of names to look up in one call."),
    ] = None,
    repo: RepoPath = None,
    limit: Annotated[
        int,
        Field(description="Max hits per name (default 100). Raise when truncated=true.", ge=1, le=10000),
    ] = 100,
) -> dict[str, Any]:
    merged: list[str] = []
    if name:
        merged.append(name)
    if names:
        merged.extend(n for n in names if n)
    merged = [n for n in merged if isinstance(n, str) and n.strip()]
    if not merged:
        return {"error": "bad_args", "message": "pass name or names"}
    for candidate_name in merged:
        if not is_symbol_query(candidate_name):
            return {
                "error": "not_a_symbol_name",
                "message": (
                    "find_references wants a symbol name, not a string. "
                    "search_text for literals/comments. find_symbol for identifiers."
                ),
            }
    args = ["find-references", *merged, "--json", "--limit", str(limit)]
    payload = run_cckit_with_miss_retry(
        args,
        repo=repo,
        is_miss=find_references_is_miss,
        parse_json=True,
    )
    if find_references_is_miss(payload):
        dirty = list(payload.pop(_DIRTY_KEY, []) or [])
        after = bool(payload.pop(_AFTER_REFRESH_KEY, False))
        raw_candidates = payload.get("candidates")
        extra = [
            (candidate, "")
            for candidate in (raw_candidates or [])
            if isinstance(candidate, str)
        ] if isinstance(raw_candidates, list) else []
        return attach_miss_response(
            strip_internal_keys(payload),
            dirty_paths=dirty,
            after_refresh=after,
            repo=repo,
            query=merged[0],
            replace_body=False,
            extra_candidates=extra,
        )
    return strip_internal_keys(payload)


@server.tool(
    title="Fetch symbol body",
    description=(
        "Return symbol body/bodies from disk. Types or methods over 200 lines "
        "return a member list instead of the body — pass a nested name. Batch "
        "names after find_symbol, or for a name a gather packet did not "
        "include. Bodies unchanged since earlier this session come back as a "
        "one-line stub (refresh=true forces full bodies). Pass repo= when unsure."
    ),
)
def symbol(
    name: Annotated[
        str | None,
        Field(description="Exact qualified symbol name (optional if names is set)."),
    ] = None,
    names: Annotated[
        list[str] | None,
        Field(description="Batch of qualified names to fetch in one call."),
    ] = None,
    repo: RepoPath = None,
    refresh: Annotated[
        bool,
        Field(
            description=(
                "Re-fetch full bodies even when unchanged since earlier this session."
            )
        ),
    ] = False,
) -> dict[str, Any]:
    merged: list[str] = []
    if name:
        merged.append(name)
    if names:
        merged.extend(n for n in names if n)
    if not merged:
        return {"error": "bad_args", "message": "pass name or names"}
    args = ["symbol", *merged, "--json"]
    payload = run_cckit_with_miss_retry(
        args,
        repo=repo,
        is_miss=symbol_is_miss,
        parse_json=True,
    )
    if symbol_is_miss(payload):
        dirty = list(payload.pop(_DIRTY_KEY, []) or [])
        after = bool(payload.pop(_AFTER_REFRESH_KEY, False))
        return attach_miss_response(
            strip_internal_keys(payload),
            dirty_paths=dirty,
            after_refresh=after,
            repo=repo,
            query=merged[0],
            replace_body=False,
        )
    out = strip_internal_keys(payload)
    try:
        out = apply_delivery_dedup(out, str(resolve_repo(repo)), refresh=refresh)
    except ValueError:
        pass
    return attach_savings(
        out,
        savings_footer(out.get("tokensDelivered"), out.get("sourceWholeFileTokens")),
    )


@server.tool(
    title="File outline",
    description=(
        "Capped structural skeleton (no docs; huge nested types collapsed). "
        "Pass docs=true or full=true to opt in. Prefer over reading a large "
        "file whole; then symbol for one body. Pass repo= when unsure."
    ),
)
def outline(
    file_path: Annotated[
        str,
        Field(description="Repo-relative or absolute source path."),
    ],
    repo: RepoPath = None,
    docs: Annotated[
        bool,
        Field(description="Include doc comments."),
    ] = False,
    full: Annotated[
        bool,
        Field(description="Full member lists, docs, no size cap."),
    ] = False,
    refresh: Annotated[
        bool,
        Field(
            description=(
                "Re-render even when unchanged since earlier this session."
            )
        ),
    ] = False,
) -> dict[str, Any]:
    args = ["outline", file_path]
    if full:
        args.append("--full")
    elif docs:
        args.append("--docs")
    payload = run_cckit(args, repo=repo)
    out = strip_internal_keys(payload)
    text, stats = split_trailing_stats(out.get("text", ""), _OUTLINE_STATS_LINE)
    if stats is not None:
        out["text"] = text
    try:
        out = apply_outline_dedup(out, str(resolve_repo(repo)), file_path, refresh=refresh)
    except ValueError:
        pass
    if stats is not None:
        attach_savings(
            out,
            savings_footer(stats.get("deliveredTokens"), stats.get("sourceWholeFileTokens")),
        )
    return out


@server.tool(
    title="Repository map",
    description=MAP_DESCRIPTION,
)
def map(
    repo: RepoPath = None,
    budget: Annotated[
        int,
        Field(description="Max tokens (default 4096).", ge=256, le=100000),
    ] = 4096,
    focus: Annotated[
        str | None,
        Field(description="Optional path/module focus."),
    ] = None,
    changed: Annotated[
        bool,
        Field(description="Focus on files changed vs git base."),
    ] = False,
    base: Annotated[
        str,
        Field(description="Git base ref when changed=True (default main)."),
    ] = "main",
) -> dict[str, Any]:
    args = ["map", "--budget", str(budget), "--base", base]
    if focus:
        args.extend(["--focus", focus])
    if changed:
        args.append("--changed")
    out = strip_internal_keys(run_cckit(args, repo=repo, timeout=180))
    match = _REPO_MAP_TOKENS.search(out.get("text", ""))
    if match:
        attach_savings(out, f"~{format_tokens_short(int(match.group(1)))} tokens delivered")
    return out


@server.tool(
    title="Index repository",
    description=(
        "Build or refresh the local code index (symbols + semantic store) and "
        "stamp the current git commit/branch. Usually unnecessary — MCP "
        "auto-refreshes on HEAD drift and dirty indexable files, and indexes "
        "once on locator miss (CCKIT_REFRESH=auto). Auto-compacts leaked Wax "
        "vectors without a full rebuild. Call on no_index or when "
        "auto-refresh is disabled. Pass repo= when unsure."
    ),
)
def index(
    repo: RepoPath = None,
    clean: Annotated[
        bool,
        Field(description="Full rebuild; ignore incremental cache."),
    ] = False,
    include: Annotated[
        list[str] | None,
        Field(description="Optional path/glob include patterns."),
    ] = None,
    exclude: Annotated[
        list[str] | None,
        Field(description="Optional path/glob exclude patterns."),
    ] = None,
    stats: Annotated[
        bool,
        Field(description="Include index statistics."),
    ] = False,
    include_build_scripts: Annotated[
        bool,
        Field(description="Also index Gradle/build scripts."),
    ] = False,
    include_generated: Annotated[
        bool,
        Field(description="Also index generated sources."),
    ] = False,
    compact: Annotated[
        bool,
        Field(description="Drop leaked Wax vectors vs SQLite; no re-embed."),
    ] = False,
) -> dict[str, Any]:
    args = ["index", "."]
    if clean:
        args.append("--clean")
    if compact:
        args.append("--compact")
    if stats:
        args.append("--stats")
    if include_build_scripts:
        args.append("--include-build-scripts")
    if include_generated:
        args.append("--include-generated")
    append_repeated_option(args, "--include", include)
    append_repeated_option(args, "--exclude", exclude)
    return strip_internal_keys(run_cckit(args, repo=repo, timeout=300))


if __name__ == "__main__":
    start_self_reload_watcher()
    server.run()
