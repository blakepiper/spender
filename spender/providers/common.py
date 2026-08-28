"""Shared local-usage aggregation helpers."""

import datetime as dt
import math


TOKEN_KEYS = (
    "inputTokens",
    "outputTokens",
    "cacheReadInputTokens",
    "cacheCreationInputTokens",
)


def integer(value):
    try:
        return max(0, round(float(value or 0)))
    except (TypeError, ValueError, OverflowError):
        return 0


def normalized_percent(value, is_percentage=False):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return -1.0
    if not math.isfinite(result):
        return -1.0
    if is_percentage or result > 1:
        result /= 100.0
    return max(0.0, min(1.0, result))


def token_bucket():
    return {key: 0 for key in TOKEN_KEYS}


def local_day(value=None, fallback=None):
    fallback = fallback or dt.datetime.now().astimezone()
    if value is None:
        return fallback.strftime("%Y-%m-%d")
    if isinstance(value, (int, float)):
        try:
            seconds = float(value) / 1000.0 if float(value) > 10_000_000_000 else float(value)
            return dt.datetime.fromtimestamp(seconds).strftime("%Y-%m-%d")
        except (OSError, OverflowError, ValueError):
            return fallback.strftime("%Y-%m-%d")
    raw = str(value).strip()
    if not raw:
        return fallback.strftime("%Y-%m-%d")
    try:
        parsed = dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))
        if parsed.tzinfo is not None:
            parsed = parsed.astimezone()
        return parsed.strftime("%Y-%m-%d")
    except ValueError:
        return fallback.strftime("%Y-%m-%d")


class LocalStats:
    def __init__(self, now=None):
        self.now = now or dt.datetime.now().astimezone()
        current = self.now.date()
        self.dates = [(current - dt.timedelta(days=offset)).strftime("%Y-%m-%d") for offset in range(6, -1, -1)]
        self.recent = {day: 0 for day in self.dates}
        self.today = self.dates[-1]
        self.today_tokens_by_model = {}
        self.model_usage = {}
        self.today_sessions = set()
        self.sessions = set()
        self.active_dates = set()
        self.today_prompts = 0
        self.today_total_tokens = 0
        self.total_prompts = 0

    def add(self, day, session, model, input_tokens, output_tokens, cache_read, cache_write):
        values = tuple(integer(value) for value in (input_tokens, output_tokens, cache_read, cache_write))
        total = sum(values)
        if total <= 0:
            return
        model = str(model or "unknown")
        session = str(session or "unknown")
        self.total_prompts += 1
        self.sessions.add(session)
        self.active_dates.add(day)
        bucket = self.model_usage.setdefault(model, token_bucket())
        for key, value in zip(TOKEN_KEYS, values):
            bucket[key] += value
        if day in self.recent:
            self.recent[day] += total
        if day == self.today:
            self.today_prompts += 1
            self.today_sessions.add(session)
            self.today_total_tokens += total
            self.today_tokens_by_model[model] = self.today_tokens_by_model.get(model, 0) + total

    def as_dict(self):
        recent_days = [{"date": day, "messageCount": self.recent[day]} for day in self.dates]
        return {
            "hasLocalStats": True,
            "todayPrompts": self.today_prompts,
            "todaySessions": len(self.today_sessions),
            "todayTotalTokens": self.today_total_tokens,
            "todayTokensByModel": self.today_tokens_by_model,
            "recentDays": recent_days,
            "totalPrompts": self.total_prompts,
            "totalSessions": len(self.sessions),
            "activeDays": len(self.active_dates),
            "activeDates": sorted(self.active_dates),
            "modelUsage": self.model_usage,
        }


def provider_result(name, local=None):
    result = {
        "schemaVersion": 1,
        "providerName": name,
        "ready": False,
        "authenticated": False,
        "tierLabel": "",
        "usageStatusText": "",
        "authHelpText": "",
        "rateLimitPercent": -1,
        "rateLimitLabel": "",
        "rateLimitResetAt": "",
        "secondaryRateLimitPercent": -1,
        "secondaryRateLimitLabel": "",
        "secondaryRateLimitResetAt": "",
        "tertiaryRateLimitPercent": -1,
        "tertiaryRateLimitLabel": "",
        "tertiaryRateLimitResetAt": "",
    }
    if local is not None:
        result.update(local.as_dict())
    return result
