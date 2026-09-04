import Foundation

class Episode: NSObject {
    var guid: String = ""
    var title: String = ""
    var audioUrl: String = ""
    var pubDate: String = ""
    var duration: String = ""
    var summary: String = ""
    var artworkUrl: String = ""
    var podcastTitle: String = ""

    func savedPosition() -> Double {
        return UserDefaults.standard.double(forKey: "pos_\(guid)")
    }
    func savePosition(_ seconds: Double) {
        UserDefaults.standard.set(seconds, forKey: "pos_\(guid)")
    }

    // MARK: - Duration
    // Feeds are inconsistent: itunes:duration may be plain seconds ("3600"),
    // "MM:SS" or "HH:MM:SS", and plenty of feeds omit it entirely. The real
    // length is only known once AVPlayer has loaded the asset, so it is cached
    // per guid the first time playback reports it.

    func savedDuration() -> Double {
        return UserDefaults.standard.double(forKey: "dur_\(guid)")
    }

    func saveDuration(_ seconds: Double) {
        // Written from the 1-s time observer — only touch UserDefaults on change
        guard seconds > 0, abs(savedDuration() - seconds) > 1 else { return }
        UserDefaults.standard.set(seconds, forKey: "dur_\(guid)")
    }

    // Best known total length in seconds; 0 when unknown.
    func totalDuration() -> Double {
        let cached = savedDuration()
        return cached > 0 ? cached : Episode.parseDuration(duration)
    }

    static func parseDuration(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return 0 }
        var total: Double = 0
        for part in t.components(separatedBy: ":") {
            guard let v = Double(part) else { return 0 }
            total = total * 60 + v
        }
        return total
    }

    // MARK: - Played tracking
    // savedPosition() alone cannot distinguish "never started" from "marked done"
    // (both are 0), so completed episodes are tracked separately by guid.
    private static let playedGuidsKey = "played_episode_guids"

    static func isPlayed(guid: String) -> Bool {
        return (UserDefaults.standard.stringArray(forKey: playedGuidsKey) ?? []).contains(guid)
    }

    static func markPlayed(guid: String) {
        var set = Set(UserDefaults.standard.stringArray(forKey: playedGuidsKey) ?? [])
        set.insert(guid)
        UserDefaults.standard.set(Array(set), forKey: playedGuidsKey)
    }

    // MARK: - Publish date parsing (for sorting the "New Episodes" swim lane)
    private static let dateFormatters: [DateFormatter] = {
        ["EEE, dd MMM yyyy HH:mm:ss ZZZ",
         "EEE, dd MMM yyyy HH:mm:ss Z",
         "dd MMM yyyy HH:mm:ss ZZZ",
         "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
         "yyyy-MM-dd'T'HH:mm:ssZ"].map { format in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            return f
        }
    }()

    func pubDateAsDate() -> Date? {
        guard !pubDate.isEmpty else { return nil }
        for f in Episode.dateFormatters {
            if let d = f.date(from: pubDate) { return d }
        }
        return nil
    }

    func localPath() -> String? {
        let path = localPathForWriting()
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }
    private static let docsDir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    func localPathForWriting() -> String {
        let safe = guid.components(separatedBy: Episode.nonAlphanumerics).joined(separator: "_")
        return (Episode.docsDir as NSString).appendingPathComponent("\(safe).mp3")
    }

    func fileSizeString() -> String {
        guard let path = localPath(),
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = attrs[.size] as? Int else { return "" }
        let mb = Double(bytes) / 1_000_000
        return mb >= 1 ? String(format: "%.0f MB", mb) : String(format: "%.1f MB", mb)
    }

    func toDict() -> [String: Any] {
        return ["guid": guid, "title": title, "audioUrl": audioUrl,
                "pubDate": pubDate, "duration": duration, "summary": summary,
                "artworkUrl": artworkUrl, "podcastTitle": podcastTitle]
    }

    static func from(dict: [String: Any]) -> Episode {
        let e = Episode()
        e.guid         = dict["guid"]         as? String ?? ""
        e.title        = dict["title"]        as? String ?? ""
        e.audioUrl     = dict["audioUrl"]     as? String ?? ""
        e.pubDate      = dict["pubDate"]      as? String ?? ""
        e.duration     = dict["duration"]     as? String ?? ""
        e.summary      = dict["summary"]      as? String ?? ""
        e.artworkUrl   = dict["artworkUrl"]   as? String ?? ""
        e.podcastTitle = dict["podcastTitle"] as? String ?? ""
        return e
    }

    // MARK: - Recents

    static let recentsKey = "recent_episodes"

    static func loadRecents() -> [Episode] {
        guard let arr = UserDefaults.standard.array(forKey: recentsKey) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }

    static func saveRecents(_ episodes: [Episode]) {
        UserDefaults.standard.set(episodes.map { $0.toDict() }, forKey: recentsKey)
    }

    // MARK: - Downloads

    static let downloadsKey = "downloaded_episodes"

    static func loadDownloads() -> [Episode] {
        guard let arr = UserDefaults.standard.array(forKey: downloadsKey) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }.filter { $0.localPath() != nil }
    }

    static func addToDownloads(_ episode: Episode) {
        var list = loadAllDownloadRecords()
        list.removeAll { $0.guid == episode.guid }
        list.insert(episode, at: 0)
        UserDefaults.standard.set(list.map { $0.toDict() }, forKey: downloadsKey)
    }

    static func removeFromDownloads(guid: String) {
        var list = loadAllDownloadRecords()
        list.removeAll { $0.guid == guid }
        UserDefaults.standard.set(list.map { $0.toDict() }, forKey: downloadsKey)
    }

    // MARK: - Auto-delete finished downloads

    private static let autoDeleteKey = "auto_delete_finished_downloads"

    // Off by default — bool(forKey:) returns false when unset.
    static var autoDeleteFinished: Bool {
        get { return UserDefaults.standard.bool(forKey: autoDeleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDeleteKey) }
    }

    // Removes the downloaded file and its record. No-op if not downloaded.
    func deleteDownload() {
        if let path = localPath() {
            try? FileManager.default.removeItem(atPath: path)
        }
        Episode.removeFromDownloads(guid: guid)
    }

    func autoDeleteIfEnabled() {
        guard Episode.autoDeleteFinished else { return }
        deleteDownload()
    }

    // Raw load without file existence check (used internally)
    private static func loadAllDownloadRecords() -> [Episode] {
        guard let arr = UserDefaults.standard.array(forKey: downloadsKey) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }
}
