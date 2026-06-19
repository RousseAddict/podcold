import Foundation

class EpisodeDownloader: NSObject, NSURLConnectionDataDelegate {
    private var connection: NSURLConnection?
    private var timer: Timer?
    private var fileHandle: FileHandle?
    private var bytesReceived: Int64 = 0
    private var expectedLength: Int64 = 0
    private var outputPath = ""
    private var episode: Episode!
    private var progressHandler: ((Float) -> Void)?
    private var completionHandler: ((Bool) -> Void)?
    private static var active: [EpisodeDownloader] = []

    static func download(episode: Episode,
                         progress: @escaping (Float) -> Void,
                         completion: @escaping (Bool) -> Void) {
        guard !episode.audioUrl.isEmpty, let url = URL(string: episode.audioUrl) else {
            completion(false); return
        }
        let dl = EpisodeDownloader()
        dl.episode           = episode
        dl.outputPath        = episode.localPathForWriting()
        dl.progressHandler   = progress
        dl.completionHandler = completion
        active.append(dl)

        let conn = NSURLConnection(request: URLRequest(url: url), delegate: dl, startImmediately: false)
        conn?.schedule(in: .main, forMode: .common)
        conn?.start()
        dl.connection = conn

        let t = Timer(timeInterval: 300, target: dl, selector: #selector(timedOut), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        dl.timer = t
    }

    // SSL bypass
    func connection(_ connection: NSURLConnection, willSendRequestFor challenge: URLAuthenticationChallenge) {
        guard let sender = challenge.sender else { return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            sender.use(URLCredential(trust: trust), for: challenge)
        } else {
            sender.performDefaultHandling?(for: challenge)
        }
    }

    func connection(_ connection: NSURLConnection, didReceive response: URLResponse) {
        expectedLength = response.expectedContentLength
        bytesReceived  = 0
        // Create the file on disk and open a write handle — stream chunks directly,
        // never accumulate the whole file in RAM
        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        fileHandle = FileHandle(forWritingAtPath: outputPath)
    }

    func connection(_ connection: NSURLConnection, didReceive data: Data) {
        fileHandle?.write(data)
        bytesReceived += Int64(data.count)
        if expectedLength > 0 {
            progressHandler?(Float(bytesReceived) / Float(expectedLength))
        }
    }

    func connectionDidFinishLoading(_ connection: NSURLConnection) {
        timer?.invalidate()
        fileHandle?.closeFile()
        fileHandle = nil
        // Verify the file was written and is non-empty
        let ok = FileManager.default.fileExists(atPath: outputPath) && bytesReceived > 0
        if ok { Episode.addToDownloads(episode) }
        completionHandler?(ok)
        EpisodeDownloader.active.removeAll { $0 === self }
    }

    func connection(_ connection: NSURLConnection, didFailWithError error: Error) {
        timer?.invalidate()
        fileHandle?.closeFile()
        fileHandle = nil
        // Clean up partial file
        try? FileManager.default.removeItem(atPath: outputPath)
        completionHandler?(false)
        EpisodeDownloader.active.removeAll { $0 === self }
    }

    @objc private func timedOut() {
        connection?.cancel()
        fileHandle?.closeFile()
        fileHandle = nil
        try? FileManager.default.removeItem(atPath: outputPath)
        completionHandler?(false)
        EpisodeDownloader.active.removeAll { $0 === self }
    }
}
