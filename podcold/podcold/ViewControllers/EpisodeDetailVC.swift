import UIKit

class EpisodeDetailVC: UIViewController {
    private let episode: Episode
    private let podcast: Podcast
    private var downloadBtn: UIButton!
    private var queueBtn: UIButton!

    private static let purple = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
    private static let red    = UIColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 1)

    init(episode: Episode, podcast: Podcast) {
        self.episode = episode; self.podcast = podcast
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        let w = UIScreen.main.bounds.width
        let scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        var y: CGFloat = 20

        let artSize: CGFloat = min(w - 40, 260)
        let artwork = AsyncImageView(frame: CGRect(x: (w - artSize) / 2, y: y, width: artSize, height: artSize))
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.layer.shouldRasterize = true
        artwork.layer.rasterizationScale = UIScreen.main.scale
        artwork.backgroundColor = UIColor(white: 0.15, alpha: 1)
        let imgUrl = episode.artworkUrl.isEmpty ? podcast.artworkUrl600 : episode.artworkUrl
        if !imgUrl.isEmpty { artwork.load(url: imgUrl) }
        scrollView.addSubview(artwork)
        y += artSize + 20

        let titleLabel = UILabel(frame: CGRect(x: 20, y: y, width: w - 40, height: 50))
        titleLabel.text = episode.title
        titleLabel.textColor = .white
        titleLabel.backgroundColor = .clear
        titleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        titleLabel.numberOfLines = 2
        scrollView.addSubview(titleLabel)
        y += 54

        let authorLabel = UILabel(frame: CGRect(x: 20, y: y, width: w - 40, height: 20))
        authorLabel.text = podcast.author
        authorLabel.textColor = UIColor(white: 0.55, alpha: 1)
        authorLabel.backgroundColor = .clear
        authorLabel.font = UIFont.systemFont(ofSize: 13)
        scrollView.addSubview(authorLabel)
        y += 32

        // Action buttons — one metric for all three: 20pt margins, 12pt gap,
        // so the two halves and the full-width row line up exactly.
        let btnH: CGFloat = 40
        let colW = (w - 52) / 2

        let playBtn = UIButton(type: .custom)
        playBtn.frame = CGRect(x: 20, y: y, width: colW, height: btnH)
        playBtn.setTitle("Play", for: .normal)
        playBtn.setTitleColor(.white, for: .normal)
        playBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 15)
        playBtn.backgroundColor = EpisodeDetailVC.purple
        playBtn.layer.cornerRadius = btnH / 2
        playBtn.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        scrollView.addSubview(playBtn)

        queueBtn = UIButton(type: .custom)
        queueBtn.frame = CGRect(x: 32 + colW, y: y, width: colW, height: btnH)
        queueBtn.layer.cornerRadius = btnH / 2
        queueBtn.layer.borderWidth = 1
        queueBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        queueBtn.addTarget(self, action: #selector(queueTapped), for: .touchUpInside)
        scrollView.addSubview(queueBtn)
        updateQueueButton()
        y += btnH + 10

        // One button cycling Download -> progress -> Remove Download, so the row is
        // never half-empty and there is no dead "Offline" button next to a Remove.
        downloadBtn = UIButton(type: .custom)
        downloadBtn.frame = CGRect(x: 20, y: y, width: w - 40, height: btnH)
        downloadBtn.layer.cornerRadius = btnH / 2
        downloadBtn.layer.borderWidth = 1
        downloadBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        downloadBtn.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        scrollView.addSubview(downloadBtn)

        updateDownloadButton(progress: nil)
        y += btnH + 12

        if !episode.summary.isEmpty {
            let sep = UIView(frame: CGRect(x: 20, y: y, width: w - 40, height: 1))
            sep.backgroundColor = UIColor(white: 0.2, alpha: 1)
            scrollView.addSubview(sep)
            y += 12

            let descLabel = UILabel()
            descLabel.textColor = UIColor(white: 0.75, alpha: 1)
            descLabel.backgroundColor = .clear
            descLabel.font = UIFont.systemFont(ofSize: 13)
            descLabel.numberOfLines = 0
            descLabel.frame = CGRect(x: 20, y: y, width: w - 40, height: 0)
            scrollView.addSubview(descLabel)

            let labelY = y
            let capturedW = w
            let summary = episode.summary
            DispatchQueue(label: "com.podcold.misc").async {
                let text = EpisodeDetailVC.stripHTML(summary)
                DispatchQueue.main.async { [weak descLabel, weak scrollView] in
                    guard let lbl = descLabel, let sv = scrollView else { return }
                    lbl.text = text
                    lbl.sizeToFit()
                    sv.contentSize = CGSize(width: capturedW, height: labelY + lbl.frame.height + 16 + 70)
                }
            }
        }

        scrollView.contentSize = CGSize(width: w, height: y + 70)
    }

    private func updateDownloadButton(progress: Float?) {
        if let p = progress {
            downloadBtn.setTitle("\(Int(p * 100))%", for: .normal)
            downloadBtn.setTitleColor(UIColor(white: 0.6, alpha: 1), for: .normal)
            downloadBtn.layer.borderColor = UIColor(white: 0.3, alpha: 1).cgColor
            downloadBtn.isEnabled = false
        } else if episode.localPath() != nil {
            downloadBtn.setTitle("Remove Download", for: .normal)
            downloadBtn.setTitleColor(EpisodeDetailVC.red, for: .normal)
            downloadBtn.layer.borderColor = EpisodeDetailVC.red.cgColor
            downloadBtn.isEnabled = true
        } else {
            downloadBtn.setTitle("Download", for: .normal)
            downloadBtn.setTitleColor(EpisodeDetailVC.purple, for: .normal)
            downloadBtn.layer.borderColor = EpisodeDetailVC.purple.cgColor
            downloadBtn.isEnabled = true
        }
    }

    private func updateQueueButton() {
        let purple = EpisodeDetailVC.purple
        if PlayQueue.shared.contains(guid: episode.guid) {
            queueBtn.setTitle("Queued", for: .normal)
            queueBtn.setTitleColor(UIColor(white: 0.45, alpha: 1), for: .normal)
            queueBtn.layer.borderColor = UIColor(white: 0.25, alpha: 1).cgColor
        } else {
            queueBtn.setTitle("+ Queue", for: .normal)
            queueBtn.setTitleColor(purple, for: .normal)
            queueBtn.layer.borderColor = purple.cgColor
        }
    }

    @objc private func queueTapped() {
        if PlayQueue.shared.contains(guid: episode.guid) {
            PlayQueue.shared.remove(guid: episode.guid)
        } else {
            PlayQueue.shared.add(episode)
        }
        updateQueueButton()
    }

    // Same button in all three states — the title says which one is live
    @objc private func downloadTapped() {
        if let path = episode.localPath() {
            try? FileManager.default.removeItem(atPath: path)
            Episode.removeFromDownloads(guid: episode.guid)
            updateDownloadButton(progress: nil)
            return
        }
        updateDownloadButton(progress: 0)
        EpisodeDownloader.download(episode: episode,
            progress: { [weak self] p in self?.updateDownloadButton(progress: p) },
            completion: { [weak self] _ in self?.updateDownloadButton(progress: nil) })
    }

    private static func stripHTML(_ s: String) -> String {
        // Remove tags
        var out = ""
        var inTag = false
        for c in s {
            if c == "<" { inTag = true }
            else if c == ">" { inTag = false }
            else if !inTag { out.append(c) }
        }
        // Decode common HTML entities
        out = out.replacingOccurrences(of: "&amp;",  with: "&")
        out = out.replacingOccurrences(of: "&lt;",   with: "<")
        out = out.replacingOccurrences(of: "&gt;",   with: ">")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&#39;",  with: "'")
        out = out.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse runs of whitespace/newlines left by removed block tags
        var result = ""
        var prevNewline = false
        for c in out {
            if c == "\n" || c == "\r" {
                if !prevNewline { result.append("\n") }
                prevNewline = true
            } else {
                prevNewline = false
                result.append(c)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func playTapped() {
        // Playing it now takes it out of "up next"
        PlayQueue.shared.remove(guid: episode.guid)
        AudioPlayer.shared.play(episode: episode)
        navigationController?.pushViewController(NowPlayingVC(), animated: true)
    }
}
