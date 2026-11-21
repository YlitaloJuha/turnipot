import Foundation

/// Unix-domain socket server on ~/Library/Application Support/Turnipot/app.sock.
/// Protocol: client writes one JSON line (HookRequest), server writes one JSON line (HookResponse)
/// and closes. Each connection handled concurrently; the handler may take up to ~55s.
/// Socket file is unlinked before bind and on stop(); permissions 0600.
///
/// If the client disconnects while the handler is still running (e.g. Claude Code killed the hook
/// because the user answered in the terminal), the handler's Task is cancelled. Handlers that want
/// to react should use `withTaskCancellationHandler`.
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookRequest) async -> HookResponse

    public let socketPath: URL
    private let handler: Handler

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    /// Inode of the socket file we bound, so stop() never unlinks another instance's socket.
    private var boundInode: ino_t = 0

    /// Max size of one request line (tool inputs such as Write contents can be large).
    static let maxRequestBytes = 16 * 1024 * 1024

    /// Typical wiring in the app:
    ///   HookServer { req in await appState.handleHookRequest(req) }
    public init(socketPath: URL = NotchPaths.appSocket, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return listenFD >= 0
    }

    /// Create runtime dir, bind, listen, accept on a background thread.
    public func start() throws {
        stop()
        try? FileManager.default.createDirectory(at: socketPath.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let path = socketPath.path
        guard var addr = UnixSocket.address(path: path) else { throw ServerError.pathTooLong }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socketCreateFailed(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        // Another live instance owns the socket: don't steal it (its hooks would be orphaned).
        if Self.isListening(path: path) {
            close(fd)
            throw ServerError.alreadyRunning
        }
        unlink(path)
        // Create the socket file with 0600 from the start.
        let oldMask = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(oldMask)
        if rc != 0 {
            let e = errno
            close(fd)
            throw ServerError.bindFailed(e)
        }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw ServerError.listenFailed(e)
        }

        var st = stat()
        let inode: ino_t = stat(path, &st) == 0 ? st.st_ino : 0
        lock.lock()
        listenFD = fd
        boundInode = inode
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "Turnipot.HookServer.accept"
        thread.qualityOfService = .userInitiated
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        let fd = listenFD
        let inode = boundInode
        listenFD = -1
        boundInode = 0
        lock.unlock()
        guard fd >= 0 else { return }
        // shutdown() wakes the blocked accept(); then close + remove the socket file (if still ours).
        shutdown(fd, SHUT_RDWR)
        close(fd)
        var st = stat()
        if stat(socketPath.path, &st) == 0, inode == 0 || st.st_ino == inode {
            unlink(socketPath.path)
        }
        acceptThread = nil
    }

    public enum ServerError: Error {
        case socketCreateFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case pathTooLong
        case alreadyRunning
    }

    /// True if something accepts connections on `path` right now.
    static func isListening(path: String) -> Bool {
        guard var addr = UnixSocket.address(path: path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return rc == 0
    }

    // MARK: - Internals

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                // Listening socket closed (stop()) or a fatal error.
                lock.lock(); let current = listenFD; lock.unlock()
                if current != fd { return }
                if errno == EMFILE || errno == ENFILE { usleep(100_000); continue }
                return
            }
            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let handler = self.handler
            DispatchQueue.global(qos: .userInitiated).async {
                HookServer.serve(client: client, handler: handler)
            }
        }
    }

    /// Reads one request line, runs the handler, writes one response line, closes.
    static func serve(client: Int32, handler: @escaping Handler) {
        // Bound the time a client may take to send its request line.
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = UnixSocket.readLine(fd: client, maxBytes: maxRequestBytes) else {
            close(client); return
        }
        guard let request = try? JSONDecoder().decode(HookRequest.self, from: line) else {
            respond(client: client, HookResponse(decision: "ask"))
            close(client); return
        }

        let conn = ClientConnection(fd: client)
        let task = Task {
            let response = await handler(request)
            conn.finish(with: response)
        }
        conn.watchForDisconnect { task.cancel() }
    }

    static func respond(client: Int32, _ response: HookResponse) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        _ = UnixSocket.writeAll(fd: client, data: data)
    }
}

/// Owns an accepted client fd while the handler runs; detects early peer close.
private final class ClientConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var done = false
    private var source: DispatchSourceRead?

    init(fd: Int32) { self.fd = fd }

    /// Calls `onDisconnect` once if the peer closes before a response was written.
    func watchForDisconnect(_ onDisconnect: @escaping @Sendable () -> Void) {
        lock.lock()
        if done { lock.unlock(); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .utility))
        let fd = self.fd
        src.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) {
                self?.closeEarly()
                onDisconnect()
            } else if n > 0 {
                // Unexpected extra bytes: drain them so the source doesn't spin.
                var junk = [UInt8](repeating: 0, count: 4096)
                _ = recv(fd, &junk, junk.count, MSG_DONTWAIT)
            }
        }
        source = src
        lock.unlock()
        src.resume()
    }

    func finish(with response: HookResponse) {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let src = source
        source = nil
        lock.unlock()
        HookServer.respond(client: fd, response)
        closeFD(after: src)
    }

    private func closeEarly() {
        lock.lock()
        if done { lock.unlock(); return }
        done = true
        let src = source
        source = nil
        lock.unlock()
        closeFD(after: src)
    }

    private func closeFD(after src: DispatchSourceRead?) {
        let fd = self.fd
        if let src {
            src.setCancelHandler { close(fd) }
            src.cancel()
        } else {
            close(fd)
        }
    }
}
