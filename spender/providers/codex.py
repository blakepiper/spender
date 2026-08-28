"""OpenAI Codex quota and local session-history scanner."""

import json
import os
import queue
import shutil
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from .common import LocalStats, integer, local_day, provider_result


def runtime_env():
    home = str(Path.home())
    paths = [
        os.environ.get("PATH", ""),
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "%s/.local/bin" % home,
        "%s/.npm-global/bin" % home,
        "%s/.local/share/mise/shims" % home,
    ]
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(path for path in paths if path)
    return env


def find_command(command, env=None):
    env = runtime_env() if env is None else env
    if os.path.sep in command:
        return command if Path(command).is_file() else None
    return shutil.which(command, path=env.get("PATH"))


def scan_pi_sessions(root, stats):
    root = Path(root)
    if not root.is_dir():
        return
    seen = set()
    for path in root.rglob("*.jsonl"):
        try:
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line_number, line in enumerate(handle, 1):
                    if '"openai-codex"' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("type") != "message":
                        continue
                    message = entry.get("message") or {}
                    unique = "%s:%s" % (path, entry.get("id") or line_number)
                    if unique in seen or message.get("role") != "assistant":
                        continue
                    seen.add(unique)
                    provider = str(message.get("provider") or "")
                    api = str(message.get("api") or "")
                    if provider != "openai-codex" and not api.startswith("openai-codex"):
                        continue
                    usage = message.get("usage") or {}
                    values = [
                        integer(usage.get("input")),
                        integer(usage.get("output")),
                        integer(usage.get("cacheRead")),
                        integer(usage.get("cacheWrite")),
                    ]
                    total = integer(usage.get("totalTokens"))
                    if total and not any(values):
                        values[0] = total
                    stats.add(
                        local_day(entry.get("timestamp") or message.get("timestamp"), stats.now),
                        path,
                        message.get("model") or "codex",
                        *values
                    )
        except OSError:
            continue


def scan_native_sessions(codex_home, stats, history_days=30):
    cutoff = time.time() - history_days * 86400 if history_days > 0 else None
    files = []
    for directory in ("sessions", "archived_sessions"):
        root = Path(codex_home) / directory
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            try:
                if cutoff is None or path.stat().st_mtime >= cutoff:
                    files.append(path)
            except OSError:
                continue
    for path in files:
        current_model = "codex"
        try:
            fallback_time = path.stat().st_mtime
            with path.open("r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    if entry.get("type") == "turn_context":
                        payload = entry.get("payload") or {}
                        current_model = str(payload.get("model") or payload.get("model_slug") or current_model)
                        continue
                    payload = entry.get("payload") or entry
                    if entry.get("type") == "response_item" and isinstance(payload, dict):
                        payload = payload.get("payload") or payload
                    if not isinstance(payload, dict) or payload.get("type") != "token_count":
                        continue
                    info = payload.get("info") or {}
                    usage = info.get("last_token_usage") or {}
                    cache_read = integer(usage.get("cached_input_tokens"))
                    cache_write = integer(usage.get("cache_write_input_tokens"))
                    input_tokens = max(0, integer(usage.get("input_tokens")) - cache_read - cache_write)
                    stats.add(
                        local_day(entry.get("timestamp") or fallback_time, stats.now),
                        path,
                        current_model,
                        input_tokens,
                        integer(usage.get("output_tokens")),
                        cache_read,
                        cache_write,
                    )
        except OSError:
            continue


def _reader(stream, responses):
    for line in stream:
        try:
            responses.put(json.loads(line))
        except ValueError:
            continue


def rpc_request(proc, responses, request_id, method, params=None, timeout=8):
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "method": method,
        "params": params or {},
    }
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise TimeoutError(method)
        try:
            message = responses.get(timeout=remaining)
        except queue.Empty:
            raise TimeoutError(method)
        if message.get("id") != request_id:
            continue
        if message.get("error"):
            raise RuntimeError("%s: %s" % (method, message["error"]))
        return message.get("result") or {}


def fetch_limits(config, env=None):
    env = runtime_env() if env is None else env
    env = env.copy()
    env["CODEX_HOME"] = str(config["home"])
    command = find_command(str(config.get("command") or "codex"), env)
    if not command:
        return None, "codex not found in PATH"
    try:
        proc = subprocess.Popen(
            [command, "app-server", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            env=env,
        )
    except OSError as exc:
        return None, str(exc)
    responses = queue.Queue()
    reader = threading.Thread(target=_reader, args=(proc.stdout, responses), daemon=True)
    reader.start()
    try:
        rpc_request(
            proc,
            responses,
            1,
            "initialize",
            {"clientInfo": {"name": "spender", "version": "0.1.0"}},
            timeout=8,
        )
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "initialized", "params": {}}) + "\n")
        proc.stdin.flush()
        account_result = rpc_request(proc, responses, 2, "account/read", timeout=5)
        limits_result = rpc_request(proc, responses, 3, "account/rateLimits/read", timeout=5)
        account = account_result.get("account") or {}
        limits = limits_result.get("rateLimits") or {}
        output = {
            "authenticated": bool(account),
            "tierLabel": str(limits.get("planType") or account.get("planType") or account.get("type") or ""),
        }

        def fill(prefix, window):
            if not isinstance(window, dict):
                return
            used = window.get("usedPercent")
            if used is not None:
                output[prefix + "Percent"] = max(0.0, min(1.0, float(used) / 100.0))
            minutes = integer(window.get("windowDurationMins"))
            if minutes == 10080:
                output[prefix + "Label"] = "Weekly (7-day)"
            elif minutes and minutes % 60 == 0:
                output[prefix + "Label"] = "%sh window" % (minutes // 60)
            elif minutes:
                output[prefix + "Label"] = "%sm window" % minutes
            reset = integer(window.get("resetsAt"))
            if reset:
                output[prefix + "ResetAt"] = datetime.fromtimestamp(reset, timezone.utc).isoformat()

        fill("rateLimit", limits.get("primary"))
        fill("secondaryRateLimit", limits.get("secondary"))
        return output, ""
    except Exception as exc:
        return None, "Codex limits unavailable: %s" % exc
    finally:
        try:
            proc.terminate()
            proc.wait(timeout=1)
        except Exception:
            try:
                proc.kill()
            except OSError:
                pass


def scan(config, now=None):
    stats = LocalStats(now)
    scan_pi_sessions(config["pi_sessions_path"], stats)
    scan_native_sessions(config["home"], stats, config.get("history_days", 30))
    result = provider_result("OpenAI Codex", stats)
    limits, error = fetch_limits(config)
    if limits:
        result.update(limits)
    else:
        result["usageStatusText"] = error
        result["authHelpText"] = error
    result["ready"] = bool(result.get("totalPrompts") or limits)
    return result
