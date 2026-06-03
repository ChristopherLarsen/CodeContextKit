#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["mcp>=1.0"]
# ///

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP


CCKIT = os.environ.get("CCKIT_BIN", "cckit")
DEFAULT_REPO = os.environ.get("CCKIT_REPO")
DEFAULT_TIMEOUT = int(os.environ.get("CCKIT_TIMEOUT", "120"))

server = FastMCP("cckit")


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


def run_cckit(
    args: list[str],
    repo: str | None = None,
    timeout: int = DEFAULT_TIMEOUT,
    parse_json: bool = False,
) -> dict[str, Any]:
    try:
        cwd = resolve_repo(repo)
    except ValueError as error:
        return {"error": "bad_repo", "message": str(error)}

    try:
        proc = subprocess.run(
            [CCKIT, *args],
            cwd=str(cwd),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return {
            "error": "cckit_not_found",
            "hint": f"Set CCKIT_BIN to the cckit executable. Current value: {CCKIT}",
        }
    except subprocess.TimeoutExpired:
        return {"error": "timeout", "after_seconds": timeout, "command": [CCKIT, *args]}

    stdout = proc.stdout.strip()
    stderr = proc.stderr.strip()

    if proc.returncode != 0:
        return {
            "error": "cckit_failed",
            "returncode": proc.returncode,
            "command": [CCKIT, *args],
            "stdout": stdout,
            "stderr": stderr,
        }

    if stdout.startswith("Error: Index not found"):
        return {
            "error": "no_index",
            "message": stdout,
            "hint": "Run the index tool for this repo, then retry.",
        }

    if parse_json:
        try:
            return {"data": json.loads(stdout), "stderr": stderr}
        except json.JSONDecodeError:
            return {"error": "bad_json", "stdout": stdout[:2000], "stderr": stderr}

    return {"text": stdout, "stderr": stderr}


def append_repeated_option(args: list[str], option: str, values: list[str] | None) -> None:
    for value in values or []:
        if value:
            args.extend([option, value])


@server.tool()
def index(
    repo: str | None = None,
    clean: bool = False,
    include: list[str] | None = None,
    exclude: list[str] | None = None,
    stats: bool = False,
    include_build_scripts: bool = False,
    include_generated: bool = False,
) -> dict[str, Any]:
    """Build or refresh the cckit index for a repository."""
    args = ["index", "."]
    if clean:
        args.append("--clean")
    if stats:
        args.append("--stats")
    if include_build_scripts:
        args.append("--include-build-scripts")
    if include_generated:
        args.append("--include-generated")
    append_repeated_option(args, "--include", include)
    append_repeated_option(args, "--exclude", exclude)
    return run_cckit(args, repo=repo, timeout=300)


@server.tool()
def search(
    query: str,
    repo: str | None = None,
    regex: bool = False,
    strict: bool = False,
    limit: int = 10,
) -> dict[str, Any]:
    """Search indexed files, symbols, text, or semantic content."""
    args = ["search", query, "--json", "--limit", str(limit)]
    if regex:
        args.append("--regex")
    if strict:
        args.append("--strict")
    return run_cckit(args, repo=repo, parse_json=True)


@server.tool()
def symbol(name: str, repo: str | None = None) -> dict[str, Any]:
    """Fetch symbols by exact qualified name."""
    return run_cckit(["symbol", name, "--json"], repo=repo, parse_json=True)


@server.tool()
def outline(file_path: str, repo: str | None = None) -> dict[str, Any]:
    """Render a structural outline for a Swift, Kotlin, or generic source file."""
    return run_cckit(["outline", file_path], repo=repo)


@server.tool()
def map(
    repo: str | None = None,
    budget: int = 4096,
    focus: str | None = None,
    changed: bool = False,
    base: str = "main",
) -> dict[str, Any]:
    """Build a token-budgeted repository map."""
    args = ["map", "--budget", str(budget), "--base", base]
    if focus:
        args.extend(["--focus", focus])
    if changed:
        args.append("--changed")
    return run_cckit(args, repo=repo, timeout=180)


@server.tool()
def pack(
    task: str,
    repo: str | None = None,
    budget: int = 12000,
    format: str = "markdown",
    failure: str | None = None,
) -> dict[str, Any]:
    """Generate a surgical context packet for an AI coding task."""
    args = ["pack", "--task", task, "--budget", str(budget), "--format", format]
    if failure:
        args.extend(["--failure", failure])
    return run_cckit(args, repo=repo, timeout=180)


@server.tool()
def estimate(
    input: str,
    repo: str | None = None,
    text: bool = False,
    model: str | None = None,
) -> dict[str, Any]:
    """Estimate token count for a file path or raw text."""
    args = ["estimate", input]
    if text:
        args.append("--text")
    if model:
        args.extend(["--model", model])
    return run_cckit(args, repo=repo)


@server.tool()
def summarize(repo: str | None = None, memory: bool = True) -> dict[str, Any]:
    """Generate a deterministic project summary suitable for agent memory."""
    args = ["summarize"]
    if memory:
        args.append("--memory")
    return run_cckit(args, repo=repo, timeout=120)


@server.tool()
def explain(
    topic: str,
    repo: str | None = None,
    context: str | None = None,
) -> dict[str, Any]:
    """Explain cckit index, pack, or symbol behavior."""
    args = ["explain", topic]
    if context:
        args.append(context)
    return run_cckit(args, repo=repo)


if __name__ == "__main__":
    server.run()
