import Foundation

// Builds the "New Episodes" swim lane on HomeVC: one card per subscribed podcast,
// showing its latest unplayed episode, sorted newest-first.
//
// Checking every subscription's feed on every app open would be slow, so:
//  - cachedUpNext() reads only from LatestEpisodeCache (instant, no network)
//  - refreshStale() re-checks feeds not verified in the last 45 min, ONE AT A TIME
//    (chained, not parallel — avoids spawning a thread per subscription on iPhone 4S,
//    same rule as the static-queue convention used elsewhere in this app)
class UpNextManager {
    static let shared = UpNextManager()
    private init() {}

    // How far back into a feed the lane is willing to look. Tapping Done marks an episode
    // played and drops its cache entry, so the next refresh walks one step further back —
    // unbounded, that keeps offering older episodes until the whole feed history is used
    // up. With a window of 2, a podcast with 3 unplayed episodes goes quiet after two
    // Dones and only speaks up again when a genuinely new episode slides into the window.
    static let maxNewEpisodesKey = "max_new_episodes"
    static let maxNewEpisodesRange = 1...10
    private static let maxNewEpisodesDefault = 3

    static var maxNewEpisodes: Int {
        // integer(forKey:) returns 0 when unset, which is indistinguishable from a real
        // 0 — but 0 is outside the allowed range, so it can only mean "never set".
        get {
            let v = UserDefaults.standard.integer(forKey: maxNewEpisodesKey)
            return maxNewEpisodesRange.contains(v) ? v : maxNewEpisodesDefault
        }
        set { UserDefaults.standard.set(newValue, forKey: maxNewEpisodesKey) }
    }

    private var refreshing = false
    // Counted, not a bool: overlapping user-facing requests are normal — EpisodeListVC
    // can have its initial load() and a loadMore() re-fetch outstanding at once — and a
    // bool let the first completion un-pause the batch while the second request was
    // still waiting its turn on the serial feed lane.
    private var suspendCount = 0
    private var paused: Bool { return suspendCount > 0 }
    private var pending: [Podcast] = []
    private var inProgressGuids: Set<String> = []

    // This batch owns CurlFetcher's serial feed lane for as long as it runs, so a
    // screen the user is actually looking at would queue behind every remaining
    // subscription. Yielding between feeds bounds that wait to the one download
    // already in flight instead of all of them.
    func suspend() { suspendCount += 1 }

    func resume() {
        guard suspendCount > 0 else { return }
        suspendCount -= 1
        if suspendCount == 0 && !refreshing { processNext() }
    }

    // Called after each feed in the batch resolves, so HomeVC can incrementally re-render.
    var onUpdate: (() -> Void)?

    // Drives HomeVC's "New Episodes" sync spinner. True from the moment a batch is
    // queued until its last feed resolves — including while suspend() has the batch
    // parked, since the remaining feeds are still coming.
    var isSyncing: Bool { return refreshing || !pending.isEmpty }
    var onSyncStateChange: (() -> Void)?

    func cachedUpNext(podcasts: [Podcast], inProgressGuids: Set<String>) -> [(Podcast, Episode)] {
        var results: [(Podcast, Episode)] = []
        for podcast in podcasts {
            guard let ep = LatestEpisodeCache.cachedEpisode(feedUrl: podcast.feedUrl) else { continue }
            guard !inProgressGuids.contains(ep.guid), !Episode.isPlayed(guid: ep.guid) else { continue }
            results.append((podcast, ep))
        }
        return results.sorted {
            ($0.1.pubDateAsDate() ?? .distantPast) > ($1.1.pubDateAsDate() ?? .distantPast)
        }
    }

    func refreshStale(podcasts: [Podcast], inProgressGuids: Set<String>) {
        guard !refreshing else { return }
        self.inProgressGuids = inProgressGuids
        pending = podcasts.filter { LatestEpisodeCache.isStale(feedUrl: $0.feedUrl) }
        onSyncStateChange?()
        processNext()
    }

    private func processNext() {
        guard !pending.isEmpty else { refreshing = false; onSyncStateChange?(); return }
        // Yield the feed lane; resume() picks the batch back up where it stopped.
        guard !paused else { refreshing = false; return }
        refreshing = true
        let podcast = pending.removeFirst()
        FeedParser.parse(feedUrl: podcast.feedUrl, podcastTitle: podcast.title) { [weak self] episodes in
            guard let self = self else { return }
            // Feed order is newest-first, so the window is simply the head of the list.
            let qualifying = episodes.prefix(UpNextManager.maxNewEpisodes).first {
                !self.inProgressGuids.contains($0.guid) && !Episode.isPlayed(guid: $0.guid)
            }
            LatestEpisodeCache.store(feedUrl: podcast.feedUrl, episode: qualifying)
            // This batch already paid for the download and the parse, so hand the full
            // list to EpisodeListCache too — opening the podcast afterwards is then free.
            EpisodeListCache.store(feedUrl: podcast.feedUrl, episodes: episodes)
            self.onUpdate?()
            self.processNext()
        }
    }
}
