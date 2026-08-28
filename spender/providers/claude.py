"""Claude Code quota and local project-history scanner."""

import json
import subprocess
import urllib.request
from pathlib import Path

from .common import LocalStats, integer, local_day, normalized_percent, provider_result


def _usage_value(usage, snake_key, camel_key):
    return integer(usage.get(snake_key, usage.get(camel_key, 0)))


def scan_projects(projects_path, now=None):
    projects_path = Path(projects_path)
    stats = LocalStats(now)
    seen = set()
    scanned_files = 0
    malformed_lines = 0
    if not projects_path.is_dir():
        result = stats.as_dict()
        result.update({"hasLocalStats": False, "scannedFiles": 0, "malformedLines": 0})
        return result

    for path in projects_path.rglob("*.jsonl"):
        scanned_files += 1
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line_number, line in enumerate(handle, 1):
                    if '"usage":' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        malformed_lines += 1
                        continue
                    message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
                    if entry.get("type") != "assistant" and message.get("role") != "assistant":
                        continue
                    usage = message.get("usage") or entry.get("usage")
                    if not isinstance(usage, dict):
                        continue
                    message_id = message.get("id") or entry.get("messageId")
                    unique = str(message_id) if message_id else "%s:%s" % (
                        path,
                        entry.get("uuid") or entry.get("requestId") or line_number,
                    )
                    if unique in seen:
                        continue
                    seen.add(unique)
                    stats.add(
                        local_day(entry.get("timestamp") or message.get("timestamp"), stats.now),
                        entry.get("sessionId") or path,
                        message.get("model") or entry.get("model") or "claude",
                        _usage_value(usage, "input_tokens", "inputTokens"),
                        _usage_value(usage, "output_tokens", "outputTokens"),
                        _usage_value(usage, "cache_read_input_tokens", "cacheReadInputTokens"),
                        _usage_value(usage, "cache_creation_input_tokens", "cacheCreationInputTokens"),
                    )
        except OSError:
            continue
    result = stats.as_dict()
    result.update({"scannedFiles": scanned_files, "malformedLines": malformed_lines})
    return result


def _read_json_file(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def read_credentials(config):
    service = str(config.get("keychain_service") or "").strip()
    account = str(config.get("keychain_account") or "").strip()
    if service:
        command = ["/usr/bin/security", "find-generic-password", "-s", service]
        if account:
            command.extend(["-a", account])
        command.append("-w")
        try:
            completed = subprocess.run(command, text=True, capture_output=True, timeout=5, check=True)
            value = json.loads(completed.stdout)
            if isinstance(value, dict):
                return value
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    path = config.get("credentials_path")
    return _read_json_file(path) if path else None


def fetch_limits(credentials, usage_url, opener=urllib.request.urlopen):
    oauth = credentials.get("claudeAiOauth") if isinstance(credentials, dict) else None
    if not isinstance(oauth, dict) or not oauth.get("accessToken"):
        return None, "Claude Code is not signed in"
    request = urllib.request.Request(
        usage_url,
        headers={
            "Authorization": "Bearer %s" % oauth["accessToken"],
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "Spender/0.1",
        },
    )
    try:
        with opener(request, timeout=10) as response:
            payload = json.load(response)
    except Exception as exc:
        return None, "Claude limits unavailable: %s" % exc
    if not isinstance(payload, dict):
        return None, "Claude limits unavailable: invalid response"
    session = payload.get("five_hour") or {}
    weekly = payload.get("seven_day_oauth_apps") or payload.get("seven_day") or {}
    return {
        "tierLabel": oauth.get("subscriptionType") or oauth.get("rateLimitTier") or "",
        "authenticated": True,
        "rateLimitPercent": normalized_percent(session.get("utilization")),
        "rateLimitLabel": "Session (5-hour)",
        "rateLimitResetAt": session.get("resets_at") or "",
        "secondaryRateLimitPercent": normalized_percent(weekly.get("utilization")),
        "secondaryRateLimitLabel": "Weekly (7-day)",
        "secondaryRateLimitResetAt": weekly.get("resets_at") or "",
    }, ""


def scan(config, now=None, credential_loader=read_credentials, opener=urllib.request.urlopen):
    local = scan_projects(config["projects_path"], now)
    result = provider_result("Claude Code")
    result.update(local)
    credentials = credential_loader(config)
    limits, error = fetch_limits(credentials, config["usage_url"], opener)
    if limits:
        result.update(limits)
    else:
        result["usageStatusText"] = error
        result["authHelpText"] = "Sign in with Claude Code to show live quota." if not credentials else error
    result["ready"] = bool(result.get("hasLocalStats") or limits)
    return result
