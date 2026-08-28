import Foundation
import XCTest
@testable import Spender

final class SpenderTests: XCTestCase {
    func testPercentNormalization() {
        XCTAssertEqual(normalizedPercent(25), 0.25)
        XCTAssertEqual(normalizedPercent(0.5), 0.5)
        XCTAssertEqual(normalizedPercent(25, percentScale: true), 0.25)
        XCTAssertNil(normalizedPercent("invalid"))
    }

    func testAccumulatorCountsTodayAndSessions() {
        let now = Date(timeIntervalSince1970: 1_787_845_600)
        let accumulator = UsageAccumulator(now: now, calendar: Calendar(identifier: .gregorian))
        accumulator.markSource()
        accumulator.add(date: now, session: "one", input: 10, output: 5, cacheRead: 3, cacheWrite: 2)
        accumulator.add(date: now, session: "one", input: 4, output: 1, cacheRead: 0, cacheWrite: 0)
        let result = accumulator.summary
        XCTAssertTrue(result.hasSource)
        XCTAssertEqual(result.todayTokens, 25)
        XCTAssertEqual(result.todayPrompts, 2)
        XCTAssertEqual(result.todaySessions, 1)
    }

    func testFormattingUsesTightestQuota() {
        var claude = ProviderSnapshot(providerName: "Claude")
        claude.quotaWindows = [QuotaWindow(label: "Session", used: 0.75, resetAt: nil)]
        var codex = ProviderSnapshot(providerName: "Codex")
        codex.quotaWindows = [QuotaWindow(label: "Weekly", used: 0.4, resetAt: nil)]
        XCTAssertEqual(UsageFormatting.menuBarRemaining([claude, codex]), 25)
        XCTAssertEqual(UsageFormatting.tokens(1_250_000), "1.2M")
    }

    func testConfigurationEnvironmentDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let environment = [
            "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path,
            "CODEX_HOME": root.appendingPathComponent("codex").path,
            "OMP_HOME": root.appendingPathComponent("omp").path,
            "SPENDER_CACHE_DIR": root.appendingPathComponent("cache").path,
            "SPENDER_CONFIG": root.appendingPathComponent("missing.json").path,
        ]
        let config = try SpenderConfig.load(environment: environment)
        XCTAssertEqual(config.claude.projectsPath, root.appendingPathComponent("claude/projects").path)
        XCTAssertEqual(config.claude.ompSessionsPath, root.appendingPathComponent("omp/agent/sessions").path)
        XCTAssertEqual(config.codex.home, root.appendingPathComponent("codex").path)
        XCTAssertEqual(config.cache.path, root.appendingPathComponent("cache/providers.json").path)
    }

    func testClaudeScannerCountsAnthropicUsageFromOMPSessions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("agent/sessions/-project")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_787_922_000)
        let anthropic: JSONObject = [
            "type": "message",
            "id": "anthropic-turn",
            "timestamp": now.timeIntervalSince1970,
            "message": [
                "role": "assistant",
                "provider": "anthropic",
                "model": "claude-sonnet-5",
                "usage": [
                    "input": 2,
                    "output": 97,
                    "cacheRead": 34_073,
                    "cacheWrite": 1_237,
                    "totalTokens": 35_409,
                ],
            ],
        ]
        let openAI: JSONObject = [
            "type": "message",
            "id": "openai-turn",
            "timestamp": now.timeIntervalSince1970,
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "usage": ["input": 100, "output": 50],
            ],
        ]
        let data = try [anthropic, openAI]
            .map { try JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { result, line in
                result.append(line)
                result.append(0x0A)
            }
        try data.write(to: sessions.appendingPathComponent("session.jsonl"))

        let result = ClaudeProvider().scanLocal(
            projectsPath: root.appendingPathComponent("missing-projects").path,
            ompSessionsPath: root.appendingPathComponent("agent/sessions").path,
            now: now
        )

        XCTAssertTrue(result.hasSource)
        XCTAssertEqual(result.todayTokens, 35_409)
        XCTAssertEqual(result.todayPrompts, 1)
        XCTAssertEqual(result.todaySessions, 1)
        XCTAssertEqual(result.totalPrompts, 1)
        XCTAssertEqual(result.totalSessions, 1)
    }

    func testFailedRefreshPreservesUnexpiredLastKnownLimits() {
        let now = Date(timeIntervalSince1970: 1_787_922_000)
        var priorClaude = ProviderSnapshot(providerName: ClaudeProvider.name)
        priorClaude.quotaWindows = [
            QuotaWindow(label: "Session (5-hour)", used: 0.31, resetAt: now.addingTimeInterval(3_600)),
            QuotaWindow(label: "Expired weekly", used: 0.9, resetAt: now.addingTimeInterval(-1)),
        ]
        let previous = UsageSnapshot(generatedAt: now.addingTimeInterval(-300), providers: [priorClaude])
        var failedClaude = ProviderSnapshot(providerName: ClaudeProvider.name)
        failedClaude.status = "Claude limits unavailable: HTTP 429"
        failedClaude.todayTokens = 123

        let result = SnapshotLoader.preservingLastKnownQuotas(
            [failedClaude],
            previous: previous,
            now: now
        )

        XCTAssertEqual(result[0].quotaWindows, [priorClaude.quotaWindows[0]])
        XCTAssertEqual(result[0].todayTokens, 123)
        XCTAssertEqual(result[0].status, "")
        XCTAssertEqual(result[0].help, "Showing last-known limits while live refresh is unavailable.")
        XCTAssertTrue(result[0].stale)
        XCTAssertTrue(result[0].ready)
    }
}
