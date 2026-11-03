import UIKit

// Posted on start, cancel and fire. The countdown itself only moves while the
// player is playing, so views repaint it off .playerTimeChanged in between.
extension Notification.Name {
    static let sleepTimerChanged = Notification.Name("podcold.sleepTimer.changed")
}

class SleepTimer: NSObject {
    enum Mode { case off, countdown, endOfEpisode }

    static let shared = SleepTimer()

    private(set) var mode: Mode = .off

    // Counts listening time, not wall time. A paused app is suspended in the
    // background, so a wall-clock deadline could not fire on time anyway — and
    // "30 minutes" should not run out while the episode sits paused.
    private var banked: TimeInterval = 0          // left as of countingSince
    private var countingSince: CFTimeInterval = 0 // CACurrentMediaTime() when last armed
    private var timer: Timer?

    private override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playerStateChanged),
                       name: .playerStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(playerEpisodeChanged),
                       name: .playerEpisodeChanged, object: nil)
    }

    var isActive: Bool { return mode != .off }

    // Measured on the monotonic clock, not by counting the player's periodic
    // ticks: those run on the item's timeline, so at 2x they come twice a second.
    var remaining: TimeInterval {
        guard mode == .countdown else { return 0 }
        guard timer != nil else { return banked }
        return max(0, banked - (CACurrentMediaTime() - countingSince))
    }

    func start(minutes: Int) {
        disarm()
        mode   = .countdown
        banked = TimeInterval(minutes * 60)
        if AudioPlayer.shared.state == .playing { arm() }
        post()
    }

    func startEndOfEpisode() {
        disarm()
        mode   = .endOfEpisode
        banked = 0
        post()
    }

    func cancel() {
        guard mode != .off else { return }
        disarm()
        mode   = .off
        banked = 0
        post()
    }

    // Asked by AudioPlayer.finishCurrent() before it advances the queue. True means
    // the timer was waiting for exactly this, and playback should stop here.
    func claimEndOfEpisode() -> Bool {
        guard mode == .endOfEpisode else { return false }
        cancel()
        return true
    }

    // MARK: - Player

    @objc private func playerStateChanged() {
        guard mode == .countdown else { return }
        switch AudioPlayer.shared.state {
        case .playing:
            arm()
        case .ended:
            cancel()   // nothing left to play, so nothing left to stop
        default:
            // Not cancel: reset() passes through .idle on every queue advance and
            // episode switch, and a pause or a stall should only stop the clock.
            bank()
        }
    }

    // Only the mini bar's close button empties the player. A timer outliving that
    // would pause whatever gets played next, long after it was set.
    @objc private func playerEpisodeChanged() {
        if AudioPlayer.shared.currentEpisode == nil { cancel() }
    }

    // MARK: - Clock

    private func arm() {
        guard timer == nil else { return }
        countingSince = CACurrentMediaTime()
        let t = Timer(timeInterval: banked, target: self, selector: #selector(fired),
                      userInfo: nil, repeats: false)
        // .common so a scroll or a slider drag in progress does not hold it back
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // Stops the clock, keeping what was left for the next arm().
    private func bank() {
        guard timer != nil else { return }
        banked = remaining
        disarm()
    }

    private func disarm() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func fired() {
        timer  = nil
        // Off before pausing, so the .paused notification does not bank a spent timer
        mode   = .off
        banked = 0
        AudioPlayer.shared.pause()
        // Positions are only written every 5th tick, and once the audio stops the
        // app is suspended and may be killed overnight before anything writes again.
        AudioPlayer.shared.flushPosition()
        post()
    }

    private func post() {
        NotificationCenter.default.post(name: .sleepTimerChanged, object: self)
    }
}
