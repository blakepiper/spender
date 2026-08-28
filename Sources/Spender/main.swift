import AppKit
import Foundation

if CommandLine.arguments.contains("--login-status") {
    print(LaunchAtLoginController().diagnostic)
} else if CommandLine.arguments.contains("--json") {
    do {
        let force = CommandLine.arguments.contains("--refresh")
        let snapshot = try SnapshotLoader().load(force: force)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(snapshot))
        FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
        FileHandle.standardError.write(Data("Spender: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
} else {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
