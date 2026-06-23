import AVFoundation
import MediaPlayer

class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observedItem: AVPlayerItem?  // KVO target — tracked so we can remove before dealloc
    var currentEpisode: Episode?
    var onProgress: ((Double, Double) -> Void)?
    var onFinish: (() -> Void)?
    var onStateChange: (() -> Void)?
    private var progressTick = 0  // counts 1-s ticks; used to throttle writes
    private static let bgQueue = DispatchQueue(label: "com.podcold.audiobg")

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
                self.progressTick += 1
                // Save position every 5s — avoids UserDefaults plist-flush stalls on main thread
                if self.progressTick % 5 == 0 { self.currentEpisode?.savePosition(cur) }
                self.onProgress?(cur, dur.isNaN ? 0 : dur)
                // Update lock-screen scrubber every 5s — iOS interpolates elapsed in-between
                if self.progressTick % 5 == 0 {
                    self.updateNowPlayingElapsed(cur, duration: dur.isNaN ? 0 : dur)
                }
        }

        // Watch for AVPlayer failure (e.g. untrusted cert not in iOS 6 root store).
        // AVPlayer has its own TLS stack — our NSURLConnection SSL bypass doesn't apply to it.
        // On failure, fall back to downloading via EpisodeDownloader (which uses CurlFetcher)
        // and replay from the local file once complete.
        if watchForFailure {
            observedItem = item
            item.addObserver(self, forKeyPath: "status", options: .new, context: nil)
        }

        onStateChange?()
        DispatchQueue.main.async { [weak self] in
            self?.updateNowPlaying(episode: episode)
        }
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

    // AVPlayer failed to stream — download via CurlFetcher then replay from local file
    private func fallbackToDownload(episode: Episode) {
        EpisodeDownloader.download(
            episode: episode,
            progress: { [weak self] _ in self?.onStateChange?() },
            completion: { [weak self] success in
                guard let self = self, success,
                      self.currentEpisode?.guid == episode.guid else { return }
                self.play(episode: episode)
            }
        )
    }

    private func addToRecents(_ episode: Episode) {
        AudioPlayer.bgQueue.async {
            var recents = Episode.loadRecents()
            recents.removeAll { $0.guid == episode.guid }
            recents.insert(episode, at: 0)
            if recents.count > 8 { recents = Array(recents.prefix(8)) }
            Episode.saveRecents(recents)
        }
    }

    func pause() {
        player?.pause()
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 0.0
        onStateChange?()
    }

    func resume() {
        player?.play()
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        onStateChange?()
    }

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
        progressTick = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    @objc private func didFinish() {
        currentEpisode?.savePosition(0)
        onFinish?()
        onStateChange?()
    }

    // MARK: - Now Playing Info (lock screen + control centre)

    private func updateNowPlaying(episode: Episode) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: episode.savedPosition(),
            MPNowPlayingInfoPropertyPlaybackRate: 1.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard !episode.artworkUrl.isEmpty else { return }
        CurlFetcher.fetchData(url: episode.artworkUrl, timeout: 15) { data in
            guard let data = data else { return }
            AudioPlayer.bgQueue.async {
                guard let image = UIImage(data: data) else { return }
                DispatchQueue.main.async {
                    var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
                }
            }
        }
    }

    private func updateNowPlayingElapsed(_ elapsed: Double, duration: Double) {
        guard MPNowPlayingInfoCenter.default().nowPlayingInfo != nil else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        if duration > 0 {
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] = duration
        }
    }
}
