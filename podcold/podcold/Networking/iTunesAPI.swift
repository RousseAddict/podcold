import Foundation

class iTunesAPI {

    // Static per the queue rule — a queue created inside search() spawned an OS
    // thread per racing response, i.e. two per search.
    private static let parseQueue = DispatchQueue(label: "com.podcold.itunesparse")

    static func search(term: String, completion: @escaping ([Podcast]) -> Void) {
        let encoded = iTunesAPI.percentEncode(term)
        // HTTP and HTTPS race, whichever answers first wins. Unlike FeedParser,
        // these are NSURLConnection requests on the run loop rather than work
        // items on a serial lane, so this is a real race and not two sequential
        // downloads — worth the duplicate ~20 KB when HTTP is blocked on a
        // captive network and HTTPS is not (or vice versa, which is the common
        // case on iOS 6, where the TLS ciphers often fail instead).
        let httpUrl  = "http://itunes.apple.com/search?term=\(encoded)&media=podcast&entity=podcast&limit=25"
        let httpsUrl = "https://itunes.apple.com/search?term=\(encoded)&media=podcast&entity=podcast&limit=25"

        // All three of these are read and written on the main thread only: both
        // HTTPClient completions and the watchdog land there, and the parse hop
        // comes back through main before touching them. Previously `done` was
        // also read from the parse queue, unsynchronised.
        var done = false
        var pendingLegs = 2

        func finish(_ podcasts: [Podcast]) {
            guard !done else { return }
            done = true
            completion(podcasts)
        }

        // nil means "this leg produced nothing usable" — no response, or a body
        // that did not parse. An *empty but valid* result is [] and finishes
        // immediately: the old code returned early on `podcasts.isEmpty`, so a
        // search with no matches sat on the 22 s watchdog before showing the
        // empty table.
        func legFinished(_ podcasts: [Podcast]?) {
            guard !done else { return }
            if let podcasts = podcasts { finish(podcasts); return }
            pendingLegs -= 1
            if pendingLegs == 0 { finish([]) }
        }

        func handle(_ data: Data?) {
            guard !done else { return }
            guard let data = data else { legFinished(nil); return }
            iTunesAPI.parseQueue.async {
                let podcasts = iTunesAPI.parse(data)
                DispatchQueue.main.async { legFinished(podcasts) }
            }
        }

        HTTPClient.get(url: httpUrl)  { data, _ in handle(data) }
        HTTPClient.get(url: httpsUrl) { data, _ in handle(data) }

        // Backstop only. HTTPClient always calls back (its own 30 s timer), so
        // both legs now report and this should no longer be reachable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
            finish([])
        }
    }

    // nil = unusable response; [] = valid response with no matches.
    private static func parse(_ data: Data) -> [Podcast]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        return results.compactMap { iTunesAPI.podcastFrom(dict: $0) }
    }

    // Percent-encode a URL query value — iOS 2+ safe.
    // CharacterSet.urlQueryAllowed / addingPercentEncoding are iOS 7+ only.
    private static func percentEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case 65...90, 97...122, 48...57, 45, 95, 46, 126:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func podcastFrom(dict: [String: Any]) -> Podcast? {
        guard let feedUrl = dict["feedUrl"] as? String, !feedUrl.isEmpty else { return nil }
        let p = Podcast()
        p.collectionId  = dict["collectionId"]     as? Int    ?? 0
        p.title         = dict["collectionName"]   as? String ?? ""
        p.author        = dict["artistName"]       as? String ?? ""
        p.feedUrl       = feedUrl
        p.artworkUrl    = dict["artworkUrl60"]     as? String ?? ""
        p.artworkUrl600 = dict["artworkUrl600"]    as? String ?? ""
        p.genre         = dict["primaryGenreName"] as? String ?? ""
        p.episodeCount  = dict["trackCount"]       as? Int    ?? 0
        return p
    }
}
