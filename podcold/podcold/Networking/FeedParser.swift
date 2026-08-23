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

    static func parse(feedUrl: String, podcastTitle: String, limit: Int = pageSize,
                      completion: @escaping ([Episode]) -> Void) {
        parseKeepingData(feedUrl: feedUrl, podcastTitle: podcastTitle, limit: limit) { eps, _ in
            completion(eps)
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
    // deeper without a second download.
    static func parseKeepingData(feedUrl: String, podcastTitle: String, limit: Int = pageSize,
                                 completion: @escaping ([Episode], Data?) -> Void) {
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
        func finish(_ data: Data?) {
            guard let data = data else { completion([], nil); return }
            FeedParser.parseQueue.async {
                let eps = FeedParser.runXML(data: data, podcastTitle: podcastTitle, limit: limit)
                DispatchQueue.main.async { completion(eps, data) }
            }
        }

        CurlFetcher.fetchFeed(url: feedUrl) { data in
            if data != nil { finish(data); return }
            guard let http = httpFallback else { finish(nil); return }
            CurlFetcher.fetchFeed(url: http) { fallbackData in finish(fallbackData) }
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
        case "itunes:summary" where currentEpisode?.summary.isEmpty == true:
            currentEpisode?.summary = text
        case "description" where currentEpisode?.summary.isEmpty == true:
            currentEpisode?.summary = text
        case "content", "content:encoded" where currentEpisode?.summary.isEmpty == true:
            currentEpisode?.summary = text
        default: break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {}
}
