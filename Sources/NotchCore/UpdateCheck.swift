import Foundation

/// Semantic version "MAJOR.MINOR.PATCH[-prerelease][+build]" (a leading "v" is accepted; missing
/// minor / patch count as 0). Ordering follows semver: a pre-release sorts before its release,
/// pre-release identifiers compare numerically when both are numbers, build metadata is ignored.
public struct SemVer: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            pre = s[s.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, !pre.contains(where: \.isEmpty) else { return nil }
            s = String(s[..<dash])
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var nums: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p) else { return nil }
            nums.append(n)
        }
        while nums.count < 3 { nums.append(0) }
        self.init(major: nums[0], minor: nums[1], patch: nums[2], prerelease: pre)
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        // A release is newer than any of its pre-releases.
        if a.prerelease.isEmpty || b.prerelease.isEmpty { return !a.prerelease.isEmpty && b.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (.some, nil): return true          // numeric identifiers sort first
            case (nil, .some): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// A GitHub release as needed for the update check.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: SemVer
    public var tag: String
    /// The release page (only ever https://github.com/…).
    public var pageURL: URL

    public init(version: SemVer, tag: String, pageURL: URL) {
        self.version = version; self.tag = tag; self.pageURL = pageURL
    }
}

/// The update check: one anonymous GET of the repo's latest release, compared with the bundle
/// version. Pure parts are here (tested); the app does the request (UpdateChecker).
public enum UpdateCheck {
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/YlitaloJuha/turnipot/releases/latest")!
    public static let releasesPageURL = URL(string: "https://github.com/YlitaloJuha/turnipot/releases")!
    public static let interval: TimeInterval = 24 * 60 * 60
    public static let timeout: TimeInterval = 10
    /// UserDefaults keys.
    public static let enabledKey = "checkForUpdates"
    public static let notifiedVersionKey = "updateNotifiedVersion"

    public static func userAgent(version: String) -> String { "Turnipot/\(version)" }

    /// Parse a `GET /repos/{owner}/{repo}/releases/latest` body. nil for drafts, pre-releases,
    /// tags that aren't semver, or a page URL that isn't on github.com over https.
    public static func parseLatestRelease(_ data: Data) -> ReleaseInfo? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = obj["tag_name"] as? String, let version = SemVer(tag), !version.isPrerelease else { return nil }
        if obj["draft"] as? Bool == true || obj["prerelease"] as? Bool == true { return nil }
        var page = releasesPageURL
        if let s = obj["html_url"] as? String, let u = URL(string: s), u.scheme == "https", u.host == "github.com" {
            page = u
        }
        return ReleaseInfo(version: version, tag: tag, pageURL: page)
    }

    /// The release if it is newer than `current` (the bundle's CFBundleShortVersionString).
    public static func newer(_ release: ReleaseInfo?, than current: String?) -> ReleaseInfo? {
        guard let release, let current, let cur = SemVer(current) else { return nil }
        return release.version > cur ? release : nil
    }

    /// HTTP status + body -> newer release or nil (404 for a private / release-less repo, rate
    /// limits, errors: nil, silently).
    public static func evaluate(status: Int, body: Data?, current: String?) -> ReleaseInfo? {
        guard status == 200, let body else { return nil }
        return newer(parseLatestRelease(body), than: current)
    }

    /// Due when never checked or the last check is at least `interval` old.
    public static func isDue(lastCheck: Date?, now: Date, interval: TimeInterval = UpdateCheck.interval) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck
    }

    /// Show the one-time "Turnipot vX is available" drop-down for this version?
    public static func shouldNotify(_ release: ReleaseInfo, notifiedVersion: String?) -> Bool {
        notifiedVersion.flatMap(SemVer.init).map { release.version > $0 } ?? true
    }
}
