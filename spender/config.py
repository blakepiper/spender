"""Configuration loading for Spender."""

import copy
import getpass
import json
import os
from pathlib import Path


class ConfigError(ValueError):
    pass


def _expand(value):
    return str(Path(os.path.expandvars(os.path.expanduser(value))).resolve())


def config_path(path=None, env=None):
    env = os.environ if env is None else env
    value = path or env.get("SPENDER_CONFIG")
    if value:
        return Path(_expand(value))
    return Path.home() / "Library" / "Application Support" / "spender" / "config.json"


def default_config(env=None):
    env = os.environ if env is None else env
    home = Path.home()
    claude_root = Path(env.get("CLAUDE_CONFIG_DIR") or home / ".claude")
    codex_root = Path(env.get("CODEX_HOME") or home / ".codex")
    cache_root = Path(env.get("SPENDER_CACHE_DIR") or home / "Library" / "Caches" / "spender")
    return {
        "cache": {
            "path": str(cache_root / "providers.json"),
            "ttl_seconds": 300,
        },
        "claude": {
            "projects_path": str(claude_root / "projects"),
            "credentials_path": str(claude_root / ".credentials.json"),
            "keychain_service": "Claude Code-credentials",
            "keychain_account": getpass.getuser(),
            "usage_url": "https://api.anthropic.com/api/oauth/usage",
        },
        "codex": {
            "home": str(codex_root),
            "pi_sessions_path": str(home / ".pi" / "agent" / "sessions"),
            "command": "codex",
            "history_days": 30,
        },
        "opencode_go": {
            "database_path": str(home / ".local" / "share" / "opencode" / "opencode.db"),
            "auth_path": str(home / ".local" / "share" / "opencode" / "auth.json"),
            "usage_url": "https://opencode.ai/zen/go/v1/usage",
        },
    }


def _merge(base, override, prefix=""):
    for key, value in override.items():
        location = "%s.%s" % (prefix, key) if prefix else key
        if key not in base:
            raise ConfigError("Unknown configuration key: %s" % location)
        if isinstance(base[key], dict):
            if not isinstance(value, dict):
                raise ConfigError("Configuration section must be an object: %s" % location)
            _merge(base[key], value, location)
        else:
            base[key] = value


def _expand_paths(config):
    path_keys = {
        "cache": ("path",),
        "claude": ("projects_path", "credentials_path"),
        "codex": ("home", "pi_sessions_path"),
        "opencode_go": ("database_path", "auth_path"),
    }
    for section, keys in path_keys.items():
        for key in keys:
            value = config[section].get(key)
            if value:
                config[section][key] = _expand(str(value))


def load_config(path=None, env=None):
    result = copy.deepcopy(default_config(env))
    source = config_path(path, env)
    if source.is_file():
        try:
            override = json.loads(source.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise ConfigError("Could not read %s: %s" % (source, exc))
        if not isinstance(override, dict):
            raise ConfigError("Configuration root must be an object: %s" % source)
        _merge(result, override)

    try:
        result["cache"]["ttl_seconds"] = max(0, int(result["cache"]["ttl_seconds"]))
        result["codex"]["history_days"] = max(0, int(result["codex"]["history_days"]))
    except (TypeError, ValueError) as exc:
        raise ConfigError("Cache TTL and Codex history days must be integers: %s" % exc)
    _expand_paths(result)
    return result
