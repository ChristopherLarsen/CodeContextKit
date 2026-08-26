#!/usr/bin/env python3
"""Unit tests for MCP miss-retry, dirty-tree refresh, and locator shaping."""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cckit_mcp as mcp  # noqa: E402
from cckit_mcp import (  # noqa: E402
    FIND_SYMBOL_DESCRIPTION,
    GATHER_DESCRIPTION,
    attach_miss_response,
    find_references,
    find_symbol,
    find_symbol_is_miss,
    gather_code_context,
    gather_packet_is_miss,
    hide_small_locator_ranges,
    is_identifier_like,
    is_symbol_query,
    miss_footer,
    rank_dirty_for_outline,
    run_cckit_with_miss_retry,
    savings_footer,
    split_trailing_stats,
    task_identifiers,
    working_tree_needs_index,
)


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=str(repo),
        check=True,
        capture_output=True,
    )


def _seed_repo(root: Path) -> Path:
    _git(root, "init")
    _git(root, "config", "user.email", "test@example.com")
    _git(root, "config", "user.name", "Test")
    swift = root / "Foo.swift"
    swift.write_text("struct Foo {}\n", encoding="utf-8")
    _git(root, "add", "Foo.swift")
    _git(root, "commit", "-m", "init")
    sha = hashlib.sha256(swift.read_bytes()).hexdigest()
    cckit = root / ".cckit"
    cckit.mkdir()
    conn = sqlite3.connect(cckit / "index.sqlite")
    conn.execute(
        """CREATE TABLE fileRecord (
            id INTEGER PRIMARY KEY,
            path TEXT NOT NULL UNIQUE,
            language TEXT NOT NULL,
            sha256 TEXT NOT NULL,
            sizeBytes INTEGER NOT NULL,
            modifiedAt DATETIME,
            indexedAt DATETIME NOT NULL
        )"""
    )
    conn.execute(
        "INSERT INTO fileRecord (path, language, sha256, sizeBytes, indexedAt) "
        "VALUES (?, ?, ?, ?, ?)",
        ("Foo.swift", "swift", sha, swift.stat().st_size, "2020-01-01"),
    )
    conn.commit()
    conn.close()
    return swift


class MissFooterTests(unittest.TestCase):
    def test_miss_clean_tree_no_grep_invitation(self) -> None:
        hint = miss_footer(dirty_paths=[], after_refresh=False)
        self.assertEqual(hint, "No indexed hit. Try a shorter fragment.")
        self.assertNotIn("Call index", hint)
        self.assertNotIn("Grep", hint)

    def test_miss_with_candidates_points_at_them(self) -> None:
        hint = miss_footer(
            dirty_paths=[],
            after_refresh=False,
            has_candidates=True,
        )
        self.assertIn("Nearest indexed symbols below", hint)
        self.assertIn("symbol() one before Grep", hint)
        self.assertNotIn("Try a shorter fragment", hint)

    def test_miss_after_refresh_invites_outline(self) -> None:
        hint = miss_footer(
            dirty_paths=["a.swift", "b.swift"],
            after_refresh=True,
        )
        self.assertIn("No indexed hit after refresh.", hint)
        self.assertIn('outline("a.swift")', hint)
        self.assertIn("Dirty files: a.swift, b.swift", hint)
        self.assertIn("Grep only if outline lacks the name", hint)
        self.assertNotIn("Grep only these dirty paths", hint)
        self.assertNotIn("Call index", hint)

    def test_miss_with_attached_outlines(self) -> None:
        hint = miss_footer(
            dirty_paths=["a.swift"],
            after_refresh=True,
            outlined_paths=["a.swift"],
        )
        self.assertIn("Dirty-file outlines below", hint)
        self.assertIn("symbol() a name from them", hint)
        self.assertNotIn("Call index", hint)

    def test_gather_miss_invites_retry_not_locators_first(self) -> None:
        hint = miss_footer(
            dirty_paths=[],
            after_refresh=False,
            for_gather=True,
        )
        self.assertIn("Retry gather_code_context", hint)
        self.assertIn("symptom in prose", hint)
        self.assertIn("outline/symbol only if gather still has nothing", hint)
        self.assertNotIn("Try a shorter fragment", hint)

    def test_success_payloads_have_no_next_footer(self) -> None:
        hidden = hide_small_locator_ranges(
            "App/MarkupView.swift\n"
            "  function MarkupView.paste 40-55\n"
        )
        self.assertNotIn("Next:", hidden)
        self.assertNotIn("Grep", hidden)



class AgentCopyTests(unittest.TestCase):
    def test_instructions_steer_gather_for_task_shaped_work(self) -> None:
        text = mcp.SERVER_INSTRUCTIONS
        self.assertIn("gather_code_context(task)", text)
        self.assertIn("symptom", text)
        self.assertIn("failure log", text)
        self.assertIn("starting context", text)
        self.assertIn("even when names are visible", text)
        self.assertIn("find_symbol after gather", text)
        self.assertNotIn("Named-identifier gather", text)
        self.assertNotIn("find_symbol(name) then symbol", text)
        self.assertNotIn("find_symbol then symbol when you need a name", text)
        self.assertLess(
            text.find("gather_code_context(task)"),
            text.find("find_symbol after gather"),
        )

    def test_find_symbol_is_not_first_retrieval_for_a_task(self) -> None:
        self.assertIn("after gather", FIND_SYMBOL_DESCRIPTION)
        self.assertIn("not a packet", FIND_SYMBOL_DESCRIPTION)
        self.assertIn("not in a first find_symbol", GATHER_DESCRIPTION)
        self.assertNotIn("Exact name lookup", FIND_SYMBOL_DESCRIPTION)


