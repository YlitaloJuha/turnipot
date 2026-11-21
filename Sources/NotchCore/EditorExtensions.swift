import Foundation

/// Installing the Turnipot Bridge extension (vscode-extension/, packed as a .vsix by
/// scripts/build-app.sh into Turnipot.app/Contents/Resources) from the app: same editors, CLIs and
/// old-id cleanup as scripts/install-extension.sh (its `--copy` fallback stays script-only).
public enum EditorExtensions {
    public struct Editor: Equatable, Sendable {
        public var id: String
        public var appName: String
        public var cliName: String
    }

    public static let editors: [Editor] = [
        Editor(id: "codium", appName: "VSCodium", cliName: "codium"),
        Editor(id: "code", appName: "Visual Studio Code", cliName: "code"),
        Editor(id: "cursor", appName: "Cursor", cliName: "cursor"),
    ]
    public static let extensionId = "local.turnipot-bridge"
    /// The extension's id from when the app was called "Claude Notch".
    public static let oldExtensionId = "local.claude-notch-bridge"
    public static let vsixResourceName = "turnipot-bridge.vsix"

    /// Where each editor's command line tool lives inside its app bundle.
    public static func cliCandidates(_ e: Editor, home: String = NSHomeDirectory()) -> [String] {
        ["/Applications", home + "/Applications"].map { "\($0)/\(e.appName).app/Contents/Resources/app/bin/\(e.cliName)" }
    }

    public struct Found: Equatable, Sendable {
        public var editor: Editor
        /// nil: the app is installed but its CLI wasn't found (use the script's --copy).
        public var cli: String?
        public init(editor: Editor, cli: String?) { self.editor = editor; self.cli = cli }
    }

    /// Installed editors (`isExecutable` / `exists` injectable for tests).
    public static func detect(home: String = NSHomeDirectory(),
                              isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                              exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Found] {
        editors.compactMap { e in
            if let cli = cliCandidates(e, home: home).first(where: isExecutable) { return Found(editor: e, cli: cli) }
            let apps = ["/Applications", home + "/Applications"].map { "\($0)/\(e.appName).app" }
            return apps.contains(where: exists) ? Found(editor: e, cli: nil) : nil
        }
    }

    /// `<cli> --list-extensions` output contains `id` (case-insensitive, whole line).
    public static func listContains(_ output: String, id: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == id.lowercased() }
    }

    public struct Outcome: Equatable, Sendable {
        public var editor: Editor
        public var ok: Bool
        public var message: String
    }

    /// Install `vsix` into each found editor with a CLI (removing the old-id extension first).
    /// Blocking: call off the main thread.
    public static func install(vsix: String, into found: [Found], timeout: TimeInterval = 90) -> [Outcome] {
        found.map { f in
            guard let cli = f.cli else {
                return Outcome(editor: f.editor, ok: false, message: "command line tool not found")
            }
            if let list = run(cli, ["--list-extensions"], timeout: 30), listContains(list.output, id: oldExtensionId) {
                _ = run(cli, ["--uninstall-extension", oldExtensionId], timeout: 60)
            }
            guard let r = run(cli, ["--install-extension", vsix, "--force"], timeout: timeout) else {
                return Outcome(editor: f.editor, ok: false, message: "the command line tool didn't finish")
            }
            let lastLine = r.output.split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.contains("DeprecationWarning") && !$0.contains("trace-deprecation") }
                .last ?? ""
            return Outcome(editor: f.editor, ok: r.status == 0, message: lastLine)
        }
    }

    /// Run a tool, capturing stdout + stderr; nil if it couldn't start or timed out (killed).
    static func run(_ path: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Read concurrently so a chatty tool can't fill the pipe and stall.
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = done.wait(timeout: .now() + 2)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 2)
        return (p.terminationStatus, String(decoding: box.get(), as: UTF8.self))
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
