import Foundation

class HTTPClient {

    static func get(url: String, headers: [String: String] = [:], completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)")); return
        }
        var req = URLRequest(url: nsUrl)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        send(req, completion: completion)
    }

    static func post(url: String, headers: [String: String] = [:], body: [String: Any], completion: @escaping (Data?, Error?) -> Void) {
        guard let nsUrl = URL(string: url) else {
            completion(nil, makeError("Invalid URL: \(url)")); return
        }
        var req = URLRequest(url: nsUrl)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let data = try? JSONSerialization.data(withJSONObject: body) { req.httpBody = data }
        send(req, completion: completion)
    }

    // Always use NSURLFetcher — works iOS 6 through iOS 15+
    // (NSURLConnection is deprecated from iOS 9 but never removed)
    private static func send(_ req: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
        if Thread.isMainThread {
            NSURLFetcher.fetch(req, completion: completion)
        } else {
            DispatchQueue.main.async { NSURLFetcher.fetch(req, completion: completion) }
        }
    }

    static func makeError(_ msg: String) -> NSError {
        NSError(domain: "HTTPClient", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// NSURLConnection delegate wrapper — static array keeps instances alive (same as EpisodeDownloader).
// Timer runs in .common mode so it fires in UITrackingRunLoopMode (UISearchBar active) too.
private class NSURLFetcher: NSObject, NSURLConnectionDataDelegate {
    private var accumulated = Data()
    private let completion: (Data?, Error?) -> Void
    private var conn: NSURLConnection?
    private var timer: Timer?
    private static var active: [NSURLFetcher] = []

    static func fetch(_ request: URLRequest, completion: @escaping (Data?, Error?) -> Void) {
        let f = NSURLFetcher(completion: completion)
        active.append(f)

        // Schedule in .common so it fires in both default and UITracking run loop modes
        let t = Timer(timeInterval: 20, target: f, selector: #selector(NSURLFetcher.timedOut),
                      userInfo: nil, repeats: false)
        RunLoop.main.add(t, forMode: .common)
        f.timer = t

        // Schedule connection on main run loop in .common mode
        let c = NSURLConnection(request: request, delegate: f, startImmediately: false)
        c?.schedule(in: .main, forMode: .common)
        c?.start()
        f.conn = c
    }

    private init(completion: @escaping (Data?, Error?) -> Void) { self.completion = completion }

    @objc private func timedOut() { finish(nil, HTTPClient.makeError("Timeout")) }

    func connection(_ c: NSURLConnection, didReceive response: URLResponse) { accumulated = Data() }
    func connection(_ c: NSURLConnection, didReceive d: Data) { accumulated.append(d) }
    func connectionDidFinishLoading(_ c: NSURLConnection) { finish(accumulated, nil) }
    func connection(_ c: NSURLConnection, didFailWithError e: Error) { finish(nil, e) }

    // iOS 6+ preferred SSL bypass (overrides old canAuthenticate + didReceiveChallenge pair)
    func connection(_ c: NSURLConnection, willSendRequestFor challenge: URLAuthenticationChallenge) {
        guard let sender = challenge.sender else { return }
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            sender.use(URLCredential(trust: trust), for: challenge)
        } else {
            sender.performDefaultHandling?(for: challenge)
        }
    }

    private func finish(_ data: Data?, _ error: Error?) {
        timer?.invalidate(); timer = nil; conn = nil
        NSURLFetcher.active.removeAll { $0 === self }
        DispatchQueue.main.async { self.completion(data, error) }
    }
}
