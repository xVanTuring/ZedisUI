import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import RediStack
import Logging

/// One Pub/Sub-mode Redis connection, separate from the session's primary
/// connection. Required because RediStack (and the Redis protocol itself)
/// puts a connection into PubSub mode after SUBSCRIBE/PSUBSCRIBE, where
/// only a fixed set of commands are allowed — we can't share the
/// connection that's serving the key browser.
///
/// Lifecycle: `start(pattern:)` dials and PSUBSCRIBEs in one call;
/// `stop()` PUNSUBSCRIBEs and closes. Messages arrive via the
/// `@Sendable` `onMessage` closure passed at init; the closure should hop
/// to MainActor before touching UI state.
actor PubSubService {
    typealias MessageHandler = @Sendable (_ channel: String, _ message: String, _ at: Date) -> Void
    typealias StateHandler = @Sendable (_ subscribed: Bool, _ pattern: String) -> Void

    private var host: String
    private var port: Int
    private let username: String?
    private let password: String?

    private let group: EventLoopGroup
    private var connection: RedisConnection?
    private var subscribedPattern: String?

    private let onMessage: MessageHandler
    private let onState: StateHandler

    init(
        host: String,
        port: Int,
        username: String?,
        password: String?,
        onMessage: @escaping MessageHandler,
        onState: @escaping StateHandler
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.onMessage = onMessage
        self.onState = onState
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        try? group.syncShutdownGracefully()
    }

    /// Late-bound endpoint patch for SSH-tunneled sessions. The controller
    /// can't read the session's forwarded local port synchronously at
    /// init, so it calls this once it has the value. No-op once we've
    /// already opened the connection.
    func setEndpoint(host: String, port: Int) {
        guard connection == nil else { return }
        self.host = host
        self.port = port
    }

    /// Open the connection (if needed) and PSUBSCRIBE to `pattern`. If a
    /// previous subscription is active, it is replaced.
    func start(pattern: String) async throws {
        if subscribedPattern != nil {
            try await punsubscribeIfNeeded()
        }
        if connection == nil {
            try await openConnection()
        }
        guard let conn = connection else { throw PubSubError.notConnected }

        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective = trimmed.isEmpty ? "*" : trimmed

        let onMessage = self.onMessage
        let onState = self.onState

        try await conn.psubscribe(
            to: [effective],
            messageReceiver: { channel, value in
                let body = Self.respString(value)
                onMessage(channel.rawValue, body, Date())
            },
            onSubscribe: { sub, _ in
                onState(true, sub)
            },
            onUnsubscribe: { sub, count in
                if count == 0 {
                    onState(false, sub)
                }
            }
        ).get()
        subscribedPattern = effective
    }

    /// PUNSUBSCRIBE and close the connection. Safe to call when nothing is
    /// running.
    func stop() async {
        await punsubscribeQuietly()
        if let conn = connection {
            try? await conn.close().get()
            connection = nil
        }
        subscribedPattern = nil
    }

    // MARK: - Internals

    enum PubSubError: LocalizedError {
        case notConnected
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Pub/Sub connection not open."
            }
        }
    }

    private func openConnection() async throws {
        let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
        let effectiveUsername = (username?.isEmpty == false) ? username : nil
        let effectivePassword = (password?.isEmpty == false) ? password : nil
        let config = try RedisConnection.Configuration(
            address: address,
            username: effectiveUsername,
            password: effectivePassword,
            initialDatabase: 0,
            defaultLogger: Logger(label: "ZedisUI.PubSub")
        )
        let conn = try await RedisConnection.make(
            configuration: config,
            boundEventLoop: group.next()
        ).get()
        self.connection = conn
    }

    private func punsubscribeIfNeeded() async throws {
        guard let conn = connection, subscribedPattern != nil else { return }
        try await conn.punsubscribe().get()
        subscribedPattern = nil
    }

    private func punsubscribeQuietly() async {
        guard let conn = connection, subscribedPattern != nil else { return }
        _ = try? await conn.punsubscribe().get()
        subscribedPattern = nil
    }

    /// Best-effort RESP → display string. Binary payloads fall back to a
    /// short placeholder so the table never shows raw garbage.
    private static func respString(_ value: RESPValue) -> String {
        switch value {
        case .simpleString(let buf), .bulkString(.some(let buf)):
            if let s = String(bytes: buf.readableBytesView, encoding: .utf8) { return s }
            return "<binary \(buf.readableBytes) bytes>"
        case .bulkString(.none), .null:
            return ""
        case .integer(let n):
            return String(n)
        case .error(let err):
            return "(error) " + err.message
        case .array:
            return value.prettyPrinted()
        }
    }
}

// MARK: - Controller

