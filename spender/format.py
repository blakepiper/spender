"""Terminal and SwiftBar rendering."""

import datetime as dt
import time


LIMIT_PREFIXES = ("rateLimit", "secondaryRateLimit", "tertiaryRateLimit")


def percent(value):
    try:
        result = float(value)
        return result if result >= 0 else None
    except (TypeError, ValueError):
        return None


def token_text(value):
    try:
        tokens = int(value or 0)
    except (TypeError, ValueError):
        tokens = 0
    if tokens >= 1_000_000_000:
        return "%.1fB" % (tokens / 1_000_000_000)
    if tokens >= 1_000_000:
        return "%.1fM" % (tokens / 1_000_000)
    if tokens >= 1_000:
        return "%.1fK" % (tokens / 1_000)
    return str(tokens)


def _parse_time(value):
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except ValueError:
        return None


def reset_text(value, now=None):
    parsed = _parse_time(value)
    if parsed is None:
        return "resets %s" % value if value else ""
    now = now or dt.datetime.now(dt.timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=dt.timezone.utc)
    seconds = max(0, int((parsed - now).total_seconds()))
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    if days:
        relative = "%sd %sh" % (days, hours)
    elif hours:
        relative = "%sh %sm" % (hours, minutes)
    else:
        relative = "%sm" % minutes
    local = parsed.astimezone().strftime("%b %-d, %-I:%M %p")
    return "resets in %s (%s)" % (relative, local)


def quota_rows(provider, now=None):
    rows = []
    for prefix in LIMIT_PREFIXES:
        used = percent(provider.get(prefix + "Percent"))
        if used is None:
            continue
        label = provider.get(prefix + "Label") or "Limit"
        reset = reset_text(provider.get(prefix + "ResetAt"), now)
        text = "%s: %.0f%% used · %.0f%% left" % (label, used * 100, max(0, 1 - used) * 100)
        if reset:
            text += " · " + reset
        rows.append(text)
    return rows


def summary_text(providers):
    values = [
        used
        for provider in providers
        for prefix in LIMIT_PREFIXES
        for used in (percent(provider.get(prefix + "Percent")),)
        if used is not None
    ]
    return "💸 %.0f%% left" % (max(0, 1 - max(values)) * 100) if values else "💸 —"


def terminal(snapshot):
    lines = [summary_text(snapshot.get("providers", [])), ""]
    for provider in snapshot.get("providers", []):
        title = provider.get("providerName") or "Provider"
        if provider.get("tierLabel"):
            title += " · " + str(provider["tierLabel"])
        lines.append(title)
        rows = quota_rows(provider)
        if rows:
            lines.extend("  " + row for row in rows)
        else:
            lines.append("  " + (provider.get("usageStatusText") or "No live quota data"))
        lines.append(
            "  Today: %s tokens · %s prompts · %s sessions"
            % (
                token_text(provider.get("todayTotalTokens")),
                provider.get("todayPrompts", 0),
                provider.get("todaySessions", 0),
            )
        )
        help_text = provider.get("authHelpText")
        if help_text and help_text != provider.get("usageStatusText"):
            lines.append("  " + str(help_text))
        lines.append("")
    return "\n".join(lines).rstrip()


def _safe(value):
    return str(value).replace("|", "¦").replace("\n", " ").replace("\r", " ")


def swiftbar(snapshot):
    providers = snapshot.get("providers", [])
    lines = [summary_text(providers), "---"]
    for index, provider in enumerate(providers):
        if index:
            lines.append("---")
        title = provider.get("providerName") or "Provider"
        if provider.get("tierLabel"):
            title += " · " + str(provider["tierLabel"])
        lines.append(_safe(title))
        rows = quota_rows(provider)
        if rows:
            lines.extend("• " + _safe(row) for row in rows)
        else:
            lines.append("• " + _safe(provider.get("usageStatusText") or "No live quota data"))
        lines.append(
            "• Today: %s tokens · %s prompts · %s sessions"
            % (
                token_text(provider.get("todayTotalTokens")),
                provider.get("todayPrompts", 0),
                provider.get("todaySessions", 0),
            )
        )
        help_text = provider.get("authHelpText")
        if help_text and help_text != provider.get("usageStatusText"):
            lines.append("• " + _safe(help_text))
    generated = float(snapshot.get("generatedAtEpoch") or time.time())
    age = max(0, int(time.time() - generated))
    lines.extend(["---", "Updated %sm ago" % (age // 60), "Refresh now | refresh=true"])
    return "\n".join(lines)
