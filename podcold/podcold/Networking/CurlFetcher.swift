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

// MARK: - CurlFetcher

class CurlFetcher {
    private static var active: [CurlFetcher] = []
    // Shared serial queue — serial prevents concurrent curl_easy_init calls before global init.
    // curl_global_init is NOT thread-safe; concurrent implicit calls via curl_easy_init crash.
    private static let curlQueue = DispatchQueue(label: "com.podcold.curl")
    // Thread-safe once-init: Swift static let uses dispatch_once.
    // First background thread to access this calls curl_global_init exactly once.
    // NOT called from main thread (crashes in AppDelegate — OpenSSL threading issue).
    private static let curlGlobalInit: Bool = { curl_bridge_global_init(); return true }()

    // Call once at app startup (AppDelegate)
    static func globalInit() {
        curl_bridge_global_init()
    }

    // Fetch URL → Data on a background thread, call completion on main thread
    static func fetchData(url: String, timeout: Int = 30, completion: @escaping (Data?) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        CurlFetcher.curlQueue.async {
            let data = fetcher.syncFetchData(url: url, timeout: timeout)
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
        CurlFetcher.curlQueue.async {
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

    private func syncFetchData(url: String, timeout: Int) -> Data? {
        _ = CurlFetcher.curlGlobalInit  // ensures curl_global_init ran once before any easy_init
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        let buf = NSMutableData()
        let ptr = Unmanaged.passUnretained(buf).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        let rc = curl_bridge_perform(h)
        guard rc == 0 else { return nil }
        let httpCode = curl_bridge_response_code(h)
        guard httpCode == 200 else { return nil }
        return buf as Data
    }

    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit  // same as syncFetchData
        let h = curl_bridge_init()
        defer { curl_bridge_cleanup(h) }

        FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: outputPath) else { return false }

        let box = CurlDownloadBox()
        box.fileHandle = fh
        box.progressHandler = progress
        let boxPtr = Unmanaged.passUnretained(box).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, 300)
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
