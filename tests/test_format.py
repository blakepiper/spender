import datetime as dt
import unittest

from spender.format import reset_text, summary_text, swiftbar, token_text


class FormatTests(unittest.TestCase):
    def test_summary_uses_most_consumed_window(self):
        providers = [
            {"rateLimitPercent": 0.2, "secondaryRateLimitPercent": 0.75},
            {"rateLimitPercent": 0.4},
        ]
        self.assertEqual(summary_text(providers), "💸 25% left")

    def test_tokens_and_reset(self):
        self.assertEqual(token_text(1_250_000), "1.2M")
        now = dt.datetime(2026, 8, 27, 12, tzinfo=dt.timezone.utc)
        self.assertIn("2h 30m", reset_text("2026-08-27T14:30:00Z", now))

    def test_swiftbar_output_has_header_sections_and_escapes_pipe(self):
        snapshot = {
            "generatedAtEpoch": 0,
            "providers": [{
                "providerName": "Test | Provider",
                "rateLimitPercent": 0.5,
                "rateLimitLabel": "Window",
                "todayTotalTokens": 1000,
                "todayPrompts": 2,
                "todaySessions": 1,
            }],
        }
        output = swiftbar(snapshot)
        self.assertTrue(output.startswith("💸 50% left\n---\n"))
        self.assertIn("Test ¦ Provider", output)
        self.assertIn("Refresh now | refresh=true", output)


if __name__ == "__main__":
    unittest.main()
