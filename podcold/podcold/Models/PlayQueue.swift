import Foundation

// Ordered list of episodes to play after the current one.
//
// The episode actually playing is NOT in here — AudioPlayer owns that — so the
// queue always reads as "up next" with no special-casing of row 0.
//
// Stored in its own file next to recents (see PlistStore), not in UserDefaults:
// each queued episode carries its show notes, and UserDefaults rewrote all of
// them with every 5-s position save.
class PlayQueue {
    static let shared = PlayQueue()
    private init() { episodes = PlayQueue.load() }

    // Internal so BackupManager can export/import it.
    static let file = PlistStore(key: "play_queue")

    private(set) var episodes: [Episode]

    private static func load() -> [Episode] {
        guard let arr = file.read() as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }

    // The singleton caches `episodes` in memory, so anything that writes the
    // file directly (BackupManager import) must tell it to re-read.
    func reload() { episodes = PlayQueue.load() }

    private func save() {
        PlayQueue.file.write(episodes.map { $0.toDict() })
    }

    func contains(guid: String) -> Bool {
        return episodes.contains { $0.guid == guid }
    }

    func add(_ episode: Episode) {
        guard !contains(guid: episode.guid) else { return }
        episodes.append(episode)
        save()
    }

    func remove(guid: String) {
        episodes.removeAll { $0.guid == guid }
        save()
    }

    func remove(at index: Int) {
        guard index >= 0, index < episodes.count else { return }
        episodes.remove(at: index)
        save()
    }

    func move(from: Int, to: Int) {
        guard from != to,
              from >= 0, from < episodes.count,
              to >= 0, to < episodes.count else { return }
        let ep = episodes.remove(at: from)
        episodes.insert(ep, at: to)
        save()
    }

    // Pops the head. Called by AudioPlayer when an episode finishes.
    func next() -> Episode? {
        guard !episodes.isEmpty else { return nil }
        let ep = episodes.removeFirst()
        save()
        return ep
    }
}
