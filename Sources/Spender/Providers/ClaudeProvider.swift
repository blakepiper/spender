import Foundation

struct ClaudeProvider {
    static let name = "Claude Code"
    private struct StoredCredentials {
        var object: JSONObject
        let keychain: Bool
    }

    func scan(config: SpenderConfig.Claude) -> ProviderSnapshot {
        let local = scanLocal(
            projectsPath: config.projectsPath,
            ompSessionsPath: config.ompSessionsPath
        )
        var result = ProviderSnapshot(providerName: Self.name)
        apply(local, to: &result)

        guard var credentials = readCredentials(config: config),
              var oauth = credentials.object["claudeAiOauth"] as? JSONObject,
              var token = oauth["accessToken"] as? String,
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
            let payload: JSONObject
            do {
                payload = try fetchUsage(config: config, token: token)
            } catch SpenderError.http(let status) where status == 401 || status == 429 {
                credentials = try refreshCredentials(credentials, config: config)
                oauth = dictionary(credentials.object["claudeAiOauth"])
                guard let refreshedToken = oauth["accessToken"] as? String, !refreshedToken.isEmpty else {
                    throw SpenderError.message("OAuth refresh returned no access token")
                }
                token = refreshedToken
                payload = try fetchUsage(config: config, token: token)
            }
            applyUsage(payload, to: &result)
        } catch {
            result.status = "Claude limits unavailable: \(error.localizedDescription)"
            result.help = "Local token history is still available."
        }
        result.ready = local.hasSource || !result.quotaWindows.isEmpty
        return result
    }

    func scanLocal(
        projectsPath: String,
        ompSessionsPath: String,
        now: Date = Date()
    ) -> LocalUsageSummary {
        let accumulator = UsageAccumulator(now: now)
        scanProjects(path: projectsPath, now: now, into: accumulator)
        scanOMPSessions(path: ompSessionsPath, now: now, into: accumulator)
        return accumulator.summary
    }

    private func scanProjects(path: String, now: Date, into accumulator: UsageAccumulator) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        accumulator.markSource()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

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
    }

    private func scanOMPSessions(path: String, now: Date, into accumulator: UsageAccumulator) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        accumulator.markSource()
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var seen = Set<String>()
        let anthropicNeedle = Data("\"provider\":\"anthropic\"".utf8)
        let usageNeedle = Data("\"usage\":".utf8)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try? forEachLine(at: url) { line, lineNumber in
                guard line.range(of: anthropicNeedle) != nil,
                      line.range(of: usageNeedle) != nil,
                      let entry = jsonObject(line),
                      entry["type"] as? String == "message"
                else { return }
                let message = dictionary(entry["message"])
                guard message["role"] as? String == "assistant",
                      message["provider"] as? String == "anthropic"
                else { return }
                let unique = "\(url.path):\((entry["id"] as? String) ?? String(lineNumber))"
                guard seen.insert(unique).inserted else { return }
                let usage = dictionary(message["usage"])
                var input = integer(usage["input"])
                let output = integer(usage["output"])
                let cacheRead = integer(usage["cacheRead"])
                let cacheWrite = integer(usage["cacheWrite"])
                if input + output + cacheRead + cacheWrite == 0 {
                    input = integer(usage["totalTokens"])
                }
                accumulator.add(
                    date: parseDate(entry["timestamp"] ?? message["timestamp"], fallback: now),
                    session: url.path,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
            }
        }
    }

    private func readCredentials(config: SpenderConfig.Claude) -> StoredCredentials? {
        if !config.keychainService.isEmpty {
            var arguments = ["find-generic-password", "-s", config.keychainService]
            if !config.keychainAccount.isEmpty {
                arguments += ["-a", config.keychainAccount]
            }
            arguments.append("-w")
            if let data = runSecurity(arguments: arguments),
               let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject {
                return StoredCredentials(object: object, keychain: true)
            }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: config.credentialsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? JSONObject
        else { return nil }
        return StoredCredentials(object: object, keychain: false)
    }
    private func fetchUsage(config: SpenderConfig.Claude, token: String) throws -> JSONObject {
        guard let url = URL(string: config.usageURL) else {
            throw SpenderError.message("invalid Claude usage URL")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Spender/0.2", forHTTPHeaderField: "User-Agent")
        return try httpJSON(request, timeout: 10)
    }

    private func applyUsage(_ payload: JSONObject, to result: inout ProviderSnapshot) {
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
    }

    private func refreshCredentials(
        _ credentials: StoredCredentials,
        config: SpenderConfig.Claude
    ) throws -> StoredCredentials {
        let oauth = dictionary(credentials.object["claudeAiOauth"])
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            throw SpenderError.message("Claude OAuth refresh token is missing")
        }
        guard let url = URL(string: "https://platform.claude.com/v1/oauth/token") else {
            throw SpenderError.message("invalid Claude OAuth token URL")
        }
        var body: JSONObject = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Spender/0.2", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let response = try httpJSON(request, timeout: 10)
        guard let accessToken = response["access_token"] as? String, !accessToken.isEmpty else {
            throw SpenderError.message("Claude OAuth refresh returned no access token")
        }

        if let latest = readCredentials(config: config),
           dictionary(latest.object["claudeAiOauth"])["refreshToken"] as? String != refreshToken {
            return latest
        }

        var updated = credentials
        var updatedOAuth = oauth
        updatedOAuth["accessToken"] = accessToken
        if let rotated = response["refresh_token"] as? String, !rotated.isEmpty {
            updatedOAuth["refreshToken"] = rotated
        }
        if let expiresIn = double(response["expires_in"]) {
            updatedOAuth["expiresAt"] = Date().timeIntervalSince1970 * 1_000 + expiresIn * 1_000
        }
        if let refreshExpiresIn = double(response["refresh_token_expires_in"]) {
            updatedOAuth["refreshTokenExpiresAt"] =
                Date().timeIntervalSince1970 * 1_000 + refreshExpiresIn * 1_000
        }
        if let scope = response["scope"] as? String {
            updatedOAuth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        updated.object["claudeAiOauth"] = updatedOAuth
        try writeCredentials(updated, config: config)
        return updated
    }

    private func writeCredentials(
        _ credentials: StoredCredentials,
        config: SpenderConfig.Claude
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: credentials.object)
        if credentials.keychain {
            guard let value = String(data: data, encoding: .utf8) else {
                throw SpenderError.message("Claude credentials are not valid UTF-8")
            }
            var arguments = ["add-generic-password", "-U", "-s", config.keychainService]
            if !config.keychainAccount.isEmpty {
                arguments += ["-a", config.keychainAccount]
            }
            arguments += ["-w", value]
            guard runSecurity(arguments: arguments) != nil else {
                throw SpenderError.message("could not update Claude credentials in Keychain")
            }
            return
        }
        let url = URL(fileURLWithPath: config.credentialsPath)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
