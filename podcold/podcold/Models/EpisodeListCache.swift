import Foundation

// Per-feed cache of the parsed episode list, so EpisodeListVC can show a podcast's
// episodes the instant it is pushed instead of leaving a spinner on screen for the
// feed download + XML parse (2-8 s on a 4S over 3G).
//
// Stored as one plist per feed under ~/Library/Caches (iOS purges it under storage
// pressure) rather than in UserDefaults: 20 episodes with their summaries runs to
// ~100 KB per feed, and UserDefaults rewrites its *entire* plist on every change —
// which is exactly the main-thread stall the rest of this app works to avoid.
class EpisodeListCache {

    private static let dir: String = {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let base = dirs.first ?? NSTemporaryDirectory()
        let d = (base as NSString).appendingPathComponent("com.podcold.feeds")
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        return d
    }()

    // Static per the queue rule — a queue per store() call would spawn an OS thread
    // per feed refresh.
    private static let writeQueue = DispatchQueue(label: "com.podcold.feedcache")
    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func path(for feedUrl: String) -> String {
        let safe = feedUrl.components(separatedBy: nonAlphanumerics).joined(separator: "_")
        let key = safe.count > 120 ? String(safe.suffix(120)) : safe
        return (dir as NSString).appendingPathComponent("\(key).plist")
    }

    // Synchronous: the whole point is to have rows ready for the first reloadData.
    // A ~100 KB plist parse plus 20 Episode inits is a couple of ms — far less than
    // the push animation it runs inside.
    static func cached(feedUrl: String) -> [Episode] {
        guard let arr = NSArray(contentsOfFile: path(for: feedUrl)) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }

    static func store(feedUrl: String, episodes: [Episode]) {
        guard !episodes.isEmpty else { return }
        let dicts = episodes.map { $0.toDict() }
        let file = path(for: feedUrl)
        writeQueue.async {
            (dicts as NSArray).write(toFile: file, atomically: true)
        }
    }

    static func remove(feedUrl: String) {
        let file = path(for: feedUrl)
        writeQueue.async {
            try? FileManager.default.removeItem(atPath: file)
        }
    }
}
