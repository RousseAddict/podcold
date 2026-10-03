import Foundation

struct BackupManager {

    static let filePrefix = "podcold-backup-"

    private static var docsDir: String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
    }

    // MARK: - Export

    struct ExportResult {
        let filePath: String
        let subscriptionCount: Int
        let recentCount: Int
        let downloadCount: Int
        let positionCount: Int
        let playedCount: Int
        let queueCount: Int
    }

    // Payload version 2 adds played/queue/durations/autoDeleteFinished.
    // Version 1 files still import — the new keys simply read as empty.
    static let payloadVersion = 2

    static func export() -> ExportResult? {
        let ud = UserDefaults.standard
        let subscriptions = ud.array(forKey: Podcast.subscriptionsKey) as? [[String: Any]] ?? []
        let recents       = ud.array(forKey: Episode.recentsKey)       as? [[String: Any]] ?? []
        let downloads     = ud.array(forKey: Episode.downloadsKey)     as? [[String: Any]] ?? []
        let queue         = ud.array(forKey: PlayQueue.storageKey)     as? [[String: Any]] ?? []
        let played        = ud.stringArray(forKey: Episode.playedGuidsKey) ?? []

        // One pass over dictionaryRepresentation for both prefixes — it is a full
        // copy of the defaults, so walking it twice is pure waste.
        var positions: [String: Double] = [:]
        var durations: [String: Double] = [:]
        for (key, val) in ud.dictionaryRepresentation() {
            guard let d = val as? Double, d > 0 else { continue }
            if      key.hasPrefix("pos_") { positions[key] = d }
            else if key.hasPrefix("dur_") { durations[key] = d }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: Date())

        let payload: [String: Any] = [
            "version":       payloadVersion,
            "exportDate":    dateStr,
            "subscriptions": subscriptions,
            "recents":       recents,
            "downloads":     downloads,
            "positions":     positions,
            // Without these a restored device replayed as if nothing had ever been
            // finished: every latest episode reappeared in New Episodes, the queue
            // was gone, and Continue Listening lost its progress-bar totals.
            "played":        played,
            "queue":         queue,
            "durations":     durations,
            "autoDeleteFinished": Episode.autoDeleteFinished
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        else { return nil }

        let name = "\(filePrefix)\(dateStr).json"
        let path = (docsDir as NSString).appendingPathComponent(name)
        guard (data as NSData).write(toFile: path, atomically: true) else { return nil }

        return ExportResult(filePath: path,
                            subscriptionCount: subscriptions.count,
                            recentCount: recents.count,
                            downloadCount: downloads.count,
                            positionCount: positions.count,
                            playedCount: played.count,
                            queueCount: queue.count)
    }

    // MARK: - List backup files (newest first)

    static func listBackupFiles() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: docsDir) else { return [] }
        return files
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }
            .sorted(by: >)
            .map { (docsDir as NSString).appendingPathComponent($0) }
    }

    // MARK: - Parse

    struct BackupContents {
        let exportDate:    String
        let subscriptions: [[String: Any]]
        let recents:       [[String: Any]]
        let downloads:     [[String: Any]]
        let positions:     [String: Double]
        let played:        [String]
        let queue:         [[String: Any]]
        let durations:     [String: Double]
        // nil when the file predates version 2 — leave the existing pref alone
        // rather than silently flipping it off on every old-file import.
        let autoDeleteFinished: Bool?
        let filePath:      String

        var fileName: String { (filePath as NSString).lastPathComponent }
        var subscriptionCount: Int { subscriptions.count }
        var recentCount: Int { recents.count }
        var downloadCount: Int { downloads.count }
        var positionCount: Int { positions.count }
        var playedCount: Int { played.count }
        var queueCount: Int { queue.count }
    }

    // JSON numbers come back as NSNumber, so a plain `as? Double` cast misses any
    // value the serialiser decided was an integer.
    private static func doubleMap(_ raw: Any?) -> [String: Double] {
        guard let dict = raw as? [String: Any] else { return [:] }
        var out: [String: Double] = [:]
        for (k, v) in dict {
            if let d = v as? Double        { out[k] = d }
            else if let n = v as? NSNumber { out[k] = n.doubleValue }
        }
        return out
    }

    static func parse(filePath: String) -> BackupContents? {
        guard let data = NSData(contentsOfFile: filePath) as Data?,
              let raw  = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any]
        else { return nil }

        return BackupContents(
            exportDate:    dict["exportDate"]    as? String ?? "",
            subscriptions: dict["subscriptions"] as? [[String: Any]] ?? [],
            recents:       dict["recents"]       as? [[String: Any]] ?? [],
            downloads:     dict["downloads"]     as? [[String: Any]] ?? [],
            positions:     doubleMap(dict["positions"]),
            played:        dict["played"]        as? [String] ?? [],
            queue:         dict["queue"]         as? [[String: Any]] ?? [],
            durations:     doubleMap(dict["durations"]),
            autoDeleteFinished: dict["autoDeleteFinished"] as? Bool,
            filePath:      filePath)
    }

    // MARK: - Apply import

    enum ImportMode { case replace, merge }

    static func applyImport(_ backup: BackupContents, mode: ImportMode) {
        let ud = UserDefaults.standard
        switch mode {
        case .replace:
            ud.set(backup.subscriptions, forKey: Podcast.subscriptionsKey)
            ud.set(backup.recents,       forKey: Episode.recentsKey)
            ud.set(backup.downloads,     forKey: Episode.downloadsKey)
            ud.set(backup.queue,  forKey: PlayQueue.storageKey)
            ud.set(backup.played, forKey: Episode.playedGuidsKey)
            for key in ud.dictionaryRepresentation().keys
            where key.hasPrefix("pos_") || key.hasPrefix("dur_") {
                ud.removeObject(forKey: key)
            }
            for (key, val) in backup.positions { ud.set(val, forKey: key) }
            for (key, val) in backup.durations { ud.set(val, forKey: key) }

        case .merge:
            let existingSubs = ud.array(forKey: Podcast.subscriptionsKey) as? [[String: Any]] ?? []
            let existingUrls = Set(existingSubs.compactMap { $0["feedUrl"] as? String })
            var mergedSubs = existingSubs
            for s in backup.subscriptions {
                if let url = s["feedUrl"] as? String, !existingUrls.contains(url) { mergedSubs.append(s) }
            }
            ud.set(mergedSubs, forKey: Podcast.subscriptionsKey)

            let existingRec      = ud.array(forKey: Episode.recentsKey) as? [[String: Any]] ?? []
            let existingRecGuids = Set(existingRec.compactMap { $0["guid"] as? String })
            var mergedRec = existingRec
            for e in backup.recents {
                if let g = e["guid"] as? String, !existingRecGuids.contains(g) { mergedRec.append(e) }
            }
            ud.set(mergedRec, forKey: Episode.recentsKey)

            let existingDL      = ud.array(forKey: Episode.downloadsKey) as? [[String: Any]] ?? []
            let existingDLGuids = Set(existingDL.compactMap { $0["guid"] as? String })
            var mergedDL = existingDL
            for e in backup.downloads {
                if let g = e["guid"] as? String, !existingDLGuids.contains(g) { mergedDL.append(e) }
            }
            ud.set(mergedDL, forKey: Episode.downloadsKey)

            let existingQ      = ud.array(forKey: PlayQueue.storageKey) as? [[String: Any]] ?? []
            let existingQGuids = Set(existingQ.compactMap { $0["guid"] as? String })
            var mergedQ = existingQ
            for e in backup.queue {
                if let g = e["guid"] as? String, !existingQGuids.contains(g) { mergedQ.append(e) }
            }
            ud.set(mergedQ, forKey: PlayQueue.storageKey)

            // Played is a set — union is the only sensible merge.
            var mergedPlayed = Set(ud.stringArray(forKey: Episode.playedGuidsKey) ?? [])
            mergedPlayed.formUnion(backup.played)
            ud.set(Array(mergedPlayed), forKey: Episode.playedGuidsKey)

            for (key, imported) in backup.positions {
                if imported > ud.double(forKey: key) { ud.set(imported, forKey: key) }
            }
            // Durations are a property of the file, not of progress — any known
            // value beats the 0 that means "not measured yet".
            for (key, imported) in backup.durations where ud.double(forKey: key) <= 0 {
                ud.set(imported, forKey: key)
            }
        }

        // Applies to both modes; nil means the file predates version 2.
        if let autoDelete = backup.autoDeleteFinished {
            Episode.autoDeleteFinished = autoDelete
        }
        ud.synchronize()

        // PlayQueue.shared holds its list in memory — without this it would keep
        // serving the pre-import queue and overwrite the imported one on next save.
        PlayQueue.shared.reload()
    }
}
