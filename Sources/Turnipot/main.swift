import AppKit

// Entry point. LSUIElement app (no Dock icon / menu bar) — Info.plist is written by scripts/build-app.sh.
// Debug aid: `Turnipot --dump [--no-usage]` prints sessions + usage as JSON and exits.
let arguments = CommandLine.arguments
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
if let a = arguments.first(where: { $0.hasPrefix("--dump-replies=") }) {
    DumpCommand.runReplies(sessionId: String(a.dropFirst("--dump-replies=".count)))
}
if arguments.contains("--dump") {
    DumpCommand.run(includeUsage: !arguments.contains("--no-usage"))
}

MainActor.assumeIsolated {
    if let dir = MediaExport.requestedDir {
        _ = NSApplication.shared
        MediaExport.run(dir: dir)
    }
    if let dir = RenderCommand.requestedDir {
        _ = NSApplication.shared
        RenderCommand.run(dir: dir)
    }
    let app = NSApplication.shared
    // SIGTERM / SIGINT -> normal termination so AppDelegate answers pending permission requests
    // ("ask") and unlinks app.sock.
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        // Terminate from the run loop, not from inside this main-queue callout: termination
        // animates first (terminateLater), and a nested run loop can't drain the main queue
        // while we're still executing a main-queue block.
        src.setEventHandler {
            RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
        src.resume()
        signalSources.append(src)
    }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
