import Foundation
import ServiceManagement

struct LaunchAtLoginController {
    enum State: String {
        case enabled
        case disabled
        case requiresApproval = "requires-approval"
    }

    private let label = "com.blake.spender.login"

    var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:
            return FileManager.default.fileExists(atPath: agentPath) ? .enabled : .disabled
        default: return .disabled
        }
    }

    var diagnostic: String {
        let backend = SMAppService.mainApp.status == .notFound ? "launch-agent" : "service-management"
        return "\(state.rawValue) (\(backend))"
    }

    func enable() throws {
        if SMAppService.mainApp.status == .notFound {
            try enableLaunchAgent()
        } else if SMAppService.mainApp.status != .enabled {
            try SMAppService.mainApp.register()
        }
    }

    func disable() throws {
        if SMAppService.mainApp.status == .notFound {
            disableLaunchAgent()
        } else if SMAppService.mainApp.status == .enabled {
            try SMAppService.mainApp.unregister()
        }
    }

    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var agentPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist").path
    }

    private func enableLaunchAgent() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw SpenderError.message("Spender must be installed as an app before enabling startup")
        }
        let path = agentPath
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: propertyList, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        do {
            try runLaunchctl(["bootstrap", "gui/\(getuid())", path])
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func disableLaunchAgent() {
        try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: agentPath)
    }

    private func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpenderError.message(detail.isEmpty ? "launchctl failed" : detail)
        }
    }
}
