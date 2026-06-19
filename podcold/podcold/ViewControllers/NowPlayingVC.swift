import UIKit

class NowPlayingVC: UIViewController {
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
    private var scrollView: UIScrollView!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Now Playing"
        view.backgroundColor = UIColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        setupUI()
        refreshFromCurrentEpisode()
        bindPlayer()
    }

    private func setupUI() {
        let w = UIScreen.main.bounds.width

        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        var y: CGFloat = 20

        // Artwork
        let artSize: CGFloat = min(w - 40, 240)
        artworkView.frame = CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize)
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.layer.cornerRadius = 8
        artworkView.backgroundColor = UIColor(white: 0.15, alpha: 1)
        scrollView.addSubview(artworkView)
        y += artSize + 18

        // Title
        titleLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 44)
        titleLabel.backgroundColor = .clear
        titleLabel.textColor = .white
        titleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        scrollView.addSubview(titleLabel)
        y += 46

        // Podcast name
        podcastLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 18)
        podcastLabel.backgroundColor = .clear
        podcastLabel.textColor = UIColor(white: 0.55, alpha: 1)
        podcastLabel.font = UIFont.systemFont(ofSize: 13)
        podcastLabel.textAlignment = .center
        scrollView.addSubview(podcastLabel)
        y += 26

        // Slider
        slider.frame = CGRect(x: 20, y: y, width: w - 40, height: 30)
        slider.minimumTrackTintColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        slider.addTarget(self, action: #selector(sliderMoved), for: .valueChanged)
        scrollView.addSubview(slider)
        y += 28

        // Time labels
        currentTimeLabel.frame = CGRect(x: 20, y: y, width: 60, height: 16)
        currentTimeLabel.backgroundColor = .clear
        currentTimeLabel.textColor = UIColor(white: 0.5, alpha: 1)
        currentTimeLabel.font = UIFont.systemFont(ofSize: 11)
        currentTimeLabel.text = "0:00"
        scrollView.addSubview(currentTimeLabel)

        remainingLabel.frame = CGRect(x: w - 80, y: y, width: 60, height: 16)
        remainingLabel.backgroundColor = .clear
        remainingLabel.textColor = UIColor(white: 0.5, alpha: 1)
        remainingLabel.font = UIFont.systemFont(ofSize: 11)
        remainingLabel.textAlignment = .right
        remainingLabel.text = "-0:00"
        scrollView.addSubview(remainingLabel)
        y += 28

        // Controls row: [-15s]  [||/>]  [+30s]
        let ctrlY = y
        let ctrlH: CGFloat = 70

        skipBackBtn.frame = CGRect(x: 20, y: ctrlY, width: 60, height: ctrlH)
        skipBackBtn.setTitle("-15s", for: .normal)
        skipBackBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipBackBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipBackBtn.addTarget(self, action: #selector(skipBack), for: .touchUpInside)
        scrollView.addSubview(skipBackBtn)

        playPauseBtn.frame = CGRect(x: (w - 70) / 2, y: ctrlY, width: 70, height: ctrlH)
        playPauseBtn.setTitle("||", for: .normal)
        playPauseBtn.setTitle(">", for: .selected)
        playPauseBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 22)
        playPauseBtn.setTitleColor(.white, for: .normal)
        playPauseBtn.setTitleColor(.white, for: .selected)
        playPauseBtn.layer.cornerRadius = 35
        playPauseBtn.layer.borderWidth = 2
        playPauseBtn.layer.borderColor = UIColor(white: 0.4, alpha: 1).cgColor
        playPauseBtn.clipsToBounds = true
        playPauseBtn.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        scrollView.addSubview(playPauseBtn)

        skipFwdBtn.frame = CGRect(x: w - 80, y: ctrlY, width: 60, height: ctrlH)
        skipFwdBtn.setTitle("+30s", for: .normal)
        skipFwdBtn.setTitleColor(UIColor(white: 0.65, alpha: 1), for: .normal)
        skipFwdBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        skipFwdBtn.addTarget(self, action: #selector(skipForward), for: .touchUpInside)
        scrollView.addSubview(skipFwdBtn)

        y = ctrlY + ctrlH + 14

        // Speed button — purple when active, gray at 1x
        speedBtn.frame = CGRect(x: (w - 60) / 2, y: y, width: 60, height: 28)
        speedBtn.setTitle("1x", for: .normal)
        speedBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        updateSpeedBtn()
        speedBtn.addTarget(self, action: #selector(speedTapped), for: .touchUpInside)
        scrollView.addSubview(speedBtn)
        y += 42

        scrollView.contentSize = CGSize(width: w, height: y + 20)
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
            guard let self = self else { return }
            self.currentTime = cur
            self.duration = dur
            if !self.slider.isTracking && dur > 0 { self.slider.value = Float(cur / dur) }
            self.currentTimeLabel.text = self.fmt(cur)
            self.remainingLabel.text   = "-\(self.fmt(max(0, dur - cur)))"
        }
        AudioPlayer.shared.onStateChange = { [weak self] in self?.updatePlayPauseBtn() }
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
        AudioPlayer.shared.onProgress    = nil
        AudioPlayer.shared.onStateChange = nil
        AudioPlayer.shared.onFinish      = nil
    }
}
