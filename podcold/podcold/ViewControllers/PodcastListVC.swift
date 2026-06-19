import UIKit

class PodcastListVC: UICollectionViewController {
    private let cellId = "PodcastCell"
    private var podcasts: [Podcast] = []

    init() {
        let w = UIScreen.main.bounds.width
        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 72, right: 12)
        let cols: CGFloat = w > 400 ? 4 : 3
        let side = floor((w - 12 * 2 - 8 * (cols - 1)) / cols)
        layout.itemSize = CGSize(width: side, height: side + 36)
        super.init(collectionViewLayout: layout)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Podcasts"
        collectionView?.backgroundColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        collectionView?.register(PodcastCell.self, forCellWithReuseIdentifier: cellId)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .search, target: self, action: #selector(openSearch))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        podcasts = Podcast.loadSubscriptions()
        collectionView?.reloadData()
    }

    @objc private func openSearch() {
        navigationController?.pushViewController(SearchVC(), animated: true)
    }

    override func collectionView(_ cv: UICollectionView, numberOfItemsInSection s: Int) -> Int {
        return podcasts.count
    }
    override func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: cellId, for: ip) as! PodcastCell
        cell.configure(podcast: podcasts[ip.item])
        return cell
    }
    override func collectionView(_ cv: UICollectionView, didSelectItemAt ip: IndexPath) {
        navigationController?.pushViewController(
            EpisodeListVC(podcast: podcasts[ip.item]), animated: true)
    }
}