class GatherHeuristicTests(unittest.TestCase):
    def test_task_identifiers_extract_camel_case(self) -> None:
        idents = task_identifiers(
            "Wire HTMLRenderPlan into DocumentSemanticConverger parse seam"
        )
        self.assertIn("HTMLRenderPlan", idents)
        self.assertIn("DocumentSemanticConverger", idents)
        self.assertNotIn("Wire", idents)

    def test_task_identifiers_skip_title_case_english(self) -> None:
        self.assertFalse(is_identifier_like("Fix"))
        self.assertFalse(is_identifier_like("Wire"))
        self.assertEqual(
            task_identifiers("Fix 401 retry after token refresh"),
            [],
        )
        self.assertIn(
            "gameStateLabel",
            task_identifiers("Fix gameStateLabel when renewGalacticCredentials fails"),
        )

    def test_gather_miss_when_packet_lacks_named_idents(self) -> None:
        task = "Finish HTMLRenderPlan and MarkupInputSeamTiming"
        packet = "## File: ParsedMarkdown.swift\nstruct ParsedMarkdown {}"
        self.assertTrue(gather_packet_is_miss(task, packet))

    def test_gather_not_miss_when_packet_contains_ident(self) -> None:
        task = "Finish HTMLRenderPlan and MarkupInputSeamTiming"
        packet = "## File\nstruct HTMLRenderPlan {}"
        self.assertFalse(gather_packet_is_miss(task, packet))

    def test_gather_not_miss_when_task_has_no_idents(self) -> None:
        self.assertFalse(
            gather_packet_is_miss("fix the parse seam", "anything")
        )

    def test_gather_not_miss_for_title_case_symptom(self) -> None:
        self.assertFalse(
            gather_packet_is_miss(
                "Fix 401 retry after token refresh",
                "# Context Packet\nAuthSession handles 401",
            )
        )


class SymbolQueryTests(unittest.TestCase):
    def test_accepts_leaf_and_qualified(self) -> None:
        self.assertTrue(is_symbol_query("zeroVisibleDelete"))
        self.assertTrue(is_symbol_query("AuthSession.refresh"))
        self.assertTrue(is_symbol_query("NodeKind"))

    def test_rejects_strings_and_fragments(self) -> None:
        self.assertFalse(is_symbol_query("nodeKind:"))
        self.assertFalse(is_symbol_query("renderer-owned chrome"))
        self.assertFalse(is_symbol_query("zero visible delete"))

    def test_find_references_rejects_non_symbol(self) -> None:
        out = find_references("renderer-owned chrome")
        self.assertEqual(out.get("error"), "not_a_symbol_name")
        self.assertIn("not a string", out.get("message", ""))


class HideSmallLocatorRangesTests(unittest.TestCase):
    def test_strips_small_keeps_huge(self) -> None:
        raw = (
            "App/MarkupView.swift\n"
            "  function MarkupView.paste 40-55\n"
            "  function MarkupView.shouldChangeTextIn 1200-4200\n"
        )
        hidden = hide_small_locator_ranges(raw)
        self.assertIn("function MarkupView.paste", hidden)
        self.assertNotIn("40-55", hidden)
        self.assertIn("MarkupView.shouldChangeTextIn 1200-4200", hidden)


class DirtyOutlineTests(unittest.TestCase):
    def test_rank_prefers_query_stem(self) -> None:
        ranked = rank_dirty_for_outline(
            ["CRPCommitPipeline.swift", "Foo.swift"],
            "Foo",
        )
        self.assertEqual(ranked[0], "Foo.swift")
        ranked = rank_dirty_for_outline(
            ["Foo.swift", "CRPCommitPipeline.swift"],
            "CRPCommitPipeline",
        )
        self.assertEqual(ranked[0], "CRPCommitPipeline.swift")
        self.assertLessEqual(len(ranked), 2)

    def test_attach_miss_replaces_gather_packet(self) -> None:
        filler = "# Context Packet\n" + ("unrelated " * 400)
        with mock.patch.object(
            mcp,
            "fetch_dirty_outlines",
            return_value=[("a.swift", "struct Foo [L1-L2]")],
        ), mock.patch.object(mcp, "semantic_candidates", return_value=[]):
            out = attach_miss_response(
                {"text": filler},
                dirty_paths=["a.swift"],
                after_refresh=True,
                repo=None,
                query="Foo",
                replace_body=True,
            )
        self.assertNotIn("unrelated", out["text"])
        self.assertIn("struct Foo", out["text"])
        self.assertIn("Dirty-file outlines below", out["text"])
        self.assertNotIn("results", out)
        self.assertNotIn("Next:", out["text"])

    def test_attach_miss_without_outlines_invites_outline(self) -> None:
        with mock.patch.object(mcp, "fetch_dirty_outlines", return_value=[]), \
             mock.patch.object(mcp, "semantic_candidates", return_value=[]):
            out = attach_miss_response(
                {"results": "no symbols matching 'Nope'"},
                dirty_paths=["a.swift"],
                after_refresh=True,
                repo=None,
                query="Nope",
                replace_body=False,
            )
        self.assertIn('outline("a.swift")', out["results"])
        self.assertNotIn("no symbols matching", out["results"])
        self.assertNotIn("Next:", out["results"])


class SemanticCandidatesTests(unittest.TestCase):
    def test_format_candidates_block_lists_names(self) -> None:
        block = mcp.format_candidates_block(
            [("Auth.refreshToken", "Sources/Auth.swift"), ("Bare", "")]
        )
        self.assertIn("- Auth.refreshToken — Sources/Auth.swift", block)
        self.assertIn("- Bare\n", block)
        self.assertIn("symbol() one of these", block)

    def test_format_candidates_block_empty(self) -> None:
        self.assertEqual(mcp.format_candidates_block([]), "")

    def test_semantic_candidates_parses_vector_payload(self) -> None:
        fake = {
            "semanticMatches": [
                {"symbol": "A.b", "file": "a.swift", "score": 0.9},
                {"symbol": "", "file": "skipped.swift"},
            ]
        }
        with mock.patch.object(mcp, "run_cckit", return_value=fake) as run_mock:
            got = mcp.semantic_candidates(None, "auth refresh")
        self.assertEqual(got, [("A.b", "a.swift")])
        args = run_mock.call_args[0][0]
        self.assertIn("--vector", args)
        self.assertEqual(args[0], "search")
        self.assertEqual(args[1], "auth refresh")

    def test_semantic_candidates_best_effort(self) -> None:
        with mock.patch.object(
            mcp, "run_cckit", return_value={"error": "cckit_failed"}
        ):
            self.assertEqual(mcp.semantic_candidates(None, "semantic:Foo"), [])
        self.assertEqual(mcp.semantic_candidates(None, "   "), [])

    def test_attach_miss_appends_candidate_block(self) -> None:
        with mock.patch.object(mcp, "fetch_dirty_outlines", return_value=[]), \
             mock.patch.object(
                 mcp,
                 "semantic_candidates",
                 return_value=[("X.y", "x.swift")],
             ):
            out = attach_miss_response(
                {"results": "no symbols matching 'Q'"},
                dirty_paths=[],
                after_refresh=False,
                repo=None,
                query="Q",
                replace_body=False,
            )
        self.assertIn("Nearest indexed symbols", out["results"])
        self.assertIn("- X.y — x.swift", out["results"])
        self.assertIn("symbol() one before Grep", out["results"])


