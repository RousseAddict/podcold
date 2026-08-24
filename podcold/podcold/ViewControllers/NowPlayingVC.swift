import UIKit

class NowPlayingVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let artworkView      = AsyncImageView()
    private let titleLabel       = UILabel()
    private let podcastLabel     = UILabel()
    private let playPauseBtn     = UIButton(type: .custom)
    private let skipBackBtn      = UIButton(type: .custom)
    private let skipFwdBtn       = UIButton(type: .custom)
    private let slider           = UISlider()
    private let currentTimeLabel = UILabel()
    private let remainingLabel   = UILabel()
    private let speedBtn         = UIButton(type: .custom)
    private var duration: Double = 0
    private var currentTime: Double = 0
    private let speeds: [Float]  = [1.0, 1.5, 2.0, 0.5]
    private var speedIndex       = 0
    private var tableView: UITableView!
    private var headerView: UIView!
    private var lastDisplayedSecond = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        bindPlayer()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard tableView == nil else {
            refreshQueue()
            return
        }
        setupUI()
        refreshFromCurrentEpisode()
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
        y += 26

        // Slider
        slider.frame = CGRect(x: 20, y: y, width: w - 40, height: 30)
        slider.minimumTrackTintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
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

        skipFwdBtn.frame = CGRect(x: w - 80, y: ctrlY, width: 60, height: ctrlH)
        skipFwdBtn.setTitle("+30s", for: .normal)
        skipFwdBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipFwdBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipFwdBtn.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        headerView.addSubview(skipFwdBtn)

        y = ctrlY + ctrlH + 14

        // Speed button — purple when active, gray at 1x
        speedBtn.frame = CGRect(x: (w - 60) / 2, y: y, width: 60, height: 28)
        speedBtn.setTitle("1x", for: .normal)
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
        updatePlayPauseBtn()
    }

    private func bindPlayer() {
        AudioPlayer.shared.onProgress = { [weak self] cur, dur in
            guard let self = self, self.headerView != nil else { return }
            self.currentTime = cur
            self.duration = dur
            if !self.slider.isTracking && dur > 0 {
                let newVal = Float(cur / dur)
                if self.slider.value != newVal { self.slider.value = newVal }
            }
            let s = Int(cur)
            if s != self.lastDisplayedSecond {
                self.lastDisplayedSecond = s
                self.currentTimeLabel.text = self.fmt(cur)
                self.remainingLabel.text   = "-\(self.fmt(max(0, dur - cur)))"
            }
        }
        AudioPlayer.shared.onStateChange = { [weak self] in self?.updatePlayPauseBtn() }
        // Queue advance: stay on screen, swap the header contents and drop the row
        AudioPlayer.shared.onEpisodeChange = { [weak self] in
            guard let self = self, self.headerView != nil else { return }
            self.lastDisplayedSecond = -1
            self.slider.value = 0
            self.refreshFromCurrentEpisode()
            self.refreshQueue()
        }
        // Only fires when the queue is empty — otherwise the next episode takes over
        AudioPlayer.shared.onFinish      = { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }

    private func updatePlayPauseBtn() {
        playPauseBtn.isSelected = !AudioPlayer.shared.isPlaying
    }

    private func updateSpeedBtn() {
        let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        let isDefault = speeds[speedIndex] == 1.0
        speedBtn.setTitleColor(isDefault ? UIColor(white: 0.45, alpha: 1) : purple, for: .normal)
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

    @objc private func sliderMoved() {
        guard duration > 0 else { return }
        AudioPlayer.shared.seek(to: Double(slider.value) * duration)
    }

    @objc private func speedTapped() {
        speedIndex = (speedIndex + 1) % speeds.count
        let s = speeds[speedIndex]
        AudioPlayer.shared.setSpeed(s)
        let label: String
        switch s {
        case 0.5: label = "0.5x"
        case 1.0: label = "1x"
        case 1.5: label = "1.5x"
        default:  label = "2x"
        }
        speedBtn.setTitle(label, for: .normal)
        updateSpeedBtn()
        if !AudioPlayer.shared.isPlaying { AudioPlayer.shared.resume() }
    }

    private func fmt(_ s: Double) -> String {
        let t = Int(s); return String(format: "%d:%02d", t / 60, t % 60)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        AudioPlayer.shared.onProgress      = nil
        AudioPlayer.shared.onStateChange   = nil
        AudioPlayer.shared.onFinish        = nil
        AudioPlayer.shared.onEpisodeChange = nil
    }
}
