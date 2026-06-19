import AVFoundation

class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private var timeObserver: Any?
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
        let urlString = episode.localPath().map { "file://\($0)" } ?? episode.audioUrl
        guard let url = URL(string: urlString) else { return }
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
        onStateChange?()
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
