import Foundation

class FeedParser: NSObject, XMLParserDelegate {
    private var episodes: [Episode] = []
    private var channelArtwork = ""
    fileprivate var podcastTitle = ""
    private var currentEpisode: Episode?
    private var currentText = ""
    private var inItem = false          // RSS <item> or Atom <entry>

    private static let maxEpisodes = 20

    // MARK: — Public entry point

    static func parse(feedUrl: String, podcastTitle: String, completion: @escaping ([Episode]) -> Void) {
        // Race HTTP and HTTPS in parallel — whichever responds first wins.
        let httpUrl: String? = feedUrl.lowercased().hasPrefix("https://")
            ? "http://" + String(feedUrl.dropFirst(8))
            : nil

        var done = false

        func handle(_ data: Data?) {
            guard !done, let data = data else { return }
            let eps = FeedParser.runXML(data: data, podcastTitle: podcastTitle)
            guard !eps.isEmpty else { return }
            done = true
            completion(eps)
        }

        HTTPClient.get(url: feedUrl) { data, _ in handle(data) }
        if let http = httpUrl { HTTPClient.get(url: http) { data, _ in handle(data) } }

        DispatchQueue.main.asyncAfter(deadline: .now() + 32) {
            guard !done else { return }
            done = true
            completion([])
        }
    }

    // MARK: — Synchronous XML parse

    private static func runXML(data: Data, podcastTitle: String) -> [Episode] {
        let p = FeedParser()
        p.podcastTitle = podcastTitle
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
            if episodes.count >= FeedParser.maxEpisodes {
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
