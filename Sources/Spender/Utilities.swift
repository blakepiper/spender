import Foundation

typealias JSONObject = [String: Any]

enum SpenderError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

func integer(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return max(0, Int(number.doubleValue.rounded())) }
    if let string = value as? String, let number = Double(string) { return max(0, Int(number.rounded())) }
    return 0
}

func double(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

func dictionary(_ value: Any?) -> JSONObject {
    value as? JSONObject ?? [:]
}

func normalizedPercent(_ value: Any?, percentScale: Bool = false) -> Double? {
    guard var result = double(value), result.isFinite else { return nil }
    if percentScale || result > 1 { result /= 100 }
    return min(1, max(0, result))
}

func parseDate(_ value: Any?, fallback: Date = Date()) -> Date {
    if let number = double(value) {
        return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
    }
    guard let text = value as? String, !text.isEmpty else { return fallback }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text) ?? fallback
}

func forEachLine(at url: URL, _ body: (Data, Int) throws -> Void) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var pending = Data()
    var lineNumber = 0
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
        pending.append(chunk)
        var lineStart = pending.startIndex
        while let newline = pending[lineStart...].firstIndex(of: 0x0A) {
            lineNumber += 1
            try body(pending[lineStart..<newline], lineNumber)
            lineStart = pending.index(after: newline)
        }
        if lineStart > pending.startIndex {
            pending.removeSubrange(pending.startIndex..<lineStart)
        }
    }
    if !pending.isEmpty {
        lineNumber += 1
        try body(pending, lineNumber)
    }
}

func jsonObject(_ data: Data) -> JSONObject? {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
    return object as? JSONObject
}

func httpJSON(_ request: URLRequest, timeout: TimeInterval) throws -> JSONObject {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: configuration)
    let semaphore = DispatchSemaphore(value: 0)
    var responseData: Data?
    var responseError: Error?
    var statusCode = 0
    let task = session.dataTask(with: request) { data, response, error in
        responseData = data
        responseError = error
        statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
        task.cancel()
        throw SpenderError.message("request timed out")
    }
    if let error = responseError { throw error }
    guard (200..<300).contains(statusCode), let data = responseData else {
        throw SpenderError.message("HTTP \(statusCode)")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
        throw SpenderError.message("invalid JSON response")
    }
    return object
}

func resolvedCommand(_ command: String, environment: [String: String]) -> String? {
    if command.contains("/") {
        return FileManager.default.isExecutableFile(atPath: command) ? command : nil
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let inherited = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
    let paths = inherited + [
        "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
        "\(home)/.npm-global/bin", "\(home)/.local/share/mise/shims",
    ]
    for path in paths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(command).path
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
