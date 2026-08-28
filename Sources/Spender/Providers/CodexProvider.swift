import Foundation

struct CodexProvider {
    static let name = "OpenAI Codex"

    func scan(config: SpenderConfig.Codex) -> ProviderSnapshot {
        let accumulator = UsageAccumulator()
        scanPiSessions(path: config.piSessionsPath, into: accumulator)
        scanNativeSessions(home: config.home, historyDays: config.historyDays, into: accumulator)
        let local = accumulator.summary
        var result = ProviderSnapshot(providerName: Self.name)
        result.todayTokens = local.todayTokens
        result.todayPrompts = local.todayPrompts
        result.todaySessions = local.todaySessions
        result.totalPrompts = local.totalPrompts
        result.totalSessions = local.totalSessions

        do {
            let remote = try fetchLimits(config: config)
            result.authenticated = remote.authenticated
            result.tierLabel = remote.tier
            result.quotaWindows = remote.windows
        } catch {
            result.status = "Codex limits unavailable: \(error.localizedDescription)"
            result.help = "Local token history is still available."
        }
        result.ready = local.hasSource || !result.quotaWindows.isEmpty
        return result
    }

    func scanNativeSessions(
        home: String,
        historyDays: Int,
        now: Date = Date(),
        into accumulator: UsageAccumulator
    ) {
        let cutoff = historyDays > 0 ? now.addingTimeInterval(-Double(historyDays) * 86_400) : nil
        for directory in ["sessions", "archived_sessions"] {
            let root = URL(fileURLWithPath: home).appendingPathComponent(directory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            accumulator.markSource()
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let tokenNeedle = Data("\"token_count\"".utf8)
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let modified = values?.contentModificationDate ?? now
                if let cutoff, modified < cutoff { continue }
                try? forEachLine(at: url) { line, _ in
                    guard line.range(of: tokenNeedle) != nil else { return }
                    guard let entry = jsonObject(line) else { return }
                    var payload = dictionary(entry["payload"])
                    if entry["type"] as? String == "response_item" {
                        let nested = dictionary(payload["payload"])
                        if !nested.isEmpty { payload = nested }
                    }
                    guard payload["type"] as? String == "token_count" else { return }
                    let info = dictionary(payload["info"])
                    let usage = dictionary(info["last_token_usage"])
                    let cacheRead = integer(usage["cached_input_tokens"])
                    let cacheWrite = integer(usage["cache_write_input_tokens"])
                    let input = max(0, integer(usage["input_tokens"]) - cacheRead - cacheWrite)
                    accumulator.add(
                        date: parseDate(entry["timestamp"], fallback: modified),
                        session: url.path,
                        input: input,
                        output: integer(usage["output_tokens"]),
                        cacheRead: cacheRead,
                        cacheWrite: cacheWrite
                    )
                }
            }
        }
    }

    private func scanPiSessions(path: String, into accumulator: UsageAccumulator) {
        let root = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        accumulator.markSource()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        var seen = Set<String>()
        let codexNeedle = Data("\"openai-codex\"".utf8)
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try? forEachLine(at: url) { line, lineNumber in
                guard line.range(of: codexNeedle) != nil, let entry = jsonObject(line),
                      entry["type"] as? String == "message"
                else { return }
                let message = dictionary(entry["message"])
                guard message["role"] as? String == "assistant" else { return }
                let provider = message["provider"] as? String ?? ""
                let api = message["api"] as? String ?? ""
                guard provider == "openai-codex" || api.hasPrefix("openai-codex") else { return }
                let unique = "\(url.path):\((entry["id"] as? String) ?? String(lineNumber))"
                guard seen.insert(unique).inserted else { return }
                let usage = dictionary(message["usage"])
                var input = integer(usage["input"])
                let output = integer(usage["output"])
                let cacheRead = integer(usage["cacheRead"])
                let cacheWrite = integer(usage["cacheWrite"])
                if input + output + cacheRead + cacheWrite == 0 { input = integer(usage["totalTokens"]) }
                accumulator.add(
                    date: parseDate(entry["timestamp"] ?? message["timestamp"]),
                    session: url.path,
                    input: input,
                    output: output,
                    cacheRead: cacheRead,
                    cacheWrite: cacheWrite
                )
            }
        }
    }

    private func fetchLimits(config: SpenderConfig.Codex) throws -> (authenticated: Bool, tier: String, windows: [QuotaWindow]) {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.npm-global/bin", "\(home)/.local/share/mise/shims",
        ].joined(separator: ":")
        environment["PATH"] = [environment["PATH"], extra].compactMap { $0 }.joined(separator: ":")
        environment["CODEX_HOME"] = config.home
        guard let command = resolvedCommand(config.command, environment: environment) else {
            throw SpenderError.message("codex not found in PATH")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["app-server", "--stdio"]
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let inbox = RPCInbox(handle: output.fileHandleForReading)
        try process.run()
        defer {
            inbox.stop()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        func send(id: Int, method: String, params: JSONObject = [:]) throws -> JSONObject {
            let request: JSONObject = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([0x0A]))
            return try inbox.response(id: id, timeout: 8)
        }

        _ = try send(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "spender", "version": "0.2.0"],
        ])
        let initialized: JSONObject = ["jsonrpc": "2.0", "method": "initialized", "params": [:]]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: initialized) + Data([0x0A]))
        let accountResult = try send(id: 2, method: "account/read")
        let limitsResult = try send(id: 3, method: "account/rateLimits/read")
        let account = dictionary(accountResult["account"])
        let limits = dictionary(limitsResult["rateLimits"])
        let tier = (limits["planType"] as? String)
            ?? (account["planType"] as? String)
            ?? (account["type"] as? String)
            ?? ""
        var windows: [QuotaWindow] = []
        for key in ["primary", "secondary"] {
            let window = dictionary(limits[key])
            guard !window.isEmpty, let used = normalizedPercent(window["usedPercent"], percentScale: true) else { continue }
            let minutes = integer(window["windowDurationMins"])
            let label: String
            if minutes == 10_080 { label = "Weekly (7-day)" }
            else if minutes > 0 && minutes % 60 == 0 { label = "\(minutes / 60)h window" }
            else if minutes > 0 { label = "\(minutes)m window" }
            else { label = "Limit" }
            let reset = double(window["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
            windows.append(QuotaWindow(label: label, used: used, resetAt: reset))
        }
        return (!account.isEmpty, tier, windows)
    }
}

private final class RPCInbox {
    private let condition = NSCondition()
    private var messages: [JSONObject] = []
    private var buffer = Data()
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    func response(id: Int, timeout: TimeInterval) throws -> JSONObject {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let index = messages.firstIndex(where: { integer($0["id"]) == id }) {
                let message = messages.remove(at: index)
                if let error = message["error"] { throw SpenderError.message("RPC error: \(error)") }
                return dictionary(message["result"])
            }
            guard condition.wait(until: deadline) else { throw SpenderError.message("RPC request timed out") }
        }
    }

    private func receive(_ data: Data) {
        condition.lock()
        defer {
            condition.broadcast()
            condition.unlock()
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let object = try? JSONSerialization.jsonObject(with: line) as? JSONObject {
                messages.append(object)
            }
        }
    }
}
