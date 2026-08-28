# Spender implementation plan

## Goal

Build a macOS-only AI usage monitor named **Spender**. The first UI is a
SwiftBar plugin, backed by a standalone Python data layer that can also be run
from Terminal. It reports live quota utilization and reset times plus local
token, prompt, and session statistics for:

- Claude Code
- OpenAI Codex
- OpenCode Go

The implementation reuses the behavior in Blix's `ai-usage.nix` aggregator and
the three scanners under `home/przvl/scripts/ai-usage-scanners/`, while removing
Nix/Linux assumptions and making data locations configurable on macOS.

## Findings from Blix and this Mac

### Existing behavior to preserve

- The menu-bar summary is based on the most-consumed available quota window and
  displays the remaining percentage.
- Provider data uses one normalized shape: up to three quota windows, tier,
  reset timestamps, status/help text, and local daily/all-time statistics.
- Token totals include input, output, cache-read, and cache-creation tokens.
- "Prompts" means completed assistant responses with usage data, matching the
  existing scanners.
- Claude local usage comes from assistant records in project JSONL files and is
  deduplicated by message identifier.
- Codex local usage combines native Codex session JSONL with optional pi agent
  sessions that used the `openai-codex` provider.
- OpenCode Go local usage comes from completed assistant rows in its SQLite
  database, while quota percentages come from the Go usage endpoint.
- Cache writes are atomic and click/open rendering should not repeat expensive
  scans unnecessarily.

### macOS adaptations required

- Claude Code 2.1.247 stores OAuth credentials in the login Keychain service
  `Claude Code-credentials`; `~/.claude/.credentials.json` is absent. Spender
  will use Keychain first on macOS and retain a configurable credentials-file
  fallback.
- The current Codex 0.150.1 app-server requires `"jsonrpc":"2.0"` on requests
  and notifications. The Blix request shape times out without it. The existing
  `account/read` and `account/rateLimits/read` methods otherwise still return
  the expected plan and quota-window fields.
- SwiftBar is not currently installed. The repository must therefore be fully
  testable from Terminal and provide installation instructions/script without
  assuming a fixed plugin folder.
- `/usr/bin/python3` is Python 3.9.6, so the implementation will remain standard
  library-only and Python 3.9 compatible. The SwiftBar launcher will use that
  absolute interpreter path so GUI PATH differences do not break it.
- Homebrew commands may not be present in SwiftBar's GUI environment. Command
  lookup will add `/opt/homebrew/bin`, `/usr/local/bin`, and common per-user bin
  directories without replacing the inherited PATH.

## Repository shape

```text
spender/
├── bin/spender                 # terminal entry point
├── spender/
│   ├── cli.py                  # CLI orchestration
│   ├── config.py               # defaults + JSON configuration
│   ├── cache.py                # atomic cached provider snapshot
│   ├── aggregate.py            # concurrent provider loading
│   ├── format.py               # human and SwiftBar rendering
│   └── providers/
│       ├── claude.py
│       ├── codex.py
│       └── opencode_go.py
├── swiftbar/spender.5m.py      # SwiftBar-compatible launcher
├── scripts/install-swiftbar    # symlink launcher into chosen plugin folder
├── config.example.json
├── tests/                      # unittest suite with local fixtures/fakes
├── README.md
└── PLAN.md
```

No third-party Python packages are needed.

## Configuration contract

The default configuration path is:

`~/Library/Application Support/spender/config.json`

It can be overridden by `SPENDER_CONFIG` or CLI `--config`. Missing config is
valid and uses macOS defaults. Tilde and environment variables in configured
paths are expanded. Supported settings:

```json
{
  "cache": {
    "path": "~/Library/Caches/spender/providers.json",
    "ttl_seconds": 300
  },
  "claude": {
    "projects_path": "~/.claude/projects",
    "credentials_path": "~/.claude/.credentials.json",
    "keychain_service": "Claude Code-credentials",
    "keychain_account": "",
    "usage_url": "https://api.anthropic.com/api/oauth/usage"
  },
  "codex": {
    "home": "~/.codex",
    "pi_sessions_path": "~/.pi/agent/sessions",
    "command": "codex",
    "history_days": 30
  },
  "opencode_go": {
    "database_path": "~/.local/share/opencode/opencode.db",
    "auth_path": "~/.local/share/opencode/auth.json",
    "usage_url": "https://opencode.ai/zen/go/v1/usage"
  }
}
```

`CLAUDE_CONFIG_DIR` and `CODEX_HOME` override the corresponding default roots
when no explicit Spender value is configured. `SPENDER_CACHE_DIR` can override
the default cache directory, including for direct SwiftBar use.

Secrets are never written to Spender's cache or emitted in output. Keychain and
auth files are read only long enough to perform provider requests.

## Data layer

### Normalized provider result

Each provider returns a JSON-serializable dictionary with:

- identity/status: `providerName`, `tierLabel`, `ready`, `authenticated`,
  `usageStatusText`, `authHelpText`
