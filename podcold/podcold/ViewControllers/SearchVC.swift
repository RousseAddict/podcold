import UIKit

class SearchVC: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    private lazy var searchBar  = UISearchBar()
    private lazy var tableView  = UITableView()
    private var results: [Podcast] = []
    private var didSetupUI = false
    private var spinner: UIActivityIndicatorView!

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didSetupUI else { return }
        didSetupUI = true
        title = "Search"
        let w = UIScreen.main.bounds.width
        let h = UIScreen.main.bounds.height

        searchBar.placeholder = "Search podcasts..."
        searchBar.delegate    = self
        searchBar.barStyle    = .blackOpaque
        searchBar.frame       = CGRect(x: 0, y: 0, width: w, height: 44)
        searchBar.autoresizingMask = .flexibleWidth
        view.addSubview(searchBar)

        tableView.frame              = CGRect(x: 0, y: 44, width: w, height: h - 44)
        tableView.autoresizingMask   = [.flexibleWidth, .flexibleHeight]
        tableView.dataSource         = self
        tableView.delegate           = self
        tableView.backgroundColor    = .clear
        tableView.separatorColor     = UIColor(white: 0.25, alpha: 1)
        tableView.rowHeight          = 72
        tableView.contentInset       = UIEdgeInsets(top: 0, left: 0, bottom: 60, right: 0)
        view.addSubview(tableView)

        spinner = UIActivityIndicatorView(style: .whiteLarge)
        spinner.center = CGPoint(x: w / 2, y: h / 2)
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let term = searchBar.text, !term.isEmpty else { return }
        searchBar.resignFirstResponder()
        results = []; tableView.reloadData(); spinner.startAnimating()
        iTunesAPI.search(term: term) { [weak self] podcasts in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.results = podcasts
            self.tableView.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { results.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "r") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "r")
        let p = results[indexPath.row]
        cell.textLabel?.text       = p.title
        cell.textLabel?.textColor  = .white
        cell.detailTextLabel?.text  = p.author
        cell.detailTextLabel?.textColor = UIColor(white: 0.6, alpha: 1)
        cell.backgroundColor       = .clear
        cell.imageView?.image      = nil
        if !p.artworkUrl.isEmpty {
            let url = p.artworkUrl
            AsyncImageView.loadCell(url: url) { [weak tableView] img in
                guard let c = tableView?.cellForRow(at: indexPath) else { return }
                c.imageView?.image = img
                c.setNeedsLayout()
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(EpisodeListVC(podcast: results[indexPath.row]), animated: true)
    }
}
