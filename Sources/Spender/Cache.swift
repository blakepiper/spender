import Foundation

struct SnapshotCache {
    let path: String
    let ttl: TimeInterval

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    func read(requireFresh: Bool) -> UsageSnapshot? {
        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              (!requireFresh || (ttl > 0 && Date().timeIntervalSince(modified) <= ttl)),
              let data = try? Data(contentsOf: url),
              var snapshot = try? decoder.decode(UsageSnapshot.self, from: data),
              snapshot.schemaVersion == 2
        else { return nil }
        snapshot.fromCache = true
        return snapshot
    }

    func write(_ snapshot: UsageSnapshot) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
