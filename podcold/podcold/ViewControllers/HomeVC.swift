import UIKit

class HomeVC: UIViewController {
    private var scrollView: UIScrollView!
    // Each section is built into its own container, so a change to one rebuilds only
    // that one, and stacking them is three frame assignments. A New Episodes result
    // used to tear down and recreate the whole screen, grid included.
    private let continueSection    = UIView()
    private let newEpisodesSection = UIView()
    private let podcastsSection    = UIView()
    private var podcasts:       [Podcast] = []
    private var recentEpisodes: [Episode] = []
    private var upNext:         [(Podcast, Episode)] = []
    private var didBuild = false
    private var builtPodcastUrls: [String] = []
    private var builtRecentState: [String] = []
    private var builtUpNextGuids: [String] = []
    private var inProgressGuids: Set<String> = []
    private var rebuildScheduled = false
    private var builtSyncing = false
    private weak var newEpisodesHeader: UILabel?
    private weak var newEpisodesStrip: UIScrollView?
    private weak var syncTag: UIView?
    private weak var syncCountLabel: UILabel?

    deinit { NotificationCenter.default.removeObserver(self) }

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
        for section in [continueSection, newEpisodesSection, podcastsSection] {
            scrollView.addSubview(section)
        }
        // Coming back from the background with Home already on screen runs neither
        // viewWillAppear nor viewDidAppear, so New Episodes stayed exactly as stale as
        // it was when the app was left.
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground),
                                               name: UIApplication.willEnterForegroundNotification,
                                               object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadState()
    }

    @objc private func appWillEnterForeground() {
        // Only while Home is the screen showing — otherwise the trip back to it runs
        // viewWillAppear and viewDidAppear, which do the same.
        guard isViewLoaded, view.window != nil else { return }
        reloadState()
        applyState()
    }

    private func reloadState() {
        podcasts       = Podcast.loadSubscriptions()
        recentEpisodes = Episode.loadRecents().filter { $0.savedPosition() > 30 }

        inProgressGuids = Set(recentEpisodes.map { $0.guid })
        upNext = UpNextManager.shared.cachedUpNext(podcasts: podcasts, inProgressGuids: inProgressGuids)
        UpNextManager.shared.onUpdate = { [weak self] in self?.scheduleUpNextRebuild() }
        // Bound after refreshStale: that call flips the state synchronously, and the
        // sync tag is already accounted for by the applyState() pass that follows.
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
        applyState()
    }

    // Rebuilds only the sections whose content changed since they were last built —
    // coming back from the player usually moves Continue Listening and nothing else.
    private func applyState() {
        let newUrls   = podcasts.map { $0.feedUrl }
        let newState  = recentFingerprint()
        let newUpNext = upNext.map { $0.1.guid }
        // The first pass builds everything. With no subscriptions every list equals its
        // empty "built" value, so a fresh install used to show a blank screen instead
        // of the empty state.
        let first = !didBuild
        didBuild = true
        var changed = false
        if first || newUrls != builtPodcastUrls {
            builtPodcastUrls = newUrls
            buildPodcastsSection()
            changed = true
        }
        if first || newState != builtRecentState {
            builtRecentState = newState
            buildContinueSection()
            changed = true
        }
        if first || newUpNext != builtUpNextGuids {
            builtUpNextGuids = newUpNext
            buildNewEpisodesSection()
            changed = true
        } else {
            // Same cards, but a batch may have started or finished while the user was
            // on another screen.
            updateSyncIndicator()
        }
        if changed { stackSections() }
    }

    // The guid list alone cannot tell that an episode has *moved*: coming back from
    // the player with ten more minutes listened produced an identical list, so the
    // rebuild was skipped and the Continue Listening progress bars stayed frozen at
    // whatever they showed when the screen was first built. Bucketing the position
    // at 30 s keeps this a cheap string compare while still catching real listening.
    private func recentFingerprint() -> [String] {
        return recentEpisodes.map { "\($0.guid)|\(Int($0.savedPosition() / 30))" }
    }

    // MARK: - Layout

    // UpNextManager streams one result per feed. This coalesces results that land
    // close together; ones that arrive seconds apart each rebuild, but only the New
    // Episodes section, which keeps that cheap.
    private func scheduleUpNextRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self = self else { return }
            self.rebuildScheduled = false
            guard self.view.window != nil else { return }
            // Swapping cards out from under a finger kills the swipe, and a strip
            // appearing shifts the grid mid-scroll. Wait for the scrolling to settle.
            if self.isUserScrolling {
                self.scheduleUpNextRebuild()
                return
            }
            let refreshed = UpNextManager.shared.cachedUpNext(podcasts: self.podcasts,
                                                             inProgressGuids: self.inProgressGuids)
            let guids = refreshed.map { $0.1.guid }
            guard guids != self.builtUpNextGuids else { return }
            self.upNext = refreshed
            self.builtUpNextGuids = guids
            self.rebuildNewEpisodes()
        }
    }

    private var isUserScrolling: Bool {
        return [scrollView, newEpisodesStrip].contains {
            guard let s = $0 else { return false }
            return s.isTracking || s.isDragging || s.isDecelerating
        }
    }

    private func rebuildNewEpisodes() {
        buildNewEpisodesSection()
        stackSections()
    }

    // Sections stack top to bottom; an empty one has zero height and takes no space.
    private func stackSections() {
        var y: CGFloat = 12
        for section in [continueSection, newEpisodesSection, podcastsSection] {
            section.frame.origin.y = y
            y += section.frame.height
        }
        scrollView.contentSize = CGSize(width: UIScreen.main.bounds.width, height: y + 80)
    }

    // Keeps the section's stacked position; stackSections() sets that.
    private func resize(_ section: UIView, height: CGFloat) {
        section.frame = CGRect(x: 0, y: section.frame.minY,
                               width: UIScreen.main.bounds.width, height: height)
    }

    private func buildContinueSection() {
        continueSection.subviews.forEach { $0.removeFromSuperview() }
        guard !recentEpisodes.isEmpty else { resize(continueSection, height: 0); return }
        let w = UIScreen.main.bounds.width
        continueSection.addSubview(sectionHeader("Continue Listening", y: 0, w: w))
        let cards = recentEpisodes.enumerated().map { episodeCard($0.element, index: $0.offset) }
        continueSection.addSubview(cardStrip(cards, y: 34, w: w))
        resize(continueSection, height: 34 + 158 + 16)
    }

    private func buildNewEpisodesSection() {
        // A result landing mid-batch must not throw the user back to the first card.
        let keptOffsetX = newEpisodesStrip?.contentOffset.x ?? 0
        newEpisodesSection.subviews.forEach { $0.removeFromSuperview() }
        newEpisodesHeader = nil
        newEpisodesStrip  = nil
        syncTag           = nil
        syncCountLabel    = nil

        // Keep the header (and its sync tag) up while a batch is running even with no
        // cards yet — that first stretch, when the lane is still empty, is exactly
        // when the user has no other sign that anything is happening.
        builtSyncing = UpNextManager.shared.isSyncing
        guard !upNext.isEmpty || builtSyncing else { resize(newEpisodesSection, height: 0); return }
        let w = UIScreen.main.bounds.width
        let header = sectionHeader("New Episodes", y: 0, w: w)
        newEpisodesSection.addSubview(header)
        newEpisodesHeader = header
        if builtSyncing { showSyncTag() }
        guard !upNext.isEmpty else { resize(newEpisodesSection, height: 34); return }

        let cards = upNext.enumerated().map { upNextCard($0.element.1, podcast: $0.element.0, index: $0.offset) }
        let strip = cardStrip(cards, y: 34, w: w)
        let maxOffsetX = max(0, strip.contentSize.width - strip.bounds.width)
        strip.contentOffset = CGPoint(x: min(keptOffsetX, maxOffsetX), y: 0)
        newEpisodesSection.addSubview(strip)
        newEpisodesStrip = strip
        resize(newEpisodesSection, height: 34 + 158 + 16)
    }

    // Horizontal strip of 120x150 cards — Continue Listening and New Episodes.
    private func cardStrip(_ cards: [UIView], y: CGFloat, w: CGFloat) -> UIScrollView {
        let stripH: CGFloat = 158
        let strip = UIScrollView(frame: CGRect(x: 0, y: y, width: w, height: stripH))
        strip.showsHorizontalScrollIndicator = false
        strip.showsVerticalScrollIndicator   = false
        var cx: CGFloat = 12
        for card in cards {
            card.frame = CGRect(x: cx, y: 4, width: 120, height: 150)
            strip.addSubview(card)
            cx += 130
        }
        strip.contentSize = CGSize(width: cx + 12, height: stripH)
        return strip
    }

    private func buildPodcastsSection() {
        podcastsSection.subviews.forEach { $0.removeFromSuperview() }
        let w = UIScreen.main.bounds.width
        podcastsSection.addSubview(sectionHeader("My Podcasts", y: 0, w: w))
        var y: CGFloat = 34

        if podcasts.isEmpty {
            let empty = emptyState(y: y, w: w)
            podcastsSection.addSubview(empty)
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
                podcastsSection.addSubview(cell)
            }
            let rows = ceil(CGFloat(podcasts.count) / cols)
            y += rows * (cellH + gap)
        }

        resize(podcastsSection, height: y)
    }

    // MARK: - Sync indicator

    private func updateSyncIndicator() {
        let syncing = UpNextManager.shared.isSyncing
        // Same state, but the batch may have moved on to its next feed.
        guard syncing != builtSyncing else { updateSyncCount(); return }
        builtSyncing = syncing
        // With no cards yet the header only exists while syncing, so its appearing
        // or disappearing shifts everything below it — rebuild the section and restack.
        guard !upNext.isEmpty else { rebuildNewEpisodes(); return }
        if syncing { showSyncTag() } else { hideSyncTag() }
    }

    // A pill right after the header text: spinner + "3/12", so a long batch reads as
    // progress instead of an open-ended spin.
    private func showSyncTag() {
        guard let header = newEpisodesHeader, syncTag == nil else { return }

        // The header label is full-width, so measure the text to find where it ends.
        let sizing = UILabel()
        sizing.font = header.font
        sizing.text = header.text
        sizing.sizeToFit()

        let tagH: CGFloat = 18
        let tint = UIColor(red: 0.78, green: 0.64, blue: 0.92, alpha: 1)
        let tag = UIView(frame: CGRect(x: sizing.frame.width + 8, y: (header.bounds.height - tagH) / 2,
                                       width: tagH, height: tagH))
        tag.backgroundColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 0.25)
        // No clipsToBounds — nothing overflows, so the corner radius alone is enough
        // and the pill stays off the off-screen render path.
        tag.layer.cornerRadius = tagH / 2

        // .white (raw value 0) rather than the modern .medium — the iOS 6 runtime
        // doesn't know the newer style constants. Scaled down so the 20pt indicator
        // fits inside the pill.
        let spinner = UIActivityIndicatorView(style: .white)
        spinner.color = tint
        spinner.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        spinner.center = CGPoint(x: 13, y: tagH / 2)
        spinner.startAnimating()
        tag.addSubview(spinner)

        let count = UILabel(frame: CGRect(x: 23, y: 0, width: 0, height: tagH))
        count.backgroundColor = .clear
        count.textColor = tint
        count.font = UIFont.boldSystemFont(ofSize: 10)
        tag.addSubview(count)

        header.addSubview(tag)
        syncTag = tag
        syncCountLabel = count
        updateSyncCount()
    }

    // Fires once per feed, so it only touches frames when the text actually changed.
    private func updateSyncCount() {
        guard let tag = syncTag, let count = syncCountLabel else { return }
        let p = UpNextManager.shared.syncProgress
        let text = "\(p.current)/\(p.total)"
        guard count.text != text else { return }
        count.text = text
        count.sizeToFit()
        count.frame = CGRect(x: 23, y: 0, width: count.frame.width, height: tag.bounds.height)
        tag.frame.size.width = count.frame.maxX + 8
    }

    private func hideSyncTag() {
        syncTag?.removeFromSuperview()
        syncTag = nil
        syncCountLabel = nil
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
        let ep = recentEpisodes[sender.tag]
        ep.savePosition(0)
        // Without this the episode leaves Continue Listening and immediately
        // reappears in New Episodes: savedPosition() == 0 cannot distinguish
        // "never started" from "done with it". upNextDoneTapped already did both.
        Episode.markPlayed(guid: ep.guid)
        ep.autoDeleteIfEnabled()
        recentEpisodes.remove(at: sender.tag)
        builtRecentState = recentFingerprint()
        buildContinueSection()
        stackSections()
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
        rebuildNewEpisodes()
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
