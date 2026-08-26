#!/usr/bin/env python3
"""Token-savings benchmarks for cckit improvements 1-6.

Measures CURRENT build behavior on a synthetic fixture repo. Run before and
after each change; diff the JSON to confirm effect.

Usage:
    cd mcp && uv run --with 'mcp<2' python ../Benchmarks/token_savings_bench.py [out.json]
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "mcp"))

os.environ.setdefault("CCKIT_SHIM_RELOAD", "off")
if not os.environ.get("CCKIT_BIN"):
    debug = REPO_ROOT / ".build/debug/cckit"
    release = REPO_ROOT / ".build/release/cckit"
    os.environ["CCKIT_BIN"] = str(debug if debug.exists() else release)
os.environ.setdefault("CCKIT_REFRESH", "never")

import cckit_mcp as m  # noqa: E402

CCKIT = os.environ["CCKIT_BIN"]


def est(text: str) -> int:
    """~chars/4, mirrors TokenEstimator's granularity."""
    return max(1, len(text or "") // 4)


def cckit(args: list[str], cwd: Path, timeout: int = 180) -> subprocess.CompletedProcess:
    return subprocess.run(
        [CCKIT, *args], cwd=str(cwd), capture_output=True, text=True, timeout=timeout
    )


AUTH_MANAGER = '''import Foundation

/// Manages auth token lifecycle.
final class AuthManager {
    private let store = TokenStore()
    private var session: Session?

    struct Session { var token: String; var expiresAt: Date }

    /// Refreshes the auth token after expiry.
    func refreshToken() throws -> String {
        guard let session, session.expiresAt > Date() else {
            let token = try store.rotate()
            session = Session(token: token, expiresAt: Date().addingTimeInterval(3600))
            return token
        }
        return session.token
    }

    /// Unique probe symbol for inline-body benchmarks.
    func rotateRefreshTokenUnique() throws -> String {
        let token = try store.rotate()
        session = Session(token: token, expiresAt: Date().addingTimeInterval(600))
        return token
    }

    func validate(_ token: String) -> Bool {
        !token.isEmpty && token.count > 8
    }
}
'''

TOKEN_STORE = '''import Foundation

/// Persists rotating tokens.
struct TokenStore {
    var backing: [String] = []

    mutating func rotate() throws -> String {
        let token = UUID().uuidString
        backing.append(token)
        return token
    }
}
'''

API_CLIENT = '''import Foundation

/// Minimal API client used by fixtures.
final class APIClient {
    let manager = AuthManager()
    let big = BigRetryService()

    func fetch(url: URL) throws -> Data {
        let token = try manager.refreshToken()
        var request = URLRequest(url: url)
        request.setValue("Bearer \\(token)", forHTTPHeaderField: "Authorization")
        let (_, data) = try URLSession.shared.synchronousData(with: request)
        return data
    }

    func authorizedValue() throws -> String {
        let token = try manager.refreshToken()
        return "Bearer \\(token)"
    }

    func resilientFetch(url: URL) throws -> Data {
        let payload = try big.retryWithBackoff(maxAttempts: 3) { attempt in
            try self.fetchOnce(url: url, attempt: attempt)
        }
        return payload
    }

    private func fetchOnce(url: URL, attempt: Int) throws -> Data {
        try fetch(url: url)
    }
}

extension URLSession {
    func synchronousData(with request: URLRequest) throws -> (URLResponse, Data) {
        (_, Data())
    }
}
'''

# >100 lines so auto pack delivers surgical slices (not whole files) whose
# bodies participate in gather-packet dedup.
BIG_SERVICE_LINES: list[str] = [
    "import Foundation",
    "",
    "/// Deliberately long service so packs use symbol slices.",
    "final class BigRetryService {",
    "    var log: [String] = []",
    "",
]
for index in range(1, 26):
    BIG_SERVICE_LINES += [
        f"    /// Step {index} of the pipeline.",
        f"    func step{index}(_ value: Int) -> Int {{",
        f"        log.append(\"step{index}\\(value)\")",
        f"        return value + {index}",
        "    }",
        "",
    ]
BIG_SERVICE_LINES += [
    "    func retryWithBackoff(maxAttempts: Int, _ body: (Int) throws -> Data) rethrows -> Data {",
    "        for attempt in 0..<maxAttempts {",
    "            log.append(\"attempt \\(attempt)\")",
    "            do {",
    "                return try body(attempt)",
    "            } catch {",
    "                log.append(\"backoff \\(attempt)\")",
    "            }",
    "        }",
    "        return Data()",
    "    }",
    "}",
    "",
]
BIG_SERVICE = "\n".join(BIG_SERVICE_LINES)


def make_fixture(root: Path) -> Path:
    src = root / "Sources" / "Auth"
    net = root / "Sources" / "Net"
    ignored = root / "ignored"
    for directory in (src, net, ignored):
        directory.mkdir(parents=True)
    (src / "AuthManager.swift").write_text(AUTH_MANAGER, encoding="utf-8")
    (src / "TokenStore.swift").write_text(TOKEN_STORE, encoding="utf-8")
    (net / "APIClient.swift").write_text(API_CLIENT, encoding="utf-8")
    (net / "BigRetryService.swift").write_text(BIG_SERVICE, encoding="utf-8")
    (ignored / "generated.swift").write_text(
        "let needleToken = \"ignoreme\"\n", encoding="utf-8"
    )
    (root / ".gitignore").write_text("ignored/\n", encoding="utf-8")
    # Failure log: 9 short errors + one gigantic minified line.
    huge = "error: minified " + "x" * 200_000
    lines = [f"error: build step {i} failed" for i in range(9)] + [huge]
    (root / "build_log.txt").write_text("\n".join(lines), encoding="utf-8")

    def git(*args: str) -> None:
        subprocess.run(["git", *args], cwd=str(root), check=True, capture_output=True)

    git("init")
    git("config", "user.email", "bench@example.com")
    git("config", "user.name", "Bench")
    git("add", "-A")
    git("commit", "-m", "fixture")
    return root


def section_b1(repo: Path) -> dict:
    """Dedup ledger v2: gather repeat, outline repeat, restart retention."""
    m._delivery_ledger.clear()
    g1 = m.gather_code_context(
        task="fix retryWithBackoff retry", repo=str(repo), budget=4000
    )
    t1 = est(g1.get("text", ""))
    g2 = m.gather_code_context(
        task="fix retryWithBackoff retry", repo=str(repo), budget=4000
    )
    t2 = est(g2.get("text", ""))
    gather_stubbed = bool(g2.get("deduplicated") or g2.get("dedupSavedTokens"))

    o1 = m.outline("Sources/Auth/AuthManager.swift", repo=str(repo))
    o2 = m.outline("Sources/Auth/AuthManager.swift", repo=str(repo))
    outline_stubbed = bool(o2.get("deduplicated"))
    ot1, ot2 = est(o1.get("text", "")), est(o2.get("text", ""))

    # Restart retention: wipe in-memory state, reload persisted ledger.
    reload_fn = getattr(m, "load_delivery_ledger", None)
    retained = None
    if callable(reload_fn):
        s1 = m.symbol(name="AuthManager.rotateRefreshTokenUnique", repo=str(repo))
        first_full = not s1.get("deduplicated")
        m._delivery_ledger.clear()
        reload_fn(str(repo))
        s2 = m.symbol(name="AuthManager.rotateRefreshTokenUnique", repo=str(repo))
        retained = bool(s2.get("deduplicated"))
    return {
        "gather_first_tokens": t1,
        "gather_second_tokens": t2,
        "gather_second_stubbed": gather_stubbed,
        "outline_first_tokens": ot1,
        "outline_second_tokens": ot2,
        "outline_second_stubbed": outline_stubbed,
        "symbol_restart_retention_stubbed": retained,
    }


def section_b2(repo: Path) -> dict:
    """Singleton find_symbol should answer without a follow-up symbol() call."""
    m._delivery_ledger.clear()
    fs = m.find_symbol(name="rotateRefreshTokenUnique", repo=str(repo))
    results = fs.get("results", "")
    fs_tokens = est(json.dumps(fs, default=str))
    has_inline = isinstance(fs.get("inlinedBody"), dict)
    # Agent flow cost today: find_symbol + follow-up symbol().
    sym = m.symbol(name="rotateRefreshTokenUnique", repo=str(repo))
    sym_tokens = est(json.dumps(sym, default=str))
    return {
        "find_symbol_count": fs.get("count"),
        "total_count": fs.get("totalCount"),
        "body_inlined": has_inline,
        "find_symbol_tokens": fs_tokens,
        "followup_symbol_tokens": sym_tokens,
        "flow_tokens_with_inline": fs_tokens + (0 if has_inline else sym_tokens),
        "flow_tokens_without_inline": fs_tokens + sym_tokens,
    }


def section_b3(repo: Path) -> dict:
    """Prose-only task: soft-miss tag + candidates vs blind re-gather."""
    task = "improve resilience of network layer retries"
    p1 = m.gather_code_context(task=task, repo=str(repo), budget=4000)
    tagged = p1.get("semanticGuessOnly") is True
    cand = p1.get("candidatesBlock") or ""
    # Policy A (no tag): agent re-gathers with reworded prose.
    p2 = m.gather_code_context(task="make network retries stronger and safer", repo=str(repo), budget=4000)
    policy_a_cost = est(p1.get("text", "")) + est(p2.get("text", ""))
    # Policy B (tagged): agent goes straight to a candidate symbol.
    target = "AuthManager.refreshToken"
    sym = m.symbol(name=target, repo=str(repo))
    policy_b_cost = est(p1.get("text", "")) + est(json.dumps(sym, default=str))
    return {
        "semantic_guess_only_tagged": tagged,
        "candidates_attached_chars": len(cand),
        "blind_regather_policy_tokens": policy_a_cost,
        "tag_then_symbol_policy_tokens": policy_b_cost,
    }


def section_b4(repo: Path) -> dict:
    """Semantic hits should carry actionable line ranges."""
    def probe(root: Path) -> list[dict]:
        out = m.run_cckit(
            ["search", "refresh token retry", "--vector", "--json", "--limit", "5"],
            repo=str(root),
            parse_json=True,
            skip_auto_refresh=True,
        )
        return out.get("semanticMatches") or []

    matches = probe(repo)
    corpus = str(repo)
    if not matches:  # tiny fixtures may score zero; use the cckit repo itself
        matches = probe(REPO_ROOT)
        corpus = str(REPO_ROOT)
    enriched = [
        hit for hit in matches
        if isinstance(hit, dict) and hit.get("startLine")
    ]
    added = sum(est(json.dumps({k: hit[k] for k in ("startLine", "endLine")}))
                for hit in enriched)
    return {
        "corpus": corpus,
        "semantic_hits": len(matches),
        "hits_with_ranges": len(enriched),
        "enrichment_fraction": round(len(enriched) / len(matches), 2) if matches else 0.0,
        "added_tokens_total": added,
    }


REF_TARGETS = ["refreshToken", "validate", "rotate"]


def section_b5(repo: Path) -> dict:
    """Batch find_references vs N individual calls."""
    m._delivery_ledger.clear()
    individual = []
    for name in REF_TARGETS:
        payload = m.run_cckit(
            ["find-references", name, "--json"], repo=str(repo), skip_auto_refresh=True,
            parse_json=True,
        )
        individual.append(est(json.dumps(payload, default=str)))
    batch = m.run_cckit(
        ["find-references", *REF_TARGETS, "--json"],
        repo=str(repo), skip_auto_refresh=True, parse_json=True,
    )
    batch_ok = "results" in batch or "batches" in batch or batch.get("count")
    return {
        "targets": REF_TARGETS,
        "individual_calls": len(REF_TARGETS),
        "individual_tokens_sum": sum(individual),
        "batch_tokens": est(json.dumps(batch, default=str)),
        "batch_supported": bool(batch_ok) and "error" not in batch,
    }


def section_b6(repo: Path) -> dict:
    """Hygiene: failure-log line cap, gitignore-aware fallback scan."""
    pack = m.run_cckit(
        ["pack", "--task", "fix refreshToken retry", "--budget", "8000",
         "--failure", "build_log.txt"],
        repo=str(repo), timeout=240,
    )
    packet_tokens = est(pack.get("text", ""))
    leaked_huge_line = "x" * 10_000 in pack.get("text", "")

    pattern = __import__("re").compile("needleToken", __import__("re").IGNORECASE)
    got = m._python_text_search(repo, pattern, stop_after=100)
    paths = sorted({p for p, _, _ in got})
    return {
        "failure_packet_tokens": packet_tokens,
        "huge_line_leaked_into_packet": leaked_huge_line,
        "fallback_scan_paths": paths,
        "fallback_scan_respects_gitignore": paths == [],
        "fallback_matches_in_tracked_only": all(not p.startswith("ignored/") for p in paths),
    }


def main() -> None:
    only = sys.argv[2] if len(sys.argv) > 2 else None
    results: dict = {"cckit": CCKIT}
    with tempfile.TemporaryDirectory(prefix="cckit-bench-") as tmp:
        repo = make_fixture(Path(tmp) / "BenchFix")
        started = time.time()
        proc = cckit(["index", ".", "--stats"], repo)
        results["index_seconds"] = round(time.time() - started, 1)
        if proc.returncode != 0:
            results["index_error"] = proc.stderr[-500:]
        sections = {
            "B1_dedup": section_b1,
            "B2_inline_singleton": section_b2,
            "B3_prose_soft_miss": section_b3,
            "B4_semantic_ranges": section_b4,
            "B5_batch_refs": section_b5,
            "B6_hygiene": section_b6,
        }
        for name, fn in sections.items():
            if only and only not in name:
                continue
            try:
                results[name] = fn(repo)
            except Exception as error:  # noqa: BLE001
                results[name] = {"error": repr(error)}
    text = json.dumps(results, indent=2, default=str)
    if len(sys.argv) > 1 and sys.argv[1] != "-":
        Path(sys.argv[1]).write_text(text, encoding="utf-8")
        print(f"wrote {sys.argv[1]}")
    print(text)


if __name__ == "__main__":
    main()
