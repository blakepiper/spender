import Foundation

struct QuotaWindow: Codable, Equatable {
    let label: String
    let used: Double
    let resetAt: Date?
}

struct ProviderSnapshot: Codable, Equatable {
    let providerName: String
    var tierLabel = ""
    var ready = false
    var authenticated = false
    var quotaWindows: [QuotaWindow] = []
    var todayTokens = 0
    var todayPrompts = 0
    var todaySessions = 0
    var totalPrompts = 0
    var totalSessions = 0
    var status = ""
    var help = ""
    var stale = false

    static func unavailable(_ name: String, error: String) -> ProviderSnapshot {
        var result = ProviderSnapshot(providerName: name)
        result.status = error
        result.help = error
        return result
    }
}

struct UsageSnapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    var providers: [ProviderSnapshot]
    var fromCache: Bool

    init(generatedAt: Date = Date(), providers: [ProviderSnapshot], fromCache: Bool = false) {
        schemaVersion = 2
        self.generatedAt = generatedAt
        self.providers = providers
        self.fromCache = fromCache
    }
}

struct LocalUsageSummary: Equatable {
    var hasSource = false
    var todayTokens = 0
    var todayPrompts = 0
    var todaySessions = 0
    var totalPrompts = 0
    var totalSessions = 0
}
