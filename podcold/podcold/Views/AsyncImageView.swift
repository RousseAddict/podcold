import UIKit

class AsyncImageView: UIImageView {

    // MARK: - Memory cache (NSCache — auto-evicts under memory pressure)
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 20                      // 20 images max
        c.totalCostLimit = 30 * 1024 * 1024   // 30 MB in decoded bytes
        return c
    }()

    // MARK: - Disk cache
    // Location: ~/Library/Caches/com.podcold.images — iOS auto-purges under storage pressure.
    // Stores raw network bytes (JPEG/PNG). Lookup: memory → disk → network.
    private static let diskCacheDir: String = {
        let dirs = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)
        let base = dirs.first ?? NSTemporaryDirectory()
        let dir = (base as NSString).appendingPathComponent("com.podcold.images")
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true,
                                                  attributes: nil)
        return dir
    }()

    private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    private static func diskPath(for url: String) -> String {
        // Sanitize URL to a safe filename; cap at 120 chars to stay within filesystem limits
        let safe = url.components(separatedBy: nonAlphanumerics).joined(separator: "_")
        let key = safe.count > 120 ? String(safe.suffix(120)) : safe
        return (diskCacheDir as NSString).appendingPathComponent("\(key).jpg")
    }

    // MARK: - Decode queue (serial)
    // UIGraphicsBeginImageContextWithOptions is safer on iOS 6 when not called concurrently.
    private static let decodeQueue = DispatchQueue(label: "com.podcold.imagedecode")

    // MARK: - Instance state
    private var loadingURL: String?

    // MARK: - Load into self (AsyncImageView instances)

    func load(url: String) {
        // Memory cache hit — instant, no queue needed
        if let cached = AsyncImageView.cache.object(forKey: url as NSString) {
            image = cached; return
        }
        loadingURL = url
        image = nil
        let capturedURL = url
        AsyncImageView.fetch(url: url) { [weak self] img in
            guard let self = self, self.loadingURL == capturedURL else { return }
            self.image = img
        }
    }

    func cancel() { loadingURL = nil }

    // MARK: - Load for table cell imageViews

    static func loadCell(url: String, completion: @escaping (UIImage) -> Void) {
        if let cached = cache.object(forKey: url as NSString) {
            completion(cached); return
        }
        fetch(url: url, completion: completion)
    }

    // MARK: - Shared pipeline: disk → network → decode → cache both layers

    private static func fetch(url: String, completion: @escaping (UIImage) -> Void) {
        let path = diskPath(for: url)

        // Step 1: Check disk on background queue (avoids main-thread file I/O)
        decodeQueue.async {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let img = safeDecode(data) {
                cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                DispatchQueue.main.async { completion(img) }
                return
            }

            // Step 2: Network fetch — CurlFetcher queues async to curlQueue, returns immediately
            CurlFetcher.fetchData(url: url, timeout: 15) { data in
                // CurlFetcher completion fires on main thread
                guard let data = data else { return }
                AsyncImageView.decodeQueue.async {
                    guard let img = safeDecode(data) else { return }
                    // Persist raw bytes to disk — next load skips network entirely
                    try? data.write(to: URL(fileURLWithPath: path), options: .atomicWrite)
                    cache.setObject(img, forKey: url as NSString, cost: bitmapCost(img))
                    DispatchQueue.main.async { completion(img) }
                }
            }
        }
    }

    // MARK: - Decode helpers

    // Guards zero dimensions before creating graphics context.
    // UIGraphicsBeginImageContextWithOptions with {0,0} raises NSInvalidArgumentException on iOS 6.
    private static func safeDecode(_ data: Data) -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        guard raw.size.width > 0, raw.size.height > 0 else { return nil }
        return downscaleAndDecode(raw)
    }

    // Cap at 300px before creating the bitmap context.
    // Many feeds serve 3000×3000 artwork (36 MB decoded; 72 MB momentary with context buffer).
    // Max display size is 260 pt — 300 px is sufficient at any screen resolution.
    private static func downscaleAndDecode(_ image: UIImage, maxPx: CGFloat = 300) -> UIImage {
        let w = image.size.width
        let h = image.size.height
        let ratio: CGFloat = (w > maxPx || h > maxPx) ? min(maxPx / w, maxPx / h) : 1.0
        let target = CGSize(width: floor(w * ratio), height: floor(h * ratio))
        // Final guard: ensure computed target is valid (protects against ratio edge cases)
        guard target.width > 0, target.height > 0 else { return image }
        UIGraphicsBeginImageContextWithOptions(target, false, UIScreen.main.scale)
        image.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return result
    }

    // Cost = decoded bitmap bytes (width × height × scale² × 4).
    // Correct cost ensures NSCache totalCostLimit reflects actual RAM usage.
    private static func bitmapCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}
