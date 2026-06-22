import AVFoundation

class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observedItem: AVPlayerItem?  // KVO target — tracked so we can remove before dealloc
    var currentEpisode: Episode?
    var onProgress: ((Double, Double) -> Void)?
    var onFinish: (() -> Void)?
    var onStateChange: (() -> Void)?

    private override init() {
        super.init()
        setupSession()
        NotificationCenter.default.addObserver(self, selector: #selector(didFinish),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: nil)
    }

    private func setupSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func play(episode: Episode) {
        addToRecents(episode)
        stop()
        currentEpisode = episode

        // If already downloaded, play local file directly — no cert issues
        if let localPath = episode.localPath() {
            startPlayer(url: URL(string: "file://\(localPath)")!, episode: episode, watchForFailure: false)
            return
        }

        guard let url = URL(string: episode.audioUrl) else { return }
        startPlayer(url: url, episode: episode, watchForFailure: true)
    }

    private func startPlayer(url: URL, episode: Episode, watchForFailure: Bool) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player?.play()

        let savedPos = episode.savedPosition()
        if savedPos > 5 {
            player?.seek(to: CMTimeMakeWithSeconds(savedPos, preferredTimescale: 1))
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTimeMakeWithSeconds(1, preferredTimescale: 1),
            queue: .main) { [weak self] time in
                guard let self = self, let item = self.player?.currentItem else { return }
                let cur = CMTimeGetSeconds(time)
                let dur = CMTimeGetSeconds(item.duration)
                self.currentEpisode?.savePosition(cur)
                self.onProgress?(cur, dur.isNaN ? 0 : dur)
        }

        // Watch for AVPlayer failure (e.g. untrusted cert not in iOS 6 root store).
        // AVPlayer has its own TLS stack — our NSURLConnection SSL bypass doesn't apply to it.
        // On failure, fall back to downloading via EpisodeDownloader (which uses NSURLFetcher
        // with the SSL bypass) and replay from the local file once complete.
        if watchForFailure {
            observedItem = item
            item.addObserver(self, forKeyPath: "status", options: .new, context: nil)
        }

        onStateChange?()
    }

    // Old-style KVO required for iOS 6 — Swift's observe() is iOS 9+
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "status", let item = object as? AVPlayerItem else { return }
        removeItemObserver()
        if item.status == .failed, let ep = currentEpisode {
            fallbackToDownload(episode: ep)
        }
    }

    private func removeItemObserver() {
        observedItem?.removeObserver(self, forKeyPath: "status")
        observedItem = nil
    }

    // AVPlayer failed to stream (likely untrusted CA on iOS 6) — download via NSURLFetcher then replay
    private func fallbackToDownload(episode: Episode) {
        // Keep currentEpisode set so UI knows something is loading
        EpisodeDownloader.download(
            episode: episode,
            progress: { [weak self] _ in self?.onStateChange?() },
            completion: { [weak self] success in
                guard let self = self, success,
                      self.currentEpisode?.guid == episode.guid else { return }
                // Re-play — localPath() now exists, startPlayer will use file://
                self.play(episode: episode)
            }
        )
    }

    private func addToRecents(_ episode: Episode) {
        var recents = Episode.loadRecents()
        recents.removeAll { $0.guid == episode.guid }
        recents.insert(episode, at: 0)
        if recents.count > 8 { recents = Array(recents.prefix(8)) }
        Episode.saveRecents(recents)
    }

    func pause()  { player?.pause(); onStateChange?() }
    func resume() { player?.play();  onStateChange?() }
    var isPlaying: Bool { return (player?.rate ?? 0) != 0 }

    func seek(to seconds: Double) {
        player?.seek(to: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1))
    }
    func setSpeed(_ rate: Float) {
        if isPlaying { player?.rate = rate }
    }

    func stop() {
        removeItemObserver()
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        player?.pause()
        player = nil
        currentEpisode = nil
    }

    @objc private func didFinish() {
        currentEpisode?.savePosition(0)
        onFinish?()
        onStateChange?()
    }
}
