import Foundation

struct ClaudeProvider {
    static let name = "Claude Code"

    func scan(config: SpenderConfig.Claude) -> ProviderSnapshot {
        let local = scanProjects(path: config.projectsPath)
        var result = ProviderSnapshot(providerName: Self.name)
        apply(local, to: &result)

        guard let credentials = readCredentials(config: config),
              let oauth = credentials["claudeAiOauth"] as? JSONObject,
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else {
            result.status = "Claude Code is not signed in"
            result.help = "Sign in with Claude Code to show live quota."
            result.ready = local.hasSource
            return result
        }

        result.authenticated = true
        result.tierLabel = (oauth["subscriptionType"] as? String)
            ?? (oauth["rateLimitTier"] as? String)
            ?? ""
        do {
            guard let url = URL(string: config.usageURL) else {
                throw SpenderError.message("invalid Claude usage URL")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Spender/0.2", forHTTPHeaderField: "User-Agent")
            let payload = try httpJSON(request, timeout: 10)
            let session = dictionary(payload["five_hour"])
            let weeklyApps = dictionary(payload["seven_day_oauth_apps"])
            let weekly = weeklyApps.isEmpty ? dictionary(payload["seven_day"]) : weeklyApps
            if let used = normalizedPercent(session["utilization"]) {
                result.quotaWindows.append(QuotaWindow(
                    label: "Session (5-hour)",
                    used: used,
                    resetAt: optionalDate(session["resets_at"])
                ))
            }
            if let used = normalizedPercent(weekly["utilization"]) {
                result.quotaWindows.append(QuotaWindow(
                    label: "Weekly (7-day)",
                    used: used,
                    resetAt: optionalDate(weekly["resets_at"])
                ))
            }
        } catch {
            result.status = "Claude limits unavailable: \(error.localizedDescription)"
            result.help = "Local token history is still available."
        }
        result.ready = local.hasSource || !result.quotaWindows.isEmpty
        return result
    }

    func scanProjects(path: String, now: Date = Date()) -> LocalUsageSummary {
        let accumulator = UsageAccumulator(now: now)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return accumulator.summary
        }
        accumulator.markSource()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return accumulator.summary }

        var seen = Set<String>()
        let usageNeedle = Data("\"usage\":".utf8)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try? forEachLine(at: url) { line, lineNumber in
                guard line.range(of: usageNeedle) != nil, let entry = jsonObject(line) else { return }
                let message = dictionary(entry["message"])
                let entryType = entry["type"] as? String
                let role = message["role"] as? String
                guard entryType == "assistant" || role == "assistant" else { return }
                var usage = dictionary(message["usage"])
                if usage.isEmpty { usage = dictionary(entry["usage"]) }
                guard !usage.isEmpty else { return }
                let messageID = (message["id"] as? String) ?? (entry["messageId"] as? String)
                let fallbackID = (entry["uuid"] as? String)
                    ?? (entry["requestId"] as? String)
                    ?? String(lineNumber)
                let unique = messageID ?? "\(url.path):\(fallbackID)"
                guard seen.insert(unique).inserted else { return }
                let timestamp = entry["timestamp"] ?? message["timestamp"]
                accumulator.add(
                    date: parseDate(timestamp, fallback: now),
                    session: (entry["sessionId"] as? String) ?? url.path,
                    input: integer(usage["input_tokens"] ?? usage["inputTokens"]),
                    output: integer(usage["output_tokens"] ?? usage["outputTokens"]),
                    cacheRead: integer(usage["cache_read_input_tokens"] ?? usage["cacheReadInputTokens"]),
                    cacheWrite: integer(usage["cache_creation_input_tokens"] ?? usage["cacheCreationInputTokens"])
                )
            }
        }
        return accumulator.summary
    }

    private func readCredentials(config: SpenderConfig.Claude) -> JSONObject? {
        if !config.keychainService.isEmpty {
            var arguments = ["find-generic-password", "-s", config.keychainService]
            if !config.keychainAccount.isEmpty {
                arguments += ["-a", config.keychainAccount]
            }
            arguments.append("-w")
            if let data = runSecurity(arguments: arguments),
               let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
                return object
            }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: config.credentialsPath)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? JSONObject
    }

    private func runSecurity(arguments: [String]) -> Data? {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + 5) == .success else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return output.fileHandleForReading.readDataToEndOfFile()
        } catch {
            return nil
        }
    }

    private func optionalDate(_ value: Any?) -> Date? {
        guard value != nil else { return nil }
        if let text = value as? String, text.isEmpty { return nil }
        return parseDate(value)
    }

    private func apply(_ local: LocalUsageSummary, to result: inout ProviderSnapshot) {
        result.todayTokens = local.todayTokens
        result.todayPrompts = local.todayPrompts
        result.todaySessions = local.todaySessions
        result.totalPrompts = local.totalPrompts
        result.totalSessions = local.totalSessions
    }
}
