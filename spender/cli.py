"""Command-line entry point for Spender."""

import argparse
import json
import os
import sys

from .aggregate import get_snapshot
from .config import ConfigError, load_config
from .format import swiftbar, terminal


def parser():
    result = argparse.ArgumentParser(prog="spender", description="macOS AI quota and local usage monitor")
    result.add_argument("mode", nargs="?", choices=("status", "json", "swiftbar"), default="status")
    result.add_argument("--config", help="path to config JSON")
    result.add_argument("--refresh", action="store_true", help="bypass cached provider data")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        config = load_config(args.config)
        refresh_reason = os.environ.get("SWIFTBAR_PLUGIN_REFRESH_REASON", "").lower()
        force = args.refresh or refresh_reason == "menuaction" or "menu action" in refresh_reason
        snapshot = get_snapshot(config, force=force)
    except ConfigError as exc:
        print("Spender configuration error: %s" % exc, file=sys.stderr)
        return 2
    except Exception as exc:
        if args.mode == "swiftbar":
            print("💸 ⚠️\n---\nSpender unavailable: %s" % exc)
            return 0
        print("Spender unavailable: %s" % exc, file=sys.stderr)
        return 1
    if args.mode == "json":
        print(json.dumps(snapshot, indent=2, sort_keys=True))
    elif args.mode == "swiftbar":
        print(swiftbar(snapshot))
    else:
        print(terminal(snapshot))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
