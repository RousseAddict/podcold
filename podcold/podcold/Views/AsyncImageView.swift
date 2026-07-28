import UIKit

class AsyncImageView: UIImageView {

    // MARK: - Memory cache (NSCache — auto-evicts under memory pressure)
    // countLimit used to be the binding constraint: HomeVC alone wants more than 20
    // distinct URLs (continue-listening + new-episodes + grid), so entries were
    // evicted and re-decoded on every appearance — the reason cached artwork still
    // showed up blank at first. Entries are now sized to the view that asked for
    // them (a 96 pt grid cell holds a 192 px bitmap, ~150 KB), so totalCostLimit is
    // the real bound and the count can be much higher.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 80
        c.totalCostLimit = 30 * 1024 * 1024   // 30 MB in decoded bytes
        return c
    }()

    // MARK: - Disk cache
    // Location: ~/Library/Caches/com.podcold.images — iOS auto-purges under storage pressure.
    // Stores the *downscaled* JPEG, not the original bytes: re-decoding a 3000x3000
    // cover on every disk hit cost 40-150 ms on a 4S, which is what made a warm
    // cache feel cold. A 192-256 px entry decodes in a few ms.
    // Lookup: memory → disk → network.
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

    // Cache entries are per (url, size): the 192 px grid thumbnail must not be
    // served to the 520 px detail view, or vice versa.
    private static func cacheKey(url: String, targetPx: CGFloat) -> NSString {
        return "\(url)|\(Int(targetPx))" as NSString
    }

    private static func diskPath(for url: String, targetPx: CGFloat) -> String {
        // Sanitize URL to a safe filename; cap at 120 chars to stay within filesystem limits
        let safe = url.components(separatedBy: nonAlphanumerics).joined(separator: "_")
        let key = safe.count > 120 ? String(safe.suffix(120)) : safe
        return (diskCacheDir as NSString).appendingPathComponent("\(key)-\(Int(targetPx)).jpg")
    }

    // Round up to a 64 px bucket so slightly different view widths (grid cells vary
    // with screen width) share one cache entry instead of fragmenting it.
    private static func bucket(_ px: CGFloat) -> CGFloat {
        let b = (ceil(px / 64) * 64)
        return max(64, min(768, b))
    }

    // MARK: - Decode queue (serial)
    // UIGraphicsBeginImageContextWithOptions is safer on iOS 6 when not called concurrently.
    private static let decodeQueue = DispatchQueue(label: "com.podcold.imagedecode")

    // MARK: - Instance state
    private var loadingURL: String?

    // MARK: - Load into self (AsyncImageView instances)

    // targetPx defaults to what this view can actually show. Callers with a frame
    // already set (all of them) get the right size for free.
    func load(url: String, maxPx: CGFloat? = nil) {
        let targetPx = AsyncImageView.bucket(maxPx ?? intrinsicTargetPx())

        // Memory cache hit — instant, no queue needed
        if let cached = AsyncImageView.cache.object(forKey: AsyncImageView.cacheKey(url: url, targetPx: targetPx)) {
            image = cached; return
        }
        loadingURL = url
        image = nil
        let capturedURL = url
        AsyncImageView.fetch(url: url, targetPx: targetPx) { [weak self] img in
            guard let self = self, self.loadingURL == capturedURL else { return }
            self.image = img
        }
    }

    func cancel() { loadingURL = nil }

    // Longest edge of this view in device pixels. Falls back to 300 pt when the
    // frame has not been set yet (bounds are 0 in viewDidLoad for pushed VCs).
    private func intrinsicTargetPx() -> CGFloat {
        let longest = max(bounds.width, bounds.height)
        return (longest > 0 ? longest : 300) * UIScreen.main.scale
    }

    // MARK: - Load for table cell imageViews
    // 120 px default: table thumbnails are ~44-60 pt.

    static func loadCell(url: String, maxPx: CGFloat = 120, completion: @escaping (UIImage) -> Void) {
        let targetPx = bucket(maxPx)
        if let cached = cache.object(forKey: cacheKey(url: url, targetPx: targetPx)) {
            completion(cached); return
        }
        fetch(url: url, targetPx: targetPx, completion: completion)
    }

    // MARK: - Shared pipeline: disk → network → decode → cache both layers

    private static func fetch(url: String, targetPx: CGFloat, completion: @escaping (UIImage) -> Void) {
        let path = diskPath(for: url, targetPx: targetPx)
        let key = cacheKey(url: url, targetPx: targetPx)

        // Step 1: Check disk on background queue (avoids main-thread file I/O).
        // The stored file is already downscaled, so this decode is cheap.
        decodeQueue.async {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let img = decode(data, targetPx: targetPx) {
                cache.setObject(img, forKey: key, cost: bitmapCost(img))
                DispatchQueue.main.async { completion(img) }
                return
            }

            // Step 2: Network fetch — CurlFetcher queues async to the image lane
            // and returns immediately
            CurlFetcher.fetchImage(url: url) { data in
                // CurlFetcher completion fires on main thread
                guard let data = data else { return }
                AsyncImageView.decodeQueue.async {
                    guard let img = decode(data, targetPx: targetPx) else { return }
                    // Persist the downscaled result, not the original bytes, so the
                    // next disk hit is a small decode instead of a full-size one.
                    if let jpeg = img.jpegData(compressionQuality: 0.85) {
                        try? jpeg.write(to: URL(fileURLWithPath: path), options: .atomicWrite)
                    }
                    cache.setObject(img, forKey: key, cost: bitmapCost(img))
                    DispatchQueue.main.async { completion(img) }
                }
            }
        }
    }

    // MARK: - Decode helpers

    // Decodes and downscales so the longest edge is at most targetPx *pixels*.
    //
    // Note this is a pixel budget, not a point budget. The previous version capped
    // the point size at 300 and then rendered at UIScreen scale, so it actually
    // produced 600 px bitmaps (1.4 MB each) regardless of how small the view was.
    //
    // Guards zero dimensions: UIGraphicsBeginImageContextWithOptions with {0,0}
    // raises NSInvalidArgumentException on iOS 6.
    private static func decode(_ data: Data, targetPx: CGFloat) -> UIImage? {
        guard let raw = UIImage(data: data) else { return nil }
        let rawW = raw.size.width * raw.scale
        let rawH = raw.size.height * raw.scale
        guard rawW > 0, rawH > 0 else { return nil }

        let screenScale = UIScreen.main.scale
        let ratio = min(1.0, targetPx / max(rawW, rawH))
        // Size in points; the context multiplies by screenScale to get pixels.
        let target = CGSize(width: floor(rawW * ratio / screenScale),
                            height: floor(rawH * ratio / screenScale))
        guard target.width > 0, target.height > 0 else { return nil }

        // opaque = true: no alpha channel to blend, and the cached form is JPEG
        // (which has no alpha) anyway. Cheaper to composite when drawn.
        UIGraphicsBeginImageContextWithOptions(target, true, screenScale)
        raw.draw(in: CGRect(origin: .zero, size: target))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    // Cost = decoded bitmap bytes (width × height × scale² × 4).
    // Correct cost ensures NSCache totalCostLimit reflects actual RAM usage.
    private static func bitmapCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }
}
