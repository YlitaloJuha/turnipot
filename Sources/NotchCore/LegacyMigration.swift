import Foundation

/// One-time carry-overs from earlier identities of the app.
/// - Bundle id `com.local.turnipot` (before 0.4.0): every setting is copied once into the current
///   domain, keys already set there win (the old domain is left alone).
/// - The mascot setting is gone (the turnip is the only mascot): a stored `mascot` key is removed.
///
/// From the app's previous name ("Claude Notch", runtime dir ~/Library/Application Support/ClaudeNotch):
/// - The old runtime dir is only tidied: sockets nobody listens on are removed (a still-running old
///   copy keeps its live socket), and the dir is removed if that leaves it empty.
public enum LegacyMigration {
    /// Settings that no longer exist; removed at launch (0.4.0: the mascot choice).
    public static let retiredKeys = ["mascot", "legacyMigrationDone"]

    /// UserDefaults domain of Turnipot before its bundle id became `com.juhaylitalo.turnipot`.
    public static let previousBundleDomain = "com.local.turnipot"
    /// Set in the new defaults once the bundle id carry-over has run.
    public static let bundleIdDoneKey = "bundleIdMigrationDone"

    /// Copies every key of `previous` (the old bundle id's domain) that the current persistent domain
    /// `domain` of `defaults` doesn't have yet, once. Registered defaults don't count as set.
    /// Returns the copied keys, sorted.
    @discardableResult
    public static func migrateBundleDomain(previous: [String: Any]?, into defaults: UserDefaults, domain: String) -> [String] {
        guard !defaults.bool(forKey: bundleIdDoneKey) else { return [] }
        let current = defaults.persistentDomain(forName: domain) ?? [:]
        var copied: [String] = []
        for (key, value) in previous ?? [:] where current[key] == nil && key != bundleIdDoneKey && !retiredKeys.contains(key) {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        defaults.set(true, forKey: bundleIdDoneKey)
        return copied.sorted()
    }

    /// ~/Library/Application Support/ClaudeNotch (old runtime dir).
    public static var legacyRuntimeDir: URL {
        NotchPaths.home.appendingPathComponent("Library/Application Support/ClaudeNotch", isDirectory: true)
    }

    /// Removes stale `*.sock` files from `dir` (nothing accepts connections on them) and then the
    /// dir itself if it is empty. Returns the names of the removed sockets.
    @discardableResult
    public static func cleanLegacyRuntimeDir(_ dir: URL) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasSuffix(".sock") {
            let path = dir.appendingPathComponent(name).path
            if !HookServer.isListening(path: path) {
                unlink(path)
                removed.append(name)
            }
        }
        if let rest = try? fm.contentsOfDirectory(atPath: dir.path),
           rest.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: dir)
        }
        return removed
    }

    /// Run once at app launch (not in demo / render / export modes).
    public static func runAtLaunch() {
        if let domain = Bundle.main.bundleIdentifier, domain != previousBundleDomain {
            let previous = UserDefaults.standard.persistentDomain(forName: previousBundleDomain)
            let keys = migrateBundleDomain(previous: previous, into: .standard, domain: domain)
            if !keys.isEmpty { NSLog("Turnipot: carried over settings from \(previousBundleDomain): \(keys.joined(separator: ", "))") }
        }
        for key in retiredKeys { UserDefaults.standard.removeObject(forKey: key) }
        cleanLegacyRuntimeDir(legacyRuntimeDir)
    }
}
