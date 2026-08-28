import Foundation

enum UsageFormatting {
    static func menuBarRemaining(_ providers: [ProviderSnapshot]) -> Int? {
        let used = providers.flatMap(\.quotaWindows).map(\.used)
        guard let maximum = used.max() else { return nil }
        return Int((max(0, 1 - maximum) * 100).rounded())
    }

    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return String(value)
    }

    static func quota(_ window: QuotaWindow) -> String {
        let used = Int((window.used * 100).rounded())
        return "\(window.label): \(used)% used · \(max(0, 100 - used))% left"
    }

    static func reset(_ date: Date, now: Date = Date()) -> String {
        var seconds = max(0, Int(date.timeIntervalSince(now)))
        let days = seconds / 86_400
        seconds %= 86_400
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let relative: String
        if days > 0 { relative = "\(days)d \(hours)h" }
        else if hours > 0 { relative = "\(hours)h \(minutes)m" }
        else { relative = "\(minutes)m" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Resets in \(relative) (\(formatter.string(from: date)))"
    }

    static func updated(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date)) / 60)
        return minutes == 0 ? "Updated just now" : "Updated \(minutes)m ago"
    }
}
