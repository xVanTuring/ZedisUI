import Foundation
import Darwin

/// Spawns `/usr/bin/ssh -L` as a child process to forward a local TCP port
/// through an SSH session to a remote target (the real Redis host:port).
///
/// We deliberately don't use a pure-Swift SSH library — OpenSSH ships with
/// macOS, handles every algorithm and key format we'd care about (including
/// `rsa-sha2-256/512`, which Citadel doesn't), and respects the user's
/// `~/.ssh/config` if they ever care. The tradeoff is process management:
/// allocate a port, launch ssh, parse stderr to learn when the forward is
/// up, and terminate it cleanly on `stop()`.
///
/// Key files and passwords are written to the app's container-scoped temp
/// dir (`NSTemporaryDirectory()`) so the sandboxed child can read them;
/// security-scoped bookmarks don't propagate to child processes, so the
/// caller must hand us the key contents, not a path.
actor SSHTunnelService {
    enum AuthCredential: Sendable {
        case password(String)
        case privateKey(key: String, passphrase: String?)
    }

    enum TunnelError: LocalizedError {
        case processLaunchFailed(String)
        case authFailed
        case hostUnreachable(String)
        case forwardFailed(String)
        case timeout
        case unexpected(String)

        var errorDescription: String? {
            switch self {
            case .processLaunchFailed(let s):
                return "Failed to launch ssh: \(s)"
            case .authFailed:
                return "SSH authentication failed. Verify username, password/passphrase, and that the key is in authorized_keys."
            case .hostUnreachable(let s):
                return "Could not reach SSH server: \(s)"
            case .forwardFailed(let s):
                return "SSH port forwarding failed: \(s)"
            case .timeout:
                return "SSH tunnel did not become ready within \(Int(SSHTunnelService.readyTimeoutSeconds)) seconds."
            case .unexpected(let s):
                return "SSH tunnel error: \(s)"
            }
        }
    }

    private let sshHost: String
    private let sshPort: Int
    private let username: String
    private let credential: AuthCredential
    private let targetHost: String
    private let targetPort: Int

    private var process: Process?
    private var stderrPipe: Pipe?
    /// Files we created under NSTemporaryDirectory() and need to clean up
    /// on stop(): the on-disk copy of the private key (chmod 600) and the
    /// askpass helper script (chmod 700).
    private var tempFiles: [URL] = []
    private(set) var localPort: Int = 0

    /// Upper bound for how long we'll wait for ssh to print
    /// "Local forwarding listening on" after launch. Must comfortably
    /// exceed `ConnectTimeout` (10s) plus key exchange + auth +
    /// forwarding setup on a slow network — a 15s budget left only ~5s
    /// after a worst-case TCP connect, which timed out for users on
    /// laggy links before any real failure could surface.
    private static let readyTimeoutSeconds: TimeInterval = 30

    init(
        sshHost: String,
        sshPort: Int,
        username: String,
        credential: AuthCredential,
        targetHost: String,
        targetPort: Int
    ) {
        self.sshHost = sshHost
        self.sshPort = sshPort
        self.username = username
        self.credential = credential
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    deinit {
        if let p = process, p.isRunning { p.terminate() }
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
    }

    // MARK: - Lifecycle

    func start() async throws -> Int {
        if let p = process, p.isRunning { return localPort }

        let port = try Self.allocateLoopbackPort()

        let (proc, stderr) = try prepareProcess(port: port)
        do {
            try proc.run()
        } catch {
            cleanupTempFiles()
            throw TunnelError.processLaunchFailed(error.localizedDescription)
        }

        self.process = proc
        self.stderrPipe = stderr

        do {
            try await waitForReady(process: proc, stderr: stderr)
        } catch {
            await stop()
            throw error
        }

        self.localPort = port
        return port
    }

    func stop() async {
        if let p = process, p.isRunning {
            p.terminate()
            // Give ssh up to 2s to exit gracefully; SIGKILL if not.
            let pid = p.processIdentifier
            for _ in 0..<40 {
                if !p.isRunning { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if p.isRunning { kill(pid, SIGKILL) }
        }
        process = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        cleanupTempFiles()
        localPort = 0
    }

    private func cleanupTempFiles() {
        for f in tempFiles { try? FileManager.default.removeItem(at: f) }
        tempFiles = []
    }

    // MARK: - Process construction

    private func prepareProcess(port: Int) throws -> (Process, Pipe) {
        var args: [String] = [
            "-v",  // verbose: we need "Local forwarding listening" on stderr to know we're ready
            "-N",  // no remote command, just forward
            "-T",  // disable pseudo-terminal — also makes ASKPASS the only password channel
            "-o", "BatchMode=no",
            "-o", "ConnectTimeout=10",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(Self.knownHostsPath().path)",
            "-p", "\(sshPort)",
        ]

        var env: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            // Force ASKPASS even without an X display (OpenSSH 8.4+). macOS
            // 15 ships with 9.x, so we can rely on this.
            "SSH_ASKPASS_REQUIRE": "force",
            // ssh historically required DISPLAY to be set before it'd try
            // ASKPASS at all. With REQUIRE=force it isn't strictly needed,
            // but setting it costs nothing and helps on older code paths.
            "DISPLAY": "ZEDIS",
        ]

        switch credential {
        case .privateKey(let contents, let passphrase):
            let keyURL = try writeTempFile(
                contents: contents.hasSuffix("\n") ? contents : contents + "\n",
                prefix: "zedis-key-",
                mode: 0o600
            )
            tempFiles.append(keyURL)
            args.append(contentsOf: [
                "-i", keyURL.path,
                "-o", "IdentitiesOnly=yes",
                "-o", "PreferredAuthentications=publickey",
            ])
            if let pp = passphrase, !pp.isEmpty {
                let askpass = try writeAskpassScript()
                tempFiles.append(askpass)
                env["SSH_ASKPASS"] = askpass.path
                env["ZEDIS_SSH_SECRET"] = pp
            }
        case .password(let pw):
            let askpass = try writeAskpassScript()
            tempFiles.append(askpass)
            env["SSH_ASKPASS"] = askpass.path
            env["ZEDIS_SSH_SECRET"] = pw
            args.append(contentsOf: [
                "-o", "PreferredAuthentications=password,keyboard-interactive",
                "-o", "NumberOfPasswordPrompts=1",
                "-o", "PubkeyAuthentication=no",
            ])
        }

        args.append("\(username)@\(sshHost)")
        args.append("-L")
        args.append("127.0.0.1:\(port):\(targetHost):\(targetPort)")

        let stderr = Pipe()
        let stdout = Pipe()

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice  // no terminal stdin
        p.standardOutput = stdout
        p.standardError = stderr

        return (p, stderr)
    }

    // MARK: - Ready detection

    /// Reads stderr until ssh signals it's actually serving the forward
    /// (or matching error markers, or the process exits). Returns
    /// successfully once the tunnel is up; throws otherwise. Stays
    /// installed as a readabilityHandler after returning so the pipe
    /// doesn't fill up over the session's lifetime.
    ///
    /// Two distinct signals matter here:
    ///   1. `"Local forwarding listening on"` — listen() has returned on
    ///      the local socket. TCP handshakes will complete (kernel
    ///      backlog), but ssh has NOT yet entered the event loop, so it
    ///      hasn't accept()ed any forwarded connections nor opened the
    ///      remote channel. Connecting Redis here races against that
    ///      gap and AUTH/PING can time out before SSH catches up.
    ///   2. `"Entering interactive session"` — ssh has entered
    ///      `client_loop()`. This is the loop that does accept() +
    ///      channel-open, so forwarding is actually live from this point.
    ///
    /// We prefer (2). (1) is kept as a fallback with a short grace
    /// period in case an ssh build elides the interactive-session line.
    private func waitForReady(process: Process, stderr: Pipe) async throws {
        let handle = stderr.fileHandleForReading
        let buf = StderrBuffer()

        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty { return }
            if let s = String(data: data, encoding: .utf8) {
                Task { await buf.append(s) }
            }
        }

        let deadline = Date().addingTimeInterval(Self.readyTimeoutSeconds)
        var listenerSeenAt: Date?
        while Date() < deadline {
            if !process.isRunning {
                // Drain anything left.
                let leftover = handle.availableData
                if !leftover.isEmpty, let s = String(data: leftover, encoding: .utf8) {
                    await buf.append(s)
                }
                let final = await buf.snapshot()
                handle.readabilityHandler = nil
                throw Self.classifyFailure(stderr: final, exitCode: process.terminationStatus)
            }

            let snapshot = await buf.snapshot()
            if Self.eventLoopReady(snapshot) {
                return
            }
            if Self.listenerReady(snapshot) {
                if let seen = listenerSeenAt {
                    if Date().timeIntervalSince(seen) >= Self.listenerGraceSeconds {
                        return
                    }
                } else {
                    listenerSeenAt = Date()
                }
            }
            if let err = Self.firstErrorMatch(snapshot) {
                process.terminate()
                handle.readabilityHandler = nil
                throw err
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }

        process.terminate()
        handle.readabilityHandler = nil
        throw TunnelError.timeout
    }

    /// Fallback grace period after the listener bind line, used only
    /// when `Entering interactive session` never appears. Longer than
    /// the typical setup-to-event-loop gap (microseconds–tens of ms),
    /// short enough that users aren't waiting needlessly.
    private static let listenerGraceSeconds: TimeInterval = 1.0

    private static func eventLoopReady(_ stderr: String) -> Bool {
        stderr.contains("Entering interactive session")
    }

    private static func listenerReady(_ stderr: String) -> Bool {
        stderr.contains("Local forwarding listening on")
    }

    private static func firstErrorMatch(_ stderr: String) -> TunnelError? {
        if stderr.contains("Permission denied") {
            return .authFailed
        }
        if stderr.contains("Could not resolve hostname") {
            return .hostUnreachable("hostname lookup failed")
        }
        if stderr.contains("Connection refused") {
            return .hostUnreachable("connection refused")
        }
        if stderr.contains("No route to host") {
            return .hostUnreachable("no route to host")
        }
        if stderr.contains("Operation timed out") {
            return .hostUnreachable("connect timed out")
        }
        if stderr.contains("bind [127.0.0.1]") && stderr.contains("Address already in use") {
            return .forwardFailed("local port already in use")
        }
        if stderr.contains("remote port forwarding failed") {
            return .forwardFailed("server rejected the forward")
        }
        return nil
    }

    private static func classifyFailure(stderr: String, exitCode: Int32) -> TunnelError {
        if let err = firstErrorMatch(stderr) { return err }
        // Surface the last meaningful line for diagnostics.
        let lines = stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        let tail = lines.suffix(5).joined(separator: "\n")
        return .unexpected("ssh exited with code \(exitCode)\n\(tail)")
    }

    // MARK: - File helpers (container-temp)

    private func writeTempFile(contents: String, prefix: String, mode: mode_t) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode)],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Tiny shell helper that ssh invokes when it needs a password or key
    /// passphrase. ssh passes the prompt text as $1; we ignore it and
    /// echo the secret we baked into the environment. The secret lives in
    /// the child's env for the duration of the ssh process and is not
    /// written to disk.
    private func writeAskpassScript() throws -> URL {
        let body = """
        #!/bin/sh
        printf '%s' "$ZEDIS_SSH_SECRET"
        """
        return try writeTempFile(contents: body, prefix: "zedis-askpass-", mode: 0o700)
    }

    /// Per-app known_hosts file in the sandbox container. We don't want to
    /// stomp on the user's real ~/.ssh/known_hosts (and sandbox usually
    /// blocks reading it anyway).
    private static func knownHostsPath() -> URL {
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()))
            .appendingPathComponent("ZedisUI", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("known_hosts")
    }

    // MARK: - Loopback port allocation

    /// Bind a TCP socket to 127.0.0.1:0 to let the kernel assign a free
    /// port, capture it, then close. There's a small TOCTOU window before
    /// ssh reuses the port — in practice this is fine. Same trick the
    /// existing Redis ecosystem GUIs use.
    private static func allocateLoopbackPort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw TunnelError.unexpected("socket() failed: \(String(cString: strerror(errno)))")
        }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)  // 127.0.0.1

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw TunnelError.unexpected("bind() failed: \(String(cString: strerror(errno)))")
        }

        var actual = sockaddr_in()
        var sz = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &sz)
            }
        }
        guard nameResult == 0 else {
            throw TunnelError.unexpected("getsockname() failed: \(String(cString: strerror(errno)))")
        }
        return Int(UInt16(bigEndian: actual.sin_port))
    }
}

// MARK: - Stderr buffer

/// Thread-safe accumulator for ssh's stderr stream. The Pipe
/// readabilityHandler runs on a Dispatch queue; we hop into this actor
/// to append, and the waiter reads snapshots.
private actor StderrBuffer {
    private var buffer = ""

    func append(_ chunk: String) {
        buffer.append(chunk)
    }

    func snapshot() -> String { buffer }
}
