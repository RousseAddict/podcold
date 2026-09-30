import UIKit

class HomeVC: UIViewController {
    private var scrollView: UIScrollView!
    private var podcasts:       [Podcast] = []
    private var recentEpisodes: [Episode] = []
    private var upNext:         [(Podcast, Episode)] = []
    private var builtPodcastUrls: [String] = []
    private var builtRecentGuids: [String] = []
    private var builtUpNextGuids: [String] = []
    private var inProgressGuids: Set<String> = []
    private var rebuildScheduled = false
    private var builtSyncing = false
    private weak var newEpisodesHeader: UILabel?
    private weak var syncSpinner: UIActivityIndicatorView?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "podcold"
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        let searchBtn   = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(openSearch))
        let settingsBtn = UIBarButtonItem(image: UIImage(named: "gear-icon"), style: .plain, target: self, action: #selector(openSettings))
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

        inProgressGuids = Set(recentEpisodes.map { $0.guid })
        upNext = UpNextManager.shared.cachedUpNext(podcasts: podcasts, inProgressGuids: inProgressGuids)
        UpNextManager.shared.onUpdate = { [weak self] in self?.scheduleUpNextRebuild() }
        // Bound after refreshStale: that call flips the state synchronously, and the
        // spinner is already accounted for by viewDidAppear's build below.
        UpNextManager.shared.refreshStale(podcasts: podcasts, inProgressGuids: inProgressGuids)
        UpNextManager.shared.onSyncStateChange = { [weak self] in self?.updateSyncIndicator() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The refresh batch keeps running while the user is on another screen; its
        // results still land in LatestEpisodeCache, and viewDidAppear's dirty check
        // picks them up on return. Rebuilding an off-screen hierarchy is pure waste.
        UpNextManager.shared.onUpdate = nil
        UpNextManager.shared.onSyncStateChange = nil
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let newUrls   = podcasts.map { $0.feedUrl }
        let newGuids  = recentEpisodes.map { $0.guid }
        let newUpNext = upNext.map { $0.1.guid }
        if newUrls != builtPodcastUrls || newGuids != builtRecentGuids || newUpNext != builtUpNextGuids {
            builtPodcastUrls  = newUrls
            builtRecentGuids  = newGuids
            builtUpNextGuids  = newUpNext
            rebuildLayout()
        } else {
            // Nothing to rebuild, but a batch may have started or finished while the
            // user was on another screen.
            updateSyncIndicator()
        }
    }

    // MARK: - Layout

    // UpNextManager streams one result per feed, and rebuildLayout tears down and
    // recreates every subview — so 15 subscriptions used to mean 15 full rebuilds
    // during the refresh, each one restarting the artwork loads it had just torn
    // down. Coalesce the burst into a single pass.
    private func scheduleUpNextRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.rebuildScheduled = false
            guard self.view.window != nil else { return }
            let refreshed = UpNextManager.shared.cachedUpNext(podcasts: self.podcasts,
                                                             inProgressGuids: self.inProgressGuids)
            let guids = refreshed.map { $0.1.guid }
            guard guids != self.builtUpNextGuids else { return }
            self.upNext = refreshed
            self.builtUpNextGuids = guids
            self.rebuildLayout()
        }
    }

    private func rebuildLayout() {
        scrollView.subviews.forEach { $0.removeFromSuperview() }
        newEpisodesHeader = nil
        syncSpinner       = nil
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

        // Keep the header (and its spinner) up while a batch is running even with no
        // cards yet — that first stretch, when the lane is still empty, is exactly
        // when the user has no other sign that anything is happening.
        builtSyncing = UpNextManager.shared.isSyncing
        if !upNext.isEmpty || builtSyncing {
            let header = sectionHeader("New Episodes", y: y, w: w)
            scrollView.addSubview(header)
            newEpisodesHeader = header
            if builtSyncing { showSyncSpinner() }
            y += 34

            if !upNext.isEmpty {
                let stripH: CGFloat = 158
                let strip = UIScrollView(frame: CGRect(x: 0, y: y, width: w, height: stripH))
                strip.showsHorizontalScrollIndicator = false
                strip.showsVerticalScrollIndicator   = false
                var cx: CGFloat = 12
                for (i, pair) in upNext.enumerated() {
                    let card = upNextCard(pair.1, podcast: pair.0, index: i)
                    card.frame = CGRect(x: cx, y: 4, width: 120, height: 150)
                    strip.addSubview(card)
                    cx += 130
                }
                strip.contentSize = CGSize(width: cx + 12, height: stripH)
                scrollView.addSubview(strip)
                y += stripH + 16
            }
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

    // MARK: - Sync indicator

    private func updateSyncIndicator() {
        let syncing = UpNextManager.shared.isSyncing
        guard syncing != builtSyncing else { return }
        builtSyncing = syncing
        // With no cards yet the header only exists while syncing, so its appearing
        // or disappearing shifts everything below it — that needs a full pass.
        guard !upNext.isEmpty else { rebuildLayout(); return }
        if syncing { showSyncSpinner() } else { hideSyncSpinner() }
    }

    private func showSyncSpinner() {
        guard let header = newEpisodesHeader, syncSpinner == nil else { return }

        // The header label is full-width, so measure the text to find where it ends.
        let sizing = UILabel()
        sizing.font = header.font
        sizing.text = header.text
        sizing.sizeToFit()

        // .white (raw value 0) rather than the modern .medium — the iOS 6 runtime
        // doesn't know the newer style constants. Scaled down so the 20pt indicator
        // sits inside an 11pt header line without dwarfing it.
        let spinner = UIActivityIndicatorView(style: .white)
        spinner.color = header.textColor
        spinner.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
        spinner.center = CGPoint(x: sizing.frame.width + 11, y: header.bounds.midY)
        spinner.startAnimating()
        header.addSubview(spinner)
        syncSpinner = spinner
    }

    private func hideSyncSpinner() {
        syncSpinner?.stopAnimating()
        syncSpinner?.removeFromSuperview()
        syncSpinner = nil
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

        // Needs the episode's real length — a hardcoded assumed duration made
        // every episode past that mark read as complete.
        let pos = episode.savedPosition()
        let total = episode.totalDuration()
        if pos > 0 && total > 0 {
            let bar = UIView(frame: CGRect(x: 0, y: 98, width: 120, height: 3))
            bar.backgroundColor = UIColor(white: 0.2, alpha: 1)
            let fraction = min(1.0, pos / total)
            let fill = UIView(frame: CGRect(x: 0, y: 0, width: CGFloat(fraction) * 120, height: 3))
            fill.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
            bar.addSubview(fill)
            card.addSubview(bar)
        }

        // Tap-to-open target — transparent button covering the card (avoids
        // UITapGestureRecognizer + button conflict, same convention as MiniPlayerBar)
        let openBtn = UIButton(type: .custom)
        openBtn.frame = CGRect(x: 0, y: 0, width: 120, height: 150)
        openBtn.backgroundColor = .clear
        openBtn.tag = index
        openBtn.addTarget(self, action: #selector(episodeTapped(_:)), for: .touchUpInside)
        card.addSubview(openBtn)

        // Mark-as-played button — top-right corner, for episodes you don't want to finish
        let doneBtn = UIButton(type: .custom)
        doneBtn.frame = CGRect(x: 120 - 44 - 4, y: 4, width: 44, height: 20)
        doneBtn.backgroundColor = UIColor(white: 0, alpha: 0.55)
        doneBtn.layer.cornerRadius = 4
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.setTitleColor(.white, for: .normal)
        doneBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 9)
        doneBtn.tag = index
        doneBtn.addTarget(self, action: #selector(markPlayedTapped(_:)), for: .touchUpInside)
        card.addSubview(doneBtn)
        card.bringSubviewToFront(doneBtn)

        return card
    }

    private func upNextCard(_ episode: Episode, podcast: Podcast, index: Int) -> UIView {
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.15, alpha: 1)
        card.layer.cornerRadius = 8
        card.clipsToBounds = true
        card.layer.shouldRasterize = true
        card.layer.rasterizationScale = UIScreen.main.scale
        card.tag = index

        let art = AsyncImageView(frame: CGRect(x: 0, y: 0, width: 120, height: 100))
        art.contentMode = .scaleAspectFill
        let artUrl = episode.artworkUrl.isEmpty ? podcast.artworkUrl600 : episode.artworkUrl
        if !artUrl.isEmpty { art.load(url: artUrl) }
        card.addSubview(art)

        let lbl = UILabel(frame: CGRect(x: 6, y: 102, width: 108, height: 42))
        lbl.text = episode.title
        lbl.textColor = .white
        lbl.backgroundColor = .clear
        lbl.font = UIFont.systemFont(ofSize: 10)
        lbl.numberOfLines = 3
        card.addSubview(lbl)

        let openBtn = UIButton(type: .custom)
        openBtn.frame = CGRect(x: 0, y: 0, width: 120, height: 150)
        openBtn.backgroundColor = .clear
        openBtn.tag = index
        openBtn.addTarget(self, action: #selector(upNextTapped(_:)), for: .touchUpInside)
        card.addSubview(openBtn)

        // Mark-as-played button — lets the user dismiss an episode without playing it
        let doneBtn = UIButton(type: .custom)
        doneBtn.frame = CGRect(x: 120 - 44 - 4, y: 4, width: 44, height: 20)
        doneBtn.backgroundColor = UIColor(white: 0, alpha: 0.55)
        doneBtn.layer.cornerRadius = 4
        doneBtn.setTitle("Done", for: .normal)
        doneBtn.setTitleColor(.white, for: .normal)
        doneBtn.titleLabel?.font = UIFont.boldSystemFont(ofSize: 9)
        doneBtn.tag = index
        doneBtn.addTarget(self, action: #selector(upNextDoneTapped(_:)), for: .touchUpInside)
        card.addSubview(doneBtn)
        card.bringSubviewToFront(doneBtn)

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

    @objc private func episodeTapped(_ sender: UIButton) {
        let ep = recentEpisodes[sender.tag]
        let podcast = podcasts.first { $0.title == ep.podcastTitle } ?? {
            let p = Podcast(); p.title = ep.podcastTitle
            p.artworkUrl600 = ep.artworkUrl; p.artworkUrl = ep.artworkUrl
            return p
        }()
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: ep, podcast: podcast), animated: true)
    }

    @objc private func markPlayedTapped(_ sender: UIButton) {
        guard sender.tag < recentEpisodes.count else { return }
        recentEpisodes[sender.tag].savePosition(0)
        recentEpisodes[sender.tag].autoDeleteIfEnabled()
        recentEpisodes.remove(at: sender.tag)
        builtRecentGuids = recentEpisodes.map { $0.guid }
        rebuildLayout()
    }

    @objc private func upNextTapped(_ sender: UIButton) {
        guard sender.tag < upNext.count else { return }
        let (podcast, ep) = upNext[sender.tag]
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: ep, podcast: podcast), animated: true)
    }

    @objc private func upNextDoneTapped(_ sender: UIButton) {
        guard sender.tag < upNext.count else { return }
        let (podcast, ep) = upNext[sender.tag]
        Episode.markPlayed(guid: ep.guid)
        ep.autoDeleteIfEnabled()
        LatestEpisodeCache.remove(feedUrl: podcast.feedUrl)
        upNext.remove(at: sender.tag)
        builtUpNextGuids = upNext.map { $0.1.guid }
        rebuildLayout()
    }

    @objc private func podcastTapped(_ tap: UITapGestureRecognizer) {
        guard let v = tap.view else { return }
        navigationController?.pushViewController(
            EpisodeListVC(podcast: podcasts[v.tag]), animated: true)
    }

    @objc private func openSearch() {
        navigationController?.pushViewController(SearchVC(), animated: true)
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsVC(), animated: true)
    }

    @objc private func openDownloads() {
        navigationController?.pushViewController(DownloadsVC(), animated: true)
    }
}
