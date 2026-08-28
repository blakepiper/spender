# Spender native implementation plan

## Outcome

Spender is a standalone, macOS-only menu-bar application. It owns a native
status item in the system menu bar, refreshes AI usage in the background, and
registers itself to launch at login. It has no SwiftBar, Python, package-manager,
or daemon runtime dependency.

## Acceptance criteria

- `~/Applications/Spender.app` launches as an agent app without a Dock icon.
- A dollar-circle status item appears among the right-side macOS menu extras.
- Its menu-bar presence is a compact dollar-circle icon with no text label.
- Clicking it shows Claude Code, OpenAI Codex, and OpenCode Go quota windows,
  resets, and local token/prompt/session statistics.
- Provider loading never blocks the main UI thread.
- Normal updates use a five-minute cache; manual refresh bypasses it.
- The app requests launch-at-login registration on first installed launch and
  exposes a persistent menu toggle/approval path.
- Provider credentials never enter Spender's cache or diagnostic JSON.
- One provider failure does not prevent the others from displaying.
- A release build, tests, live provider diagnostics, code signing, login-item
  status, and visible menu-bar process are verified on the target Mac.

## Architecture

```text
Spender.app
├── AppDelegate
│   ├── NSStatusItem + NSMenu
│   ├── five-minute timer
│   ├── manual refresh
│   └── native launch-at-login control
├── SnapshotLoader
│   ├── configuration
│   ├── concurrent provider collection
│   └── atomic cached UsageSnapshot
├── ClaudeProvider
│   ├── streaming project JSONL scan
│   ├── macOS Keychain lookup
│   └── Anthropic OAuth usage request
├── CodexProvider
│   ├── streaming native/pi JSONL scan
│   └── Codex app-server JSON-RPC client
└── OpenCodeGoProvider
    ├── read-only SQLite scan
    └── OpenCode Go usage request
```

Swift Package Manager builds the executable. `scripts/build-app` wraps the
optimized binary in a conventional `.app` bundle, supplies `Info.plist`, signs
it ad hoc, and verifies the signature. `scripts/install-app` copies it into the
user's Applications directory and launches it.

## Menu-bar application

AppKit's `NSStatusBar.system.statusItem(withLength:)` creates the native status
item. The button uses only the `dollarsign.circle` SF Symbol; the tightest
remaining percentage is available in its tooltip and menu. `LSUIElement=true`
suppresses Dock and application-switcher icons.

The menu is rebuilt when a snapshot, refresh state, or login-item state changes.
It contains flat, readable provider sections followed by refresh, login,
configuration, and quit actions. Quota reset timestamps are rendered as both a
relative duration and local wall-clock time.

`LaunchAtLoginController` prefers `SMAppService.mainApp`. If Service Management
reports that an ad-hoc-signed service cannot be found, it installs a scoped
per-user LaunchAgent that opens the app in the Aqua session. This target Mac has
no Apple code-signing identity, so the fallback is required here. Signed builds
retain Apple's preferred API. A `requiresApproval` result is shown explicitly
and the menu action opens System Settings → Login Items.

## Native provider data layer

### Shared local accounting

`UsageAccumulator` counts completed assistant records with non-zero usage. A
token total is input + output + cache-read + cache-write. Today uses the current
macOS calendar/time zone. Sessions are unique local session identifiers.

JSONL files are streamed in one-megabyte chunks. Buffer prefixes are removed
once per chunk, and raw byte patterns prefilter unrelated lines before JSON
decoding. This is required because the target Mac currently has roughly 900 MB
of Claude/Codex history.

### Claude Code

- Enumerate `.jsonl` under the configurable projects directory.
- Accept assistant entry/message variants, snake/camel token keys, timestamp
  variants, and message-ID fallback keys.
- Deduplicate message identifiers across files.
- Invoke `/usr/bin/security` with a five-second bound to read the existing
  `Claude Code-credentials` item. This uses the stable macOS system binary and
  avoids tying Keychain ACL prompts to every ad-hoc development build.
- Fall back to the configured credentials JSON.
- Send only the access token to the OAuth usage endpoint and normalize the
  five-hour and seven-day utilization formats used by Blix.

### OpenAI Codex

- Scan native `sessions` and `archived_sessions` modified within the configured
  history horizon, plus optional pi sessions.
- Prefilter for `token_count` or `openai-codex` before decoding.
- Use `last_token_usage`, subtract cached input from inclusive input, and retain
  cached write/read components without double counting.
- Resolve Codex across inherited, Homebrew, and common user paths.
- Start `codex app-server --stdio`, send JSON-RPC 2.0 initialize/initialized,
  and request `account/read` plus `account/rateLimits/read`.
- Read responses asynchronously, ignore notifications, apply timeouts, and
  terminate the child after the account snapshot.

### OpenCode Go

- Open the configured database with SQLite read-only/full-mutex flags.
- Select assistant message rows, accept only `providerID=opencode-go`, and skip
  empty streaming placeholders.
- Combine output and reasoning, and preserve cache read/write buckets.
- Read the auth key only for the HTTP request and normalize rolling, weekly,
  and monthly percentage/reset windows.

## Configuration and cache

The optional config remains compatible with the first Spender implementation:

`~/Library/Application Support/spender/config.json`

Environment defaults support `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, and
`SPENDER_CACHE_DIR`; `SPENDER_CONFIG` selects another file. Paths expand tilde
and environment variables.

The versioned Codable cache lives at `~/Library/Caches/spender/providers.json`
by default. Reads validate schema and modification age. Writes are atomic and
mode `0600`. It contains display aggregates only.

## Verification

1. `swift test` for percent normalization, accounting, formatting, and config.
2. Release `--json --refresh` against all real providers; assert provider order,
   readiness, quota presence, local stats, and absence of secret/account fields.
3. Measure forced refresh and cached refresh performance.
4. Build the `.app`, validate `Info.plist`, and verify its code signature.
5. Install and launch the app; confirm the `Spender` process and menu-bar item.
6. Confirm `SMAppService` or per-user LaunchAgent registration and startup.
7. Run `git diff --check`, inspect the scoped diff, and commit on `main`.
