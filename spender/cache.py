"""Atomic, process-safe snapshot caching."""

import fcntl
import json
import os
import time
from contextlib import contextmanager
from pathlib import Path


def read_cache(path, max_age_seconds=None):
    path = Path(path)
    try:
        if max_age_seconds is not None:
            if max_age_seconds <= 0 or time.time() - path.stat().st_mtime > max_age_seconds:
                return None
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or not isinstance(value.get("providers"), list):
            return None
        return value
    except (OSError, ValueError, TypeError):
        return None


def write_cache(path, snapshot):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(".%s.%s.tmp" % (path.name, os.getpid()))
    try:
        temporary.write_text(json.dumps(snapshot, separators=(",", ":")), encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(str(temporary), str(path))
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def cache_lock(path):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    with lock_path.open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield
