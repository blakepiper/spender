#!/usr/bin/python3
# <xbar.title>Spender</xbar.title>
# <xbar.version>v0.1.0</xbar.version>
# <xbar.desc>Claude Code, OpenAI Codex, and OpenCode Go quota and local usage.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>

import sys
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from spender.cli import main  # noqa: E402


raise SystemExit(main(["swiftbar"]))
