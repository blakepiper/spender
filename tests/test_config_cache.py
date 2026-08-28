import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from spender.cache import read_cache, write_cache
from spender.config import ConfigError, load_config


class ConfigTests(unittest.TestCase):
    def test_environment_defaults_and_file_override(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "config.json"
            config_path.write_text(json.dumps({
                "cache": {"ttl_seconds": 42},
                "codex": {"history_days": 7},
            }))
            env = {
                "CLAUDE_CONFIG_DIR": str(root / "claude"),
                "CODEX_HOME": str(root / "codex"),
                "SPENDER_CACHE_DIR": str(root / "cache"),
            }
            config = load_config(str(config_path), env)
            self.assertEqual(config["cache"]["ttl_seconds"], 42)
            self.assertEqual(config["codex"]["history_days"], 7)
            self.assertEqual(config["claude"]["projects_path"], str((root / "claude/projects").resolve()))
            self.assertEqual(config["codex"]["home"], str((root / "codex").resolve()))
            self.assertEqual(config["cache"]["path"], str((root / "cache/providers.json").resolve()))

    def test_unknown_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            path.write_text('{"unknown": true}')
            with self.assertRaises(ConfigError):
                load_config(str(path), {})


class CacheTests(unittest.TestCase):
    def test_atomic_round_trip_and_freshness(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "providers.json"
            value = {"providers": [{"providerName": "test"}]}
            write_cache(path, value)
            self.assertEqual(read_cache(path, 60), value)
            old = time.time() - 120
            os.utime(path, (old, old))
            self.assertIsNone(read_cache(path, 60))
            self.assertEqual(read_cache(path), value)

    def test_malformed_cache_is_ignored(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "providers.json"
            path.write_text("not json")
            self.assertIsNone(read_cache(path))


if __name__ == "__main__":
    unittest.main()
