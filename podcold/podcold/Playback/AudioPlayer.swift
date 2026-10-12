import AVFoundation
import MediaPlayer

// The player's actual situation, which `rate != 0` could not express: it read the
// same (0) for "not started yet", "buffering", "user paused", "finished" and
// "failed". Every view drove its play/pause glyph off that boolean, so an episode
// that was still opening showed the pause glyph — "I am playing" — in silence.
enum PlaybackState {
    case idle       // nothing loaded
    case loading    // asset opening, seeking to the resume point, or falling back to a download
    case playing
    case paused
    case stalled    // was playing, ran out of buffer
    case ended      // played to the end with an empty queue — parked, not torn down
    case failed
}

// Replaces the four single-assignment closures on AudioPlayer. Those could only
// ever have one owner, so NowPlayingVC took them and MiniPlayerBar had to poll at
// 2 Hz instead; and because NowPlayingVC cleared them on every disappear but only
// bound them in viewDidLoad, pushing a screen on top of it and coming back left a
// dead slider.
extension Notification.Name {
    static let playerStateChanged   = Notification.Name("podcold.player.stateChanged")
    static let playerTimeChanged    = Notification.Name("podcold.player.timeChanged")
    static let playerEpisodeChanged = Notification.Name("podcold.player.episodeChanged")
    // Posted by NowPlayingVC so the mini bar can hide behind it without polling.
    static let nowPlayingVisibilityChanged = Notification.Name("podcold.nowPlaying.visibility")
}

class AudioPlayer: NSObject {
    static let shared = AudioPlayer()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var observedItem: AVPlayerItem?  // KVO target — tracked so we can remove before dealloc
    private static let itemKeyPaths = ["status", "playbackLikelyToKeepUp", "playbackBufferEmpty"]

    var currentEpisode: Episode?

    // MARK: - Snapshot
    //
    // The one source of truth every view renders. It is seeded from disk in
    // play() so the slider and both time labels are already correct before the
    // asset has opened — previously each view kept its own copy, fed only by the
    // periodic time observer, which does not tick until the item is ready.
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    // >= 0 only while the AVPlayer-failed fallback download is running.
    private(set) var downloadProgress: Float = -1

