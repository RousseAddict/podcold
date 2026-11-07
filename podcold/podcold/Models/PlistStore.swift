import Foundation

// One property list in its own file under Library/Application Support, with the
// parsed value kept in memory. Holds the episode lists that carry show notes:
// recents, download records, the play queue and the New Episodes cache.
//
// They used to live in UserDefaults, which is a single plist that iOS 6 rewrites
// whole, on the main thread, whenever any key in it changes. The position is saved
// every 5 s during playback and flushPosition() forces a synchronize() on every
// episode switch, so each of those also rewrote every stored episode's show notes
// (~4 KB each for Hugo Décrypte), often with the same episode in three or four of
// the lists. Now a position save rewrites only the small prefs file, and a list is
// written only when it changes, off the main thread.
//
// Application Support, not Caches like EpisodeListCache: this is the user's data
// (the download records are how DownloadsVC finds the files), so iOS must never
// purge it.
//
// Thread-safe: AudioPlayer writes recents from its own queue while HomeVC reads them
// on main.
final class PlistStore {
    // The UserDefaults key the list used to live under. It names the file too.
    let key: String
    private let path: String

    private let lock = NSLock()
    private var value: Any?
    private var loaded = false
    private var flushPending = false

    private static let dir: String = {
        let base = NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first!
        let d = (base as NSString).appendingPathComponent("com.podcold.lists")
        try? FileManager.default.createDirectory(atPath: d,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        return d
    }()

    // Static per the queue rule. Serial, so writes to one file land in order.
    private static let writeQueue = DispatchQueue(label: "com.podcold.plists")

    init(key: String) {
        self.key = key
        path = (PlistStore.dir as NSString).appendingPathComponent("\(key).plist")
    }

    func read() -> Any? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return value
    }

    // nil deletes the file.
    func write(_ newValue: Any?) {
        lock.lock()
        // Migrate first even though the value is about to be replaced: otherwise
        // the UserDefaults copy outlives it, and the launch after a clear() would
        // find no file and bring the old list back.
        loadIfNeeded()
        value = newValue
        let schedule = !flushPending
        flushPending = true
        lock.unlock()
        // At most one write queued per file: a burst of changes (a New Episodes batch
        // stores one feed after another) lands as one write of the latest value.
        if schedule { PlistStore.writeQueue.async { self.flush() } }
    }

    // Blocks until every queued write is on disk. Writes are asynchronous, so a
    // process that exits with one still queued would lose it — called when the app
    // is backgrounded or terminated.
    static func waitForWrites() {
        writeQueue.sync {}
    }

    private func flush() {
        lock.lock()
        let v = value
        flushPending = false
        lock.unlock()
        PlistStore.save(v, to: path)
    }

    // Called with the lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = FileManager.default.contents(atPath: path),
           let v = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            value = v
            return
        }
        // First launch of a build that keeps this list on disk: move it out of
        // UserDefaults. The key is only dropped once the file is written, so a
        // failed write leaves the list where it was for the next launch to retry.
        let ud = UserDefaults.standard
        guard let legacy = ud.object(forKey: key) else { return }
        value = legacy
        if PlistStore.save(legacy, to: path) { ud.removeObject(forKey: key) }
    }

    // Binary, not the XML NSArray.write produces: smaller, and faster to parse on
    // the launch that reads it back.
    @discardableResult
    private static func save(_ value: Any?, to path: String) -> Bool {
        guard let value = value else {
            try? FileManager.default.removeItem(atPath: path)
            return true
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value,
                                                            format: .binary, options: 0)
        else { return false }
        return (data as NSData).write(toFile: path, atomically: true)
    }
}
