import datetime as dt
import io
import json
import queue
import tempfile
import unittest
from pathlib import Path

from spender.providers.codex import rpc_request, scan_native_sessions
from spender.providers.common import LocalStats


class FakeProcess:
    def __init__(self):
        self.stdin = io.StringIO()


class CodexTests(unittest.TestCase):
    def test_native_scan_splits_cached_input_without_double_counting(self):
        now = dt.datetime(2026, 8, 27, 12, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sessions = root / "sessions"
            sessions.mkdir()
            entries = [
                {"type": "turn_context", "payload": {"model": "gpt-test"}},
                {
                    "timestamp": "2026-08-27T12:00:00Z",
                    "payload": {
                        "type": "token_count",
                        "info": {
                            "last_token_usage": {
                                "input_tokens": 100,
                                "output_tokens": 30,
                                "cached_input_tokens": 20,
                                "cache_write_input_tokens": 0,
                            }
                        },
                    },
                },
            ]
            path = sessions / "session.jsonl"
            path.write_text("\n".join(json.dumps(item) for item in entries))
            stats = LocalStats(now)
            scan_native_sessions(root, stats, history_days=0)
            result = stats.as_dict()
            self.assertEqual(result["todayTotalTokens"], 130)
            self.assertEqual(result["modelUsage"]["gpt-test"]["inputTokens"], 80)
            self.assertEqual(result["modelUsage"]["gpt-test"]["cacheReadInputTokens"], 20)

    def test_rpc_request_marks_jsonrpc_and_ignores_notifications(self):
        responses = queue.Queue()
        responses.put({"method": "status/changed", "params": {}})
        responses.put({"id": 7, "result": {"ok": True}})
        process = FakeProcess()
        result = rpc_request(process, responses, 7, "test/read", timeout=1)
        sent = json.loads(process.stdin.getvalue())
        self.assertEqual(sent["jsonrpc"], "2.0")
        self.assertEqual(sent["method"], "test/read")
        self.assertEqual(result, {"ok": True})


if __name__ == "__main__":
    unittest.main()