    private(set) var state: PlaybackState = .idle {
        didSet {
            guard oldValue != state else { return }
            if state == .loading { startWatchdog() } else { cancelWatchdog() }
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] =
                (state == .playing) ? Double(playbackRate) : 0.0
            post(.playerStateChanged)
        }
    }

    // "Means to be playing" — loading and stalled count, so a transport toggle
    // does not offer "play" for something that is already starting.
    var isPlaying: Bool {
        switch state {
        case .playing, .loading, .stalled: return true
        default: return false
        }
    }

    var isBusy: Bool { return state == .loading || state == .stalled }

    private var pendingSeek: Double = 0
    private var isStreaming = false
    private var watchdog: Timer?
    private static let loadTimeout: TimeInterval = 25
    private var progressTick = 0  // counts 1-s ticks; used to throttle writes
    // The chosen playback rate belongs to the player, not to NowPlayingVC: AVPlayer
    // resets to 1.0 on every play() and a queue advance builds a whole new AVPlayer,
    // so the rate has to be re-applied rather than set once.
    private(set) var playbackRate: Float = 1.0
    private static let bgQueue = DispatchQueue(label: "com.podcold.audiobg")

    private override init() {
        super.init()
        setupSession()
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidPlayToEnd(_:)),
            name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemStalled(_:)),
            name: NSNotification.Name.AVPlayerItemPlaybackStalled, object: nil)
    }

    private func setupSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    // AVFoundation delivers KVO and seek completions on arbitrary threads.
    private func post(_ name: Notification.Name) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: name, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: name, object: self)
            }
        }
    }

    // MARK: - Transport

    func play(episode: Episode) {
        addToRecents(episode)
        // reset(), not stop(): stop() announces an empty player, and the Now Playing
        // screen closes itself on that — a queue advance would pop the screen it is
        // supposed to hand over to.
        reset()
        currentEpisode = episode

        // Seed the snapshot from what is already on disk, so every view can draw
        // the real slider position and both time labels immediately. resumePosition()
        // also refuses to hand back a point at the very end of the file — a stored
        // near-end position used to be seeked to verbatim, which ended the item on
        // the spot and closed the player as soon as it opened.
        pendingSeek      = episode.resumePosition()
        currentTime      = pendingSeek
        duration         = episode.totalDuration()
        downloadProgress = -1
        state            = .loading
        post(.playerEpisodeChanged)
        post(.playerTimeChanged)

        // If already downloaded, play local file directly — no cert issues
        if let localPath = episode.localPath() {
            startPlayer(url: URL(fileURLWithPath: localPath), episode: episode, isStream: false)
            return
        }

        guard let url = URL(string: episode.audioUrl) else { state = .failed; return }
        startPlayer(url: url, episode: episode, isStream: true)
    }

    private func startPlayer(url: URL, episode: Episode, isStream: Bool) {
        isStreaming = isStream
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)

        // Deliberately not calling play() here. The resume seek has to land before
        // the first sample does, or playback starts at 0 and audibly jumps once the
        // seek catches up. startRolling() runs from the readyToPlay transition.
        observedItem = item
        for key in AudioPlayer.itemKeyPaths {
            item.addObserver(self, forKeyPath: key, options: .new, context: nil)
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTimeMakeWithSeconds(1, preferredTimescale: 1),
            queue: .main) { [weak self] time in
                guard let self = self, let item = self.player?.currentItem else { return }
                let cur = CMTimeGetSeconds(time)
                guard !cur.isNaN else { return }
                let dur = CMTimeGetSeconds(item.duration)
                self.currentTime = cur
                // Keep the seeded duration when AVPlayer does not know the real one yet
                if !dur.isNaN, dur > 0 { self.duration = dur }
                self.progressTick += 1
                // AVPlayer snaps back to 1.0 whenever it actually starts rolling —
                // the item becoming ready to play is the common case, and it happens
                // after startPlayer() has already returned. Re-assert once per tick
                // while playing; a user pause (rate 0) is left alone.
                if let p = self.player, p.rate != 0 {
                    if p.rate != self.playbackRate { p.rate = self.playbackRate }
                    if self.state == .loading || self.state == .stalled { self.state = .playing }
                }
                // Save position every 5s — avoids UserDefaults plist-flush stalls on main
                // thread. recordProgress also caches the real length (itunes:duration is
                // often missing or wrong) and collapses a near-end position to "finished".
                if self.progressTick % 5 == 0 {
                    self.currentEpisode?.recordProgress(cur, duration: self.duration)
                    // Update lock-screen scrubber every 5s — iOS interpolates elapsed in-between
                    self.updateNowPlayingElapsed(cur, duration: self.duration)
                }
                self.post(.playerTimeChanged)
        }

        DispatchQueue.main.async { [weak self] in
            self?.updateNowPlaying(episode: episode)
        }
    }

    // Old-style KVO required for iOS 6 — Swift's observe() is iOS 9+
    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard let item = object as? AVPlayerItem, item === observedItem else { return }
        let key = keyPath ?? ""
        DispatchQueue.main.async { [weak self] in self?.handleItemChange(key, item: item) }
    }

    private func handleItemChange(_ keyPath: String, item: AVPlayerItem) {
        guard item === observedItem else { return }
        switch keyPath {
        case "status":
            if item.status == .readyToPlay {
                beginPlayback()
            } else if item.status == .failed {
                handleLoadFailure()
            }
        case "playbackLikelyToKeepUp":
            if item.isPlaybackLikelyToKeepUp, state == .stalled { startRolling() }
        case "playbackBufferEmpty":
            if item.isPlaybackBufferEmpty, state == .playing { state = .stalled }
        default:
            break
        }
    }

    // The item is ready: land the resume seek first, then roll.
    private func beginPlayback() {
        guard state == .loading || state == .stalled || state == .paused else { return }
        let shouldRoll = (state != .paused)   // a pause during loading must be honoured
        let target = pendingSeek
        pendingSeek = 0
        guard target > 0 else {
            if shouldRoll { startRolling() }
            return
        }
        player?.seek(to: CMTimeMakeWithSeconds(target, preferredTimescale: 1)) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if shouldRoll { self.startRolling() } else { self.state = .paused }
            }
        }
    }

    private func startRolling() {
        player?.play()
        player?.rate = playbackRate
        state = .playing
    }

    // AVPlayer has its own TLS stack and ignores our certificate bypass, so a
    // stream it refuses can still be fetched by CurlFetcher and played from disk.
    private func handleLoadFailure() {
        guard isStreaming, let ep = currentEpisode else {
            state = .failed
            return
        }
        fallbackToDownload(episode: ep)
    }

    private func fallbackToDownload(episode: Episode) {
        downloadProgress = 0
        state = .loading
        post(.playerStateChanged)   // already .loading, so didSet will not fire
        EpisodeDownloader.download(
            episode: episode,
            progress: { [weak self] p in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // The curl callback fires per chunk — only whole percents reach the UI
                    guard Int(p * 100) != Int(self.downloadProgress * 100) else { return }
                    self.downloadProgress = p
                    self.post(.playerStateChanged)
                }
            },
            completion: { [weak self] success in
                DispatchQueue.main.async {
                    guard let self = self,
                          self.currentEpisode?.guid == episode.guid else { return }
                    self.downloadProgress = -1
                    if success { self.play(episode: episode) } else { self.state = .failed }
                }
            }
        )
    }

    // MARK: - Load watchdog
    //
    // A stream that never opens does not produce an AVPlayerItem .failed on iOS 6,
    // it just stays silent forever — which is what left the screen showing a pause
    // glyph with no audio and no way out.

    private func startWatchdog() {
        cancelWatchdog()
        let t = Timer(timeInterval: AudioPlayer.loadTimeout, target: self,
                      selector: #selector(watchdogFired), userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func cancelWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    @objc private func watchdogFired() {
        watchdog = nil
        guard state == .loading else { return }
        guard downloadProgress < 0 else { return }   // fallback download running, let it finish
        handleLoadFailure()
    }

    private func removeItemObserver() {
        guard let item = observedItem else { return }
        for key in AudioPlayer.itemKeyPaths {
            item.removeObserver(self, forKeyPath: key)
        }
        observedItem = nil
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
        state = .paused
    }

    func resume() {
        // An AVPlayer parked at the end of its item ignores play(), so the only
        // meaningful "play" there is to start over.
        if state == .ended { replay(); return }
        guard let p = player else {
            // Torn down while the episode stayed current (e.g. a failed load)
            if let ep = currentEpisode { play(episode: ep) }
            return
        }
        p.play()
        // play() is rate = 1.0, so the chosen speed has to be restored right after.
        p.rate = playbackRate
        state = (p.currentItem?.status == .readyToPlay) ? .playing : .loading
    }

    // Start the current episode over. Backs the ended state's play button.
    func replay() {
        guard let ep = currentEpisode else { return }
        ep.savePosition(0)
        play(episode: ep)
        // play() tears the old player down, and that flush records the end position
        // as "finished" all over again — so the unmark has to come afterwards.
        Episode.unmarkPlayed(guid: ep.guid)
    }

    func seek(to seconds: Double) {
        let target = max(0, seconds)
        currentTime = target
        if state == .ended {
            // Scrubbing back out of the end is a resume, not a replay
            state = .paused
            if let guid = currentEpisode?.guid { Episode.unmarkPlayed(guid: guid) }
        }
        player?.seek(to: CMTimeMakeWithSeconds(target, preferredTimescale: 1))
        post(.playerTimeChanged)
    }

    // Remembered even when set while paused — it used to be dropped on the floor,
    // so picking a speed from a paused player did nothing.
    func setSpeed(_ rate: Float) {
        playbackRate = rate
        if state == .playing {
            player?.rate = rate
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = Double(rate)
        }
    }

    // Positions are only written on every 5th tick, so tearing the player down
    // without a final write throws away up to 5 s — on closing the mini player,
    // on switching episodes, and on being killed in the background.
    func flushPosition() {
        guard let ep = currentEpisode, let p = player else { return }
        let cur = CMTimeGetSeconds(p.currentTime())
        guard !cur.isNaN, cur > 0 else { return }
        ep.recordProgress(cur, duration: duration)
        UserDefaults.standard.synchronize()
    }

    func stop() {
        reset()
        post(.playerEpisodeChanged)
    }

    private func reset() {
        flushPosition()
        teardownPlayer()
        currentEpisode   = nil
        currentTime      = 0
        duration         = 0
        downloadProgress = -1
        pendingSeek      = 0
        state            = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func teardownPlayer() {
        removeItemObserver()
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        player?.pause()
        player = nil
        progressTick = 0
    }

    // Registered for every item rather than one: a torn-down player's end
    // notification used to be enough to close the Now Playing screen.
    @objc private func itemDidPlayToEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
        finishCurrent()
    }

    @objc private func itemStalled(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player?.currentItem else { return }
        if state == .playing { state = .stalled }
    }

    private func finishCurrent() {
        if let ep = currentEpisode {
            ep.savePosition(0)
            Episode.markPlayed(guid: ep.guid)
            ep.autoDeleteIfEnabled()
        }
        // Queued episodes take over instead of tearing the player down.
        if let next = PlayQueue.shared.next() {
            // The position was just reset to 0 — drop the reference so the stop()
            // inside play() doesn't flush the near-end time straight back over it
            // and resurrect the episode in Continue Listening.
            currentEpisode = nil
            play(episode: next)
            return
        }
        // Park at the end rather than popping the screen out from under the user.
        currentTime = duration
        state = .ended
        post(.playerTimeChanged)
    }

    // MARK: - Now Playing Info (lock screen + control centre)

    private func updateNowPlaying(episode: Episode) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: episode.title,
            MPMediaItemPropertyArtist: episode.podcastTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: (state == .playing) ? Double(playbackRate) : 0.0
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard !episode.artworkUrl.isEmpty else { return }
        // Go through AsyncImageView so this shares the memory/disk cache with the UI
        // instead of re-downloading on every play, and so the image arrives already
        // downscaled — decoding a 3000x3000 cover here spiked ~36 MB on a 4S.
        AsyncImageView.loadCell(url: episode.artworkUrl, maxPx: 300) { image in
            var updated = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            updated[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(image: image)
            MPNowPlayingInfoCenter.default().nowPlayingInfo = updated
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
