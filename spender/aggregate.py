"""Provider orchestration and cached snapshot loading."""

import concurrent.futures
import datetime as dt
from pathlib import Path

from .cache import cache_lock, read_cache, write_cache
from .providers import claude, codex, opencode_go
from .providers.common import provider_result


PROVIDERS = (
    ("Claude Code", "claude", claude.scan),
    ("OpenAI Codex", "codex", codex.scan),
    ("OpenCode Go", "opencode_go", opencode_go.scan),
)


def _prior_by_name(snapshot):
    if not snapshot:
        return {}
    return {
        provider.get("providerName"): provider
        for provider in snapshot.get("providers", [])
        if isinstance(provider, dict) and provider.get("providerName")
    }


def _failed_provider(name, error, prior=None):
    if prior:
        result = dict(prior)
        result["stale"] = True
        result["usageStatusText"] = "%s (showing cached data)" % error
        return result
    result = provider_result(name)
    result["usageStatusText"] = error
    result["authHelpText"] = error
    return result


def collect(config, prior=None):
    previous = _prior_by_name(prior)
    results = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(PROVIDERS)) as pool:
        futures = {
            pool.submit(scanner, config[section]): (name, section)
            for name, section, scanner in PROVIDERS
        }
        for future, (name, _section) in futures.items():
            try:
                results[name] = future.result()
            except Exception as exc:
                results[name] = _failed_provider(name, "%s unavailable: %s" % (name, exc), previous.get(name))
    return [results[name] for name, _section, _scanner in PROVIDERS]


def get_snapshot(config, force=False):
    path = Path(config["cache"]["path"])
    ttl = config["cache"]["ttl_seconds"]
    if not force:
        cached = read_cache(path, ttl)
        if cached is not None:
            cached["fromCache"] = True
            return cached
    with cache_lock(path):
        if not force:
            cached = read_cache(path, ttl)
            if cached is not None:
                cached["fromCache"] = True
                return cached
        prior = read_cache(path)
        generated = dt.datetime.now(dt.timezone.utc)
        snapshot = {
            "schemaVersion": 1,
            "generatedAt": generated.isoformat(),
            "generatedAtEpoch": generated.timestamp(),
            "fromCache": False,
            "providers": collect(config, prior),
        }
        write_cache(path, snapshot)
        return snapshot