- local today: `todayPrompts`, `todaySessions`, `todayTotalTokens`,
  `todayTokensByModel`
- local history: `recentDays`, `totalPrompts`, `totalSessions`, `activeDays`,
  `activeDates`, `modelUsage`
- quota windows: `rateLimit*`, `secondaryRateLimit*`, and optionally
  `tertiaryRateLimit*`, each with percentage, label, and ISO reset timestamp

Percentages are normalized to `0.0...1.0`; unavailable percentages are `-1`.
Remote quota failure does not discard local statistics.

### Provider implementations

1. **Claude Code**
   - Stream project JSONL rather than materializing ripgrep output.
   - Deduplicate usage records and bucket them by local calendar day/model.
   - Read OAuth JSON from macOS Keychain, then the configured credentials file
     as fallback.
   - Fetch the five-hour and seven-day windows from Anthropic's OAuth usage
     endpoint and merge them into the local result.

2. **OpenAI Codex**
   - Scan native recent/archived Codex session JSONL.
   - Optionally scan pi agent JSONL without requiring ripgrep.
   - Preserve the existing no-double-counting treatment for cached input and
     reasoning/output tokens.
   - Start `codex app-server` read-only, complete a JSON-RPC 2.0 handshake, and
     request account and rate-limit data while ignoring unrelated notifications.
   - Always terminate the child process and return local stats if RPC/auth fails.

3. **OpenCode Go**
   - Open SQLite in read-only mode so the running application is unaffected.
   - Count completed `opencode-go` assistant messages and aggregate model usage.
   - Read the Go key from the configured auth JSON only for the request.
   - Map rolling, weekly, and monthly endpoint percentages/reset timestamps to
     the normalized quota fields.

### Caching and refresh

- Cache one versioned aggregate snapshot with `generatedAt` and provider data.
- Use a five-minute TTL by default, matching the SwiftBar filename/Blix interval.
- Write through a temporary file and atomic replace.
- Serialize refreshes with `fcntl.flock` and recheck freshness after locking.
- `--refresh` bypasses freshness; a SwiftBar menu-action refresh does the same.
- A malformed cache is ignored. A provider crash is isolated to that provider,
  and a usable prior provider result may be retained with a stale/error marker.

## SwiftBar presentation

The launcher calls the same CLI/data layer as Terminal usage. Output follows
SwiftBar's documented header/body protocol:

- Header: `💸 N% left`, calculated from the highest available utilization.
- One provider section each for Claude Code, Codex, and OpenCode Go.
- Each available quota row shows used percentage, remaining percentage, and a
  human relative reset time plus local reset date/time.
- Each provider shows today's tokens, response/prompt count, and session count.
- Unavailable live limits show concise status/help text without hiding local data.
- Footer contains cache age and a `Refresh now` action.

The plugin is named `spender.5m.py`, making the normal refresh schedule explicit.
It also detects SwiftBar's menu-action refresh reason and forces a cache refresh.

## CLI

`bin/spender` will support:

- `spender json` — cached normalized snapshot for other UIs/integrations
- `spender status` — readable provider details in Terminal
- `spender swiftbar` — raw SwiftBar plugin output
- global `--config PATH` and `--refresh`

Errors go to stderr where appropriate; user-facing status remains valid output so
one unavailable provider does not make the entire menu item fail.

## Verification and acceptance criteria

### Automated

- Config merging/path expansion and environment precedence.
- Cache freshness, malformed-cache fallback, and atomic round trip.
- Claude JSONL aggregation/deduplication and quota normalization with fake HTTP.
- Codex native JSONL cumulative-token behavior and JSON-RPC response filtering.
- OpenCode SQLite filtering/token aggregation and remote-window mapping.
- Reset/time/token formatting and SwiftBar escaping/output structure.
- `python3 -m unittest discover` passes on `/usr/bin/python3` 3.9.
- `python3 -m compileall` and `git diff --check` pass.

### Live macOS smoke checks

- `bin/spender --refresh json` returns all three providers without secrets.
- Claude reports local usage and Keychain-backed quota data.
- Codex reports local usage and current app-server quota data.
- OpenCode Go reports SQLite usage and remote quota data.
- `swiftbar/spender.5m.py` exits successfully and emits a valid header, first
  separator, three provider sections, and refresh action.
- A second non-forced run uses the cache and completes quickly.

### Delivery

- README documents requirements, SwiftBar installation, plugin-folder symlink,
  Keychain behavior, configuration, CLI usage, and troubleshooting.
- Executable bits are set on entry points/install script.
- Final diff is reviewed and committed on `main` with no changes to Blix.

## Deliberate first-version boundaries

- macOS only; no Nix module or Linux credential backend.
- SwiftBar is the UI; no native AppKit/Swift process yet.
- No background daemon, notifications, charts, cost estimation, or credential
  refresh implementation.
- Provider endpoints and local file formats are unofficial integration surfaces
  where the vendor does not publish a stable usage API. Failures remain isolated
  and visible rather than crashing the menu plugin.
