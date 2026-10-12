import UIKit

class MiniPlayerBar: UIView {
    private let titleLabel   = UILabel()
    private let playPauseBtn = UIButton(type: .custom)
    private let closeBtn     = UIButton(type: .custom)
    private let openBtn      = UIButton(type: .custom)  // transparent tap-to-expand area
    private let spinner      = UIActivityIndicatorView(style: .white)

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupUI()
        observePlayer()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 0.97)

        let border = UIView(frame: CGRect(x: 0, y: 0, width: bounds.width, height: 1))
        border.autoresizingMask = .flexibleWidth
        border.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        addSubview(border)

        // Close button — rightmost, stops playback entirely
        closeBtn.frame = CGRect(x: bounds.width - 40, y: 10, width: 36, height: 40)
        closeBtn.autoresizingMask = .flexibleLeftMargin
        closeBtn.setImage(UIImage(named: "close"), for: .normal)
        closeBtn.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        addSubview(closeBtn)

        // Play/pause button — left of close
        playPauseBtn.frame = CGRect(x: bounds.width - 80, y: 10, width: 36, height: 40)
        playPauseBtn.autoresizingMask = .flexibleLeftMargin
        // pause shown while playing, play shown while paused
        playPauseBtn.setImage(UIImage(named: "pause"), for: .normal)
        playPauseBtn.setImage(UIImage(named: "play"), for: .selected)
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        addSubview(playPauseBtn)

        // Stands in for the button while the episode opens or the buffer runs dry
        spinner.frame = playPauseBtn.frame
        spinner.autoresizingMask = .flexibleLeftMargin
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        // Title label — left side, not interactive
        titleLabel.frame = CGRect(x: 14, y: 8, width: bounds.width - 104, height: 44)
        titleLabel.autoresizingMask = .flexibleWidth
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 13)
        titleLabel.numberOfLines = 2
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        // Transparent button over the title area — tap to open NowPlayingVC
        openBtn.frame = CGRect(x: 0, y: 0, width: bounds.width - 88, height: bounds.height)
        openBtn.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        openBtn.backgroundColor = .clear
        openBtn.addTarget(self, action: #selector(openTapped), for: .touchUpInside)
        addSubview(openBtn)
        // Bring action buttons above the open button so they receive taps first
        bringSubviewToFront(playPauseBtn)
        bringSubviewToFront(closeBtn)
    }

    // Replaces a 0.5 s poll timer: the bar only ever changed when the player or
    // the Now Playing screen did, and both now say so.
    private func observePlayer() {
        let nc = NotificationCenter.default
        for name: Notification.Name in [.playerStateChanged, .playerEpisodeChanged,
                                        .nowPlayingVisibilityChanged] {
            nc.addObserver(self, selector: #selector(updateUI), name: name, object: nil)
        }
    }

    @objc private func updateUI() {
        let p = AudioPlayer.shared
        let shouldHide = (p.currentEpisode == nil) || NowPlayingVC.isOnScreen
        if isHidden != shouldHide { isHidden = shouldHide }
        guard let ep = p.currentEpisode else { return }
        if titleLabel.text != ep.title { titleLabel.text = ep.title }
        let busy = p.isBusy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        if playPauseBtn.isHidden != busy { playPauseBtn.isHidden = busy }
        let wantSelected = !p.isPlaying
        if playPauseBtn.isSelected != wantSelected { playPauseBtn.isSelected = wantSelected }
    }

    @objc private func playPauseTapped() {
        AudioPlayer.shared.isPlaying ? AudioPlayer.shared.pause() : AudioPlayer.shared.resume()
    }

    @objc private func closeTapped() {
        AudioPlayer.shared.stop()
        isHidden = true
    }

    @objc private func openTapped() {
        guard let window = self.window,
              let nav = window.rootViewController as? UINavigationController else { return }
        if nav.topViewController is NowPlayingVC { return }
        nav.pushViewController(NowPlayingVC(), animated: true)
    }
}
