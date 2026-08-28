import Foundation

struct SnapshotLoader {
    func load(force: Bool) throws -> UsageSnapshot {
        let config = try SpenderConfig.load()
        let cache = SnapshotCache(path: config.cache.path, ttl: config.cache.ttl)
        let previous = cache.read(requireFresh: false)
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

        let current = results.enumerated().map { index, provider in
            provider ?? ProviderSnapshot.unavailable(
                [ClaudeProvider.name, CodexProvider.name, OpenCodeGoProvider.name][index],
                error: "Provider unavailable"
            )
        }
        let providers = Self.preservingLastKnownQuotas(current, previous: previous)
        let snapshot = UsageSnapshot(providers: providers)
        try? cache.write(snapshot)
        return snapshot
    }

    static func preservingLastKnownQuotas(
        _ providers: [ProviderSnapshot],
        previous: UsageSnapshot?,
        now: Date = Date()
    ) -> [ProviderSnapshot] {
        guard let previous else { return providers }
        return providers.map { provider in
            guard provider.quotaWindows.isEmpty,
                  !provider.status.isEmpty,
                  let prior = previous.providers.first(where: {
                      $0.providerName == provider.providerName
                  })
            else { return provider }
            let usable = prior.quotaWindows.filter { window in
                window.resetAt.map { $0 > now } ?? true
            }
            guard !usable.isEmpty else { return provider }
            var merged = provider
            merged.quotaWindows = usable
            merged.status = ""
            merged.help = "Showing last-known limits while live refresh is unavailable."
            merged.stale = true
            merged.ready = true
            return merged
        }
    }
}
