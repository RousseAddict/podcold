import Foundation

class Podcast: NSObject {
    var collectionId: Int = 0
    var title: String = ""
    var author: String = ""
    var feedUrl: String = ""
    var artworkUrl: String = ""
    var artworkUrl600: String = ""
    var genre: String = ""
    var episodeCount: Int = 0

    static let subscriptionsKey = "subscribed_podcasts"

    static func loadSubscriptions() -> [Podcast] {
        guard let arr = UserDefaults.standard.array(forKey: subscriptionsKey) as? [[String: Any]] else { return [] }
        return arr.map { Podcast.from(dict: $0) }
    }

    static func saveSubscriptions(_ podcasts: [Podcast]) {
        UserDefaults.standard.set(podcasts.map { $0.toDict() }, forKey: subscriptionsKey)
    }

    func toDict() -> [String: Any] {
        return ["collectionId": collectionId, "title": title, "author": author,
                "feedUrl": feedUrl, "artworkUrl": artworkUrl, "artworkUrl600": artworkUrl600, "genre": genre]
    }

    static func from(dict: [String: Any]) -> Podcast {
        let p = Podcast()
        p.collectionId = dict["collectionId"] as? Int ?? 0
        p.title        = dict["title"]        as? String ?? ""
        p.author       = dict["author"]       as? String ?? ""
        p.feedUrl      = dict["feedUrl"]      as? String ?? ""
        p.artworkUrl   = dict["artworkUrl"]   as? String ?? ""
        p.artworkUrl600 = dict["artworkUrl600"] as? String ?? ""
        p.genre        = dict["genre"]        as? String ?? ""
        return p
    }
}
