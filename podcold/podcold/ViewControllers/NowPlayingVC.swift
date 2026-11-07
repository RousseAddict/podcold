import UIKit

class NowPlayingVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIActionSheetDelegate {
    // The mini bar hides behind this screen. It used to discover that by polling
    // the navigation stack twice a second; now the screen simply says so.
    private(set) static var isOnScreen = false

    // Full: the big-artwork player scrolls away with the queue under it.
    // List: the same player, compacted and pinned on top; the queue fills the rest.
    private enum Mode { case full, list }
    private static let listModeKey = "now_playing_list_mode"
    private var mode: Mode = UserDefaults.standard.bool(forKey: NowPlayingVC.listModeKey) ? .list : .full
    private var switchingMode = false

    private let artworkView      = AsyncImageView()
    private let artworkBtn       = UIButton(type: .custom)
    private let titleLabel       = UILabel()
    private let podcastLabel     = UILabel()
    private let statusLabel      = UILabel()
    private let playPauseBtn     = UIButton(type: .custom)
    private let skipBackBtn      = UIButton(type: .custom)
    private let skipFwdBtn       = UIButton(type: .custom)
    private let slider           = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingLabel   = UILabel()
    private let speedBtn         = UIButton(type: .custom)
    private let spinner          = UIActivityIndicatorView(style: .white)
    private let speeds: [Float]  = [1.0, 1.5, 2.0, 0.5]
    private var speedIndex       = 0
    private let sleepBtn         = UIButton(type: .custom)
    private let sleepMinutes     = [15, 30, 45, 60]
    // One entry per non-cancel button of the sheet on screen, in button-index order
    private var sleepActions: [() -> Void] = []
    private var tableView: UITableView!
    private var headerView: UIView!
    private var lastDisplayedSecond = -1
    private var lastDisplayedDuration: Double = -1
    // Live parts of the "UP NEXT" section header, repainted without a reload
    private weak var queueEditBtn: UIButton?
    private weak var queueSummaryLabel: UILabel?

    // The player owns these now. The screen used to keep its own copies, which
    // only existed after the first periodic tick — so the skip buttons and the
    // slider were inert for as long as the episode took to open.
    private var currentTime: Double { return AudioPlayer.shared.currentTime }
    private var duration: Double    { return AudioPlayer.shared.duration }

    private var fullArtSize: CGFloat { return min(UIScreen.main.bounds.width - 40, 240) }

