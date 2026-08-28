import unittest
from unittest import mock

from spender.aggregate import collect


class AggregateTests(unittest.TestCase):
    def test_scanner_failure_reuses_only_matching_prior_provider(self):
        prior = {
            "providers": [
                {"providerName": "Claude Code", "todayTotalTokens": 123, "rateLimitPercent": 0.5}
            ]
        }
        config = {"claude": {}, "codex": {}, "opencode_go": {}}

        def fail(_config):
            raise RuntimeError("broken")

        with mock.patch("spender.aggregate.PROVIDERS", (
            ("Claude Code", "claude", fail),
        )):
            providers = collect(config, prior)
        self.assertEqual(providers[0]["todayTotalTokens"], 123)
        self.assertTrue(providers[0]["stale"])
        self.assertIn("showing cached data", providers[0]["usageStatusText"])


if __name__ == "__main__":
    unittest.main()
