# Spender

Spender is a macOS menu-bar monitor for AI subscription usage. It shows live
quota percentages and reset times alongside local token, prompt, and session
statistics for Claude Code, OpenAI Codex, and OpenCode Go.

The first UI is a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin. The
provider and caching logic is a separate, standard-library-only Python package,
so it can also be used from Terminal or by a future native UI.

## What it shows

- The menu-bar title is the remaining percentage in the most-consumed available
  quota window.
- Claude Code: five-hour and weekly quota, plus local project JSONL history.
- OpenAI Codex: available account quota windows, plus native Codex and optional
  pi agent session history.
- OpenCode Go: five-hour, weekly, and monthly quota, plus local SQLite history.
- Each provider includes today's tokens, completed responses (shown as prompts),
  and sessions.

Token totals preserve the Blix scanner behavior: input, output, cache-read, and
cache-creation tokens are included. "Prompts" counts assistant responses that
contain usage data; it is a practical local proxy rather than a count supplied
by the provider.

## Requirements

- macOS
- `/usr/bin/python3` (the system/Xcode Python 3.9 or newer)
- The provider CLIs/apps you want to monitor, signed in locally
- SwiftBar for the menu-bar UI

Spender has no Python package dependencies. SwiftBar can be installed with:

```sh
brew install swiftbar
```

On first launch, SwiftBar asks you to choose a plugin folder. Its plugin naming
convention uses the filename to set refresh cadence, so Spender's launcher is
named `spender.5m.py`.

## Install the SwiftBar plugin

Clone or keep this repository at a stable location, then pass your chosen
SwiftBar plugin folder to the installer:

```sh
cd ~/spender
./scripts/install-swiftbar "$HOME/Documents/SwiftBar"
```

The installer creates a symlink to `swiftbar/spender.5m.py`; it refuses to
replace an existing plugin. If your SwiftBar folder is elsewhere, use that path
instead. Open or refresh SwiftBar after installation.

The repository is intentionally not used as the entire SwiftBar plugin folder:
SwiftBar scans plugin folders recursively, while only the launcher is a plugin.

## Terminal usage

```sh
# Readable provider details (uses a fresh cache when available)
bin/spender status

# Normalized data for another UI or integration
bin/spender json

# Bypass the cache and query all providers now
bin/spender --refresh status

# Preview exactly what SwiftBar parses
bin/spender swiftbar
```

The default cache TTL is five minutes. Refreshing from Spender's SwiftBar menu
bypasses the cache; ordinary scheduled runs reuse it.

## Configuration

No configuration file is required for the normal macOS locations. To customize
paths, copy the example:

```sh
mkdir -p "$HOME/Library/Application Support/spender"
cp config.example.json "$HOME/Library/Application Support/spender/config.json"
```

The default config path can be changed with `SPENDER_CONFIG` or `--config PATH`.
Tildes and environment variables in configured paths are expanded.

Defaults:

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
corresponding defaults when an explicit value is not present in Spender's config.
See [config.example.json](config.example.json) for every setting.

## Credentials and privacy

Spender only reads existing local sign-in state:

- On macOS, Claude OAuth JSON is read from the login Keychain service
  `Claude Code-credentials`. The configured credentials file is a fallback.
- Codex account limits are requested from the locally installed `codex
  app-server`; Spender does not read or store the Codex access token.
- The OpenCode Go API key is read from its auth JSON only for the usage request.

You may see a macOS Keychain access prompt the first time SwiftBar runs Spender.
The cache contains aggregate usage statistics and quota values, never access
tokens, API keys, account email addresses, or raw conversation content. Cache
files are created with mode `0600`.

## Failure behavior

Providers are collected independently. A missing CLI, unavailable endpoint, or
unreadable local database is shown inside that provider's section and does not
remove the other providers. Local statistics remain visible when only a live
quota call fails. If a provider scanner crashes during refresh, a usable prior
provider result can be retained and marked stale.

For a direct diagnostic run:

```sh
cd ~/spender
bin/spender --refresh status
```

Common checks:

- A `💸 —` header means no provider returned a live quota percentage; inspect
  the provider messages in the menu or Terminal output.
- If Claude has local stats but no quota, confirm Claude Code is signed in and
  allow Keychain access when macOS asks.
- If Codex has local stats but no quota, ensure `codex` is installed and signed
  in. Set `codex.command` to an absolute path if it is outside the standard
  Homebrew/user locations.
- If OpenCode Go has no local stats, verify the configured database/auth paths.

## Development

Run the dependency-free test suite and syntax checks with the system Python:

```sh
/usr/bin/python3 -m unittest discover -s tests -v
/usr/bin/python3 -m compileall -q spender bin swiftbar tests
git diff --check
```

The detailed design, data contract, and acceptance criteria are in
[PLAN.md](PLAN.md).

## Project layout

```text
bin/spender                 Terminal entry point
spender/                    Config, cache, aggregation, formatting, providers
swiftbar/spender.5m.py      SwiftBar launcher
scripts/install-swiftbar    Symlink installer for a chosen plugin folder
tests/                      Local fixtures and protocol/format tests
```