    // iOS 7 lays this view out under the translucent bar, iOS 6 starts it below —
    // measuring the bar covers both without a version check.
    private var topInset: CGFloat {
        guard let bar = navigationController?.navigationBar else { return 0 }
        return max(0, bar.convert(bar.bounds, to: view).maxY)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        // iOS 7 would pad the table for the bar by itself, but in list mode the table
        // no longer starts at the top — the insets are set by hand in both modes.
        // The property does not exist on iOS 6.
        if responds(to: #selector(setter: UIViewController.automaticallyAdjustsScrollViewInsets)) {
            automaticallyAdjustsScrollViewInsets = false
        }
        updateModeButton()
        observePlayer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Before the push animation, so the bar does not ride over the incoming screen
        NowPlayingVC.isOnScreen = true
        NotificationCenter.default.post(name: .nowPlayingVisibilityChanged, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if tableView == nil {
            setupUI()
            refreshFromCurrentEpisode()
        } else {
            refreshQueue()
        }
        // The rate outlives this screen, so the button adopts it rather than
        // assuming 1x on every appearance.
        syncSpeedFromPlayer()
        renderSleep()
    }

    // Creates and styles the player once. Frames come from layoutControls() and
    // layoutText(), which know both modes; installPlayer() puts it in place.
    private func setupUI() {
        let w = UIScreen.main.bounds.width

        headerView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 0))
        headerView.backgroundColor = .clear

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1)
        tableView.rowHeight = 64
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        // Artwork
        artworkView.contentMode = .scaleAspectFill
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        headerView.addSubview(artworkView)

        // The cover flips the mode too. A transparent button rather than a tap
        // recognizer, which fights with buttons on iOS 6.
        artworkBtn.backgroundColor = .clear
        artworkBtn.addTarget(self, action: #selector(modeTapped), for: .touchUpInside)
        headerView.addSubview(artworkBtn)

        // Title
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        headerView.addSubview(titleLabel)

        // Podcast name
        podcastLabel.backgroundColor = .clear
        podcastLabel.textColor = UIColor(white: 0.55, alpha: 1)
        headerView.addSubview(podcastLabel)

        // Why the player is not making any sound right now: loading, buffering,
        // downloading a stream AVPlayer refused, failed, or finished. Empty while
        // playing or paused, which are self-evident from the button.
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 12)
        headerView.addSubview(statusLabel)

        // Slider
        slider.minimumTrackTintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        // Continuous would fire valueChanged on every pixel of the drag, i.e. an
        // AVPlayer seek per tick — the thumb stutters and the audio stammers.
        // One seek on release, with the drag events keeping the labels live.
        slider.isContinuous = false
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderDragging),
                         for: [.touchDragInside, .touchDragOutside])
        headerView.addSubview(slider)

        // Time labels
        currentTimeLabel.backgroundColor = .clear
        currentTimeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        currentTimeLabel.font = UIFont.systemFont(ofSize: 11)
        currentTimeLabel.text = "0:00"
        headerView.addSubview(currentTimeLabel)

        remainingLabel.backgroundColor = .clear
        remainingLabel.textColor = UIColor(white: 0.5, alpha: 1)
        remainingLabel.font = UIFont.systemFont(ofSize: 11)
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-0:00"
        headerView.addSubview(remainingLabel)

        // Controls: [-15s]  [||/>]  [+30s]
        skipBackBtn.setTitle("-15s", for: .normal)
        skipBackBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipBackBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipBackBtn.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        headerView.addSubview(skipBackBtn)

        // Sized once: list mode shrinks it with a transform, so the circle and the
        // glyph scale together instead of the border radius going out of step.
        playPauseBtn.bounds = CGRect(x: 0, y: 0, width: 70, height: 70)
        playPauseBtn.setImage(UIImage(named: "pause"), for: .normal)
        playPauseBtn.setImage(UIImage(named: "play"), for: .selected)
        playPauseBtn.layer.cornerRadius = 35
        playPauseBtn.layer.borderWidth = 2
        playPauseBtn.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        headerView.addSubview(playPauseBtn)

        // Takes the button's place while the asset opens or the buffer runs dry,
        // instead of showing a pause glyph over silence.
        spinner.bounds = playPauseBtn.bounds
        spinner.hidesWhenStopped = true
        headerView.addSubview(spinner)

        skipFwdBtn.setTitle("+30s", for: .normal)
        skipFwdBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipFwdBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipFwdBtn.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        headerView.addSubview(skipFwdBtn)

        // Speed and sleep — purple when active, gray when not
        speedBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        updateSpeedBtn()
        speedBtn.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        headerView.addSubview(speedBtn)

        sleepBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        sleepBtn.addTarget(self, action: #selector(sleepTapped), for: .touchUpInside)
        headerView.addSubview(sleepBtn)
        renderSleep()

        installPlayer()
    }

    // MARK: - Layout

    // Frames for everything except the three text labels, for the current mode.
    // Run inside an animation block, this is the morph between the two layouts.
    // Returns the player's height.
    private func layoutControls() -> CGFloat {
        let w = UIScreen.main.bounds.width
        let mid = w / 2
        let playCenter: CGPoint
        let playScale: CGFloat
        let height: CGFloat
        switch mode {
        case .full:
            let art = fullArtSize
            artworkView.frame = CGRect(x: (w - art) / 2, y: 20, width: art, height: art)
            // Under the title, podcast and status lines (laid out by layoutText)
            let sliderY = 20 + art + 108
            slider.frame = CGRect(x: 20, y: sliderY, width: w - 40, height: 30)
            currentTimeLabel.frame = CGRect(x: 20, y: sliderY + 28, width: 50, height: 16)
            remainingLabel.frame   = CGRect(x: w - 70, y: sliderY + 28, width: 50, height: 16)
            let ctrlY = sliderY + 56
            skipBackBtn.frame = CGRect(x: 20, y: ctrlY, width: 60, height: 70)
            skipFwdBtn.frame  = CGRect(x: w - 80, y: ctrlY, width: 60, height: 70)
            playCenter = CGPoint(x: mid, y: ctrlY + 35)
            playScale  = 1
            // Speed and sleep share a row either side of centre
            speedBtn.frame = CGRect(x: mid - 72, y: ctrlY + 84, width: 64, height: 28)
            sleepBtn.frame = CGRect(x: mid + 8, y: ctrlY + 84, width: 64, height: 28)
            height = ctrlY + 126
        case .list:
            artworkView.frame = CGRect(x: 14, y: 12, width: 64, height: 64)
            // Elapsed and remaining either side of a shorter slider: one row, not two.
            // The labels keep their full-mode size so their text never stretches mid-morph.
            slider.frame = CGRect(x: 66, y: 86, width: w - 132, height: 30)
            currentTimeLabel.frame = CGRect(x: 14, y: 93, width: 50, height: 16)
            remainingLabel.frame   = CGRect(x: w - 64, y: 93, width: 50, height: 16)
            // Speed, -15s, play, +30s, sleep on one row, 60 pt apart
            skipBackBtn.frame = CGRect(x: mid - 86, y: 120, width: 52, height: 48)
            skipFwdBtn.frame  = CGRect(x: mid + 34, y: 120, width: 52, height: 48)
            playCenter = CGPoint(x: mid, y: 144)
            playScale  = 48 / 70
            speedBtn.frame = CGRect(x: mid - 152, y: 130, width: 64, height: 28)
            sleepBtn.frame = CGRect(x: mid + 88, y: 130, width: 64, height: 28)
            height = 176
        }
        artworkBtn.frame = artworkView.frame
        playPauseBtn.center = playCenter
        playPauseBtn.transform = playScale == 1 ? .identity
                                                : CGAffineTransform(scaleX: playScale, y: playScale)
        spinner.center = playCenter
        return height
    }

    // Title, podcast and status. Kept out of the morph: font and alignment differ
    // between the modes and neither animates, so these fade instead.
    private func layoutText() {
        let w = UIScreen.main.bounds.width
        switch mode {
        case .full:
            let y = 20 + fullArtSize + 18
            titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
            titleLabel.textAlignment = .center
            titleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
            podcastLabel.font = UIFont.systemFont(ofSize: 13)
            podcastLabel.textAlignment = .center
            podcastLabel.frame = CGRect(x: 20, y: y + 46, width: w - 40, height: 18)
            statusLabel.textAlignment = .center
            statusLabel.frame = CGRect(x: 20, y: y + 68, width: w - 40, height: 14)
        case .list:
            let x: CGFloat = 90
            let textW = w - x - 14
            titleLabel.font = UIFont.boldSystemFont(ofSize: 14)
            titleLabel.textAlignment = .left
            podcastLabel.font = UIFont.systemFont(ofSize: 12)
            podcastLabel.textAlignment = .left
            statusLabel.textAlignment = .left
            // One or two title lines plus the line under it, centred on the thumbnail
            let fit = titleLabel.textRect(forBounds: CGRect(x: 0, y: 0, width: textW, height: 34),
                                          limitedToNumberOfLines: 2)
            let titleH = min(34, ceil(fit.height))
            let y = 12 + floor((64 - titleH - 18) / 2)
            titleLabel.frame   = CGRect(x: x, y: y, width: textW, height: titleH)
            podcastLabel.frame = CGRect(x: x, y: y + titleH + 2, width: textW, height: 16)
            statusLabel.frame  = podcastLabel.frame
        }
        syncSubtitle()
    }

    // List mode has one line under the title: the status when there is one, else
    // the podcast. Full mode has room for both.
    private func syncSubtitle() {
        let hidePodcast = mode == .list && !(statusLabel.text ?? "").isEmpty
        if podcastLabel.isHidden != hidePodcast { podcastLabel.isHidden = hidePodcast }
    }

    // Puts the player where the current mode wants it, without animation.
    private func installPlayer() {
        let w = UIScreen.main.bounds.width
        let top = topInset
        let h = layoutControls()
        layoutText()
        switch mode {
        case .full:
            headerView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            tableView.frame = view.bounds
            tableView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
            tableView.scrollIndicatorInsets = tableView.contentInset
            tableView.tableHeaderView = headerView
            tableView.contentOffset = CGPoint(x: 0, y: -top)
        case .list:
            tableView.tableHeaderView = nil
            headerView.frame = CGRect(x: 0, y: top, width: w, height: h)
            view.addSubview(headerView)
            tableView.frame = CGRect(x: 0, y: top + h, width: w, height: view.bounds.height - top - h)
            tableView.contentInset = .zero
            tableView.scrollIndicatorInsets = .zero
        }
        updateFooter()
    }

    @objc private func modeTapped() {
        guard headerView != nil, !switchingMode else { return }
        switchingMode = true
        mode = (mode == .full) ? .list : .full
        UserDefaults.standard.set(mode == .list, forKey: NowPlayingVC.listModeKey)
        updateModeButton()

        // The text fades out, moves while invisible and fades back in where it
        // lands; everything else morphs.
        let texts = [titleLabel, podcastLabel, statusLabel]
        UIView.animate(withDuration: 0.1) { texts.forEach { $0.alpha = 0 } }
        morph {
            self.layoutText()
            UIView.animate(withDuration: 0.15, animations: {
                texts.forEach { $0.alpha = 1 }
            }, completion: { _ in self.switchingMode = false })
        }
    }

    // The player is re-parented only at a moment when its old and new homes put it
    // on the same pixels — out of the table where it currently sits on screen, back
    // into the table header once it has grown to full size at the top — so the
    // animation is the only thing that ever moves it.
    private func morph(completion: @escaping () -> Void) {
        let w = UIScreen.main.bounds.width
        let top = topInset
        if mode == .list {
            let onScreenY = headerView.convert(CGPoint.zero, to: view).y
            let rowsY = onScreenY + headerView.bounds.height
            tableView.tableHeaderView = nil
            headerView.frame.origin.y = onScreenY
            view.addSubview(headerView)
            tableView.contentInset = .zero
            tableView.scrollIndicatorInsets = .zero
            tableView.contentOffset = .zero
            tableView.frame = CGRect(x: 0, y: rowsY, width: w, height: view.bounds.height - top)
            updateFooter()
            // Settle the rows at their new origin now, or the animation block would
            // also slide them up from where the header used to push them
            tableView.layoutIfNeeded()
        }
        UIView.animate(withDuration: 0.3, animations: {
            let h = self.layoutControls()
            self.headerView.frame = CGRect(x: 0, y: top, width: w, height: h)
            // Lets the buttons and the slider re-lay their insides along with the frames
            self.headerView.layoutIfNeeded()
            if self.mode == .list {
                self.tableView.frame = CGRect(x: 0, y: top + h, width: w,
                                              height: self.view.bounds.height - top - h)
            } else {
                self.tableView.frame.origin.y = top + h
                self.tableView.contentOffset = .zero
            }
        }, completion: { _ in
            if self.mode == .full { self.installPlayer() }
            completion()
        })
    }

    // Shows where a tap goes: Phosphor "queue" in full mode (the list is Up Next),
    // "monitor-play" in list mode. Bar items read only the alpha channel (iOS 6
    // embosses it, iOS 7 tints it), so the PNGs' white fill is moot.
    private func updateModeButton() {
        let icon = UIImage(named: mode == .full ? "queue-icon" : "player-icon")
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: icon, style: .plain,
                                                            target: self, action: #selector(modeTapped))
    }

    private func refreshFromCurrentEpisode() {
        guard let ep = AudioPlayer.shared.currentEpisode else { return }
        titleLabel.text   = ep.title
        podcastLabel.text = ep.podcastTitle
        // Always at the full-mode size: a bitmap fetched for the list-mode thumbnail
        // would come back blurry once the cover grows into the full player.
        if !ep.artworkUrl.isEmpty {
            artworkView.load(url: ep.artworkUrl, maxPx: fullArtSize * UIScreen.main.scale)
        }
        layoutText()   // the list layout follows the title's line count
        renderTime()
        renderState()
    }

    // Registered for the whole lifetime of the screen. The four closures this
    // replaced were cleared on every disappear and only ever bound in
    // viewDidLoad, so pushing anything on top and coming back left a dead slider.
    private func observePlayer() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(playerTimeChanged),
                       name: .playerTimeChanged, object: nil)
        nc.addObserver(self, selector: #selector(playerStateChanged),
                       name: .playerStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(playerEpisodeChanged),
                       name: .playerEpisodeChanged, object: nil)
        nc.addObserver(self, selector: #selector(sleepTimerChanged),
                       name: .sleepTimerChanged, object: nil)
    }

    // The sleep countdown only moves while playing, which is when time ticks arrive.
    @objc private func playerTimeChanged()  { renderTime(); renderSleep() }
    @objc private func playerStateChanged() { renderState() }
    @objc private func sleepTimerChanged()  { renderSleep() }

    // Queue advance: stay on screen, swap the header contents and drop the row.
    @objc private func playerEpisodeChanged() {
        guard headerView != nil else { return }
        // Only the mini bar's close button can empty the player from under us
        guard AudioPlayer.shared.currentEpisode != nil else {
            navigationController?.popViewController(animated: true)
            return
        }
        lastDisplayedSecond   = -1
        lastDisplayedDuration = -1
        refreshFromCurrentEpisode()
        refreshQueue()
    }

    private func renderTime() {
        guard headerView != nil else { return }
        // While scrubbing, the drag handler owns both the thumb and the labels.
        guard !slider.isTracking else { return }
        let cur = currentTime, dur = duration
        let newVal = dur > 0 ? Float(min(1, max(0, cur / dur))) : 0
        if slider.value != newVal { slider.value = newVal }
        let s = Int(cur)
        guard s != lastDisplayedSecond || dur != lastDisplayedDuration else { return }
        lastDisplayedSecond   = s
        lastDisplayedDuration = dur
        currentTimeLabel.text = fmt(cur)
        // "--:--" rather than "-0:00" when the length is genuinely not known yet
        remainingLabel.text   = dur > 0 ? "-\(fmt(max(0, dur - cur)))" : "--:--"
    }

    private func renderState() {
        guard headerView != nil else { return }
        let p = AudioPlayer.shared
        let busy = p.isBusy
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        if playPauseBtn.isHidden != busy { playPauseBtn.isHidden = busy }
        playPauseBtn.isSelected = !p.isPlaying   // selected == the play glyph
        let canScrub = (p.duration > 0 && !busy)
        slider.isEnabled      = canScrub
        skipBackBtn.isEnabled = canScrub
        skipFwdBtn.isEnabled  = canScrub
        statusLabel.text = statusText()
        syncSubtitle()
    }

    private func statusText() -> String {
        let p = AudioPlayer.shared
        switch p.state {
        case .loading:
            if p.downloadProgress >= 0 {
                return "Downloading \(Int(p.downloadProgress * 100))%"
            }
            return "Loading…"
        case .stalled: return "Buffering…"
        case .failed:  return "Couldn't play this episode"
        case .ended:
            // Only an end-of-episode sleep timer parks here with something still queued
            return PlayQueue.shared.episodes.isEmpty ? "Finished — play to listen again"
                                                     : "Finished — play for up next"
        default:       return ""
        }
    }

    private func syncSpeedFromPlayer() {
        guard speedBtn.superview != nil else { return }
        speedIndex = speeds.firstIndex(of: AudioPlayer.shared.playbackRate) ?? 0
        updateSpeedBtn()
    }

    private func updateSpeedBtn() {
        let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        let s = speeds[speedIndex]
        let label: String
        switch s {
        case 0.5: label = "0.5x"
        case 1.5: label = "1.5x"
        case 2.0: label = "2x"
        default:  label = "1x"
        }
        speedBtn.setTitle(label, for: .normal)
        speedBtn.setTitleColor(s == 1.0 ? UIColor(white: 0.45, alpha: 1) : purple, for: .normal)
    }

    // MARK: - Sleep timer

    private func renderSleep() {
        guard sleepBtn.superview != nil else { return }
        let timer = SleepTimer.shared
        let label: String
        switch timer.mode {
        case .off:          label = "Sleep"
        case .endOfEpisode: label = "End"
        // Rounded up, so the last minute reads "1m" until it fires rather than "0m"
        case .countdown:    label = "\(max(1, Int(ceil(timer.remaining / 60))))m"
        }
        // Called on every time tick — only touch the button when the text moves
        guard sleepBtn.title(for: .normal) != label else { return }
        let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        sleepBtn.setTitle(label, for: .normal)
        sleepBtn.setTitleColor(timer.isActive ? purple : UIColor(white: 0.45, alpha: 1), for: .normal)
    }

    @objc private func sleepTapped() {
        let timer = SleepTimer.shared
        // addButton, NOT the vararg init: the ObjC nil-terminated list gets no
        // terminator from Swift — the same crash as UIAlertView on iOS 6.
        let sheet = UIActionSheet()
        sheet.title = "Sleep Timer"
        sheet.delegate = self
        var actions: [() -> Void] = []
        for m in sleepMinutes {
            sheet.addButton(withTitle: m == 60 ? "1 hour" : "\(m) minutes")
            actions.append { timer.start(minutes: m) }
        }
        // There is no end left to wait for once the episode has finished
        if AudioPlayer.shared.state != .ended {
            sheet.addButton(withTitle: "End of episode")
            actions.append { timer.startEndOfEpisode() }
        }
        if timer.isActive {
            sheet.destructiveButtonIndex = sheet.addButton(withTitle: "Turn Off Timer")
            actions.append { timer.cancel() }
        }
        sheet.cancelButtonIndex = sheet.addButton(withTitle: "Cancel")
        sleepActions = actions
        sheet.show(in: view)
    }

    func actionSheet(_ actionSheet: UIActionSheet, clickedButtonAt buttonIndex: Int) {
        let actions = sleepActions
        sleepActions = []
        // Cancel sits past the end of the list
        guard buttonIndex >= 0, buttonIndex < actions.count else { return }
        actions[buttonIndex]()
    }

    // MARK: - Queue

    private func refreshQueue() {
        guard tableView != nil else { return }
        // Nothing left to edit once the last row has gone
        if PlayQueue.shared.episodes.isEmpty && isEditing { setEditing(false, animated: false) }
        tableView.reloadData()
        updateFooter()
        renderState()   // the finished status reads differently with something queued
    }

    // List mode with nothing queued says so instead of showing an empty table
    private lazy var emptyQueueView: UIView = {
        let w = UIScreen.main.bounds.width
        let v = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 110))
        v.backgroundColor = .clear
        let title = UILabel(frame: CGRect(x: 20, y: 30, width: w - 40, height: 20))
        title.backgroundColor = .clear
        title.textColor = UIColor(white: 0.6, alpha: 1)
        title.font = UIFont.boldSystemFont(ofSize: 15)
        title.textAlignment = .center
        title.text = "Nothing up next"
        v.addSubview(title)
        let hint = UILabel(frame: CGRect(x: 30, y: 54, width: w - 60, height: 34))
        hint.backgroundColor = .clear
        hint.textColor = UIColor(white: 0.4, alpha: 1)
        hint.font = UIFont.systemFont(ofSize: 13)
        hint.textAlignment = .center
        hint.numberOfLines = 2
        hint.text = "Add episodes with + Queue on any episode."
        v.addSubview(hint)
        return v
    }()

    private func updateFooter() {
        guard tableView != nil else { return }
        if mode == .list && PlayQueue.shared.episodes.isEmpty {
            if tableView.tableFooterView !== emptyQueueView { tableView.tableFooterView = emptyQueueView }
        } else if tableView.tableFooterView == nil || tableView.tableFooterView === emptyQueueView {
            // An empty footer is what stops a plain table ruling lines under the last row
            tableView.tableFooterView = UIView(frame: .zero)
        }
    }

    private func updateQueueHeader() {
        queueEditBtn?.setTitle(isEditing ? "Done" : "Edit", for: .normal)
        queueSummaryLabel?.text = queueSummary()
    }

    // "4 episodes · 2 hr 10 min". The time is left off when any queued episode's
    // length is unknown — a total that silently skipped some would understate it.
    private func queueSummary() -> String {
        let eps = PlayQueue.shared.episodes
        let count = eps.count == 1 ? "1 episode" : "\(eps.count) episodes"
        var left: Double = 0
        for ep in eps {
            let len = ep.totalDuration()
            guard len > 0 else { return count }
            left += max(0, len - ep.resumePosition())
        }
        return "\(count) · \(NowPlayingVC.shortDuration(left))"
    }

    // "Podcast · 42 min", or "18 min left" for an episode already started
    private static func rowDetail(_ ep: Episode) -> String {
        let len = ep.totalDuration()
        guard len > 0 else { return ep.podcastTitle }
        let pos = ep.resumePosition()
        let time = pos > 0 ? "\(shortDuration(len - pos)) left" : shortDuration(len)
        return ep.podcastTitle.isEmpty ? time : "\(ep.podcastTitle) · \(time)"
    }

    // Rounded up, so a 20-second tail reads "1 min" rather than "0 min"
    private static func shortDuration(_ s: Double) -> String {
        let mins = max(1, Int(ceil(s / 60)))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    @objc private func editTapped() {
        setEditing(!isEditing, animated: true)
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
        updateQueueHeader()
    }

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        return PlayQueue.shared.episodes.count
    }

    func tableView(_ tv: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return PlayQueue.shared.episodes.isEmpty ? 0 : 32
    }

    // Edit lives here rather than in the nav bar, which now holds the mode switch.
    // A plain table's section header sticks to the top while the rows scroll, so
    // Edit stays in reach wherever the queue is.
    func tableView(_ tv: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard !PlayQueue.shared.episodes.isEmpty else { return nil }
        let w = tv.bounds.width
        let header = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 32))
        header.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.17, alpha: 1)

        let label = UILabel(frame: CGRect(x: 14, y: 8, width: 0, height: 16))
        label.backgroundColor = .clear
        label.textColor = UIColor(white: 0.55, alpha: 1)
        label.font = UIFont.boldSystemFont(ofSize: 12)
        label.text = "UP NEXT"
        label.sizeToFit()
        header.addSubview(label)

        let edit = UIButton(type: .custom)
        edit.frame = CGRect(x: w - 74, y: 0, width: 64, height: 32)
        edit.contentHorizontalAlignment = .right
        edit.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        edit.setTitleColor(UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1), for: .normal)
        edit.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        header.addSubview(edit)

        let summaryX = label.frame.maxX + 8
        let summary = UILabel(frame: CGRect(x: summaryX, y: 8, width: edit.frame.minX - summaryX - 4, height: 16))
        summary.backgroundColor = .clear
        summary.textColor = UIColor(white: 0.45, alpha: 1)
        summary.font = UIFont.systemFont(ofSize: 12)
        header.addSubview(summary)

        queueEditBtn = edit
        queueSummaryLabel = summary
        updateQueueHeader()
        return header
    }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tv.dequeueReusableCell(withIdentifier: "queue") as? QueueCell
            ?? QueueCell(style: .default, reuseIdentifier: "queue")
        let ep = PlayQueue.shared.episodes[indexPath.row]
        cell.episodeLabel.text = ep.title
        cell.infoLabel.text    = NowPlayingVC.rowDetail(ep)
        if ep.artworkUrl.isEmpty {
            cell.artView.cancel()
            cell.artView.image = nil
        } else {
            cell.artView.load(url: ep.artworkUrl)
        }
        cell.setNeedsLayout()   // the title's line count moves the labels
        return cell
    }

    func tableView(_ tv: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { return true }

    func tableView(_ tv: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { return true }

    // Swipe-to-delete when idle; plain reorder handles in edit mode (no red minus)
    func tableView(_ tv: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        return tv.isEditing ? .none : .delete
    }

    func tableView(_ tv: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        return false
    }

    func tableView(_ tv: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        PlayQueue.shared.remove(at: indexPath.row)
        tv.deleteRows(at: [indexPath], with: .automatic)
        // Losing the last row takes the section header with it
        if PlayQueue.shared.episodes.isEmpty { refreshQueue() } else { updateQueueHeader() }
    }

    func tableView(_ tv: UITableView, moveRowAt from: IndexPath, to: IndexPath) {
        PlayQueue.shared.move(from: from.row, to: to.row)
    }

    func tableView(_ tv: UITableView, didSelectRowAt indexPath: IndexPath) {
        tv.deselectRow(at: indexPath, animated: true)
        let ep = PlayQueue.shared.episodes[indexPath.row]
        PlayQueue.shared.remove(at: indexPath.row)
        AudioPlayer.shared.play(episode: ep)
    }

    // MARK: - Transport

    @objc private func playPauseTapped() {
        AudioPlayer.shared.isPlaying ? AudioPlayer.shared.pause() : AudioPlayer.shared.resume()
    }

    @objc private func skipBack() {
        AudioPlayer.shared.seek(to: max(0, currentTime - 15))
    }

    @objc private func skipForward() {
        guard duration > 0 else { return }
        AudioPlayer.shared.seek(to: min(duration - 1, currentTime + 30))
    }

    // Fires on release only (isContinuous = false).
    @objc private func sliderMoved() {
        guard duration > 0 else { return }
        lastDisplayedSecond = -1   // let the next tick repaint the labels
        AudioPlayer.shared.seek(to: Double(slider.value) * duration)
    }

    // Live labels during the drag, since no seek happens until the finger lifts.
    @objc private func sliderDragging() {
        guard duration > 0 else { return }
        let t = Double(slider.value) * duration
        currentTimeLabel.text = fmt(t)
        remainingLabel.text   = "-\(fmt(max(0, duration - t)))"
    }

    @objc private func speedTapped() {
        speedIndex = (speedIndex + 1) % speeds.count
        AudioPlayer.shared.setSpeed(speeds[speedIndex])
        updateSpeedBtn()
        // Only wake a deliberately paused player — resume() on a finished one
        // restarts the episode, which is not what picking a speed asked for.
        if AudioPlayer.shared.state == .paused { AudioPlayer.shared.resume() }
    }

    // Past the hour, "84:12" makes you do the arithmetic — long episodes get an hours field.
    private func fmt(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NowPlayingVC.isOnScreen = false
        NotificationCenter.default.post(name: .nowPlayingVisibilityChanged, object: nil)
    }
}

// Queue row: thumbnail, title, "Podcast · 42 min". Laid out by hand because edit
// mode narrows the content view to make room for the reorder handle.
private class QueueCell: UITableViewCell {
    let artView      = AsyncImageView(frame: CGRect(x: 14, y: 10, width: 44, height: 44))
    let episodeLabel = UILabel()
    let infoLabel    = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        // A plain rectangular clip: with no cornerRadius it costs no off-screen pass
        artView.contentMode = .scaleAspectFill
        artView.clipsToBounds = true
        artView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        contentView.addSubview(artView)

        episodeLabel.backgroundColor = .clear
        episodeLabel.textColor = .white
        episodeLabel.font = UIFont.systemFont(ofSize: 14)
        episodeLabel.numberOfLines = 2
        contentView.addSubview(episodeLabel)

        infoLabel.backgroundColor = .clear
        infoLabel.textColor = UIColor(white: 0.5, alpha: 1)
        infoLabel.font = UIFont.systemFont(ofSize: 11)
        contentView.addSubview(infoLabel)

        let sel = UIView()
        sel.backgroundColor = UIColor(white: 0.2, alpha: 1)
        selectedBackgroundView = sel
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = contentView.bounds
        artView.frame = CGRect(x: 14, y: floor((b.height - 44) / 2), width: 44, height: 44)
        let x: CGFloat = 70
        let w = max(0, b.width - x - 10)
        // A one-line title sits centred with the line under it instead of floating
        // in a two-line box
        let fit = episodeLabel.textRect(forBounds: CGRect(x: 0, y: 0, width: w, height: 34),
                                        limitedToNumberOfLines: 2)
        let titleH = min(34, ceil(fit.height))
        let y = floor((b.height - titleH - 16) / 2)
        episodeLabel.frame = CGRect(x: x, y: y, width: w, height: titleH)
        infoLabel.frame    = CGRect(x: x, y: y + titleH + 2, width: w, height: 14)
    }
}