class OutlineGatingTests(unittest.TestCase):
    def test_rank_keeps_only_query_related_dirty_files(self) -> None:
        ranked = mcp.rank_dirty_for_outline(
            ["Alpha.swift", "AuthZeta.swift", "zeta_parts/Beta.swift"],
            "zeta",
        )
        self.assertEqual(ranked, ["AuthZeta.swift", "zeta_parts/Beta.swift"])

    def test_rank_drops_all_when_nothing_related(self) -> None:
        self.assertEqual(mcp.rank_dirty_for_outline(["Alpha.swift"], "zzz"), [])

    def test_rank_empty_without_query(self) -> None:
        self.assertEqual(mcp.rank_dirty_for_outline(["Alpha.swift"], None), [])
        self.assertEqual(mcp.rank_dirty_for_outline([], "foo"), [])

    def test_exact_stem_beats_partial_stem_and_path(self) -> None:
        ranked = mcp.rank_dirty_for_outline(
            ["parts/zeta_extra.swift", "zeta_path/Beta.swift", "Zeta.swift"],
            "zeta",
        )
        self.assertEqual(ranked[0], "Zeta.swift")
        self.assertIn("parts/zeta_extra.swift", ranked)

    def test_fetch_dirty_outlines_skips_unrelated(self) -> None:
        with mock.patch.object(mcp, "run_cckit") as run_mock:
            got = mcp.fetch_dirty_outlines(None, ["Alpha.swift"], "zzz")
        self.assertEqual(got, [])
        run_mock.assert_not_called()


class InlineSingletonTests(unittest.TestCase):
    @staticmethod
    def _results_block(span: str = "1-12") -> str:
        return (
            "Sources/Auth.swift\n"
            f"  function AuthManager.rotate  {span}\n"
        )

    def test_singleton_small_hit_gets_body(self) -> None:
        payload = {
            "count": 1,
            "totalCount": 1,
            "results": self._results_block(),
        }
        fake_symbol = {
            "symbols": [
                {"qualifiedName": "AuthManager.rotate", "kind": "function",
                 "filePath": "Sources/Auth.swift", "startLine": 1,
                 "endLine": 12, "body": "func rotate() {\n}\n"}
            ]
        }

        def fake_run(args, **kwargs):
            assert args[0] == "symbol"
            return dict(fake_symbol)

        with mock.patch.object(mcp, "run_cckit", side_effect=fake_run), \
             mock.patch.object(mcp, "_delivery_ledger", mcp.OrderedDict()):
            out = mcp.inline_singleton_body(payload, "/repo")
        self.assertIsInstance(out.get("inlinedBody"), dict)
        self.assertEqual(out["inlinedBody"]["qualifiedName"], "AuthManager.rotate")
        self.assertIn("inlinedBody", out["results"])

    def test_multi_hit_and_huge_span_skip_inlining(self) -> None:
        multi = {"count": 3, "totalCount": 3, "results": self._results_block()}
        out_multi = mcp.inline_singleton_body(dict(multi), "/repo")
        self.assertNotIn("inlinedBody", out_multi)
        huge = {"count": 1, "totalCount": 1,
                "results": self._results_block("1-400")}
        with mock.patch.object(mcp, "run_cckit") as run_mock:
            out = mcp.inline_singleton_body(huge, "/repo")
        run_mock.assert_not_called()
        self.assertNotIn("inlinedBody", out)


class SemanticGuessHintTests(unittest.TestCase):
    def test_prose_task_gets_tag_and_candidates(self) -> None:
        payload = {"text": "# Context Packet\n\nSome guessed content.\n"}
        with mock.patch.object(
            mcp,
            "semantic_candidates",
            return_value=[("Auth.refreshToken", "Sources/Auth.swift")],
        ) as cand_mock:
            out = mcp.attach_semantic_guess_hint(payload, "/repo", "make retries resilient")
        self.assertTrue(out["semanticGuessOnly"])
        self.assertIn("semantic guesses", out["text"])
        self.assertIn("- Auth.refreshToken — Sources/Auth.swift", out["text"])
        self.assertIn("Auth.refreshToken", out["candidatesBlock"])
        cand_mock.assert_called_once()

    def test_identifier_task_untouched(self) -> None:
        payload = {"text": "# Context Packet\nbody\n"}
        with mock.patch.object(mcp, "semantic_candidates") as cand_mock:
            out = mcp.attach_semantic_guess_hint(
                payload, "/repo", "fix refreshToken retry"
            )
        self.assertNotIn("semanticGuessOnly", out)
        self.assertEqual(out["text"], payload["text"])
        cand_mock.assert_not_called()


