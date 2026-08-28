import Foundation

final class UsageAccumulator {
    private let calendar: Calendar
    private let today: Date
    private(set) var hasSource = false
    private(set) var todayTokens = 0
    private(set) var todayPrompts = 0
    private(set) var totalPrompts = 0
    private var todaySessions = Set<String>()
    private var sessions = Set<String>()

    init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
    }

    func markSource() {
        hasSource = true
    }

    func add(
        date: Date,
        session: String,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int
    ) {
        let total = max(0, input) + max(0, output) + max(0, cacheRead) + max(0, cacheWrite)
        guard total > 0 else { return }
        totalPrompts += 1
        sessions.insert(session)
        if calendar.isDate(date, inSameDayAs: today) {
            todayPrompts += 1
            todayTokens += total
            todaySessions.insert(session)
        }
    }

    var summary: LocalUsageSummary {
        LocalUsageSummary(
            hasSource: hasSource,
            todayTokens: todayTokens,
            todayPrompts: todayPrompts,
            todaySessions: todaySessions.count,
            totalPrompts: totalPrompts,
            totalSessions: sessions.count
        )
    }
}
