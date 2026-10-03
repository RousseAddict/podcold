import Foundation

class EpisodeDownloader {

    // Static per the queue rule — one thread, created at class load, used once.
    private static let sweepQueue = DispatchQueue(label: "com.podcold.downloadsweep")

    // A download interrupted by a crash or force-quit leaves its ".part" sidecar
    // behind (CurlFetcher only unlinks it on a clean failure). Nothing ever reads
    // those files, so they would just accumulate in Documents. Called once from
    // AppDelegate at launch.
    static func sweepStalePartFiles() {
        sweepQueue.async {
            let fm = FileManager.default
            let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
            guard let names = try? fm.contentsOfDirectory(atPath: docs) else { return }
            for name in names where name.hasSuffix(".part") {
                try? fm.removeItem(atPath: (docs as NSString).appendingPathComponent(name))
            }
        }
    }

    static func download(episode: Episode,
                         progress: @escaping (Float) -> Void,
                         completion: @escaping (Bool) -> Void) {
        guard !episode.audioUrl.isEmpty else { completion(false); return }
        let outputPath = episode.localPathForWriting()
        CurlFetcher.downloadToFile(url: episode.audioUrl, outputPath: outputPath, progress: progress) { ok in
            if ok { Episode.addToDownloads(episode) }
            completion(ok)
        }
    }
}
