import Foundation

// MARK: - C-compatible callbacks (file scope, no captures allowed)

// Write callback for in-memory data accumulation
private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let buf = Unmanaged<NSMutableData>.fromOpaque(userdata).takeUnretainedValue()
    buf.append(ptr, length: bytes)
    return bytes
}

// Write callback for file-based downloads
private let curlFileWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(userdata).takeUnretainedValue()
    box.fileHandle?.write(Data(bytes: ptr, count: bytes))
    box.bytesReceived += Int64(bytes)
    return bytes
}

// Progress callback for file downloads (xferinfo: dltotal/dlnow are Int64 = curl_off_t)
private let curlProgressCallback: @convention(c) (UnsafeMutableRawPointer?, Int64, Int64, Int64, Int64) -> Int32 = { clientp, dltotal, dlnow, _, _ in
    guard let clientp = clientp, dltotal > 0 else { return 0 }
    let box = Unmanaged<CurlDownloadBox>.fromOpaque(clientp).takeUnretainedValue()
    let progress = Float(dlnow) / Float(dltotal)
    DispatchQueue.main.async { box.progressHandler?(progress) }
    return 0
}

// MARK: - Download state container

private class CurlDownloadBox {
    var fileHandle: FileHandle?
    var bytesReceived: Int64 = 0
    var progressHandler: ((Float) -> Void)?
}

// MARK: - Lane
//
// One serial queue + one persistent curl handle. Three lanes exist so that a
// multi-minute episode download can no longer block artwork or feed requests
// behind it, while still capping the app at three network threads (the
// static-queue rule: a queue per call would spawn an OS thread per request).
//
// The handle is reused across requests on its lane. curl_easy_reset clears the
// options but keeps the connection cache, DNS cache and TLS session cache, so
// consecutive requests to the same host skip the TCP + TLS handshake entirely —
// the dominant cost when loading a screen full of artwork from one CDN.
// `handle` is only ever touched from inside `queue`, which is serial, so no lock
// is needed.
private final class CurlLane {
    let queue: DispatchQueue
    private var handle: CurlHandle?

    init(label: String) { queue = DispatchQueue(label: label) }

    // Must be called on `queue`.
    func borrowHandle() -> CurlHandle? {
        if let h = handle {
            curl_bridge_reset(h)
        } else {
            handle = curl_bridge_init()
        }
        return handle
    }
}

// MARK: - CurlFetcher

class CurlFetcher {
    private static var active: [CurlFetcher] = []

    private static let imageLane    = CurlLane(label: "com.podcold.curl.image")
    private static let feedLane     = CurlLane(label: "com.podcold.curl.feed")
    private static let downloadLane = CurlLane(label: "com.podcold.curl.download")

    // Thread-safe once-init: Swift static let uses dispatch_once, so the first
    // lane to touch it runs curl_global_init exactly once even though three
    // queues now race for it. NOT called from main thread (crashes in
    // AppDelegate — OpenSSL threading issue).
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // Artwork and other small images. Separate lane so a feed refresh batch or an
    // episode download can never delay the images the user is looking at.
    static func fetchImage(url: String, timeout: Int = 15, completion: @escaping (Data?) -> Void) {
        fetch(url: url, timeout: timeout, lane: imageLane, gzip: false, completion: completion)
    }

    // RSS/Atom feeds — gzip enabled, these are highly compressible XML.
    static func fetchFeed(url: String, timeout: Int = 20, completion: @escaping (Data?) -> Void) {
        fetch(url: url, timeout: timeout, lane: feedLane, gzip: true, completion: completion)
    }

    private static func fetch(url: String,
                              timeout: Int,
                              lane: CurlLane,
                              gzip: Bool,
                              completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        lane.queue.async {
            let data = fetcher.syncFetchData(url: url, timeout: timeout, lane: lane, gzip: gzip)
            DispatchQueue.main.async {
                release(fetcher)
                completion(data)
            }
        }
    }

    // Download URL to file on a background thread, call completion on main thread
    static func downloadToFile(url: String,
                                outputPath: String,
                                progress: ((Float) -> Void)?,
                                completion: @escaping (Bool) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.downloadLane.queue.async {
            let ok = fetcher.syncDownload(url: url, outputPath: outputPath, progress: progress)
            DispatchQueue.main.async {
                release(fetcher)
                completion(ok)
            }
        }
    }

    // MARK: - Lifecycle management

    private static func retain(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.append(f)
        objc_sync_exit(CurlFetcher.self)
    }

    private static func release(_ f: CurlFetcher) {
        objc_sync_enter(CurlFetcher.self)
        active.removeAll { $0 === f }
        objc_sync_exit(CurlFetcher.self)
    }

    // MARK: - Synchronous implementations (run on background thread)

    private func syncFetchData(url: String, timeout: Int, lane: CurlLane, gzip: Bool) -> Data? {
        _ = CurlFetcher.curlGlobalInit  // ensures curl_global_init ran once before any easy_init
        guard let h = lane.borrowHandle() else { return nil }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        // Fail fast on dead hosts instead of burning the whole total timeout
        curl_bridge_set_connect_timeout(h, 15)
        if gzip { curl_bridge_set_accept_encoding(h) }
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let httpCode = curl_bridge_response_code(h)
        guard httpCode == 200 else { return nil }
        return buf as Data
    }

    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit  // same as syncFetchData
        guard let h = CurlFetcher.downloadLane.borrowHandle() else { return false }

        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: outputPath) else { return false }

        let box = CurlDownloadBox()
        box.fileHandle = fh
        box.progressHandler = progress
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        // No total-time cap: a 100 MB episode on 3G legitimately exceeds any fixed
        // limit. Abort only if the transfer stops making progress (< 1 KB/s for 60s).
        curl_bridge_set_connect_timeout(h, 20)
        curl_bridge_set_low_speed_abort(h, 1024, 60)
        curl_bridge_set_write_fn(h, curlFileWriteCallback, boxPtr)
        if progress != nil {
            curl_bridge_set_progress_fn(h, curlProgressCallback, boxPtr)
        }

        let rc = curl_bridge_perform(h)
        fh.closeFile()

        guard rc == 0 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            return false
        }
        let code = curl_bridge_response_code(h)
        guard code == 200 || code == 206 else {
            try? FileManager.default.removeItem(atPath: outputPath)
            return false
        }
        return box.bytesReceived > 0
    }
}
