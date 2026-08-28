import Foundation

struct SnapshotLoader {
    func load(force: Bool) throws -> UsageSnapshot {
        let config = try SpenderConfig.load()
        let cache = SnapshotCache(path: config.cache.path, ttl: config.cache.ttl)
        if !force, let cached = cache.read(requireFresh: true) {
            return cached
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var results = Array<ProviderSnapshot?>(repeating: nil, count: 3)
        let tasks: [(Int, () -> ProviderSnapshot)] = [
            (0, { ClaudeProvider().scan(config: config.claude) }),
            (1, { CodexProvider().scan(config: config.codex) }),
            (2, { OpenCodeGoProvider().scan(config: config.openCodeGo) }),
        ]
        for (index, task) in tasks {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let value = task()
                lock.lock()
                results[index] = value
                lock.unlock()
                group.leave()
            }
        }
        group.wait()

        let providers = results.enumerated().map { index, provider in
            provider ?? ProviderSnapshot.unavailable(
                [ClaudeProvider.name, CodexProvider.name, OpenCodeGoProvider.name][index],
                error: "Provider unavailable"
            )
        }
        let snapshot = UsageSnapshot(providers: providers)
        try? cache.write(snapshot)
        return snapshot
    }
}
