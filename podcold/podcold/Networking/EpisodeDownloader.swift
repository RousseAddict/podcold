import Foundation

class EpisodeDownloader {
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
