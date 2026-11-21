import Foundation
import NotchCore

/// Install & distribution: semver / update check, the in-app hook installer (checked against
/// scripts/install-hook.sh --dry-run), editor detection.
func registerDistributionTests() {
    // MARK: SemVer
    expectEqual(SemVer("0.3.0"), SemVer(major: 0, minor: 3, patch: 0), "semver: plain")
    expectEqual(SemVer("v1.2.3"), SemVer(major: 1, minor: 2, patch: 3), "semver: v prefix")
    expectEqual(SemVer("1.2"), SemVer(major: 1, minor: 2, patch: 0), "semver: missing patch")
    expectEqual(SemVer("1.2.3-beta.2+build.7")?.prerelease, ["beta", "2"], "semver: prerelease, build ignored")
    check("semver: garbage rejected", SemVer("latest") == nil && SemVer("1..2") == nil && SemVer("") == nil
          && SemVer("1.2.3.4") == nil && SemVer("1.2.3-") == nil && SemVer("1.x") == nil)
    check("semver: patch", SemVer("0.3.1")! > SemVer("0.3.0")!)
    check("semver: minor beats patch", SemVer("0.4.0")! > SemVer("0.3.9")!)
    check("semver: numeric, not lexical", SemVer("0.10.0")! > SemVer("0.9.0")!)
    check("semver: major", SemVer("1.0.0")! > SemVer("0.99.99")!)
    check("semver: prerelease < release", SemVer("1.0.0-rc.1")! < SemVer("1.0.0")!)
    check("semver: rc.2 < rc.10", SemVer("1.0.0-rc.2")! < SemVer("1.0.0-rc.10")!)
    check("semver: alpha < beta", SemVer("1.0.0-alpha")! < SemVer("1.0.0-beta")!)
    check("semver: alpha < alpha.1", SemVer("1.0.0-alpha")! < SemVer("1.0.0-alpha.1")!)
    check("semver: equal", SemVer("v0.3.0") == SemVer("0.3"))
    expectEqual(SemVer("v0.3.0-rc.1")?.description, "0.3.0-rc.1", "semver: description")

    // MARK: Release parsing + decision
    func body(_ s: String) -> Data { Data(s.utf8) }
    let latest = body(#"{"tag_name":"v0.4.0","name":"Turnipot 0.4.0","draft":false,"prerelease":false,"html_url":"https://github.com/YlitaloJuha/turnipot/releases/tag/v0.4.0","assets":[]}"#)
    let r = UpdateCheck.parseLatestRelease(latest)
    expectEqual(r?.version, SemVer("0.4.0"), "release: version")
    expectEqual(r?.pageURL.absoluteString, "https://github.com/YlitaloJuha/turnipot/releases/tag/v0.4.0", "release: page")
    check("release: newer than 0.3.0", UpdateCheck.newer(r, than: "0.3.0") != nil)
    check("release: not newer than itself", UpdateCheck.newer(r, than: "0.4.0") == nil)
    check("release: not newer than 0.5.0", UpdateCheck.newer(r, than: "0.5.0") == nil)
    check("release: unknown bundle version -> nothing", UpdateCheck.newer(r, than: nil) == nil && UpdateCheck.newer(r, than: "dev") == nil)
    check("release: prerelease ignored", UpdateCheck.parseLatestRelease(body(#"{"tag_name":"v0.5.0-rc.1","html_url":"https://github.com/x"}"#)) == nil)
    check("release: prerelease flag ignored", UpdateCheck.parseLatestRelease(body(#"{"tag_name":"v0.5.0","prerelease":true}"#)) == nil)
    check("release: draft ignored", UpdateCheck.parseLatestRelease(body(#"{"tag_name":"v0.5.0","draft":true}"#)) == nil)
    check("release: non-semver tag ignored", UpdateCheck.parseLatestRelease(body(#"{"tag_name":"nightly"}"#)) == nil)
    check("release: junk ignored", UpdateCheck.parseLatestRelease(body("<html>")) == nil
          && UpdateCheck.parseLatestRelease(body(#"[1,2]"#)) == nil)
    let evil = UpdateCheck.parseLatestRelease(body(#"{"tag_name":"v9.0.0","html_url":"https://evil.example/x"}"#))
    expectEqual(evil?.pageURL, UpdateCheck.releasesPageURL, "release: foreign page URL replaced by the releases page")
    let http = UpdateCheck.parseLatestRelease(body(#"{"tag_name":"v9.0.0","html_url":"http://github.com/x"}"#))
    expectEqual(http?.pageURL, UpdateCheck.releasesPageURL, "release: non-https page URL replaced")
    // Private repo / no release yet / rate limit: silent.
    check("update: 404 -> nothing", UpdateCheck.evaluate(status: 404, body: body(#"{"message":"Not Found"}"#), current: "0.3.0") == nil)
    check("update: 403 -> nothing", UpdateCheck.evaluate(status: 403, body: latest, current: "0.3.0") == nil)
    check("update: no body -> nothing", UpdateCheck.evaluate(status: 200, body: nil, current: "0.3.0") == nil)
    check("update: 200 newer -> release", UpdateCheck.evaluate(status: 200, body: latest, current: "0.3.0")?.tag == "v0.4.0")
    expectEqual(UpdateCheck.userAgent(version: "0.3.0"), "Turnipot/0.3.0", "update: user agent")
    expectEqual(UpdateCheck.latestReleaseURL.absoluteString, "https://api.github.com/repos/YlitaloJuha/turnipot/releases/latest", "update: endpoint")
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    check("update: due when never checked", UpdateCheck.isDue(lastCheck: nil, now: t))
    check("update: not due after 23 h", !UpdateCheck.isDue(lastCheck: t, now: t.addingTimeInterval(23 * 3600)))
    check("update: due after 24 h", UpdateCheck.isDue(lastCheck: t, now: t.addingTimeInterval(24 * 3600)))
    check("update: clock went back -> due", UpdateCheck.isDue(lastCheck: t, now: t.addingTimeInterval(-60)))
    if let r {
        check("update: notify once", UpdateCheck.shouldNotify(r, notifiedVersion: nil))
        check("update: already notified", !UpdateCheck.shouldNotify(r, notifiedVersion: "0.4.0"))
        check("update: notified for an older one", UpdateCheck.shouldNotify(r, notifiedVersion: "0.3.5"))
    }

    // MARK: OrderedJSON
    let src = #"{"z": 1, "a": {"y": [1, 2.50, -3e2, true, null], "x": "é \"q\" \\ / \t \u0001 😀"}, "e": {}, "l": []}"#
    if let v = try? OrderedJSON.parse(src) {
        expectEqual(v.serialized(), """
        {
          "z": 1,
          "a": {
            "y": [
              1,
              2.5,
              -300.0,
              true,
              null
            ],
            "x": "é \\"q\\" \\\\ / \\t \\u0001 😀"
          },
          "e": {},
          "l": []
        }
        """, "json: python-style layout, key order kept")
    } else { check("json: parses", false) }
    check("json: invalid rejected", (try? OrderedJSON.parse("{\"a\": }")) == nil && (try? OrderedJSON.parse("{} x")) == nil)
    check("json: surrogate pair", (try? OrderedJSON.parse(#""😀""#)) == .string("😀"))
    check("json: duplicate key keeps first position, last value",
          (try? OrderedJSON.parse(#"{"a":1,"b":2,"a":3}"#))?.serialized(indent: 0) == "{\n\"a\": 3,\n\"b\": 2\n}")

    // MARK: Hook settings
    expectEqual(HookSettings.shellQuote("/Applications/Turnipot.app/Contents/Helpers/turnipot-hook"),
                "/Applications/Turnipot.app/Contents/Helpers/turnipot-hook", "hook: safe path unquoted")
    expectEqual(HookSettings.shellQuote("/Users/x/Work Projects/it's/turnipot-hook"),
                #"'/Users/x/Work Projects/it'"'"'s/turnipot-hook'"#, "hook: quoted path")
    expectEqual(HookSettings.firstWord(#"'/a b/turnipot-hook' --x"#), "/a b/turnipot-hook", "hook: first word single quotes")
    expectEqual(HookSettings.firstWord(#"  "/a \"b\"/x" y"#), #"/a "b"/x"#, "hook: first word double quotes")
    expectEqual(HookSettings.firstWord(#"/a\ b/x y"#), "/a b/x", "hook: first word backslash")
    check("hook: unbalanced quotes -> nil", HookSettings.firstWord("'/a b") == nil)
    func hookEntry(_ c: String) -> OrderedJSON { .object([("type", .string("command")), ("command", .string(c))]) }
    check("hook: ours by name", HookSettings.isOurs(hookEntry("'/x y/Turnipot.app/Contents/Helpers/turnipot-hook'")))
    check("hook: old name", HookSettings.isOurs(hookEntry("/x/claude-notch/.build/release/notch-hook")))
    check("hook: lookalike folder not ours", !HookSettings.isOurs(hookEntry("/x/claude-notch-sounds/play.sh")))
    check("hook: argument not ours", !HookSettings.isOurs(hookEntry("/usr/bin/logger turnipot-hook")))

    let hook = "/Users/x/Work Projects/turnipot/build/Turnipot.app/Contents/Helpers/turnipot-hook"
    let fixtures: [(String, String?)] = [
        ("no file", nil),
        ("empty file", "  \n"),
        ("other settings", #"{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"], "deny": []}, "env": {"A": "é"}, "n": 1.50}"#),
        ("other hooks + old entries", #"""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "say done"}]}],
          "PermissionRequest": [
            {"matcher": "Bash", "hooks": [{"type": "command", "command": "/x/claude-notch-sounds/play.sh"}, {"type": "command", "command": "'/old/ClaudeNotch.app/Contents/Helpers/notch-hook'", "timeout": 90}]},
            {"matcher": "*", "hooks": [{"type": "command", "command": "/old/turnipot/build/Turnipot.app/Contents/Helpers/turnipot-hook", "timeout": 600}]},
            {"matcher": "Edit", "hooks": []}
          ]}, "theme": "dark"}
        """#),
    ]
    let fm = FileManager.default
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("turnipot-hooktest-\(getpid())")
    try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    // A fake hook binary for the script (it needs an executable path); a folder with a space.
    let fakeDir = tmp.appendingPathComponent("Work Projects")
    try? fm.createDirectory(at: fakeDir, withIntermediateDirectories: true)
    let fakeHook = fakeDir.appendingPathComponent("turnipot-hook").path
    fm.createFile(atPath: fakeHook, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("scripts/install-hook.sh").path
    let canRunScript = fm.isExecutableFile(atPath: "/usr/bin/python3") && fm.fileExists(atPath: script)

    for (name, text) in fixtures {
        guard let install = try? HookSettings.plan(settingsText: text, hookPath: hook),
              let uninstall = try? HookSettings.plan(settingsText: text, hookPath: nil) else {
            check("hook plan: \(name) parses", false); continue
        }
        check("hook plan: \(name) installs our entry", install.output.contains(#""command": "'\#(hook)'""#))
        check("hook plan: \(name) timeout 600", install.output.contains(#""timeout": 600"#))
        // Idempotent: installing again changes nothing.
        let again = try? HookSettings.plan(settingsText: install.output, hookPath: hook)
        check("hook plan: \(name) reinstall is a no-op", again?.changes == false && again?.removed == 1)
        check("hook plan: \(name) uninstall leaves none of ours", !uninstall.output.contains("turnipot-hook") && !uninstall.output.contains("notch-hook"))

        // Same output as the script (--dry-run never writes), byte for byte.
        guard canRunScript else { continue }
        let settingsFile = tmp.appendingPathComponent("settings-\(name.replacingOccurrences(of: " ", with: "-")).json")
        if let text { try? Data(text.utf8).write(to: settingsFile) } else { try? fm.removeItem(at: settingsFile) }
        let mine = try? HookSettings.plan(settingsText: text, hookPath: fakeHook)
        let scriptInstall = runScript(script, ["--dry-run", "--hook", fakeHook, "--settings", settingsFile.path])
        expectEqual(mine?.output, scriptInstall, "hook plan: \(name) matches install-hook.sh --dry-run")
        let scriptUninstall = runScript(script, ["--dry-run", "--uninstall", "--settings", settingsFile.path])
        expectEqual(uninstall.output, scriptUninstall, "hook plan: \(name) uninstall matches the script")
    }
    if let p = try? HookSettings.plan(settingsText: fixtures[3].1, hookPath: hook) {
        expectEqual(p.removed, 2, "hook plan: replaces the old notch-hook and turnipot-hook entries")
        expectEqual(p.otherCommands, ["/x/claude-notch-sounds/play.sh"], "hook plan: other PermissionRequest hooks kept")
        check("hook plan: Stop hook untouched", p.output.contains("say done"))
    }
    check("hook plan: invalid JSON throws", (try? HookSettings.plan(settingsText: "{nope", hookPath: hook)) == nil)
    check("hook plan: array root throws", (try? HookSettings.plan(settingsText: "[]", hookPath: hook)) == nil)

    // apply(): backup, symlink kept, mode kept, no write when nothing changes.
    let realDir = tmp.appendingPathComponent("dotfiles")
    try? fm.createDirectory(at: realDir, withIntermediateDirectories: true)
    let real = realDir.appendingPathComponent("settings.json").path
    fm.createFile(atPath: real, contents: Data(fixtures[2].1!.utf8), attributes: [.posixPermissions: 0o600])
    let link = tmp.appendingPathComponent("settings.json").path
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: real)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    if let applied = try? HookSettings.apply(settingsPath: link, hookPath: hook, now: now) {
        check("hook apply: wrote", applied.wrote)
        check("hook apply: backup next to settings.json", applied.backupPath?.hasPrefix(link + ".bak-") == true
              && fm.contents(atPath: applied.backupPath ?? "") == Data(fixtures[2].1!.utf8))
        check("hook apply: symlink kept", (try? fm.destinationOfSymbolicLink(atPath: link)) == real)
        check("hook apply: real file updated", String(decoding: fm.contents(atPath: real) ?? Data(), as: UTF8.self) == applied.plan.output)
        let mode = ((try? fm.attributesOfItem(atPath: real))?[.posixPermissions] as? NSNumber)?.intValue
        expectEqual(mode, 0o600, "hook apply: mode kept")
        let second = try? HookSettings.apply(settingsPath: link, hookPath: hook, now: now.addingTimeInterval(5))
        check("hook apply: unchanged -> no write, no backup", second?.wrote == false && second?.backupPath == nil)
        let removed = try? HookSettings.apply(settingsPath: link, hookPath: nil, now: now.addingTimeInterval(10))
        check("hook apply: uninstall", removed?.wrote == true && !(String(decoding: fm.contents(atPath: real) ?? Data(), as: UTF8.self)).contains("turnipot-hook"))
    } else { check("hook apply: succeeded", false) }
    let fresh = tmp.appendingPathComponent("new/.claude/settings.json").path
    let created = try? HookSettings.apply(settingsPath: fresh, hookPath: hook, now: now)
    check("hook apply: creates a missing settings.json", created?.wrote == true && created?.backupPath == nil && fm.fileExists(atPath: fresh))
    expectEqual(HookSettings.backupPath(for: "/s.json", now: now, pid: 42).hasPrefix("/s.json.bak-20"), true, "hook apply: backup name")

    // MARK: Editor extension
    let home = "/Users/x"
    let codiumCli = "/Applications/VSCodium.app/Contents/Resources/app/bin/codium"
    let cursorCli = home + "/Applications/Cursor.app/Contents/Resources/app/bin/cursor"
    let found = EditorExtensions.detect(home: home, isExecutable: { $0 == codiumCli || $0 == cursorCli },
                                        exists: { $0 == "/Applications/Visual Studio Code.app" })
    expectEqual(found.map(\.editor.id), ["codium", "code", "cursor"], "editors: found in menu order")
    expectEqual(found.map(\.cli), [codiumCli, nil, cursorCli], "editors: CLI paths (~/Applications too; app without CLI)")
    check("editors: none installed", EditorExtensions.detect(home: home, isExecutable: { _ in false }, exists: { _ in false }).isEmpty)
    check("editors: list contains old id", EditorExtensions.listContains("ms-python.python\nLocal.Claude-Notch-Bridge\n", id: EditorExtensions.oldExtensionId))
    check("editors: list substring is not a match", !EditorExtensions.listContains("local.claude-notch-bridge-2\n", id: EditorExtensions.oldExtensionId))
    let noCli = EditorExtensions.install(vsix: "/x.vsix", into: [EditorExtensions.Found(editor: EditorExtensions.editors[1], cli: nil)])
    check("editors: no CLI -> reported, nothing run", noCli.first?.ok == false)
}

private func runScript(_ script: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = [script] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
}
