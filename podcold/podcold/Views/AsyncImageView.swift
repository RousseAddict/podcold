import UIKit

class AsyncImageView: UIImageView {

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 60
        c.totalCostLimit = 25 * 1024 * 1024
        return c
    }()

    private var loadingURL: String?

    func load(url: String) {
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached; return
        }
        loadingURL = url
        image = nil
        let capturedURL = url
        // Use HTTPClient (NSURLFetcher) — sendAsynchronousRequest hangs on iOS 6
        HTTPClient.get(url: url) { [weak self] data, _ in
            guard let data = data, let raw = UIImage(data: data) else { return }
            let decoded = AsyncImageView.forceDecoded(raw)
            AsyncImageView.cache.setObject(decoded, forKey: capturedURL as NSString, cost: data.count)
            // HTTPClient already dispatches to main thread
            guard let self = self, self.loadingURL == capturedURL else { return }
            self.image = decoded
        }
    }

    private static func forceDecoded(_ image: UIImage) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(at: .zero)
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    func cancel() { loadingURL = nil }
}
