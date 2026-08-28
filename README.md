# Spender

<img src="logo.png" alt="Spender logo" width="220">

Spender is a standalone native macOS menu-bar app for AI subscription usage. It
shows live quota percentages and reset times alongside local token, prompt, and
session statistics for:

- Claude Code
- OpenAI Codex
- OpenCode Go

It runs directly in the system menu bar with no Dock icon, SwiftBar, Python
runtime, daemon, or third-party package dependencies.

## Install and launch

```sh
cd ~/spender
./scripts/install-app
```

This builds an optimized, ad-hoc-signed app, installs it at
`~/Applications/Spender.app`, launches it, and removes the generated
`build/Spender.app` copy. Spender automatically requests launch-at-login
registration on its first installed launch. If macOS requires approval, the
menu shows **Launch at Login — Approval Required…**; select it to open the
correct System Settings page.

The menu-bar item is a native dollar-circle symbol. It appears with the other
status items on the right side of the macOS menu bar. Hold Command and drag it
to reposition it. Hovering shows the remaining percentage in the most-consumed
available quota window; full details remain inside the menu.

## Menu

Click Spender's menu-bar item to see:

- Each provider and signed-in tier
- Every available quota window with used/remaining percentages
- Relative and local reset times
- Today's local tokens, completed responses (shown as prompts), and sessions
- Refresh status and snapshot age
- **Refresh Now**
- **Launch at Login**
- **Open Configuration Folder**
- **Quit Spender**

The app refreshes every five minutes. Provider collection runs off the main
thread, so the menu bar stays responsive. A normal refresh uses the cache;
**Refresh Now** bypasses it.

## Provider behavior

### Claude Code

- Streams assistant usage records from `~/.claude/projects`.
- Deduplicates message identifiers and aggregates local token history.
- Reads the existing `Claude Code-credentials` login Keychain entry through
  macOS's system security tool, with `.credentials.json` as a fallback.
- Fetches five-hour and weekly OAuth quota windows.

### OpenAI Codex

- Streams recent native and archived Codex session JSONL.
- Optionally includes pi agent sessions using the `openai-codex` provider.
- Preserves cached-input accounting without double counting.
- Uses the locally installed `codex app-server` JSON-RPC interface for account
  and quota information. No Codex token is read or cached.

### OpenCode Go

- Opens OpenCode's SQLite database read-only.
- Aggregates completed `opencode-go` assistant messages.
- Uses the existing OpenCode Go key only for its live usage request.
- Shows rolling five-hour, weekly, and monthly windows.

Token totals include input, output, cache-read, and cache-creation tokens.
"Prompts" counts completed assistant responses containing usage data, matching
the original Blix provider logic.

## Configuration

No configuration file is required for normal macOS paths. To customize paths:

```sh
mkdir -p "$HOME/Library/Application Support/spender"
cp config.example.json "$HOME/Library/Application Support/spender/config.json"
```

The menu's **Open Configuration Folder** command opens this location. The
default configuration can also be changed with `SPENDER_CONFIG`, and configured
paths expand tildes and environment variables.

| Setting | Default |
| --- | --- |
| Cache | `~/Library/Caches/spender/providers.json` |
| Claude projects | `~/.claude/projects` |
| Claude credentials fallback | `~/.claude/.credentials.json` |
| Claude Keychain service | `Claude Code-credentials` |
| Codex home | `~/.codex` |
| pi sessions | `~/.pi/agent/sessions` |
| OpenCode database | `~/.local/share/opencode/opencode.db` |
| OpenCode auth | `~/.local/share/opencode/auth.json` |

`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and `SPENDER_CACHE_DIR` override their
corresponding defaults when an explicit config value is absent. See
[config.example.json](config.example.json) for every setting.

## Privacy and failure behavior

Spender stores only aggregate usage statistics, quota values, and reset times.
Its mode-`0600` cache never contains access tokens, API keys, account email
addresses, or conversation content.

Providers refresh independently. A missing CLI, unavailable endpoint, or
unreadable data source is reported within that provider without hiding the
others. Local statistics remain visible when only a live quota request fails.

## Development

Requirements: macOS 13 or later and Xcode/Swift 6.

```sh
# Unit tests
swift test

# Build an app bundle at build/Spender.app
./scripts/build-app

# Exercise all native providers without launching the UI
.build/release/Spender --json --refresh
```

The bundle is an agent app (`LSUIElement=true`), so it intentionally has no Dock
or application-switcher icon. It uses AppKit's `NSStatusItem` for the system
menu bar. Signed builds use `SMAppService.mainApp` for launch at login; ad-hoc
personal builds fall back to a per-user LaunchAgent because Service Management
requires a signing identity that is not present on every development Mac.

See [PLAN.md](PLAN.md) for the detailed architecture and acceptance criteria.
