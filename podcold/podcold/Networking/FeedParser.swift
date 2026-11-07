import Foundation

class FeedParser: NSObject, XMLParserDelegate {
    private var episodes: [Episode] = []
    private var channelArtwork = ""
    fileprivate var podcastTitle = ""
    private var currentEpisode: Episode?
    private var currentText = ""
    private var inItem = false          // RSS <item> or Atom <entry>

    private var limit = FeedParser.pageSize
    private static let parseQueue = DispatchQueue(label: "com.podcold.feedparser")

    // MARK: — Public entry point

    // A feed is a single XML document with no server-side paging, so "load more"
    // means parsing further into the same bytes (see FeedPager). Parsing stops at
    // `limit` via abortParsing(), so a deeper re-parse only reads as far as it needs to.
    static let pageSize = 20

    // Headroom over `limit` when cutting a download short: the cut counts every
    // </item>, but the parser skips items with no audio, so an exact cut could
    // come up a few episodes short.
    fileprivate static let itemSlack = 5

    // What a New Episodes check found — see parseIfChanged.
    enum Check {
        case episodes([Episode], FeedValidators)
        case unchanged
        case failed
    }

    // The New Episodes batch's entry point. Nothing is kept, so the download stops
    // once the page is in hand. Parsing already stopped at `limit`, but the
    // transfer used to run to the end anyway — for Hugo Décrypte that is 16.8 MB
    // (acast doesn't gzip) to use the first 210 KB, and too much to finish inside
    // the 20 s timeout on cellular at all.
    //
    // `validators` from the previous check are sent back, so a feed that hasn't
    // changed answers 304 with no body: .unchanged, and the caller reuses the page
    // it already has. Empty ones ask for the whole page and still collect this
    // response's validators for next time.
    static func parseIfChanged(feedUrl: String, podcastTitle: String, validators: FeedValidators,
                               limit: Int = pageSize, completion: @escaping (Check) -> Void) {
        let request = FeedRequest(maxItems: limit + itemSlack, validators: validators)
        fetch(feedUrl: feedUrl, request: request) { response in
            switch response {
            case .failed:      completion(.failed)
            case .notModified: completion(.unchanged)
            case .data(let data, let info):
                parse(data: data, podcastTitle: podcastTitle, limit: limit) { eps in
                    completion(.episodes(eps, info.validators))
                }
            }
        }
    }

    // Parse bytes the caller already holds — no network. Used by FeedPager.
    static func parse(data: Data, podcastTitle: String, limit: Int,
                      completion: @escaping ([Episode]) -> Void) {
        parseQueue.async {
            let eps = runXML(data: data, podcastTitle: podcastTitle, limit: limit)
            DispatchQueue.main.async { completion(eps) }
        }
    }

    // Use CurlFetcher (libcurl + OpenSSL) — handles GCM ciphers that NSURLConnection
    // (Apple Secure Transport) cannot negotiate on iOS 6.
    //
    // HTTP is a *sequential fallback*, not a parallel race: the feed lane is a
    // serial queue, so firing both at once did not race — the loser still
    // downloaded the entire feed and threw it away, doubling traffic on every
    // refresh. Only try plain HTTP once HTTPS has actually failed.
    //
    // No wall-clock watchdog here: it measured from enqueue rather than from
    // request start, so a busy lane made it fire while the request was still
    // queued — reporting failure and then discarding the real response.
    // CURLOPT_TIMEOUT guarantees curl always calls back.
    fileprivate static func fetch(feedUrl: String, request: FeedRequest,
                                  completion: @escaping (FeedResponse) -> Void) {
        let httpFallback: String? = feedUrl.lowercased().hasPrefix("https://")
            ? "http://" + String(feedUrl.dropFirst(8))
            : nil
        CurlFetcher.fetchFeed(url: feedUrl, request: request) { response in
            guard case .failed = response, let http = httpFallback else { completion(response); return }
            CurlFetcher.fetchFeed(url: http, request: request, completion: completion)
        }
    }

    // MARK: — Synchronous XML parse

    private static func runXML(data: Data, podcastTitle: String, limit: Int) -> [Episode] {
        let p = FeedParser()
        p.podcastTitle = podcastTitle
        p.limit = limit
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        return p.episodes
    }

    // MARK: — XMLParserDelegate

