import Foundation

// Persists, per subscribed podcast feed, the most recent unplayed episode found the
// last time its feed was checked. HomeVC reads this cache to build the "New Episodes"
// swim lane instantly (no network wait), while UpNextManager refreshes stale entries
// one feed at a time in the background.
class LatestEpisodeCache {
    private static let key = "latest_episode_cache"
    private static let staleInterval: TimeInterval = 45 * 60

    private static func loadRaw() -> [String: [String: Any]] {
        return UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    }

    // nil = no cache entry yet, or feed had no qualifying unplayed episode
    static func cachedEpisode(feedUrl: String) -> Episode? {
        guard let entry = loadRaw()[feedUrl], let epDict = entry["episode"] as? [String: Any] else { return nil }
        return Episode.from(dict: epDict)
    }

    static func isStale(feedUrl: String) -> Bool {
        guard let entry = loadRaw()[feedUrl], let checkedAt = entry["checkedAt"] as? TimeInterval else { return true }
        return Date().timeIntervalSince1970 - checkedAt > staleInterval
    }

    // episode == nil records that the feed was checked but nothing qualified
    static func store(feedUrl: String, episode: Episode?) {
        var raw = loadRaw()
        var entry: [String: Any] = ["checkedAt": Date().timeIntervalSince1970]
        if let episode = episode { entry["episode"] = episode.toDict() }
        raw[feedUrl] = entry
        UserDefaults.standard.set(raw, forKey: key)
    }

    static func remove(feedUrl: String) {
        var raw = loadRaw()
        raw.removeValue(forKey: feedUrl)
        UserDefaults.standard.set(raw, forKey: key)
    }
}
