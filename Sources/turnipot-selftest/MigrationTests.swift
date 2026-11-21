import Foundation
import NotchCore

/// Carry-overs: settings from the old bundle id copied once (retired keys dropped), stale old sockets removed.
func registerMigrationTests() {
    let suite = "turnipot-selftest-\(UUID().uuidString)"
    guard let d = UserDefaults(suiteName: suite) else { check("migration: suite", false); return }
    defer { d.removePersistentDomain(forName: suite) }

    // Bundle id change: every old setting copied once, keys already set win.
    d.removePersistentDomain(forName: suite)
    d.set(false, forKey: "haptics")
    let copied = LegacyMigration.migrateBundleDomain(
        previous: ["mascot": "peeker", "haptics": true, "checkForUpdates": false, "updateNotifiedVersion": "0.3.0",
                   "legacyMigrationDone": true],
        into: d, domain: suite)
    expectEqual(copied, ["checkForUpdates", "updateNotifiedVersion"], "bundle id: copies the missing keys")
    check("bundle id: retired mascot key not carried over", d.object(forKey: "mascot") == nil)
    check("bundle id: existing key wins", d.object(forKey: "haptics") as? Bool == false)
    check("bundle id: done flag", d.bool(forKey: LegacyMigration.bundleIdDoneKey))
    expectEqual(LegacyMigration.migrateBundleDomain(previous: ["other": 1], into: d, domain: suite), [], "bundle id: runs once")
    d.removePersistentDomain(forName: suite)
    d.register(defaults: ["checkForUpdates": true])
    expectEqual(LegacyMigration.migrateBundleDomain(previous: ["checkForUpdates": false], into: d, domain: suite),
                ["checkForUpdates"], "bundle id: registered defaults don't count as set")
    d.removePersistentDomain(forName: suite)

    // Old runtime dir: a stale socket (bound, then closed) is removed, a live one stays.
    let dir = URL(fileURLWithPath: "/tmp/tp-mig-\(getpid())", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func bindSocket(_ name: String, listen live: Bool) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(dir.appendingPathComponent(name).path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if live { listen(fd, 1) } else { close(fd) }
        return fd
    }
    _ = bindSocket("app.sock", listen: false)
    _ = bindSocket("vscode-vscodium-1.sock", listen: false)
    let liveFd = bindSocket("vscode-vscodium-2.sock", listen: true)
    let removed = LegacyMigration.cleanLegacyRuntimeDir(dir).sorted()
    expectEqual(removed, ["app.sock", "vscode-vscodium-1.sock"], "migration: stale sockets removed")
    check("migration: live socket kept", FileManager.default.fileExists(atPath: dir.appendingPathComponent("vscode-vscodium-2.sock").path))
    close(liveFd)
    expectEqual(LegacyMigration.cleanLegacyRuntimeDir(dir), ["vscode-vscodium-2.sock"], "migration: now-stale socket removed")
    check("migration: empty old dir removed", !FileManager.default.fileExists(atPath: dir.path))
    expectEqual(LegacyMigration.cleanLegacyRuntimeDir(dir), [], "migration: missing dir is fine")
    check("migration: new runtime dir name", NotchPaths.runtimeDir.path.hasSuffix("Application Support/Turnipot"))
}
