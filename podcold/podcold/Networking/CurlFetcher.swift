import Foundation

// MARK: - C-compatible callbacks (file scope, no captures allowed)

// Write callback for in-memory data accumulation
private let curlDataWriteCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    guard let ptr = ptr, let userdata = userdata else { return 0 }
    let bytes = size * nmemb
    let box = Unmanaged<CurlDataBox>.fromOpaque(userdata).takeUnretainedValue()
    box.buf.append(ptr, length: bytes)
    // Returning short of `bytes` makes curl abort with CURLE_WRITE_ERROR;
    // syncFetchData treats that as success when the limit is why.
    if box.itemLimit > 0 && box.countItemEnds() >= box.itemLimit {
        box.reachedLimit = true
        return 0
    }
    return bytes
}

// Header callback for feed requests — one response header line per call.
private let curlHeaderCallback: @convention(c) (UnsafeRawPointer?, Int, Int, UnsafeMutableRawPointer?) -> Int = { ptr, size, nmemb, userdata in
    let bytes = size * nmemb
    guard let ptr = ptr, let userdata = userdata else { return bytes }
    let box = Unmanaged<CurlDataBox>.fromOpaque(userdata).takeUnretainedValue()
    box.readHeader(ptr, length: bytes)
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

// MARK: - Feed validators
//
// ETag / Last-Modified from a feed response, sent back on the next check so an
// unchanged feed answers 304 with no body at all. "" = the server sent none.
// Measured 2026-11-06: acast sends only an ETag, simplecast both; both answer 304.

struct FeedValidators {
    var etag = ""
    var lastModified = ""

    // What If-Range accepts: a strong ETag or a date — never a weak ETag.
    var ifRange: String {
        if !etag.isEmpty && !etag.hasPrefix("W/") { return etag }
        return lastModified
    }
}

// MARK: - Feed requests

struct FeedRequest {
    var maxItems = 0                        // stop after this many items; 0 = all
    var validators: FeedValidators? = nil   // conditional GET (New Episodes batch)
    var resume: FeedResume? = nil           // byte-range continuation (FeedPager)
}

// Carry on from `offset`, where the caller's bytes end. `itemsHeld` closing item
// tags are already in those bytes, so maxItems still counts from the top of the
// document. If-Range makes a feed that changed since answer from the top instead.
struct FeedResume {
    var offset: Int
    var ifRange: String
    var itemsHeld: Int
}

struct FeedInfo {
    var validators = FeedValidators()
    var partial = false     // 206: the bytes continue from FeedResume.offset
    var truncated = false   // stopped at maxItems; the document goes on
    var itemEnds = 0        // closing item tags from the top of the document to here
    // Content-Encoding other than identity: the bytes were decoded on arrival, so
    // their offsets no longer match the server's and a range can't continue them.
    var encoded = false
}

enum FeedResponse {
    case data(Data, FeedInfo)
    case notModified
    case failed
}

// MARK: - In-memory state container
//
// Feeds have no server-side paging and run to megabytes, but the parser only
// reads the first page. With itemLimit set, the transfer stops once that many
// closing </item> / </entry> tags have arrived — everything after them is bytes
// the parser would never look at.

private final class CurlDataBox {
    let buf = NSMutableData()
    var itemLimit = 0          // 0 = no limit
    var itemBase = 0           // item ends already held by the caller (FeedResume)
    var reachedLimit = false
    var validators = FeedValidators()
    var encoded = false
    var rangeStart = -1        // from Content-Range; -1 = none

    // Reads what FeedInfo reports. A redirect delivers one header block per hop, each
    // opening with a status line, so that line clears what an earlier hop sent — only
    // the final response's values count.
    func readHeader(_ ptr: UnsafeRawPointer, length: Int) {
        let line = String(decoding: UnsafeRawBufferPointer(start: ptr, count: length), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("HTTP/") {
            // "HTTP/1.1 206 Partial Content", "HTTP/2 200"
            let fields = line.split(separator: " ")
            let status = fields.count > 1 ? Int(fields[1]) ?? 0 : 0
            validators = FeedValidators()
            encoded = false
            rangeStart = -1
            // A 206 continues the caller's bytes, so the count carries on from theirs;
            // anything else is the document from the top. The status line arrives
            // before any body, so the write callback's limit check counts right.
            itemEnds = status == 206 ? itemBase : 0
            return
        }
        guard let colon = line.firstIndex(of: ":") else { return }
        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        switch line[..<colon].lowercased() {
        case "etag":          validators.etag = value
        case "last-modified": validators.lastModified = value
        case "content-encoding":
            let v = value.lowercased()
            encoded = !v.isEmpty && v != "identity"
        case "content-range":
            // "bytes 210000-260000/16761194"
            let spec = value.lowercased().hasPrefix("bytes ") ? value.dropFirst(6) : ""
            rangeStart = Int(spec.prefix { $0 != "-" }) ?? -1
        default:              break
        }
    }

    private static let endTags: [[UInt8]] = [Array("</item>".utf8), Array("</entry>".utf8)]
    private(set) var itemEnds = 0
    // Per tag: where the next search starts. Every match starting before it has
    // been counted, so a tag split across two chunks is found exactly once.
    private var searchFrom = [0, 0]

    // Only searches what arrived since the last call (plus a tag's length of overlap).
    func countItemEnds() -> Int {
        let base = buf.bytes
        let len = buf.length
        for (i, tag) in CurlDataBox.endTags.enumerated() {
            var from = searchFrom[i]
            tag.withUnsafeBytes { t in
                while from + tag.count <= len,
                      let hit = memmem(base + from, len - from, t.baseAddress, tag.count) {
                    itemEnds += 1
                    from = base.distance(to: UnsafeRawPointer(hit)) + tag.count
                }
            }
            searchFrom[i] = max(from, len - tag.count + 1)
        }
        return itemEnds
    }
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
        fetch(url: url, timeout: timeout, lane: imageLane, gzip: false, feed: nil) { response in
            if case .data(let data, _) = response { completion(data) } else { completion(nil) }
        }
    }

    // RSS/Atom feeds — gzip enabled, these are highly compressible XML. Except for a
    // range continuation: offsets into gzipped bytes would mean nothing to us.
    static func fetchFeed(url: String, timeout: Int = 20, request: FeedRequest,
                          completion: @escaping (FeedResponse) -> Void) {
        fetch(url: url, timeout: timeout, lane: feedLane, gzip: request.resume == nil,
              feed: request, completion: completion)
    }

    // feed == nil: a plain fetch (images) — no item counting, no header parsing.
    private static func fetch(url: String,
                              timeout: Int,
                              lane: CurlLane,
                              gzip: Bool,
                              feed: FeedRequest?,
                              completion: @escaping (FeedResponse) -> Void) {
        let fetcher = CurlFetcher()
        retain(fetcher)
        lane.queue.async {
            let response = fetcher.syncFetchData(url: url, timeout: timeout, lane: lane, gzip: gzip,
                                                 feed: feed)
            DispatchQueue.main.async {
                release(fetcher)
                completion(response)
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

    private func syncFetchData(url: String, timeout: Int, lane: CurlLane, gzip: Bool,
                               feed: FeedRequest?) -> FeedResponse {
        _ = CurlFetcher.curlGlobalInit  // ensures curl_global_init ran once before any easy_init
        guard let h = lane.borrowHandle() else { return .failed }

        let box = CurlDataBox()
        let ptr = Unmanaged.passUnretained(box).toOpaque()

        url.withCString { curl_bridge_set_url(h, $0) }
        curl_bridge_set_ssl_noverify(h)
        curl_bridge_set_follow_redirects(h)
        curl_bridge_set_timeout(h, CLong(timeout))
        // Fail fast on dead hosts instead of burning the whole total timeout
        curl_bridge_set_connect_timeout(h, 15)
        if gzip { curl_bridge_set_accept_encoding(h) }
        curl_bridge_set_write_fn(h, curlDataWriteCallback, ptr)

        var lines: [String] = []
        if let feed = feed {
            box.itemLimit = feed.maxItems
            if let v = feed.validators {
                if !v.etag.isEmpty         { lines.append("If-None-Match: \(v.etag)") }
                if !v.lastModified.isEmpty { lines.append("If-Modified-Since: \(v.lastModified)") }
            }
            if let r = feed.resume {
                box.itemBase = r.itemsHeld
                "\(r.offset)-".withCString { curl_bridge_set_range(h, $0) }
                lines.append("If-Range: \(r.ifRange)")
            }
            curl_bridge_set_header_fn(h, curlHeaderCallback, ptr)
        }
        // The list must outlive the transfer, so it is freed on the way out; the
        // option still pointing at it is cleared by the next borrowHandle() reset.
        var headerList: UnsafeMutableRawPointer?
        for line in lines {
            headerList = line.withCString { curl_bridge_append_header(headerList, $0) }
        }
        if headerList != nil { curl_bridge_set_headers(h, headerList) }
        defer { curl_bridge_free_headers(headerList) }

        let rc = curl_bridge_perform(h)
        // Stopping at the item limit surfaces as a write error, but everything up
        // to that point arrived intact — and it is all the caller asked for. The
        // aborted connection is closed rather than kept alive, which costs the
        // next request to that host a handshake: far cheaper than the rest of a
        // multi-megabyte feed.
        guard rc == 0 || box.reachedLimit else { return .failed }
        let httpCode = curl_bridge_response_code(h)
        if httpCode == 304 && feed?.validators != nil { return .notModified }

        var info = FeedInfo(validators: box.validators, partial: false, truncated: box.reachedLimit,
                            itemEnds: feed == nil ? 0 : box.countItemEnds(), encoded: box.encoded)
        if httpCode == 206, let r = feed?.resume {
            // Only a continuation from exactly where the caller's bytes end, in the
            // same encoding, can be appended to them.
            guard box.rangeStart == r.offset, !box.encoded else { return .failed }
            info.partial = true
        } else if httpCode != 200 {
            return .failed
        }
        return .data(box.buf as Data, info)
    }

    private func syncDownload(url: String, outputPath: String, progress: ((Float) -> Void)?) -> Bool {
        _ = CurlFetcher.curlGlobalInit  // same as syncFetchData
        guard let h = CurlFetcher.downloadLane.borrowHandle() else { return false }

        // Stream into a ".part" sidecar and only move it into place once the
        // transfer has actually succeeded. Writing straight to outputPath meant a
        // crash, OOM kill or force-quit mid-download left a truncated file that
        // Episode.localPath() — which only checks existence — reported as a
        // complete download, so the episode played a few seconds and stopped with
        // no way to re-download it.
        let partPath = outputPath + ".part"
        try? FileManager.default.removeItem(atPath: partPath)
        FileManager.default.createFile(atPath: partPath, contents: nil, attributes: nil)
        guard let fh = FileHandle(forWritingAtPath: partPath) else { return false }

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

        func discardPart() -> Bool {
            try? FileManager.default.removeItem(atPath: partPath)
            return false
        }

        guard rc == 0 else { return discardPart() }
        let code = curl_bridge_response_code(h)
        guard code == 200 || code == 206 else { return discardPart() }
        // A zero-byte body used to be reported as failure while the empty file was
        // left behind at the final path — which localPath() then saw as a download.
        guard box.bytesReceived > 0 else { return discardPart() }

        // Replace any previous copy, then publish atomically under the real name.
        try? FileManager.default.removeItem(atPath: outputPath)
        do {
            try FileManager.default.moveItem(atPath: partPath, toPath: outputPath)
        } catch {
            return discardPart()
        }
        return true
    }
}
