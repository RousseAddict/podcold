import UIKit

class PodcastCell: UICollectionViewCell {
    let artworkView = AsyncImageView()
    let titleLabel  = UILabel()

    override init(frame: CGRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        layer.cornerRadius = 8
        clipsToBounds = true
        backgroundColor = UIColor(white: 0.15, alpha: 1)
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        contentView.addSubview(artworkView)
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 11)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        titleLabel.backgroundColor = UIColor(white: 0, alpha: 0.65)
        contentView.addSubview(titleLabel)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lh: CGFloat = 36
        artworkView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - lh)
        titleLabel.frame  = CGRect(x: 0, y: bounds.height - lh, width: bounds.width, height: lh)
    }

    func configure(podcast: Podcast) {
        titleLabel.text = podcast.title
        let url = podcast.artworkUrl.isEmpty ? podcast.artworkUrl600 : podcast.artworkUrl
        if !url.isEmpty { artworkView.load(url: url) } else { artworkView.image = nil }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkView.cancel(); artworkView.image = nil; titleLabel.text = nil
    }
}
