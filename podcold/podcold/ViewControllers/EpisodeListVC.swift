import UIKit

class EpisodeListVC: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let podcast: Podcast
    private var episodes: [Episode] = []
    private let tableView = UITableView()
    private var spinner: UIActivityIndicatorView!
    private var subscribeBtn: UIBarButtonItem!
    private var emptyView: UIView!
    private var emptyLabel: UILabel!
    private var retryBtn: UIButton!

    // Load-more state. A feed has no server-side paging, so paging deeper means
    // re-parsing the same bytes with a higher cap — kept here so it costs no
    // network. Dropped above the size cap so a 2000-episode feed can't sit in RAM.
    private static let maxRetainedFeedBytes = 6 * 1024 * 1024
    private var feedData: Data?
    private var loadedLimit = FeedParser.pageSize
    private var hasMore = false
    private var isLoadingMore = false
    // Until the first feed response lands we cannot know whether there is more.
    // That response queues behind UpNextManager's batch on the serial feed lane,
    // so it can be slow — the footer has to say "working" rather than show
    // nothing, which reads as a dead control.
    private var initialLoadInFlight = false
    private var footerView: UIView!
    private var footerLabel: UILabel!
    private var footerSpinner: UIActivityIndicatorView!

    init(podcast: Podcast) { self.podcast = podcast; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = podcast.title
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        let isSubscribed = Podcast.isSubscribed(feedUrl: podcast.feedUrl)
        subscribeBtn = UIBarButtonItem(title: isSubscribed ? "Subscribed" : "Subscribe",
                                       style: .plain, target: self, action: #selector(toggleSubscribe))
        navigationItem.rightBarButtonItem = subscribeBtn

        tableView.frame            = view.bounds
        tableView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource       = self
        tableView.delegate         = self
        tableView.backgroundColor  = .clear
        tableView.separatorColor   = UIColor(white: 0.2, alpha: 1)
        tableView.rowHeight        = 72
        tableView.contentInset     = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        view.addSubview(tableView)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = view.center
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        // Empty state — shown when load completes with 0 episodes
        let w = UIScreen.main.bounds.width
        let midY = view.bounds.height / 2

        emptyView = UIView(frame: view.bounds)
        emptyView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        emptyView.isHidden = true

        emptyLabel = UILabel(frame: CGRect(x: 20, y: midY - 50, width: w - 40, height: 44))
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = UIColor(white: 0.55, alpha: 1)
        emptyLabel.backgroundColor = .clear
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.numberOfLines = 2
        emptyView.addSubview(emptyLabel)

        retryBtn = UIButton(type: .custom)
        retryBtn.frame = CGRect(x: (w - 140) / 2, y: midY + 10, width: 140, height: 40)
        retryBtn.setTitle("Retry", for: .normal)
        retryBtn.setTitleColor(UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1), for: .normal)
        retryBtn.layer.borderColor = UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1).cgColor
        retryBtn.layer.borderWidth = 1
        retryBtn.layer.cornerRadius = 20
        retryBtn.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        retryBtn.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        emptyView.addSubview(retryBtn)

        view.addSubview(emptyView)

        // Load-more footer. Attached to tableFooterView only while there is more
        // to fetch, so it doubles as the "you've reached the end" signal.
        footerView = UIView(frame: CGRect(x: 0, y: 0, width: w, height: 64))
        footerView.backgroundColor = .clear

        footerSpinner = UIActivityIndicatorView(style: .white)
        footerSpinner.frame = CGRect(x: (w - 20) / 2, y: 10, width: 20, height: 20)
        footerSpinner.hidesWhenStopped = true
        footerView.addSubview(footerSpinner)

        footerLabel = UILabel(frame: CGRect(x: 20, y: 36, width: w - 40, height: 20))
        footerLabel.textAlignment = .center
        footerLabel.backgroundColor = .clear
        footerLabel.textColor = UIColor(white: 0.55, alpha: 1)
        footerLabel.font = UIFont.systemFont(ofSize: 14)
        footerView.addSubview(footerLabel)

        // Transparent button rather than a tap gesture — on iOS 6 a recognizer on
        // a container fires alongside its subviews' taps. Also a manual fallback
        // if the scroll trigger is missed.
        let footerBtn = UIButton(type: .custom)
        footerBtn.frame = footerView.bounds
        footerBtn.backgroundColor = .clear
        footerBtn.addTarget(self, action: #selector(loadMoreTapped), for: .touchUpInside)
        footerView.addSubview(footerBtn)

        // Show whatever we had last time before the first reloadData, so the table
        // arrives populated instead of empty-with-a-spinner.
        episodes = EpisodeListCache.cached(feedUrl: podcast.feedUrl)

        load()
    }

    private func load() {
        emptyView.isHidden = true
        // Only spin when there is nothing to look at; a background refresh over
        // already-visible rows should be invisible.
        if episodes.isEmpty { spinner.startAnimating() }

        initialLoadInFlight = true
        updateFooter()
        // Stand the background batch down so this request — the one the user is
        // waiting on — gets the feed lane next instead of after every subscription.
        UpNextManager.shared.suspend()

        FeedParser.parseKeepingData(feedUrl: podcast.feedUrl,
                                    podcastTitle: podcast.title,
                                    limit: FeedParser.pageSize) { [weak self] eps, data in
            // Before the weak-self guard: the batch must restart even if this
            // screen was popped mid-request.
            UpNextManager.shared.resume()
            guard let self = self else { return }
            self.initialLoadInFlight = false
            self.spinner.stopAnimating()
            self.retainFeedData(data)

            if !eps.isEmpty {
                self.episodes = eps
                self.loadedLimit = FeedParser.pageSize
                // A full page means the parser stopped early, so there is more.
                self.hasMore = eps.count >= FeedParser.pageSize
                self.tableView.reloadData()
                self.updateFooter()
                // `hasMore` may have just flipped true under a user who is already
                // scrolled to the bottom of the cached rows — nothing further will
                // move, so nothing else would ever trigger the first page.
                self.maybeLoadMore()
                // Only the first page is cached — EpisodeListVC.viewDidLoad reads
                // this synchronously, and a 200-episode plist would stall it.
                EpisodeListCache.store(feedUrl: self.podcast.feedUrl, episodes: eps)
                return
            }

            // Refresh failed. Keep the cached rows on screen — replacing real
            // episodes with an error because the network blipped is worse than
            // showing slightly stale ones. Drop the footer either way, or its
            // spinner spins forever.
            self.updateFooter()
            guard self.episodes.isEmpty else { return }
            self.emptyLabel.text = "Could not load episodes.\nCheck your connection."
            self.emptyView.isHidden = false
        }
    }

    @objc private func retryTapped() { load() }

    // MARK: — Load more

    private func retainFeedData(_ data: Data?) {
        guard let data = data, data.count <= EpisodeListVC.maxRetainedFeedBytes else {
            feedData = nil
            return
        }
        feedData = data
    }

    @objc private func loadMoreTapped() { loadMore() }

    private func loadMore() {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        updateFooter()

        let next = loadedLimit + FeedParser.pageSize

        // A deeper parse re-reads from the top, so it is a superset of what we
        // already show. Not growing means the feed ran out before `next`.
        let apply: ([Episode]) -> Void = { [weak self] eps in
            guard let self = self else { return }
            self.isLoadingMore = false
            if eps.count > self.episodes.count {
                self.episodes = eps
                self.loadedLimit = next
                self.hasMore = eps.count >= next
                self.tableView.reloadData()
            } else {
                self.hasMore = false
            }
            self.updateFooter()
        }

        if let data = feedData {
            FeedParser.parse(data: data, podcastTitle: podcast.title, limit: next, completion: apply)
        } else {
            // Feed was too big to keep in memory — pay for a re-fetch instead,
            // and take the lane off the background batch for the same reason.
            UpNextManager.shared.suspend()
            FeedParser.parseKeepingData(feedUrl: podcast.feedUrl,
                                        podcastTitle: podcast.title,
                                        limit: next) { [weak self] eps, data in
                UpNextManager.shared.resume()
                self?.retainFeedData(data)
                apply(eps)
            }
        }
    }

    private func updateFooter() {
        // Show it while there is more to fetch, and also while the first feed
        // response is still outstanding over cached rows — during that window
        // `hasMore` is false only because we don't know yet.
        let show = hasMore || (initialLoadInFlight && !episodes.isEmpty)
        guard show else {
            footerSpinner.stopAnimating()
            tableView.tableFooterView = nil
            return
        }
        if isLoadingMore || initialLoadInFlight {
            footerLabel.text = "Loading older episodes…"
            footerSpinner.startAnimating()
        } else {
            footerLabel.text = "Load older episodes"
            footerSpinner.stopAnimating()
        }
        if tableView.tableFooterView !== footerView { tableView.tableFooterView = footerView }
    }

    @objc private func toggleSubscribe() {
        var subs = Podcast.loadSubscriptions()
        if subs.contains(where: { $0.feedUrl == podcast.feedUrl }) {
            subs.removeAll { $0.feedUrl == podcast.feedUrl }
            LatestEpisodeCache.remove(feedUrl: podcast.feedUrl)
            EpisodeListCache.remove(feedUrl: podcast.feedUrl)
            subscribeBtn.title = "Subscribe"
        } else {
            subs.append(podcast)
            subscribeBtn.title = "Subscribed"
        }
        Podcast.saveSubscriptions(subs)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { episodes.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ep") ??
                   UITableViewCell(style: .subtitle, reuseIdentifier: "ep")
        let ep = episodes[indexPath.row]

        cell.textLabel?.text          = ep.title
        cell.textLabel?.textColor     = .white
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.backgroundColor = .clear

        let localFile = ep.localPath()
        var detail = ep.pubDate.isEmpty ? ep.duration : "\(ep.pubDate)  \(ep.duration)"
        if localFile != nil { detail = detail.isEmpty ? "Offline" : "\(detail) · Offline" }
        cell.detailTextLabel?.text      = detail
        cell.detailTextLabel?.textColor = localFile != nil
            ? UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
            : UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.backgroundColor = .clear

        cell.backgroundColor = .clear
        cell.accessoryType   = .disclosureIndicator
        return cell
    }

    // Level trigger, not an edge one. `willDisplay` fires only at the instant a
    // cell scrolls into view — and on first entry the rows are already on screen
    // from the cache while `hasMore` is still false, so the bail-out in loadMore()
    // consumed the only trigger those cells would ever get, and it took a bounce
    // past the bottom to re-display them. Re-evaluating on every scroll tick means
    // a late `hasMore` still fires.
    func scrollViewDidScroll(_ scrollView: UIScrollView) { maybeLoadMore() }

    private func maybeLoadMore() {
        guard hasMore, !isLoadingMore, tableView.bounds.height > 0 else { return }
        let remaining = tableView.contentSize.height
            - tableView.contentOffset.y
            - tableView.bounds.height
        // One screenful of lead time.
        if remaining < tableView.bounds.height { loadMore() }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: episodes[indexPath.row], podcast: podcast), animated: true)
    }
}
