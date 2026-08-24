import Foundation

// Ordered list of episodes to play after the current one.
//
// The episode actually playing is NOT in here — AudioPlayer owns that — so the
// queue always reads as "up next" with no special-casing of row 0.
//
// Stored in UserDefaults next to recents. A queue is a handful of episodes, so
// the whole-plist rewrite UserDefaults performs on every change is affordable
// here in a way it is not for a 20-episode feed cache (which is why
// EpisodeListCache uses one plist per feed under Caches instead).
class PlayQueue {
    static let shared = PlayQueue()
    private init() { episodes = PlayQueue.load() }

    private static let key = "play_queue"

    private(set) var episodes: [Episode]

    private static func load() -> [Episode] {
        guard let arr = UserDefaults.standard.array(forKey: key) as? [[String: Any]] else { return [] }
        return arr.map { Episode.from(dict: $0) }
    }

    private func save() {
        UserDefaults.standard.set(episodes.map { $0.toDict() }, forKey: PlayQueue.key)
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
