"""OpenCode Go quota and local SQLite-history scanner."""

import json
import sqlite3
import urllib.request
from pathlib import Path

from .common import LocalStats, integer, local_day, normalized_percent, provider_result


WINDOWS = (
    ("rateLimit", "5-hour window", "rolling"),
    ("secondaryRateLimit", "Weekly window", "weekly"),
    ("tertiaryRateLimit", "Monthly window", "monthly"),
)


def read_api_key(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    provider = data.get("opencode-go") if isinstance(data, dict) else None
    key = provider.get("key") if isinstance(provider, dict) else None
    return str(key).strip() if key else ""


def fetch_remote_usage(api_key, usage_url, opener=urllib.request.urlopen):
    if not api_key:
        return None
    request = urllib.request.Request(
        usage_url,
        headers={
            "Accept": "application/json",
            "Authorization": "Bearer %s" % api_key,
            "User-Agent": "Spender/0.1",
        },
    )
    try:
        with opener(request, timeout=5) as response:
            payload = json.load(response)
    except Exception:
        return None
    usage = payload.get("usage") if isinstance(payload, dict) else None
    return usage if isinstance(usage, dict) else None


def read_messages(database_path):
    path = Path(database_path)
    if not path.is_file():
        return []
    connection = None
    try:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=2)
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT id, session_id, time_created, data FROM message").fetchall()
    except (OSError, sqlite3.Error):
        return []
    finally:
        if connection is not None:
            connection.close()
    messages = []
    for row in rows:
        try:
            data = json.loads(row["data"])
        except (TypeError, ValueError):
            continue
        if not isinstance(data, dict) or data.get("role") != "assistant" or data.get("providerID") != "opencode-go":
            continue
        tokens = data.get("tokens") if isinstance(data.get("tokens"), dict) else {}
        cache = tokens.get("cache") if isinstance(tokens.get("cache"), dict) else {}
        values = (
            integer(tokens.get("input")),
            integer(tokens.get("output")) + integer(tokens.get("reasoning")),
            integer(cache.get("read")),
            integer(cache.get("write")),
        )
        try:
            cost = float(data.get("cost") or 0)
        except (TypeError, ValueError):
            cost = 0.0
        finish = data.get("finish")
        if cost <= 0 and (sum(values) <= 0 or not isinstance(finish, str) or not finish):
            continue
        timestamp_ms = integer(row["time_created"])
        if timestamp_ms <= 0 and isinstance(data.get("time"), dict):
            timestamp_ms = integer(data["time"].get("created"))
        if timestamp_ms <= 0:
            continue
        messages.append({
            "session": str(row["session_id"]),
            "timestamp": timestamp_ms / 1000.0,
            "model": str(data.get("modelID") or "unknown"),
            "tokens": values,
        })
    return messages


def scan(config, now=None, fetcher=fetch_remote_usage):
    messages = read_messages(config["database_path"])
    stats = LocalStats(now)
    for message in messages:
        stats.add(
            local_day(message["timestamp"], stats.now),
            message["session"],
            message["model"],
            *message["tokens"]
        )
    result = provider_result("OpenCode Go", stats)
    result["hasLocalStats"] = Path(config["database_path"]).is_file()
    api_key = read_api_key(config["auth_path"])
    result["authenticated"] = bool(api_key)
    remote = fetcher(api_key, config["usage_url"])
    if remote is not None:
        for prefix, label, key in WINDOWS:
            window = remote.get(key) if isinstance(remote.get(key), dict) else {}
            result[prefix + "Percent"] = normalized_percent(window.get("percent"), is_percentage=True)
            result[prefix + "Label"] = label
            result[prefix + "ResetAt"] = str(window.get("resetsAt") or "")
        result["tierLabel"] = "Go"
    elif api_key:
        result["usageStatusText"] = "OpenCode Go live limits unavailable"
        result["authHelpText"] = "Token history is local; the live usage request failed."
    else:
        result["authHelpText"] = "Connect OpenCode Go to show live quota."
    result["ready"] = bool(api_key or messages)
    return result