class DeliveryDedupTests(unittest.TestCase):
    def setUp(self) -> None:
        mcp._delivery_ledger.clear()
        mcp._dedup_saved_total = 0

    def tearDown(self) -> None:
        mcp._delivery_ledger.clear()

    @staticmethod
    def _payload(body: str, name: str = "A.b") -> dict:
        return {
            "count": 1,
            "symbols": [
                {
                    "qualifiedName": name,
                    "kind": "function",
                    "filePath": "a.swift",
                    "startLine": 1,
                    "endLine": 2,
                    "body": body,
                }
            ],
        }

    def test_second_identical_delivery_is_stubbed(self) -> None:
        first = mcp.apply_delivery_dedup(self._payload("let x = 1"), "/repo")
        self.assertNotIn("deduplicated", first)
        second = mcp.apply_delivery_dedup(self._payload("let x = 1"), "/repo")
        item = second["symbols"][0]
        self.assertTrue(item["deduplicated"])
        self.assertIn("unchanged since earlier this session", item["body"])
        self.assertIn("refresh=true", item["body"])
        self.assertGreater(second["dedupSavedTokens"], 0)

    def test_changed_body_re_delivers_in_full(self) -> None:
        mcp.apply_delivery_dedup(self._payload("old"), "/repo")
        out = mcp.apply_delivery_dedup(self._payload("new"), "/repo")
        self.assertNotIn("deduplicated", out)
        self.assertEqual(out["symbols"][0]["body"], "new")

    def test_refresh_bypasses_stub_but_records_fingerprint(self) -> None:
        mcp.apply_delivery_dedup(self._payload("same"), "/repo")
        refreshed = mcp.apply_delivery_dedup(
            self._payload("same"), "/repo", refresh=True
        )
        self.assertNotIn("deduplicated", refreshed)
        again = mcp.apply_delivery_dedup(self._payload("same"), "/repo")
        self.assertTrue(again["symbols"][0]["deduplicated"])

    def test_env_opt_out_disables_stubbing(self) -> None:
        with mock.patch.dict(os.environ, {"CCKIT_DEDUP": "off"}):
            mcp.apply_delivery_dedup(self._payload("x"), "/repo")
            out = mcp.apply_delivery_dedup(self._payload("x"), "/repo")
        self.assertNotIn("deduplicated", out)
        self.assertEqual(out["symbols"][0]["body"], "x")

    def test_ledger_cap_evicts_oldest(self) -> None:
        for index in range(mcp._DELIVERY_LEDGER_CAP + 10):
            mcp.apply_delivery_dedup(
                self._payload(f"body{index}", name=f"S{index}"), "/repo"
            )
        self.assertLessEqual(len(mcp._delivery_ledger), mcp._DELIVERY_LEDGER_CAP)

    def test_same_body_other_repo_not_stubbed(self) -> None:
        mcp.apply_delivery_dedup(self._payload("x"), "/repoA")
        out = mcp.apply_delivery_dedup(self._payload("x"), "/repoB")
        self.assertNotIn("deduplicated", out)

    def test_non_symbol_payload_untouched(self) -> None:
        payload = {"count": 0}
        self.assertIs(mcp.apply_delivery_dedup(payload, "/repo"), payload)

    def _packet(self, body: str) -> dict:
        return {
            "text": (
                "# Context Packet\n\n"
                "### Auth.refresh (SYMBOL · Sources/A.swift:10-40)\n"
                "```swift\n" + body + "\n```\n"
            )
        }

    def test_packet_dedup_stubs_repeat_body(self) -> None:
        big = "let x = 1\n" * 60
        first = mcp.apply_packet_dedup(self._packet(big), "/repo")
        self.assertNotIn("deduplicated", first)
        second = mcp.apply_packet_dedup(self._packet(big), "/repo")
        self.assertTrue(second.get("deduplicated"))
        self.assertIn("unchanged since earlier this session", second["text"])
        self.assertIn("### Auth.refresh", second["text"])
        self.assertGreater(second["dedupSavedTokens"], 0)

    def test_packet_dedup_skips_small_bodies(self) -> None:
        first = mcp.apply_packet_dedup(self._packet("tiny"), "/repo")
        second = mcp.apply_packet_dedup(self._packet("tiny"), "/repo")
        self.assertNotIn("deduplicated", first)
        self.assertNotIn("deduplicated", second)

    def test_outline_dedup_stubs_repeat(self) -> None:
        payload = {"text": "struct X\n" + "member line\n" * 60}
        first = mcp.apply_outline_dedup(dict(payload), "/repo", "X.swift")
        self.assertNotIn("deduplicated", first)
        second = mcp.apply_outline_dedup(dict(payload), "/repo", "X.swift")
        self.assertTrue(second.get("deduplicated"))
        self.assertIn("unchanged since earlier this session", second["text"])
        self.assertEqual(
            second["originalOutlineTokens"],
            max(1, len(payload["text"]) // 4),
        )

    def test_ledger_persists_and_reloads(self) -> None:
        import tempfile as _tf
        from pathlib import Path as _Path

        with _tf.TemporaryDirectory() as tmp:
            repo = str(_Path(tmp))
            mcp.apply_delivery_dedup(self._payload("persist-me"), repo)
            path = _Path(repo) / ".cckit" / "delivery_ledger.json"
            self.assertTrue(path.exists())
            mcp._delivery_ledger.clear()
            loaded = mcp.load_delivery_ledger(repo)
            self.assertEqual(loaded, 1)
            stubbed = mcp.apply_delivery_dedup(self._payload("persist-me"), repo)
            self.assertTrue(stubbed["symbols"][0]["deduplicated"])

    def test_dedup_savings_rows_written(self) -> None:
        import tempfile as _tf
        from pathlib import Path as _Path

        with _tf.TemporaryDirectory() as tmp:
            repo = str(_Path(tmp))
            mcp.record_dedup_saving(repo, "symbol", 120)
            mcp.record_dedup_saving(repo, "gather", 80)
            rows_file = _Path(repo) / ".cckit" / "dedup_savings.jsonl"
            rows = [json.loads(line) for line in rows_file.read_text().splitlines()]
            self.assertEqual([row["savedTokens"] for row in rows], [120, 80])


class SearchTextTests(unittest.TestCase):
    def test_collapse_ranges(self) -> None:
        self.assertEqual(mcp._collapse_ranges([1, 2, 3, 7, 9]), "1-3, 7, 9")
        self.assertEqual(mcp._collapse_ranges([5]), "5")
        self.assertEqual(mcp._collapse_ranges([]), "")
        self.assertEqual(mcp._collapse_ranges([4, 4, 5]), "4-5")

    def test_parse_rg_line_handles_colons_in_path(self) -> None:
        parsed = mcp._parse_rg_line("a:b.swift:12:let x = 1")
        self.assertEqual(parsed, ("a:b.swift", 12, "let x = 1"))
        self.assertIsNone(mcp._parse_rg_line("not an rg line"))

    def test_group_text_matches_groups_and_previews(self) -> None:
        block = mcp._group_text_matches(
            "refreshToken",
            [
                ("A.swift", 12, "func refreshToken() {"),
                ("A.swift", 30, "x = refreshToken()"),
                ("B.kt", 3, "val t = refreshToken"),
            ],
            total_matches=57,
            truncated=True,
        )
        self.assertIn("57 match(es) in 2 file(s) (truncated)", block)
        self.assertIn("A.swift: 12, 30", block)
        self.assertIn("B.kt: 3", block)
        self.assertIn("12: func refreshToken() {", block)

    def test_group_text_matches_empty(self) -> None:
        block = mcp._group_text_matches("zzz", [], total_matches=0, truncated=False)
        self.assertIn("No text matches", block)

    def test_rg_args_shape(self) -> None:
        args = mcp._rg_args(
            "tok",
            regex=False,
            case_sensitive=True,
            include="*.swift",
            root="/r",
        )
        self.assertIn("-F", args)
        self.assertNotIn("-i", args)
        self.assertEqual(args[-5:], ["-g", "*.swift", "-e", "tok", "/r"])

    def test_rg_args_regex_and_insensitive(self) -> None:
        args = mcp._rg_args(
            "t.k",
            regex=True,
            case_sensitive=False,
            include=None,
            root="/r",
        )
        self.assertNotIn("-F", args)
        self.assertIn("-i", args)
        self.assertEqual(args[-3:], ["-e", "t.k", "/r"])

    def test_python_fallback_skips_junk_dirs(self) -> None:
        import tempfile as _tf
        from pathlib import Path as _Path
        with _tf.TemporaryDirectory() as tmp:
            root = _Path(tmp)
            (root / "src").mkdir()
            (root / ".build").mkdir()
            (root / "src" / "a.swift").write_text(
                "let needle = 1\nlet other = 2\n", encoding="utf-8"
            )
            (root / ".build" / "gen.swift").write_text(
                "let needle = 3\n", encoding="utf-8"
            )
            compiled = re.compile("needle", re.IGNORECASE)
            got = mcp._python_text_search(root, compiled, stop_after=100)
        self.assertEqual([(path, line) for path, line, _ in got], [("src/a.swift", 1)])


class WorkingTreeNeedsIndexTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        self.swift = _seed_repo(self.repo)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_clean_tree_does_not_need_index(self) -> None:
        self.assertFalse(working_tree_needs_index(self.repo))

    def test_modified_swift_needs_index(self) -> None:
        self.swift.write_text("struct Foo { var x: Int }\n", encoding="utf-8")
        self.assertTrue(working_tree_needs_index(self.repo))

    def test_indexed_dirty_file_does_not_need_index(self) -> None:
        self.swift.write_text("struct Foo { var x: Int }\n", encoding="utf-8")
        sha = hashlib.sha256(self.swift.read_bytes()).hexdigest()
        conn = sqlite3.connect(self.repo / ".cckit" / "index.sqlite")
        conn.execute("UPDATE fileRecord SET sha256 = ? WHERE path = ?", (sha, "Foo.swift"))
        conn.commit()
        conn.close()
        self.assertFalse(working_tree_needs_index(self.repo))

    def test_new_untracked_swift_needs_index(self) -> None:
        (self.repo / "Bar.swift").write_text("struct Bar {}\n", encoding="utf-8")
        self.assertTrue(working_tree_needs_index(self.repo))

    def test_markdown_only_does_not_need_index(self) -> None:
        (self.repo / "NOTES.md").write_text("# notes\n", encoding="utf-8")
        self.assertFalse(working_tree_needs_index(self.repo))

    def test_deleted_indexed_swift_needs_index(self) -> None:
        self.swift.unlink()
        self.assertTrue(working_tree_needs_index(self.repo))

    def test_untracked_css_needs_index(self) -> None:
        (self.repo / "theme.css").write_text(":root { --link-color: #06c; }\n", encoding="utf-8")
        self.assertTrue(working_tree_needs_index(self.repo))

    def test_css_suffix_is_indexable(self) -> None:
        self.assertIn(".css", mcp.INDEXABLE_SUFFIXES)


class RefreshLockTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        _seed_repo(self.repo)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_maybe_refresh_skips_when_fresh_after_lock(self) -> None:
        run_calls: list[Path] = []
        checks = {"n": 0}

        def fake_current(repo: Path) -> bool:
            checks["n"] += 1
            return checks["n"] >= 2

        with (
            mock.patch.object(mcp, "_index_is_current", side_effect=fake_current),
            mock.patch.object(
                mcp,
                "_run_incremental_index",
                side_effect=lambda repo, freshness: run_calls.append(repo) or {"refreshed": True},
            ),
        ):
            out = mcp.maybe_refresh_index(self.repo, ["find-symbol", "Foo"])

        self.assertIsNone(out)
        self.assertEqual(run_calls, [])
        self.assertGreaterEqual(checks["n"], 2)

    def test_force_refresh_skips_when_another_session_already_indexed(self) -> None:
        run_calls: list[Path] = []
        with (
            mock.patch.object(mcp, "_index_is_current", return_value=True),
            mock.patch.object(
                mcp,
                "_run_incremental_index",
                side_effect=lambda repo, freshness: run_calls.append(repo) or {"refreshed": True},
            ),
        ):
            out = mcp.force_refresh_index(self.repo)

        self.assertTrue(out.get("skipped"))
        self.assertEqual(out.get("reason"), "already_fresh")
        self.assertEqual(run_calls, [])


class WaxCompactAutoTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        _seed_repo(self.repo)
        self.wax = self.repo / ".cckit" / "repo.wax"
        self.wax.write_bytes(b"x" * 1024)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    @staticmethod
    def _write_compact_stamp(repo: Path, wax_bytes: int | None = None) -> None:
        """Test fixture: simulate a CLI-written compact stamp."""
        wax = repo / ".cckit" / "repo.wax"
        size = wax_bytes if wax_bytes is not None else (wax.stat().st_size if wax.is_file() else 0)
        payload = {"waxBytes": max(0, int(size)), "deletedFrames": 0}
        stamp = repo / ".cckit" / mcp._COMPACT_STAMP
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(json.dumps(payload), encoding="utf-8")

    def test_needs_compact_when_stamp_missing(self) -> None:
        self.assertTrue(mcp.wax_needs_compact(self.repo))

    def test_skips_compact_when_stamp_matches_size(self) -> None:
        self._write_compact_stamp(self.repo)
        self.assertFalse(mcp.wax_needs_compact(self.repo))

    def test_needs_compact_after_wax_grows(self) -> None:
        self._write_compact_stamp(self.repo)
        self.wax.write_bytes(b"x" * (2 * 1024 * 1024))
        self.assertTrue(mcp.wax_needs_compact(self.repo))

    def test_maybe_refresh_compacts_when_index_is_current(self) -> None:
        compact_calls: list[Path] = []
        with (
            mock.patch.object(mcp, "_index_is_current", return_value=True),
            mock.patch.object(
                mcp,
                "_run_compact",
                side_effect=lambda repo: compact_calls.append(repo) or {"compacted": True},
            ),
            mock.patch.object(mcp, "_run_incremental_index") as index_mock,
        ):
            out = mcp.maybe_refresh_index(self.repo, ["find-symbol", "Foo"])

        self.assertEqual(compact_calls, [self.repo])
        self.assertTrue(out and out.get("compacted"))
        index_mock.assert_not_called()

    def test_maybe_refresh_indexes_instead_of_compact_when_stale(self) -> None:
        index_calls: list[Path] = []
        with (
            mock.patch.object(mcp, "_index_is_current", return_value=False),
            mock.patch.object(
                mcp,
                "_run_incremental_index",
                side_effect=lambda repo, freshness: index_calls.append(repo)
                or {"refreshed": True},
            ),
            mock.patch.object(mcp, "_run_compact") as compact_mock,
        ):
            out = mcp.maybe_refresh_index(self.repo, ["find-symbol", "Foo"])

        self.assertEqual(index_calls, [self.repo])
        self.assertTrue(out and out.get("refreshed"))
        compact_mock.assert_not_called()

    def test_maybe_refresh_skips_compact_when_stamp_current(self) -> None:
        self._write_compact_stamp(self.repo)
        with (
            mock.patch.object(mcp, "_index_is_current", return_value=True),
            mock.patch.object(mcp, "_run_compact") as compact_mock,
            mock.patch.object(mcp, "_run_incremental_index") as index_mock,
        ):
            out = mcp.maybe_refresh_index(self.repo, ["find-symbol", "Foo"])

        self.assertIsNone(out)
        compact_mock.assert_not_called()
        index_mock.assert_not_called()


class WaxStampUnificationTests(unittest.TestCase):
    """The CLI is the sole stamper; the shim only reads the WaxCompact line."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        _seed_repo(self.repo)
        (self.repo / ".cckit" / "repo.wax").write_bytes(b"x" * 1024)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _stamp_path(self) -> Path:
        return self.repo / ".cckit" / mcp._COMPACT_STAMP

    def _run_index_proc(
        self,
        *,
        returncode: int = 0,
        stdout: str = "",
    ) -> mock.MagicMock:
        proc = mock.Mock()
        proc.returncode = returncode
        proc.stdout = stdout
        proc.stderr = ""
        return proc

    def test_run_compact_never_stamps_even_without_shrink(self) -> None:
        stdout = (
            'WaxCompact {"scanned": 21668, "deleted": 0, "kept": 21668, '
            '"bytesBefore": 14789726662, "bytesAfter": 14789726662, '
            '"shrank": false, "stamped": false}'
        )
        with mock.patch.object(
            mcp.subprocess,
            "run",
            return_value=self._run_index_proc(stdout=stdout),
        ):
            out = mcp._run_compact(self.repo)

        self.assertTrue(out.get("compacted"))
        self.assertFalse(self._stamp_path().is_file())
        self.assertEqual(out["waxCompact"]["deleted"], 0)

    def test_run_compact_does_not_stamp_when_cli_withheld(self) -> None:
        stdout = (
            'WaxCompact {"scanned": 10, "deleted": 5, "kept": 5, '
            '"bytesBefore": 1000000, "bytesAfter": 1000000, '
            '"shrank": false, "stamped": false}'
        )
        with mock.patch.object(
            mcp.subprocess,
            "run",
            return_value=self._run_index_proc(stdout=stdout),
        ):
            mcp._run_compact(self.repo)

        self.assertFalse(self._stamp_path().is_file())

    def test_run_incremental_index_attaches_wax_compact_and_growth_warning(self) -> None:
        stdout = (
            'WaxCompact {"scanned": 21668, "deleted": 0, "kept": 21668, '
            '"bytesBefore": 1000000, "bytesAfter": 1170000000, '
            '"shrank": false, "stamped": false}'
        )
        with mock.patch.object(
            mcp.subprocess,
            "run",
            return_value=self._run_index_proc(stdout=stdout),
        ):
            out = mcp._run_incremental_index(self.repo, {"stale": False})

        self.assertTrue(out.get("refreshed"))
        self.assertEqual(out["waxCompact"]["bytesAfter"], 1170000000)
        warning = out.get("waxGrowthWarning")
        self.assertIsNotNone(warning)
        self.assertEqual(warning["grownBytes"], 1169000000)

    def test_run_incremental_index_quiet_on_small_growth(self) -> None:
        stdout = (
            'WaxCompact {"scanned": 21668, "deleted": 0, "kept": 21668, '
            '"bytesBefore": 1000000, "bytesAfter": 1010000, '
            '"shrank": false, "stamped": false}'
        )
        with mock.patch.object(
            mcp.subprocess,
            "run",
            return_value=self._run_index_proc(stdout=stdout),
        ):
            out = mcp._run_incremental_index(self.repo, {"stale": False})

        self.assertNotIn("waxGrowthWarning", out)
        self.assertIn("waxCompact", out)

    def test_growth_warning_thresholds(self) -> None:
        below = {"bytesBefore": 1000, "bytesAfter": 1100}
        ratio_breach = {"bytesBefore": 1_000_000_000, "bytesAfter": 1_600_000_000}
        absolute_breach = {"bytesBefore": 1_000_000, "bytesAfter": 1_000_000 + mcp._WAX_COMPACT_GROWTH_BYTES}
        shrink = {"bytesBefore": 2_000_000, "bytesAfter": 100}
        self.assertIsNone(mcp._wax_growth_warning(below))
        self.assertIsNotNone(mcp._wax_growth_warning(ratio_breach))
        self.assertIsNotNone(mcp._wax_growth_warning(absolute_breach))
        self.assertIsNone(mcp._wax_growth_warning(shrink))
        self.assertIsNone(mcp._wax_growth_warning(None))


class ShimSelfReloadTests(unittest.TestCase):
    """Long-lived shims execv themselves when cckit_mcp.py changes on disk."""

    def test_identity_reflects_stat(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / "probe.py"
            probe.write_text("x = 1\n", encoding="utf-8")
            first = mcp._shim_identity(probe)
            self.assertIsNotNone(first)
            # Rewrite with a different size so mtime_ns must move too.
            probe.write_text("x = 22\n", encoding="utf-8")
            second = mcp._shim_identity(probe)
            self.assertIsNotNone(second)
            self.assertNotEqual(first, second)

    def test_identity_none_for_missing_file(self) -> None:
        self.assertIsNone(mcp._shim_identity(Path("/nonexistent/probe.py")))

    def test_should_exec_reload_matrix(self) -> None:
        base = (1, 10, 100)
        changed = (1, 20, 200)
        other = (1, 30, 300)
        # Unchanged file never reloads.
        self.assertFalse(mcp._should_exec_reload(base, base, base))
        # Changed but not yet stable (pending is None or differs) waits.
        self.assertFalse(mcp._should_exec_reload(base, changed, None))
        self.assertFalse(mcp._should_exec_reload(base, changed, other))
        # Changed and stable across two polls reloads.
        self.assertTrue(mcp._should_exec_reload(base, changed, changed))
        # Missing baseline or missing file never reloads.
        self.assertFalse(mcp._should_exec_reload(None, changed, changed))
        self.assertFalse(mcp._should_exec_reload(base, None, changed))

    def test_disabled_via_environment(self) -> None:
        with mock.patch.dict(os.environ, {"CCKIT_SHIM_RELOAD": "off"}):
            self.assertTrue(mcp.shim_reload_disabled())
        with mock.patch.dict(os.environ, {"CCKIT_SHIM_RELOAD": "auto"}):
            self.assertFalse(mcp.shim_reload_disabled())

    def test_watcher_thread_starts_and_respects_off(self) -> None:
        before = threading.active_count()
        with mock.patch.dict(os.environ, {"CCKIT_SHIM_RELOAD": "off"}):
            mcp.start_self_reload_watcher()
        self.assertEqual(threading.active_count(), before)
        with mock.patch.dict(os.environ, {"CCKIT_SHIM_RELOAD": "auto"}):
            mcp.start_self_reload_watcher()
        self.assertEqual(threading.active_count(), before + 1)


class MissRetryTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name)
        _seed_repo(self.repo)
        self.calls: list[tuple] = []

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _miss_payload(self) -> dict:
        return {
            "count": 0,
            "totalCount": 0,
            "truncated": False,
            "results": "no symbols matching 'HTMLRenderPlan'",
            mcp._REFRESHED_KEY: False,
        }

    def _hit_payload(self) -> dict:
        return {
            "count": 1,
            "totalCount": 1,
            "truncated": False,
            "results": (
                "App/HTMLRenderPlan.swift\n"
                "  struct HTMLRenderPlan 1-10"
            ),
            mcp._REFRESHED_KEY: False,
        }

    def test_miss_with_dirty_file_forces_index_and_retries(self) -> None:
        (self.repo / "Bar.swift").write_text("struct Bar {}\n", encoding="utf-8")
        responses = [self._miss_payload(), self._hit_payload()]
        force_calls: list[Path] = []

        def fake_run(args, repo=None, **kwargs):
            self.calls.append((list(args), kwargs.get("skip_auto_refresh")))
            return responses.pop(0)

        with (
            mock.patch.object(mcp, "run_cckit", side_effect=fake_run),
            mock.patch.object(
                mcp,
                "force_refresh_index",
                side_effect=lambda repo: force_calls.append(repo) or {"refreshed": True},
            ),
        ):
            out = run_cckit_with_miss_retry(
                ["find-symbol", "HTMLRenderPlan", "--json"],
                repo=str(self.repo),
                is_miss=find_symbol_is_miss,
                parse_json=True,
            )

        self.assertEqual(len(force_calls), 1)
        self.assertEqual(len(self.calls), 2)
        self.assertTrue(self.calls[1][1])  # skip_auto_refresh on retry
        self.assertFalse(find_symbol_is_miss(out))
        self.assertNotIn(mcp._REFRESHED_KEY, out)

    def test_miss_already_refreshed_skips_second_index(self) -> None:
        (self.repo / "Bar.swift").write_text("struct Bar {}\n", encoding="utf-8")
        first = self._miss_payload()
        first[mcp._REFRESHED_KEY] = True
        force_calls: list[Path] = []

        def fake_run(args, repo=None, **kwargs):
            self.calls.append(list(args))
            return first

        with (
            mock.patch.object(mcp, "run_cckit", side_effect=fake_run),
            mock.patch.object(
                mcp,
                "force_refresh_index",
                side_effect=lambda repo: force_calls.append(repo) or {"refreshed": True},
            ),
        ):
            out = run_cckit_with_miss_retry(
                ["find-symbol", "HTMLRenderPlan", "--json"],
                repo=str(self.repo),
                is_miss=find_symbol_is_miss,
                parse_json=True,
            )

        self.assertEqual(force_calls, [])
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(find_symbol_is_miss(out))
        self.assertEqual(out.get(mcp._DIRTY_KEY), ["Bar.swift"])
        self.assertTrue(out.get(mcp._AFTER_REFRESH_KEY))

    def test_miss_clean_tree_does_not_force_index(self) -> None:
        force_calls: list[Path] = []

        def fake_run(args, repo=None, **kwargs):
            return self._miss_payload()

        with (
            mock.patch.object(mcp, "run_cckit", side_effect=fake_run),
            mock.patch.object(
                mcp,
                "force_refresh_index",
                side_effect=lambda repo: force_calls.append(repo) or {"refreshed": True},
            ),
        ):
            out = run_cckit_with_miss_retry(
                ["find-symbol", "Nope", "--json"],
                repo=str(self.repo),
                is_miss=find_symbol_is_miss,
                parse_json=True,
            )

        self.assertEqual(force_calls, [])
        self.assertEqual(out.get(mcp._DIRTY_KEY), [])
        footer = miss_footer(
            dirty_paths=out.get(mcp._DIRTY_KEY) or [],
            after_refresh=bool(out.get(mcp._AFTER_REFRESH_KEY)),
        )
        self.assertEqual(footer, "No indexed hit. Try a shorter fragment.")
        self.assertNotIn("Call index", footer)


class FindSymbolAliasTests(unittest.TestCase):
    def test_requires_name_or_fragment(self) -> None:
        out = find_symbol()
        self.assertEqual(out.get("error"), "bad_args")

    def test_fragment_alias_is_forwarded(self) -> None:
        hit = {
            "count": 1,
            "totalCount": 1,
            "truncated": False,
            "results": "Theme.swift\n  enum Theme",
        }
        with mock.patch.object(
            mcp,
            "run_cckit_with_miss_retry",
            return_value=hit,
        ) as run:
            out = find_symbol(fragment="Theme")
        args = run.call_args[0][0]
        self.assertEqual(args[0], "find-symbol")
        self.assertEqual(args[1], "Theme")
        self.assertIn("enum Theme", out.get("results", ""))


class SavingsFooterTests(unittest.TestCase):
    def test_split_trailing_stats_strips_and_parses(self) -> None:
        text = "# Context Packet\n\nbody...\n"
        stats_line = 'PACK_STATS {"deliveredMode":"surgical","deliveredTokens":5606,"sourceWholeFileTokens":11641,"tokensSaved":6035}'
        out, stats = mcp.split_trailing_stats(text + stats_line + "\n", mcp._PACK_STATS_LINE)
        self.assertEqual(out, text.rstrip())
        self.assertEqual(stats["deliveredTokens"], 5606)

    def test_split_trailing_stats_absent(self) -> None:
        out, stats = mcp.split_trailing_stats("# Context Packet\n\nplain\n", mcp._PACK_STATS_LINE)
        self.assertIn("plain", out)
        self.assertIsNone(stats)

    def test_split_trailing_stats_invalid_json_returns_none(self) -> None:
        out, stats = mcp.split_trailing_stats("packet\nPACK_STATS {broken", mcp._PACK_STATS_LINE)
        self.assertIn("PACK_STATS", out)
        self.assertIsNone(stats)

    def test_savings_footer_full_form(self) -> None:
        footer = mcp.savings_footer(2255, 11641)
        self.assertIn("2.3k tokens delivered", footer)
        self.assertIn("11.6k whole-file", footer)
        self.assertIn("saved ~9.4k (81%)", footer)

    def test_savings_footer_delivered_only_when_no_baseline(self) -> None:
        self.assertEqual(mcp.savings_footer(850, None), "~850 tokens delivered")
        self.assertIsNone(mcp.savings_footer(None, 1000))
        self.assertIsNone(mcp.savings_footer(0, 1000))

    def test_negative_saved_shows_no_savings(self) -> None:
        footer = mcp.savings_footer(3157, 2918)
        self.assertIn("no savings (read was cheaper)", footer)
        self.assertNotIn("saved ~-", footer)


class GatherPreviewTests(unittest.TestCase):
    def test_preview_mode_passes_flag_and_kept_text(self) -> None:
        packet = "## Primary hits\n- Foo (struct · F.swift:1-2)\n"
        with mock.patch.object(
            mcp,
            "run_cckit_with_miss_retry",
            return_value={"text": packet},
        ) as run:
            out = gather_code_context(task="fix login retry", mode="preview")
        args = run.call_args[0][0]
        self.assertIn("--preview", args)
        self.assertIn("Primary hits", out.get("text", ""))

    def test_invalid_mode_returns_bad_mode(self) -> None:
        out = gather_code_context(task="fix login retry", mode="raw")
        self.assertEqual(out.get("error"), "bad_mode")

    def test_gather_attaches_savings_from_stats_line(self) -> None:
        packet = "packet body"
        stats = 'PACK_STATS {"deliveredTokens":5606,"sourceWholeFileTokens":11641,"tokensSaved":6035,"deliveredMode":"surgical"}'
        with mock.patch.object(
            mcp,
            "run_cckit_with_miss_retry",
            return_value={"text": packet + "\n" + stats},
        ):
            out = gather_code_context(task="fix login retry")
        self.assertNotIn("PACK_STATS", out["text"])
        self.assertIn("savings", out)
        self.assertIn("5.6k tokens delivered", out["savings"])


class PlaybookConsistencyTests(unittest.TestCase):
    """docs/agent-playbook.md is canonical; instructions, descriptions, and the
    packaged skill must keep its routing rules. These phrases are shared across
    all renderings — if one goes missing here, an adoption surface drifted."""

    PLAYBOOK_PHRASES = (
        "symptom, a change, more than one file, or a failure log",
        "even when names are visible",
        "starting context",
        "Prefer gather over Grep/Read",
        "mode=\"preview\"",
        "find_symbol after gather",
        "do not Grep that name",
        "symbol will not dump the whole type",
        "auto-refreshes",
    )

    def _read(self, relative: str) -> str:
        return (Path(__file__).resolve().parents[1] / relative).read_text(encoding="utf-8")

    def test_playbook_file_exists_with_decision_table(self) -> None:
        playbook = self._read("docs/agent-playbook.md")
        self.assertIn("Decision table", playbook)
        self.assertIn("gather_code_context", playbook)

    def test_server_instructions_match_playbook(self) -> None:
        text = mcp.SERVER_INSTRUCTIONS
        for phrase in self.PLAYBOOK_PHRASES:
            self.assertIn(phrase, text)
        # gather routes before locators.
        self.assertLess(
            text.find("gather_code_context(task)"),
            text.find("find_symbol after gather"),
        )

    def test_skill_matches_playbook(self) -> None:
        skill = self._read("codecontextkit-skill/codecontextkit/SKILL.md")
        for phrase in self.PLAYBOOK_PHRASES:
            self.assertIn(phrase, skill)
        self.assertIn("gather_code_context(task)", skill)
        self.assertIn("find_references", skill)


if __name__ == "__main__":
    unittest.main()
