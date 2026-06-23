import Foundation

class iTunesAPI {
    static func search(term: String, completion: @escaping ([Podcast]) -> Void) {
        let encoded = iTunesAPI.percentEncode(term)
        // Use HTTP to avoid TLS cipher negotiation issues on iOS 6
        // Race HTTP and HTTPS so whichever answers first wins
        let httpUrl  = "http://itunes.apple.com/search?term=\(encoded)&media=podcast&entity=podcast&limit=25"
        let httpsUrl = "https://itunes.apple.com/search?term=\(encoded)&media=podcast&entity=podcast&limit=25"

        var done = false
        func handle(_ data: Data?) {
            guard !done, let data = data else { return }
            DispatchQueue(label: "com.podcold.misc").async {
                guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = root["results"] as? [[String: Any]] else { return }
                let podcasts = results.compactMap { iTunesAPI.podcastFrom(dict: $0) }
                guard !podcasts.isEmpty else { return }
                DispatchQueue.main.async {
                    guard !done else { return }
                    done = true
                    completion(podcasts)
                }
            }
        }

        HTTPClient.get(url: httpUrl)  { data, _ in handle(data) }
        HTTPClient.get(url: httpsUrl) { data, _ in handle(data) }

        // Fallback: if neither responded after 22s, return empty
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) {
            guard !done else { return }
            done = true
            completion([])
        }
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
