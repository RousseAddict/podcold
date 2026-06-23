import UIKit

class HomeVC: UIViewController {
    private var scrollView: UIScrollView!
    private var podcasts:       [Podcast] = []
    private var recentEpisodes: [Episode] = []
    private var builtPodcastUrls: [String] = []
    private var builtRecentGuids: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "podcold"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let searchBtn   = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(openSearch))
        let settingsBtn = UIBarButtonItem(image: HomeVC.gearIcon(), style: .plain, target: self, action: #selector(openSettings))
        navigationItem.rightBarButtonItems = [searchBtn, settingsBtn]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Downloads", style: .plain, target: self, action: #selector(openDownloads))
        scrollView = UIScrollView(frame: view.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        podcasts       = Podcast.loadSubscriptions()
        recentEpisodes = Episode.loadRecents().filter { $0.savedPosition() > 30 }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let newUrls  = podcasts.map { $0.feedUrl }
        let newGuids = recentEpisodes.map { $0.guid }
        guard newUrls != builtPodcastUrls || newGuids != builtRecentGuids else { return }
        builtPodcastUrls  = newUrls
        builtRecentGuids  = newGuids
        rebuildLayout()
    }

    // MARK: - Layout

    private func rebuildLayout() {
        scrollView.subviews.forEach { $0.removeFromSuperview() }
        let w = UIScreen.main.bounds.width
        var y: CGFloat = 12

        if !recentEpisodes.isEmpty {
            scrollView.addSubview(sectionHeader("Continue Listening", y: y, w: w))
            y += 34

            let stripH: CGFloat = 158
            let strip = UIScrollView(frame: CGRect(x: 0, y: y, width: w, height: stripH))
            strip.showsHorizontalScrollIndicator = false
            strip.showsVerticalScrollIndicator   = false
            var cx: CGFloat = 12
            for (i, ep) in recentEpisodes.enumerated() {
                let card = episodeCard(ep, index: i)
                card.frame = CGRect(x: cx, y: 4, width: 120, height: 150)
                strip.addSubview(card)
                cx += 130
            }
            strip.contentSize = CGSize(width: cx + 12, height: stripH)
            scrollView.addSubview(strip)
            y += stripH + 16
        }

        scrollView.addSubview(sectionHeader("My Podcasts", y: y, w: w))
        y += 34

        if podcasts.isEmpty {
            let empty = emptyState(y: y, w: w)
            scrollView.addSubview(empty)
            y += 150
        } else {
            let cols:  CGFloat = 3
            let gap:   CGFloat = 10
            let pad:   CGFloat = 12
            let cellW = floor((w - pad * 2 - gap * (cols - 1)) / cols)
            let cellH = cellW + 34
            for (i, podcast) in podcasts.enumerated() {
                let col = CGFloat(i % 3)
                let row = CGFloat(i / 3)
                let cell = podcastCell(podcast, index: i, w: cellW, h: cellH)
                cell.frame = CGRect(x: pad + col * (cellW + gap),
                                    y: y + row * (cellH + gap),
                                    width: cellW, height: cellH)
                scrollView.addSubview(cell)
            }
            let rows = ceil(CGFloat(podcasts.count) / cols)
            y += rows * (cellH + gap)
        }

        scrollView.contentSize = CGSize(width: w, height: y + 80)
    }

    // MARK: - Subview factories

    private func sectionHeader(_ text: String, y: CGFloat, w: CGFloat) -> UILabel {
        let l = UILabel(frame: CGRect(x: 16, y: y, width: w - 32, height: 26))
        l.text = text.uppercased()
        l.textColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        l.backgroundColor = .clear
        l.font = UIFont.boldSystemFont(ofSize: 11)
        return l
    }

    private func episodeCard(_ episode: Episode, index: Int) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.15, alpha: 1)
        card.layer.cornerRadius = 8
        card.clipsToBounds = true
        card.layer.shouldRasterize = true
        card.layer.rasterizationScale = UIScreen.main.scale
        card.tag = index

        let art = AsyncImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        art.contentMode = .scaleAspectFill
        if !episode.artworkUrl.isEmpty { art.load(url: episode.artworkUrl) }
        card.addSubview(art)

        let lbl = UILabel(frame: CGRect(x: 6, y: 102, width: 108, height: 42))
        lbl.text = episode.title
        lbl.textColor = .white
        lbl.backgroundColor = .clear
        lbl.font = UIFont.systemFont(ofSize: 10)
        lbl.numberOfLines = 3
        card.addSubview(lbl)

        let pos = episode.savedPosition()
        if pos > 0 {
            let bar = UIView(frame: CGRect(x: 0, y: 98, width: 120, height: 3))
            bar.backgroundColor = UIColor(white: 0.2, alpha: 1)
            let fill = UIView(frame: CGRect(x: 0, y: 0, width: min(120, CGFloat(pos / 1800) * 120), height: 3))
            fill.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
            bar.addSubview(fill)
            card.addSubview(bar)
        }

        let tap = UITapGestureRecognizer(target: self, action: #selector(episodeTapped(_:)))
        card.addGestureRecognizer(tap)
        return card
    }

    private func podcastCell(_ podcast: Podcast, index: Int, w: CGFloat, h: CGFloat) -> UIView {
        let cell = UIView()
        cell.tag = index

        let art = AsyncImageView(frame: CGRect(x: 0, y: 0, width: w, height: w))
        art.contentMode = .scaleAspectFill
        art.clipsToBounds = true
        art.layer.cornerRadius = 6
        art.layer.shouldRasterize = true
        art.layer.rasterizationScale = UIScreen.main.scale
        art.backgroundColor = UIColor(white: 0.15, alpha: 1)
        let url = podcast.artworkUrl600.isEmpty ? podcast.artworkUrl : podcast.artworkUrl600
        if !url.isEmpty { art.load(url: url) }
        cell.addSubview(art)

        let lbl = UILabel(frame: CGRect(x: 0, y: w + 4, width: w, height: 28))
        lbl.text = podcast.title
        lbl.textColor = UIColor(white: 0.85, alpha: 1)
        lbl.backgroundColor = .clear
        lbl.font = UIFont.systemFont(ofSize: 10)
        lbl.textAlignment = .center
        lbl.numberOfLines = 2
        cell.addSubview(lbl)

        let tap = UITapGestureRecognizer(target: self, action: #selector(podcastTapped(_:)))
        cell.addGestureRecognizer(tap)
        return cell
    }

    private func emptyState(y: CGFloat, w: CGFloat) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: y, width: w, height: 140))

        let title = UILabel(frame: CGRect(x: 20, y: 18, width: w - 40, height: 24))
        title.text = "No podcasts yet"
        title.textColor = UIColor(white: 0.4, alpha: 1)
        title.backgroundColor = .clear
        title.font = UIFont.systemFont(ofSize: 15)
        title.textAlignment = .center
        v.addSubview(title)

        let sub = UILabel(frame: CGRect(x: 20, y: 46, width: w - 40, height: 18))
        sub.text = "Tap the search icon to find podcasts"
        sub.textColor = UIColor(white: 0.28, alpha: 1)
        sub.backgroundColor = .clear
        sub.font = UIFont.systemFont(ofSize: 12)
        sub.textAlignment = .center
        v.addSubview(sub)

        let btn = UIButton(type: .custom)
        btn.frame = CGRect(x: (w - 170) / 2, y: 78, width: 170, height: 34)
        btn.setTitle("Search Podcasts", for: .normal)
        btn.setTitleColor(.white, for: .normal)
        btn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 14)
        btn.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
        btn.layer.cornerRadius = 17
        btn.addTarget(self, action: #selector(openSearch), for: .touchUpInside)
        v.addSubview(btn)

        return v
    }

    // MARK: - Actions

    @objc private func episodeTapped(_ tap: UITapGestureRecognizer) {
        guard let v = tap.view else { return }
        let ep = recentEpisodes[v.tag]
        let podcast = podcasts.first { $0.title == ep.podcastTitle } ?? {
            let p = Podcast(); p.title = ep.podcastTitle
            p.artworkUrl600 = ep.artworkUrl; p.artworkUrl = ep.artworkUrl
            return p
        }()
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: ep, podcast: podcast), animated: true)
    }

    @objc private func podcastTapped(_ tap: UITapGestureRecognizer) {
        guard let v = tap.view else { return }
        navigationController?.pushViewController(
            EpisodeListVC(podcast: podcasts[v.tag]), animated: true)
    }

    @objc private func openSearch() {
        navigationController?.pushViewController(SearchVC(), animated: true)
    }

    // MARK: - Gear icon (programmatic — Unicode gear char falls back to emoji on iOS 6)

    private static func gearIcon() -> UIImage {
        let pt: CGFloat = 22
        UIGraphicsBeginImageContextWithOptions(CGSize(width: pt, height: pt), false, UIScreen.main.scale)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return UIImage()
        }
        UIColor.white.setFill()
        let cx = pt / 2, cy = pt / 2
        let outerR: CGFloat = 9.0   // ring outer edge
        let holeR:  CGFloat = 3.2   // centre hole
        let nTeeth = 6
        let toothW: CGFloat = 3.4
        let toothH: CGFloat = 3.6

        // Draw ring (donut) using even-odd fill rule so centre is hollow
        let ring = UIBezierPath()
        ring.addArc(withCenter: CGPoint(x: cx, y: cy), radius: outerR,
                    startAngle: 0, endAngle: .pi * 2, clockwise: true)
        ring.addArc(withCenter: CGPoint(x: cx, y: cy), radius: holeR,
                    startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ring.usesEvenOddFillRule = true
        ring.fill()

        // Draw teeth — each is a small rect extending outward, overlapping ring by 2pt
        for i in 0..<nTeeth {
            let angle = CGFloat(i) * 2 * .pi / CGFloat(nTeeth)
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: angle)
            ctx.fill(CGRect(x: -toothW / 2, y: -(outerR + toothH), width: toothW, height: toothH + 2))
            ctx.restoreGState()
        }

        // Re-punch centre hole clean (teeth may have overlapped it)
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: cx - holeR, y: cy - holeR, width: holeR * 2, height: holeR * 2))

        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    @objc private func openDownloads() {
        navigationController?.pushViewController(DownloadsVC(), animated: true)
    }
}
