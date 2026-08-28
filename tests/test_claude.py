import datetime as dt
import io
import json
import tempfile
import unittest
from pathlib import Path

from spender.providers import claude


class ClaudeTests(unittest.TestCase):
    def test_project_scan_deduplicates_and_aggregates_tokens(self):
        now = dt.datetime(2026, 8, 27, 12, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            entries = [
                {
                    "type": "assistant",
                    "sessionId": "session-1",
                    "timestamp": "2026-08-27T12:00:00Z",
                    "message": {
                        "id": "message-1",
                        "model": "claude-test",
                        "usage": {
                            "input_tokens": 10,
                            "output_tokens": 5,
                            "cache_read_input_tokens": 3,
                            "cache_creation_input_tokens": 2,
                        },
                    },
                },
                {
                    "type": "assistant",
                    "sessionId": "session-1",
                    "timestamp": "2026-08-27T12:01:00Z",
                    "message": {"id": "message-1", "usage": {"input_tokens": 999}},
                },
            ]
            (root / "session.jsonl").write_text("\n".join(json.dumps(item) for item in entries))
            result = claude.scan_projects(root, now)
            self.assertEqual(result["todayPrompts"], 1)
            self.assertEqual(result["todaySessions"], 1)
            self.assertEqual(result["todayTotalTokens"], 20)
            self.assertEqual(result["modelUsage"]["claude-test"]["cacheReadInputTokens"], 3)

    def test_scan_merges_remote_limits_without_exposing_credentials(self):
        now = dt.datetime(2026, 8, 27, 12, tzinfo=dt.timezone.utc)
        payload = {
            "five_hour": {"utilization": 25, "resets_at": "2026-08-27T15:00:00Z"},
            "seven_day": {"utilization": 0.5, "resets_at": "2026-09-01T00:00:00Z"},
        }

        def opener(_request, timeout=0):
            self.assertEqual(timeout, 10)
            return io.BytesIO(json.dumps(payload).encode())

        with tempfile.TemporaryDirectory() as temporary:
            config = {
                "projects_path": temporary,
                "credentials_path": "",
                "keychain_service": "",
                "keychain_account": "",
                "usage_url": "https://example.test/usage",
            }
            credentials = {"claudeAiOauth": {"accessToken": "secret", "subscriptionType": "pro"}}
            result = claude.scan(config, now, credential_loader=lambda _config: credentials, opener=opener)
            self.assertEqual(result["rateLimitPercent"], 0.25)
            self.assertEqual(result["secondaryRateLimitPercent"], 0.5)
            self.assertEqual(result["tierLabel"], "pro")
            self.assertNotIn("secret", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
