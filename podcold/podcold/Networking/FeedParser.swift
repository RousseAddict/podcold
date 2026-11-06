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
    // means parsing further into the same bytes. Parsing stops at `limit` via
    // abortParsing(), so a deeper re-parse only reads as far as it needs to.
    static let pageSize = 20

    // Headroom over `limit` when cutting a download short: the cut counts every
    // </item>, but the parser skips items with no audio, so an exact cut could
    // come up a few episodes short.
    private static let itemSlack = 5

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
        load(feedUrl: feedUrl, podcastTitle: podcastTitle, limit: limit,
             maxItems: limit + itemSlack, validators: validators) { check, _ in
            completion(check)
        }
    }

    // Re-parse bytes the caller already holds — no network. Used by
    // EpisodeListVC's load-more.
    static func parse(data: Data, podcastTitle: String, limit: Int,
                      completion: @escaping ([Episode]) -> Void) {
        parseQueue.async {
            let eps = runXML(data: data, podcastTitle: podcastTitle, limit: limit)
            DispatchQueue.main.async { completion(eps) }
        }
    }

    // As `parse`, but also hands back the raw feed bytes so the caller can page
    // deeper without a second download — which needs the whole document, so this
    // path never cuts the transfer short.
    static func parseKeepingData(feedUrl: String, podcastTitle: String, limit: Int = pageSize,
                                 completion: @escaping ([Episode], Data?) -> Void) {
        load(feedUrl: feedUrl, podcastTitle: podcastTitle, limit: limit,
             maxItems: 0, validators: nil) { check, data in
            if case .episodes(let eps, _) = check { completion(eps, data) } else { completion([], nil) }
        }
    }

    // maxItems: stop the download after this many items; 0 = fetch it all.
    // validators: nil = a plain request, otherwise a conditional one (see parseIfChanged).
    private static func load(feedUrl: String, podcastTitle: String, limit: Int, maxItems: Int,
                             validators: FeedValidators?,
                             completion: @escaping (Check, Data?) -> Void) {
        // Use CurlFetcher (libcurl + OpenSSL) — handles GCM ciphers that NSURLConnection
        // (Apple Secure Transport) cannot negotiate on iOS 6.
        //
        // HTTP is a *sequential fallback*, not a parallel race: the feed lane is a
        // serial queue, so firing both at once did not race — the loser still
        // downloaded the entire feed and threw it away, doubling traffic on every
        // refresh. Only try plain HTTP once HTTPS has actually failed.
        let httpFallback: String? = feedUrl.lowercased().hasPrefix("https://")
            ? "http://" + String(feedUrl.dropFirst(8))
            : nil

        // No wall-clock watchdog here: it measured from enqueue rather than from
        // request start, so a busy lane made it fire while the request was still
        // queued — reporting failure and then discarding the real response.
        // CURLOPT_TIMEOUT guarantees curl always calls back.
        func finish(_ response: FeedResponse) {
            switch response {
            case .failed:      completion(.failed, nil)
            case .notModified: completion(.unchanged, nil)
            case .data(let data, let received):
                FeedParser.parseQueue.async {
                    let eps = FeedParser.runXML(data: data, podcastTitle: podcastTitle, limit: limit)
                    DispatchQueue.main.async { completion(.episodes(eps, received), data) }
                }
            }
        }

        CurlFetcher.fetchFeed(url: feedUrl, maxItems: maxItems, validators: validators) { response in
            guard case .failed = response, let http = httpFallback else { finish(response); return }
            CurlFetcher.fetchFeed(url: http, maxItems: maxItems, validators: validators) { finish($0) }
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
