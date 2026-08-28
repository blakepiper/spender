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
            "SPENDER_CACHE_DIR": root.appendingPathComponent("cache").path,
            "SPENDER_CONFIG": root.appendingPathComponent("missing.json").path,
        ]
        let config = try SpenderConfig.load(environment: environment)
        XCTAssertEqual(config.claude.projectsPath, root.appendingPathComponent("claude/projects").path)
        XCTAssertEqual(config.codex.home, root.appendingPathComponent("codex").path)
        XCTAssertEqual(config.cache.path, root.appendingPathComponent("cache/providers.json").path)
    }
}
