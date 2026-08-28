import Foundation
import SQLite3

struct OpenCodeGoProvider {
    static let name = "OpenCode Go"

    func scan(config: SpenderConfig.OpenCodeGo) -> ProviderSnapshot {
        let local = scanDatabase(path: config.databasePath)
        var result = ProviderSnapshot(providerName: Self.name)
        result.todayTokens = local.todayTokens
        result.todayPrompts = local.todayPrompts
        result.todaySessions = local.todaySessions
        result.totalPrompts = local.totalPrompts
        result.totalSessions = local.totalSessions

        guard let apiKey = readAPIKey(path: config.authPath), !apiKey.isEmpty else {
            result.help = "Connect OpenCode Go to show live quota."
            result.ready = local.hasSource
            return result
        }
        result.authenticated = true
        result.tierLabel = "Go"
        do {
            guard let url = URL(string: config.usageURL) else {
                throw SpenderError.message("invalid OpenCode Go usage URL")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Spender/0.2", forHTTPHeaderField: "User-Agent")
            let payload = try httpJSON(request, timeout: 5)
            let usage = dictionary(payload["usage"])
            for (key, label) in [
                ("rolling", "5-hour window"),
                ("weekly", "Weekly window"),
                ("monthly", "Monthly window"),
            ] {
                let window = dictionary(usage[key])
                guard let used = normalizedPercent(window["percent"], percentScale: true) else { continue }
                let reset = (window["resetsAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                result.quotaWindows.append(QuotaWindow(label: label, used: used, resetAt: reset))
            }
        } catch {
            result.status = "OpenCode Go live limits unavailable"
            result.help = "Local token history is still available: \(error.localizedDescription)"
        }
        result.ready = local.hasSource || !result.quotaWindows.isEmpty
        return result
    }

    func scanDatabase(path: String, now: Date = Date()) -> LocalUsageSummary {
        let accumulator = UsageAccumulator(now: now)
        guard FileManager.default.fileExists(atPath: path) else { return accumulator.summary }
        accumulator.markSource()
        var database: OpaquePointer?
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else {
            if database != nil { sqlite3_close(database) }
            return accumulator.summary
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let query = "SELECT id, session_id, time_created, data FROM message"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return accumulator.summary
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let sessionText = sqlite3_column_text(statement, 1),
                  let dataText = sqlite3_column_text(statement, 3),
                  let data = String(cString: dataText).data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  message["role"] as? String == "assistant",
                  message["providerID"] as? String == "opencode-go"
            else { continue }
            let tokens = dictionary(message["tokens"])
            let cache = dictionary(tokens["cache"])
            let input = integer(tokens["input"])
            let output = integer(tokens["output"]) + integer(tokens["reasoning"])
            let cacheRead = integer(cache["read"])
            let cacheWrite = integer(cache["write"])
            let cost = double(message["cost"]) ?? 0
            let finish = message["finish"] as? String ?? ""
            if cost <= 0 && (input + output + cacheRead + cacheWrite <= 0 || finish.isEmpty) { continue }
            var timestamp = Double(sqlite3_column_int64(statement, 2))
            if timestamp <= 0 {
                timestamp = double(dictionary(message["time"])["created"]) ?? 0
            }
            guard timestamp > 0 else { continue }
            accumulator.add(
                date: Date(timeIntervalSince1970: timestamp / 1000),
                session: String(cString: sessionText),
                input: input,
                output: output,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            )
        }
        return accumulator.summary
    }

    private func readAPIKey(path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
              let provider = root["opencode-go"] as? JSONObject
        else { return nil }
        return provider["key"] as? String
    }
}
