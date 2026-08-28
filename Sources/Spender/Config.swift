import Foundation

struct SpenderConfig {
    struct Cache {
        var path: String
        var ttl: TimeInterval
    }

    struct Claude {
        var projectsPath: String
        var credentialsPath: String
        var keychainService: String
        var keychainAccount: String
        var usageURL: String
    }

    struct Codex {
        var home: String
        var piSessionsPath: String
        var command: String
        var historyDays: Int
    }

    struct OpenCodeGo {
        var databasePath: String
        var authPath: String
        var usageURL: String
    }

    var cache: Cache
    var claude: Claude
    var codex: Codex
    var openCodeGo: OpenCodeGo

    static func configurationPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["SPENDER_CONFIG"], !override.isEmpty {
            return expandPath(override, environment: environment)
        }
        return NSString(string: "~/Library/Application Support/spender/config.json").expandingTildeInPath
    }

    static func load(
        path: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SpenderConfig {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeRoot = environment["CLAUDE_CONFIG_DIR"] ?? "\(home)/.claude"
        let codexRoot = environment["CODEX_HOME"] ?? "\(home)/.codex"
        let cacheRoot = environment["SPENDER_CACHE_DIR"] ?? "\(home)/Library/Caches/spender"
        var result = SpenderConfig(
            cache: Cache(path: "\(cacheRoot)/providers.json", ttl: 300),
            claude: Claude(
                projectsPath: "\(claudeRoot)/projects",
                credentialsPath: "\(claudeRoot)/.credentials.json",
                keychainService: "Claude Code-credentials",
                keychainAccount: NSUserName(),
                usageURL: "https://api.anthropic.com/api/oauth/usage"
            ),
            codex: Codex(
                home: codexRoot,
                piSessionsPath: "\(home)/.pi/agent/sessions",
                command: "codex",
                historyDays: 30
            ),
            openCodeGo: OpenCodeGo(
                databasePath: "\(home)/.local/share/opencode/opencode.db",
                authPath: "\(home)/.local/share/opencode/auth.json",
                usageURL: "https://opencode.ai/zen/go/v1/usage"
            )
        )

        let source = path.map { expandPath($0, environment: environment) }
            ?? configurationPath(environment: environment)
        if FileManager.default.fileExists(atPath: source) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: source)))
            guard let root = object as? [String: Any] else {
                throw SpenderError.message("Configuration root must be an object: \(source)")
            }
            if let section = root["cache"] as? [String: Any] {
                result.cache.path = string(section, "path") ?? result.cache.path
                result.cache.ttl = max(0, number(section, "ttl_seconds") ?? result.cache.ttl)
            }
            if let section = root["claude"] as? [String: Any] {
                result.claude.projectsPath = string(section, "projects_path") ?? result.claude.projectsPath
                result.claude.credentialsPath = string(section, "credentials_path") ?? result.claude.credentialsPath
                result.claude.keychainService = string(section, "keychain_service") ?? result.claude.keychainService
                result.claude.keychainAccount = string(section, "keychain_account") ?? result.claude.keychainAccount
                result.claude.usageURL = string(section, "usage_url") ?? result.claude.usageURL
            }
            if let section = root["codex"] as? [String: Any] {
                result.codex.home = string(section, "home") ?? result.codex.home
                result.codex.piSessionsPath = string(section, "pi_sessions_path") ?? result.codex.piSessionsPath
                result.codex.command = string(section, "command") ?? result.codex.command
                result.codex.historyDays = max(0, Int(number(section, "history_days") ?? Double(result.codex.historyDays)))
            }
            if let section = root["opencode_go"] as? [String: Any] {
                result.openCodeGo.databasePath = string(section, "database_path") ?? result.openCodeGo.databasePath
                result.openCodeGo.authPath = string(section, "auth_path") ?? result.openCodeGo.authPath
                result.openCodeGo.usageURL = string(section, "usage_url") ?? result.openCodeGo.usageURL
            }
        }

        result.cache.path = expandPath(result.cache.path, environment: environment)
        result.claude.projectsPath = expandPath(result.claude.projectsPath, environment: environment)
        result.claude.credentialsPath = expandPath(result.claude.credentialsPath, environment: environment)
        result.codex.home = expandPath(result.codex.home, environment: environment)
        result.codex.piSessionsPath = expandPath(result.codex.piSessionsPath, environment: environment)
        result.openCodeGo.databasePath = expandPath(result.openCodeGo.databasePath, environment: environment)
        result.openCodeGo.authPath = expandPath(result.openCodeGo.authPath, environment: environment)
        return result
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func number(_ object: [String: Any], _ key: String) -> Double? {
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? String { return Double(value) }
        return nil
    }

    private static func expandPath(_ value: String, environment: [String: String]) -> String {
        var result = NSString(string: value).expandingTildeInPath
        for (key, replacement) in environment {
            result = result.replacingOccurrences(of: "${\(key)}", with: replacement)
            result = result.replacingOccurrences(of: "$\(key)", with: replacement)
        }
        return URL(fileURLWithPath: result).standardized.path
    }
}