/// MainActor-bound state for one Pub/Sub window. Owns the underlying
/// `PubSubService` actor and a capped ring buffer of received messages so
/// long-running subscriptions don't grow without bound.
@Observable
@MainActor
final class PubSubController {
    struct Message: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let channel: String
        let body: String
    }

    enum ViewerMode: String, CaseIterable, Identifiable {
        /// Picks Plain or JSON per message based on whether the body
        /// parses as JSON. Default — matches Medis's behavior. Auto never
        /// resolves to Hex; binary payloads have to be picked manually.
        case auto = "Auto"
        case plain = "Plain"
        case json = "JSON"
        case hex = "Hex"
        var id: String { rawValue }
    }

    /// Sub-mode when JSON is the effective viewer. Mirrors the Tree/Text
    /// toggle in `JSONEditor`, but read-only — pub/sub messages aren't
    /// editable.
    enum JSONMode: String, CaseIterable, Identifiable {
        case tree = "Tree"
        case text = "Text"
        var id: String { rawValue }
    }

    /// How the raw message bytes were encoded by the publisher. Only
    /// `.none` is wired up in v1; the others are enum-only placeholders so
    /// the UI shows the full Medis-style menu — see TODO.md for the
    /// implementation backlog.
    enum EncoderMode: String, CaseIterable, Identifiable {
        case none = "None"
        case messagePack = "MessagePack"
        case gzip = "Gzip"
        case php = "PHP"
        case base64 = "Base64"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case idle
        case starting
        case running
        case failed(String)
    }

    let connection: Connection

    var pattern: String = "*"
    var status: Status = .idle
    /// Pattern that's actively subscribed on the wire. Mirrors the footer
    /// "Subscribed to: …" line. Nil while idle.
    var subscribedPattern: String?
    var messages: [Message] = []
    var selectedMessageID: Message.ID?
    var viewer: ViewerMode = .auto
    var jsonMode: JSONMode = .tree
    var encoder: EncoderMode = .none

    private let service: PubSubService
    private let maxMessages: Int
    private let tunneled: Bool
    private weak var session: RedisSession?

    init(session: RedisSession, maxMessages: Int = 5000) {
        self.connection = session.connection
        self.maxMessages = maxMessages
        self.tunneled = (session.tunnel != nil)
        self.session = session

        // Default dial target: the connection's saved host/port. For
        // tunneled sessions we patch this via setEndpoint() once start()
        // is invoked (see start()), pulling the forwarded local port from
        // the live RedisService.
        let host = session.connection.host
        let port = session.connection.port

        let password: String?
        switch session.connection.passwordMode {
        case .keychain: password = KeychainHelper.password(for: session.connection.id)
        case .askEachTime, .none: password = nil
        }

        // Service callbacks need to reach back into self. Capture a weak
        // box so we don't keep the controller alive after the window goes
        // away.
        let box = ControllerBox()
        self.service = PubSubService(
            host: host,
            port: port,
            username: session.connection.username,
            password: password,
            onMessage: { channel, body, at in
                Task { @MainActor in
                    box.controller?.appendMessage(channel: channel, body: body, at: at)
                }
            },
            onState: { subscribed, sub in
                Task { @MainActor in
                    box.controller?.applySubscribeState(subscribed: subscribed, sub: sub)
                }
            }
        )
        box.controller = self
    }

    func start() {
        switch status {
        case .running, .starting: return
        case .idle, .failed: break
        }
        status = .starting
        let p = pattern
        let svc = service
        let tunneled = self.tunneled
        let session = self.session
        Task {
            if tunneled, let session {
                let ep = await session.service.currentEndpoint()
                await svc.setEndpoint(host: ep.host, port: ep.port)
            }
            do {
                try await svc.start(pattern: p)
            } catch {
                await MainActor.run {
                    self.status = .failed(error.localizedDescription)
                    self.subscribedPattern = nil
                }
            }
        }
    }

    func stop() {
        let svc = service
        Task {
            await svc.stop()
            await MainActor.run {
                self.status = .idle
                self.subscribedPattern = nil
            }
        }
    }

    func clear() {
        messages.removeAll()
        selectedMessageID = nil
    }

    fileprivate func appendMessage(channel: String, body: String, at: Date) {
        let msg = Message(timestamp: at, channel: channel, body: body)
        messages.append(msg)
        if messages.count > maxMessages {
            let drop = messages.count - maxMessages
            messages.removeFirst(drop)
        }
    }

    fileprivate func applySubscribeState(subscribed: Bool, sub: String) {
        if subscribed {
            status = .running
            subscribedPattern = sub
        } else {
            subscribedPattern = nil
            if case .running = status { status = .idle }
        }
    }
}

/// Holds a weak reference back to the controller so the service's escaping
/// callbacks can call it without retaining it. We need this indirection
/// because `self` isn't usable inside the designated initializer before
/// all stored properties are set.
@MainActor
private final class ControllerBox {
    weak var controller: PubSubController?
}