    func parserDidStartDocument(_ parser: XMLParser) { episodes = [] }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        switch elementName {

        case "item", "entry":
            inItem = true
            currentEpisode = Episode()
            currentEpisode?.podcastTitle = podcastTitle

        case "enclosure" where inItem:
            if let url = attributes["url"], !url.isEmpty {
                currentEpisode?.audioUrl = url
            }

        case "media:content" where inItem:
            if let url = attributes["url"], !url.isEmpty,
               currentEpisode?.audioUrl.isEmpty == true {
                let mime = attributes["type"] ?? ""
                if mime.hasPrefix("audio") || mime.isEmpty {
                    currentEpisode?.audioUrl = url
                }
            }

        case "link" where inItem:
            if attributes["rel"] == "enclosure",
               let href = attributes["href"], !href.isEmpty,
               currentEpisode?.audioUrl.isEmpty == true {
                currentEpisode?.audioUrl = href
            }

        case "itunes:image" where !inItem:
            channelArtwork = attributes["href"] ?? ""
        case "itunes:image" where inItem:
            if let href = attributes["href"], !href.isEmpty {
                currentEpisode?.artworkUrl = href
            }

        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if elementName == "item" || elementName == "entry" {
            if let ep = currentEpisode, !ep.audioUrl.isEmpty {
                if ep.artworkUrl.isEmpty { ep.artworkUrl = channelArtwork }
                // <guid> is optional in RSS 2.0 — without a substitute every
                // guid-less episode in the feed collides on one download path
                // and one saved position. See Episode.ensureGuid().
                ep.ensureGuid()
                episodes.append(ep)
            }
            inItem = false; currentEpisode = nil
            // RSS/Atom feeds are newest-first — abort as soon as we have enough
            if episodes.count >= limit {
                parser.abortParsing()
            }
            return
        }

        guard inItem else { return }

        switch elementName {
        case "title":
            currentEpisode?.title = text
        case "guid", "id":
            currentEpisode?.guid = text
        case "pubDate", "published", "updated":
            if currentEpisode?.pubDate.isEmpty == true { currentEpisode?.pubDate = text }
        case "itunes:duration":
            currentEpisode?.duration = text
        // First one wins. A `where` on a multi-pattern case only guards the last
        // pattern, so "content" used to clobber an already-parsed summary.
        case "itunes:summary", "description", "content", "content:encoded":
            if currentEpisode?.summary.isEmpty == true { currentEpisode?.summary = text }
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {}
}

// MARK: - Paging one feed (EpisodeListVC)
//
// Downloads only as far into a feed as the pages on screen need. The first page
// stops the transfer after its items, as the New Episodes batch does. Each later
// page resumes where the last one stopped with an HTTP byte range — the next
// stretch of the same document — stops again a page further on, and parses the
// bytes held so far. Hugo Décrypte (16.8 MB, not gzipped) costs ~255 KB for the
// first page and ~210 KB for each one after, where every open and every load-more
// used to download all 16.8 MB.
//
// A range only lines up when the bytes held are the bytes served. A gzipped
// response is decoded on arrival, so its offsets mean nothing to the server, and
// some servers ignore ranges altogether: both answer from the top, which this
// takes as a fresh start and cuts at the deeper page. Gzipped feeds are small
// anyway (The Daily: 60 KB whole). If-Range does the same for a feed that changed
// between pages, so two versions are never stitched together.
//
// Main thread only, like the screen that owns it.
final class FeedPager {
    let feedUrl: String
    let podcastTitle: String

    private var data = Data()     // the document's first data.count bytes, as served
    private var complete = false  // `data` is the whole document
    private var itemsHeld = 0     // closing item tags in `data`
    private var ifRange = ""      // validator to resume with; "" = start over instead

    init(feedUrl: String, podcastTitle: String) {
        self.feedUrl = feedUrl
        self.podcastTitle = podcastTitle
    }

    // The first `limit` episodes, downloading only what isn't held yet.
    // episodes == nil: the fetch failed, or the bytes held no episodes at all.
    // hasMore: the document goes on past what was parsed.
    func load(limit: Int, completion: @escaping (_ episodes: [Episode]?, _ hasMore: Bool) -> Void) {
        let wanted = limit + FeedParser.itemSlack
        guard !complete, itemsHeld < wanted else {
            parseHeld(limit: limit, completion: completion)
            return
        }
        var request = FeedRequest(maxItems: wanted)
        if !data.isEmpty && !ifRange.isEmpty {
            request.resume = FeedResume(offset: data.count, ifRange: ifRange, itemsHeld: itemsHeld)
        }
        // Holds self strongly: the completion must run even if the screen was popped
        // meanwhile, because the caller resumes the New Episodes batch from it.
        FeedParser.fetch(feedUrl: feedUrl, request: request) { response in
            guard case .data(let bytes, let info) = response else { completion(nil, false); return }
            if info.partial {
                self.data.append(bytes)
            } else {
                // From the top: a first page, a gzipped feed, a server that ignored
                // the range, or a feed that changed since the bytes held.
                self.data = bytes
                self.ifRange = info.encoded ? "" : info.validators.ifRange
            }
            self.itemsHeld = info.itemEnds
            self.complete = !info.truncated
            self.parseHeld(limit: limit, completion: completion)
        }
    }

    private func parseHeld(limit: Int, completion: @escaping ([Episode]?, Bool) -> Void) {
        FeedParser.parse(data: data, podcastTitle: podcastTitle, limit: limit) { eps in
            // Nothing parseable — a captive portal's page, say. Holding on to it would
            // make every retry re-read that page instead of fetching again.
            guard !eps.isEmpty else {
                self.reset()
                completion(nil, false)
                return
            }
            // A parse that stopped at `limit` may have more behind it, held or not;
            // one that ran short has more only if the download stopped short too.
            completion(eps, eps.count >= limit || !self.complete)
        }
    }

    private func reset() {
        data = Data()
        complete = false
        itemsHeld = 0
        ifRange = ""
    }
}
