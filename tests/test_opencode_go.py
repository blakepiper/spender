import datetime as dt
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from spender.providers import opencode_go


class OpenCodeGoTests(unittest.TestCase):
    def test_sqlite_scan_filters_provider_and_maps_windows(self):
        now = dt.datetime(2026, 8, 27, 12).astimezone()
        timestamp_ms = int(now.timestamp() * 1000)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            database = root / "opencode.db"
            auth = root / "auth.json"
            auth.write_text('{"opencode-go":{"key":"secret"}}')
            connection = sqlite3.connect(database)
            connection.execute("CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)")
            valid = {
                "role": "assistant",
                "providerID": "opencode-go",
                "modelID": "go-test",
                "finish": "stop",
                "cost": 0,
                "tokens": {"input": 10, "output": 5, "reasoning": 2, "cache": {"read": 3, "write": 1}},
            }
            other = dict(valid, providerID="other")
            connection.executemany(
                "INSERT INTO message VALUES (?, ?, ?, ?)",
                [
                    ("1", "session-1", timestamp_ms, json.dumps(valid)),
                    ("2", "session-2", timestamp_ms, json.dumps(other)),
                ],
            )
            connection.commit()
            connection.close()
            config = {
                "database_path": str(database),
                "auth_path": str(auth),
                "usage_url": "https://example.test/usage",
            }
            remote = {
                "rolling": {"percent": 25, "resetsAt": "2026-08-27T15:00:00Z"},
                "weekly": {"percent": 50, "resetsAt": "2026-09-01T00:00:00Z"},
                "monthly": {"percent": 75, "resetsAt": "2026-09-15T00:00:00Z"},
            }
            result = opencode_go.scan(config, now, fetcher=lambda _key, _url: remote)
            self.assertEqual(result["todayPrompts"], 1)
            self.assertEqual(result["todayTotalTokens"], 21)
            self.assertEqual(result["rateLimitPercent"], 0.25)
            self.assertEqual(result["secondaryRateLimitPercent"], 0.5)
            self.assertEqual(result["tertiaryRateLimitPercent"], 0.75)
            self.assertNotIn("secret", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
