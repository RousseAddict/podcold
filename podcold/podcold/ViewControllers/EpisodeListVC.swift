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

    init(podcast: Podcast) { self.podcast = podcast; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = podcast.title
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)

        let isSubscribed = Podcast.loadSubscriptions().contains { $0.feedUrl == podcast.feedUrl }
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

        load()
    }

    private func load() {
        emptyView.isHidden = true
        spinner.startAnimating()
        FeedParser.parse(feedUrl: podcast.feedUrl, podcastTitle: podcast.title) { [weak self] eps in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.episodes = eps
            self.tableView.reloadData()
            if eps.isEmpty {
                self.emptyLabel.text = "Could not load episodes.\nCheck your connection."
                self.emptyView.isHidden = false
            }
        }
    }

    @objc private func retryTapped() { load() }

    @objc private func toggleSubscribe() {
        var subs = Podcast.loadSubscriptions()
        if subs.contains(where: { $0.feedUrl == podcast.feedUrl }) {
            subs.removeAll { $0.feedUrl == podcast.feedUrl }
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

        var detail = ep.pubDate.isEmpty ? ep.duration : "\(ep.pubDate)  \(ep.duration)"
        if ep.localPath() != nil { detail = detail.isEmpty ? "Offline" : "\(detail) · Offline" }
        cell.detailTextLabel?.text      = detail
        cell.detailTextLabel?.textColor = ep.localPath() != nil
            ? UIColor(red: 0.53, green: 0.26, blue: 0.73, alpha: 1)
            : UIColor(white: 0.55, alpha: 1)
        cell.detailTextLabel?.backgroundColor = .clear

        cell.backgroundColor = .clear
        cell.accessoryType   = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            EpisodeDetailVC(episode: episodes[indexPath.row], podcast: podcast), animated: true)
    }
}
