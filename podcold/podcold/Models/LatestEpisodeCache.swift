import Foundation

// Persists, per subscribed podcast feed, the most recent unplayed episode found the
// last time its feed was checked. HomeVC reads this cache to build the "New Episodes"
// swim lane instantly (no network wait), while UpNextManager refreshes stale entries
// one feed at a time in the background.
class LatestEpisodeCache {
    private static let key = "latest_episode_cache"
    private static let staleInterval: TimeInterval = 45 * 60
    private static let failureRetryInterval: TimeInterval = 5 * 60

    private static func loadRaw() -> [String: [String: Any]] {
        return UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] ?? [:]
    }

    // Every entry from a single UserDefaults read. HomeVC looks up each subscription on
    // every appearance, and reading per lookup decoded the whole dict — every cached
    // episode, show notes included — twice per subscription.
    struct Snapshot {
        fileprivate let raw: [String: [String: Any]]

        // nil = no cache entry yet, or feed had no qualifying unplayed episode
        func episode(feedUrl: String) -> Episode? {
            guard let epDict = raw[feedUrl]?["episode"] as? [String: Any] else { return nil }
            return Episode.from(dict: epDict)
        }

        func isStale(feedUrl: String) -> Bool {
            guard let checkedAt = raw[feedUrl]?["checkedAt"] as? TimeInterval else { return true }
            return Date().timeIntervalSince1970 - checkedAt > LatestEpisodeCache.staleInterval
        }

        // The lane's sort key, parsed once when the entry was stored. Entries written
        // before it existed fall back to parsing the episode's date string.
        func published(feedUrl: String, episode: Episode) -> Date {
            if let ts = raw[feedUrl]?["published"] as? TimeInterval {
                return Date(timeIntervalSince1970: ts)
            }
            return episode.pubDateAsDate() ?? .distantPast
        }
    }

    static func snapshot() -> Snapshot {
        return Snapshot(raw: loadRaw())
    }

    // episode == nil records that the feed was checked but nothing qualified
    static func store(feedUrl: String, episode: Episode?) {
        var raw = loadRaw()
        var entry: [String: Any] = ["checkedAt": Date().timeIntervalSince1970]
        if let episode = episode {
            entry["episode"] = episode.toDict()
            entry["published"] = (episode.pubDateAsDate() ?? .distantPast).timeIntervalSince1970
        }
        raw[feedUrl] = entry
        UserDefaults.standard.set(raw, forKey: key)
    }

    // A failed check says nothing about the feed, so it must not overwrite what the
    // last good one found — storing nil here is what emptied the lane whenever the
    // app opened offline. Keeps the entry's episode and backdates checkedAt so the
    // feed goes stale again after failureRetryInterval rather than the full 45 min
    // (and not on every Home appearance, which on a bad link would re-burn the
    // timeout each time).
    static func deferRetry(feedUrl: String) {
        var raw = loadRaw()
        var entry = raw[feedUrl] ?? [:]
        entry["checkedAt"] = Date().timeIntervalSince1970 - staleInterval + failureRetryInterval
        raw[feedUrl] = entry
        UserDefaults.standard.set(raw, forKey: key)
    }

    // Forces every feed to be re-checked on the next refresh. Needed when the rule that
    // decides *which* episode qualifies changes — the stored entry is one already-chosen
    // episode, so nothing short of a re-parse can re-apply a new rule to it.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func remove(feedUrl: String) {
        var raw = loadRaw()
        raw.removeValue(forKey: feedUrl)
        UserDefaults.standard.set(raw, forKey: key)
    }
}
