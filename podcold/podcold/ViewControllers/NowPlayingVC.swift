import UIKit

class NowPlayingVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    // The mini bar hides behind this screen. It used to discover that by polling
    // the navigation stack twice a second; now the screen simply says so.
    private(set) static var isOnScreen = false

    private let artworkView      = AsyncImageView()
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
    private var tableView: UITableView!
    private var headerView: UIView!
    private var lastDisplayedSecond = -1
    private var lastDisplayedDuration: Double = -1

    // The player owns these now. The screen used to keep its own copies, which
    // only existed after the first periodic tick — so the skip buttons and the
    // slider were inert for as long as the episode took to open.
    private var currentTime: Double { return AudioPlayer.shared.currentTime }
    private var duration: Double    { return AudioPlayer.shared.duration }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
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
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width

        // The whole player lives in the table header — queue rows scroll underneath it.
        headerView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 0))
        headerView.backgroundColor = .clear

        tableView = UITableView(frame: view.bounds, style: .plain)
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        tableView.separatorColor = UIColor(white: 0.18, alpha: 1)
        tableView.rowHeight = 56
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)

        var y: CGFloat = 20

        // Artwork
        let artSize: CGFloat = min(w - 40, 240)
        artworkView.frame = CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize)
        artworkView.contentMode = .scaleAspectFill
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        headerView.addSubview(artworkView)
        y += artSize + 18

        // Title
        titleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        headerView.addSubview(titleLabel)
        y += 46

        // Podcast name
        podcastLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 18)
        podcastLabel.backgroundColor = .clear
        podcastLabel.textColor = UIColor(white: 0.55, alpha: 1)
        podcastLabel.font = UIFont.systemFont(ofSize: 13)
        podcastLabel.textAlignment = .center
        headerView.addSubview(podcastLabel)
        y += 22

        // Why the player is not making any sound right now: loading, buffering,
        // downloading a stream AVPlayer refused, failed, or finished. Empty while
        // playing or paused, which are self-evident from the button.
        statusLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 14)
        statusLabel.backgroundColor = .clear
        statusLabel.textColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 12)
        statusLabel.textAlignment = .center
        headerView.addSubview(statusLabel)
        y += 22

        // Slider
        slider.frame = CGRect(x: 20, y: y, width: w - 40, height: 30)
        slider.minimumTrackTintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        // Continuous would fire valueChanged on every pixel of the drag, i.e. an
        // AVPlayer seek per tick — the thumb stutters and the audio stammers.
        // One seek on release, with the drag events keeping the labels live.
        slider.isContinuous = false
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        slider.addTarget(self, action: #selector(sliderDragging),
                         for: [.touchDragInside, .touchDragOutside])
        headerView.addSubview(slider)
        y += 28

        // Time labels
        currentTimeLabel.frame = CGRect(x: 20, y: y, width: 60, height: 16)
        currentTimeLabel.backgroundColor = .clear
        currentTimeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        currentTimeLabel.font = UIFont.systemFont(ofSize: 11)
        currentTimeLabel.text = "0:00"
        headerView.addSubview(currentTimeLabel)

        remainingLabel.frame = CGRect(x: w - 80, y: y, width: 60, height: 16)
        remainingLabel.backgroundColor = .clear
        remainingLabel.textColor = UIColor(white: 0.5, alpha: 1)
        remainingLabel.font = UIFont.systemFont(ofSize: 11)
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-0:00"
        headerView.addSubview(remainingLabel)
        y += 28

        // Controls row: [-15s]  [||/>]  [+30s]
        let ctrlY = y
        let ctrlH: CGFloat = 70

        skipBackBtn.frame = CGRect(x: 20, y: ctrlY, width: 60, height: ctrlH)
        skipBackBtn.setTitle("-15s", for: .normal)
        skipBackBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipBackBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipBackBtn.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        headerView.addSubview(skipBackBtn)

        playPauseBtn.frame = CGRect(x: (w - 70) / 2, y: ctrlY, width: 70, height: ctrlH)
        playPauseBtn.setImage(UIImage(named: "pause"), for: .normal)
        playPauseBtn.setImage(UIImage(named: "play"), for: .selected)
        playPauseBtn.layer.cornerRadius = 35
        playPauseBtn.layer.borderWidth = 2
        playPauseBtn.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        headerView.addSubview(playPauseBtn)

        // Takes the button's place while the asset opens or the buffer runs dry,
        // instead of showing a pause glyph over silence.
        spinner.frame = playPauseBtn.frame
        spinner.hidesWhenStopped = true
        headerView.addSubview(spinner)

        skipFwdBtn.frame = CGRect(x: w - 80, y: ctrlY, width: 60, height: ctrlH)
        skipFwdBtn.setTitle("+30s", for: .normal)
        skipFwdBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipFwdBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipFwdBtn.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        headerView.addSubview(skipFwdBtn)

        y = ctrlY + ctrlH + 14

        // Speed button — purple when active, gray at 1x
        speedBtn.frame = CGRect(x: (w - 60) / 2, y: y, width: 60, height: 28)
        speedBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        updateSpeedBtn()
        speedBtn.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        headerView.addSubview(speedBtn)
        y += 42

        headerView.frame = CGRect(x: 0, y: 0, width: w, height: y)
        tableView.tableHeaderView = headerView
        updateEditButton()
    }

    private func refreshFromCurrentEpisode() {
        guard let ep = AudioPlayer.shared.currentEpisode else { return }
        titleLabel.text   = ep.title
        podcastLabel.text = ep.podcastTitle
        if !ep.artworkUrl.isEmpty { artworkView.load(url: ep.artworkUrl) }
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
    }

    @objc private func playerTimeChanged()  { renderTime() }
    @objc private func playerStateChanged() { renderState() }

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
        case .ended:   return "Finished — play to listen again"
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

    // MARK: - Queue

    private func refreshQueue() {
        guard tableView != nil else { return }
        tableView.reloadData()
        updateEditButton()
    }

    private func updateEditButton() {
        if PlayQueue.shared.episodes.isEmpty {
            if isEditing { setEditing(false, animated: false) }
            navigationItem.rightBarButtonItem = nil
        } else {
            navigationItem.rightBarButtonItem = editButtonItem
        }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        tableView?.setEditing(editing, animated: animated)
    }

    func tableView(_ tv: UITableView, numberOfRowsInSection section: Int) -> Int {
        return PlayQueue.shared.episodes.count
    }

    func tableView(_ tv: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return PlayQueue.shared.episodes.isEmpty ? 0 : 28
    }

    func tableView(_ tv: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard !PlayQueue.shared.episodes.isEmpty else { return nil }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tv.bounds.width, height: 28))
        header.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.17, alpha: 1)
        let label = UILabel(frame: CGRect(x: 14, y: 6, width: tv.bounds.width - 28, height: 16))
        label.backgroundColor = .clear
        label.textColor = UIColor(white: 0.55, alpha: 1)
        label.font = UIFont.boldSystemFont(ofSize: 12)
        label.text = "UP NEXT"
        header.addSubview(label)
        return header
    }

    func tableView(_ tv: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = "queue"
        var cell = tv.dequeueReusableCell(withIdentifier: id)
        if cell == nil {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: id)
            cell?.backgroundColor = .clear
            cell?.textLabel?.backgroundColor = .clear
            cell?.textLabel?.textColor = .white
            cell?.textLabel?.font = UIFont.systemFont(ofSize: 14)
            cell?.textLabel?.numberOfLines = 2
            cell?.detailTextLabel?.backgroundColor = .clear
            cell?.detailTextLabel?.textColor = UIColor(white: 0.5, alpha: 1)
            cell?.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
            let sel = UIView()
            sel.backgroundColor = UIColor(white: 0.2, alpha: 1)
            cell?.selectedBackgroundView = sel
        }
        let ep = PlayQueue.shared.episodes[indexPath.row]
        cell?.textLabel?.text = ep.title
        cell?.detailTextLabel?.text = ep.podcastTitle
        return cell!
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
        // Losing the last row takes the section header and the Edit button with it
        if PlayQueue.shared.episodes.isEmpty { refreshQueue() } else { updateEditButton() }
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

    private func fmt(_ s: Double) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NowPlayingVC.isOnScreen = false
        NotificationCenter.default.post(name: .nowPlayingVisibilityChanged, object: nil)
    }
}
