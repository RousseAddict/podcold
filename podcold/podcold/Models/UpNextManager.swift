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

    private var refreshing = false
    private var pending: [Podcast] = []
    private var inProgressGuids: Set<String> = []

    // Called after each feed in the batch resolves, so HomeVC can incrementally re-render.
    var onUpdate: (() -> Void)?

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
        processNext()
    }

    private func processNext() {
        guard !pending.isEmpty else { refreshing = false; return }
        refreshing = true
        let podcast = pending.removeFirst()
        FeedParser.parse(feedUrl: podcast.feedUrl, podcastTitle: podcast.title) { [weak self] episodes in
            guard let self = self else { return }
            let qualifying = episodes.first {
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
