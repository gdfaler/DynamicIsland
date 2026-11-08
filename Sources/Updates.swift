import AppKit

/// Looks for a newer release on GitHub (the public Releases API; nothing is sent but the request itself) and tells
/// the island when there is one. It never downloads or installs anything: the island opens the release page.
final class UpdateChecker {
    static let repository = "gdfaler/DynamicIsland"
    private static let interval: TimeInterval = 12 * 3600

    struct Release: Equatable {
        var version: String
        var url: URL
    }

    /// A release newer than the running app, once one has been found.
    private(set) var available: Release?
    /// Called on the main thread when the island should announce a release: the first time, and then once a day
    /// until the user has opened the release page.
    var onNewVersion: ((Release) -> Void)?
    /// A release the user hasn't opened yet — what the persistent signs (badge, chip) show. Called on change.
    var onPendingChange: ((Release?) -> Void)?
    var pending: Release? {
        guard let available, defaults.string(forKey: "updateAcknowledged") != available.version else { return nil }
        return available
    }
    private static let reminder: TimeInterval = 24 * 3600

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    /// ISLAND_VERSION_OVERRIDE lets a test pretend to be an older version.
    static var currentVersion: String {
        ProcessInfo.processInfo.environment["ISLAND_VERSION_OVERRIDE"] ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Checks shortly after launch and then twice a day, but never more often than the interval.
    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfDue() {
        let last = defaults.object(forKey: "updateLastCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= Self.interval else { return }
        check(userInitiated: false) { _ in }
    }

    /// `userInitiated` checks always report the result (to the completion), and tell the island even about a version
    /// the user was already told about.
    func check(userInitiated: Bool, completion: @escaping (Result<Release?, Error>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest") else { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DynamicIsland/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let result: Result<Release?, Error>
            if let error {
                result = .failure(error)
            } else if let data, let release = Self.parse(data) {
                result = .success(Self.isNewer(release.version, than: Self.currentVersion) ? release : nil)
            } else {
                result = .success(nil)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure = result {} else { self.defaults.set(Date(), forKey: "updateLastCheck") }
                if case .success(let release) = result {
                    self.available = release
                    self.onPendingChange?(self.pending)
                    if let release {
                        let lastAlert = self.defaults.object(forKey: "updateLastAlert") as? Date ?? .distantPast
                        let due = self.pending != nil && Date().timeIntervalSince(lastAlert) >= Self.reminder
                        if userInitiated || due {
                            self.defaults.set(Date(), forKey: "updateLastAlert")
                            self.onNewVersion?(release)
                        }
                    }
                }
                completion(result)
            }
        }.resume()
    }

    /// Opens the release page, and counts the news as seen: the badge and reminders stop.
    func openReleasePage() {
        if let available { defaults.set(available.version, forKey: "updateAcknowledged") }
        onPendingChange?(pending)
        let fallback = URL(string: "https://github.com/\(Self.repository)/releases/latest")!
        NSWorkspace.shared.open(available?.url ?? fallback)
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: page)
    }

    /// "1.10" is newer than "1.9": compared number by number.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] { version.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }
}
