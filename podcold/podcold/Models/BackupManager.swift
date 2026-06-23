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
    }

    static func export() -> ExportResult? {
        let ud = UserDefaults.standard
        let subscriptions = ud.array(forKey: Podcast.subscriptionsKey) as? [[String: Any]] ?? []
        let recents       = ud.array(forKey: Episode.recentsKey)       as? [[String: Any]] ?? []
        let downloads     = ud.array(forKey: Episode.downloadsKey)     as? [[String: Any]] ?? []

        var positions: [String: Double] = [:]
        for (key, val) in ud.dictionaryRepresentation() {
            if key.hasPrefix("pos_"), let d = val as? Double, d > 0 { positions[key] = d }
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: Date())

        let payload: [String: Any] = [
            "version":       1,
            "exportDate":    dateStr,
            "subscriptions": subscriptions,
            "recents":       recents,
            "downloads":     downloads,
            "positions":     positions
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
                            positionCount: positions.count)
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
        let filePath:      String

        var fileName: String { (filePath as NSString).lastPathComponent }
        var subscriptionCount: Int { subscriptions.count }
        var recentCount: Int { recents.count }
        var downloadCount: Int { downloads.count }
        var positionCount: Int { positions.count }
    }

    static func parse(filePath: String) -> BackupContents? {
        guard let data = NSData(contentsOfFile: filePath) as Data?,
              let raw  = try? JSONSerialization.jsonObject(with: data),
              let dict = raw as? [String: Any]
        else { return nil }

        let exportDate    = dict["exportDate"]    as? String ?? ""
        let subscriptions = dict["subscriptions"] as? [[String: Any]] ?? []
        let recents       = dict["recents"]       as? [[String: Any]] ?? []
        let downloads     = dict["downloads"]     as? [[String: Any]] ?? []

        var positions: [String: Double] = [:]
        if let raw = dict["positions"] as? [String: Any] {
            for (k, v) in raw {
                if let d = v as? Double        { positions[k] = d }
                else if let n = v as? NSNumber { positions[k] = n.doubleValue }
            }
        }
        return BackupContents(exportDate: exportDate, subscriptions: subscriptions,
                              recents: recents, downloads: downloads,
                              positions: positions, filePath: filePath)
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
            for key in ud.dictionaryRepresentation().keys where key.hasPrefix("pos_") {
                ud.removeObject(forKey: key)
            }
            for (key, val) in backup.positions { ud.set(val, forKey: key) }

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

            for (key, imported) in backup.positions {
                if imported > ud.double(forKey: key) { ud.set(imported, forKey: key) }
            }
        }
        ud.synchronize()
    }
}
