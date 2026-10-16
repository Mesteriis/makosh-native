// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// Pinned source and retained notice: Dependencies/Mail.lock.json, Dependencies/Mail/MMail.MIT.notice.
// Makosh adaptations are recorded in docs/mail-migration.md.
import Foundation
import NIO
import NIOCore
import NIOPosix
import NIOIMAP
import NIOIMAPCore

enum MailError: LocalizedError {
    case notConnected
    case connectFailed(String)
    case commandFailed(String)
    case noResult

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .connectFailed(let m): return "Connection failed: \(m)"
        case .commandFailed(let m): return "Server rejected the command: \(m)"
        case .noResult: return "No response from server."
        }
    }
}

struct IMAPMessage: Sendable {
    var uid: UInt32
    var subject: String
    var fromName: String
    var fromEmail: String
    var toName: String
    var toEmail: String
    var ccEmail: String
    var bccEmail: String
    var date: Date
    var seen: Bool
    var flagged: Bool
    var messageID: String
    var inReplyTo: String
    var keywords: [String]
}

// NIO-free flag kind so the app layer doesn't import NIOIMAPCore.
enum MailFlagKind: Sendable { case seen, flagged, deleted }

/// Linearizes cancellation against the final command write on NIO's event loop.
final class MailCommandDispatch: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func dispatch<Value>(_ write: () throws -> Value) throws -> Value {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        return try write()
    }
}

// NIO-free incremental-sync results.
struct IMAPFlagState: Sendable {
    var seen: Bool
    var flagged: Bool
    var keywords: [String]
}

struct IMAPFolderSync: Sendable {
    var newMessages: [IMAPMessage]               // UID greater than the highest we had
    var flags: [UInt32: IMAPFlagState]           // current flags for the already-loaded range
}

// NIO-free advanced-search criteria. The app builds this; IMAPService turns it
// into a server SearchKey so the app layer stays free of NIOIMAPCore.
struct MailSearchCriteria: Sendable {
    var text = ""
    var from = ""
    var to = ""
    var subject = ""
    var since: Date?
    var before: Date?
    var unseenOnly = false
    var flaggedOnly = false

    var isEmpty: Bool {
        text.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty
            && since == nil && before == nil && !unseenOnly && !flaggedOnly
    }
}

enum MailboxKind: String, Codable, Sendable { case inbox, sent, drafts, trash, junk, archive, other }

struct IMAPMailbox: Sendable {
    let name: String          // server mailbox path (used for SELECT/MOVE)
    let displayName: String
    let kind: MailboxKind
    let selectable: Bool
}

// Collects responses per command, matching the FIFO of issued tags.
final class IMAPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Response

    private struct Pending { let tag: String; let promise: EventLoopPromise<[Response]>; var acc: [Response] }
    private var queue: [Pending] = []
    private var receivedBytes = 0
    private var idleStarted = false, idleStopRequested = false, idleEnding = false
    private var idleTag: String?
    func beginIdle(tag: String, promise: EventLoopPromise<[Response]>) {
        idleTag = tag; idleStarted = false; idleStopRequested = false; idleEnding = false
        enqueue(tag: tag, promise: promise)
    }
    func stopIdle(channel: Channel) {
        guard idleTag != nil else { return }
        idleStopRequested = true
        if idleStarted && !idleEnding {
            idleEnding = true
            let endingTag = idleTag
            channel.writeAndFlush(IMAPClientHandler.Message.part(.idleDone), promise: nil)
            // A server that ignores DONE must not hold shutdown forever.
            channel.eventLoop.scheduleTask(in: .seconds(5)) { [weak self] in
                if self?.idleTag == endingTag { channel.close(promise: nil) }
            }
        }
    }
    func closeUnstartedIdle(channel: Channel) { if idleTag != nil && !idleStarted { channel.close(promise: nil) } }

    func enqueue(tag: String, promise: EventLoopPromise<[Response]>) {
        queue.append(Pending(tag: tag, promise: promise, acc: []))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = unwrapInboundIn(data)
        guard !queue.isEmpty else { return } // greeting / unsolicited
        if case .fetch(.streamingBytes(let bytes)) = response { receivedBytes += bytes.readableBytes }
        guard receivedBytes <= 32 * 1024 * 1024, queue[0].acc.count < 200000 else {
            failAll(MailFailure.tooLarge); context.close(promise:nil); return
        }
        switch response {
        case .idleStarted:
            idleStarted = true
            queue[0].acc.append(response)
            if idleStopRequested { stopIdle(channel: context.channel) }
        case .tagged(let tagged):
            guard tagged.tag == queue[0].tag else { failAll(MailError.noResult); context.close(promise:nil); return }
            receivedBytes = 0
            var head = queue.removeFirst()
            if idleTag == tagged.tag { idleTag = nil }
            head.acc.append(response)
            head.promise.succeed(head.acc)
        case .fatal:
            failAll(MailError.notConnected); context.close(promise:nil)
        default:
            queue[0].acc.append(response)
            if idleTag != nil {
                switch response {
                case .untagged(.mailboxData), .fetch: stopIdle(channel: context.channel)
                default: break
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failAll(error)
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        failAll(MailError.notConnected)
        context.fireChannelInactive()
    }
    private func failAll(_ error: Error) {
        idleTag = nil
        let pending = queue; queue.removeAll()
        pending.forEach { $0.promise.fail(error) }
    }
}

final class IMAPService: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let security: ConnectionSecurity
    private let username: String
    private let password: String
    private let tlsCAFile: String?

    private static let group = MultiThreadedEventLoopGroup.singleton
    private let collector = IMAPResponseHandler()
    private let channelLock = NSLock()
    private var storedChannel: Channel?
    private var channel: Channel? {
        get { channelLock.lock(); defer { channelLock.unlock() }; return storedChannel }
        set { channelLock.lock(); storedChannel = newValue; channelLock.unlock() }
    }
    private let lifetime = MailCommandDispatch()
    private var tagCounter = 0
    /// The mailbox currently SELECTed on this connection, if any. Lets us skip
    /// redundant SELECTs (the slowest no-op an IMAP client can issue).
    private var currentMailbox: String?
    private(set) var selectedUIDValidity: UInt32 = 0
    private var supportsIdle: Bool?

    init(config: MailAccountConfig, password: String, tlsCAFile: String? = nil) {
        self.tlsCAFile = tlsCAFile
        self.host = config.imapHost
        self.port = config.imapPort
        self.security = config.imapSecurity
        self.username = config.imapUsername
        self.password = password
    }

    private func nextTag() -> String { tagCounter += 1; return "a\(String(format: "%04d", tagCounter))" }

    // MARK: Connection

    func connectAndLogin() async throws {
        let bootstrap = ClientBootstrap(group: Self.group)
            .channelInitializer { [collector] channel in
                do { try channel.pipeline.syncOperations.addHandlers([IMAPClientHandler(), collector]); return channel.eventLoop.makeSucceededVoidFuture() }
                catch { return channel.eventLoop.makeFailedFuture(error) }
            }
        do {
            let channel = try await bootstrap.connectTimeout(.seconds(15)).connect(host: host, port: port).get()
            do { try lifetime.dispatch { self.channel = channel } }
            catch { channel.close(promise: nil); throw error }
            if security == .tls { try await MailTLSHandler.install(channel: channel, host: host, caFile: tlsCAFile).get() }
        } catch {
            throw MailError.connectFailed(error.localizedDescription)
        }

        if security == .startTLS {
            _ = try await send(.startTLS)
            guard let channel = self.channel else { throw MailError.notConnected }
            try await MailTLSHandler.install(channel: channel, host: host, caFile: tlsCAFile).get()
        }

        _ = try await send(.login(username: username, password: password))
    }

    func disconnect() async {
        lifetime.cancel()
        if let channel = self.channel {
            try? await channel.close().get()
        }
        self.channel = nil
        self.currentMailbox = nil
        self.supportsIdle = nil
    }
    /// A dedicated watcher owns this connection. nil means the server needs polling.
    /// DONE and the final tagged response are drained before returning to its caller.
    func waitForChanges(mailbox name: String, maximumWait: Duration = .seconds(25 * 60)) async throws -> Bool? {
        if supportsIdle == nil {
            let responses = try await send(.capability)
            supportsIdle = responses.contains { response in
                if case .untagged(.capabilityData(let capabilities)) = response { return capabilities.contains(.idle) }
                return false
            }
        }
        guard supportsIdle == true else { return nil }
        _ = try await select(name)
        guard let channel else { throw MailError.notConnected }
        let tag = nextTag(), admission = MailCommandDispatch()
        let components = maximumWait.components
        let milliseconds = min(Int64(25 * 60 * 1000), max(1, components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000))
        let responses = try await withTaskCancellationHandler {
            let resources = try await channel.eventLoop.submit { [collector] in
                try admission.dispatch { try self.lifetime.dispatch {
                    guard channel.isActive else { throw MailError.notConnected }
                    let promise = channel.eventLoop.makePromise(of: [Response].self)
                    collector.beginIdle(tag: tag, promise: promise)
                    channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: .idleStart))), promise: nil)
                    let startup = channel.eventLoop.scheduleTask(in: .seconds(15)) { collector.closeUnstartedIdle(channel: channel) }
                    let renewal = channel.eventLoop.scheduleTask(in: .milliseconds(milliseconds)) { collector.stopIdle(channel: channel) }
                    return (promise, startup, renewal)
                } }
            }.get()
            defer { resources.1.cancel(); resources.2.cancel() }
            return try await resources.0.futureResult.get()
        } onCancel: {
            admission.cancel()
            channel.eventLoop.execute { [collector] in collector.stopIdle(channel: channel) }
        }
        try Task.checkCancellation()
        guard let last = responses.last, case .tagged(let tagged) = last, case .ok = tagged.state else { throw MailFailure.serverRejected }
        return responses.contains { response in
            switch response { case .untagged(.mailboxData), .fetch: true; default: false }
        }
    }

    // MARK: Commands

    private func mailbox(_ name: String) -> MailboxName {
        name.uppercased() == "INBOX" ? .inbox : MailboxName(ByteBuffer(string: name))
    }

    func listMailboxes() async throws -> [IMAPMailbox] {
        let responses = try await send(.list(nil, reference: MailboxName(ByteBuffer(string: "")),
                                             .mailbox(ByteBuffer(string: "*")), []))
        var out: [IMAPMailbox] = []
        for r in responses {
            guard case .untagged(.mailboxData(.list(let info))) = r else { continue }
            let sep = info.path.pathSeparator.map(String.init) ?? "/"
            let displayName = info.path.displayStringComponents(omittingEmptySubsequences: false).joined(separator: sep)
            guard let name = String(bytes: info.path.name.bytes, encoding: .utf8) else { throw MailFailure.serverRejected }
            if name.isEmpty { continue }
            let attrs = info.attributes
            let selectable = !attrs.contains(MailboxInfo.Attribute("\\Noselect"))
            out.append(IMAPMailbox(name: name, displayName: displayName, kind: Self.classify(name: displayName, attributes: attrs), selectable: selectable))
        }
        return out
    }

    @discardableResult
    func select(_ name: String) async throws -> Int {
        let responses = try await send(.select(mailbox(name)))
        currentMailbox = name
        selectedUIDValidity = 0
        var total = 0
        for r in responses {
            if case .untagged(.mailboxData(.exists(let n))) = r { total = n }
            if case .untagged(.conditionalState(.ok(let text))) = r, case .uidValidity(let value) = text.code { selectedUIDValidity = UInt32(value) }
        }
        guard selectedUIDValidity > 0 else { currentMailbox = nil; throw MailFailure.staleFolder }
        return total
    }

    /// SELECT only if we're not already on `name`. Returns -1 when the SELECT
    /// was skipped (the caller didn't need an EXISTS count); otherwise returns
    /// the fresh count from the server.
    @discardableResult
    private func ensureSelected(_ name: String) async throws -> Int {
        if let curr = currentMailbox, curr == name || (curr.uppercased() == "INBOX" && name.uppercased() == "INBOX") {
            return -1
        }
        return try await select(name)
    }

    func fetchRecent(mailbox name: String, limit: Int) async throws -> [IMAPMessage] {
        let total = try await select(name)
        guard total > 0 else { return [] }
        let hi = UInt32(total)
        let lo = UInt32(max(1, total - limit + 1))
        let range = MessageIdentifierRange<SequenceNumber>(SequenceNumber(rawValue: lo)...SequenceNumber(rawValue: hi))
        let responses = try await send(.fetch(.range(range), [.uid, .flags, .envelope, .internalDate], []))
        return parseMessages(responses).sorted { $0.date > $1.date }
    }

    /// Incremental refresh: fetch only messages newer than `afterUID`, plus the
    /// current flags for the already-loaded range `[oldestUID...afterUID]` (so
    /// read/star/label changes from other clients show up). Reuses the existing
    /// SELECT when we're already on the mailbox.
    func syncFolder(mailbox name: String, afterUID: UInt32, oldestUID: UInt32, newLimit: Int) async throws -> IMAPFolderSync {
        _ = try await ensureSelected(name)

        var newMessages: [IMAPMessage] = []
        if afterUID < UInt32.max {
            let newRange = MessageIdentifierRange<UID>(UID(rawValue: afterUID + 1)...UID.max)
            let r = try await send(.uidFetch(.range(newRange), [.uid, .flags, .envelope, .internalDate], []))
            newMessages = parseMessages(r).sorted { $0.date > $1.date }
            if newMessages.count > newLimit { newMessages = Array(newMessages.prefix(newLimit)) }
        }

        var flags: [UInt32: IMAPFlagState] = [:]
        if oldestUID > 0 && oldestUID <= afterUID {
            let flagRange = MessageIdentifierRange<UID>(UID(rawValue: oldestUID)...UID(rawValue: afterUID))
            let r = try await send(.uidFetch(.range(flagRange), [.uid, .flags], []))
            flags = parseFlags(r)
        }
        return IMAPFolderSync(newMessages: newMessages, flags: flags)
    }

    /// Fetch envelopes for every UID delivered on or after `date`. Far cheaper
    /// than `fetchRecent` for a weekly window — the server filters by
    /// INTERNALDATE and we FETCH only the matching subset.
    func fetchSince(mailbox name: String, since date: Date, limit: Int) async throws -> [IMAPMessage] {
        guard let day = IMAPService.imapDay(date) else { return [] }
        return try await search(mailbox: name, key: .since(day), limit: limit)
    }

    /// Fetch envelopes for the page of messages immediately older than
    /// `beforeUID`. The list is returned newest-first (by date) and capped at
    /// `limit`. Used by "Load more" to extend the loaded window backwards.
    func fetchOlder(mailbox name: String, beforeUID: UInt32, limit: Int) async throws -> [IMAPMessage] {
        guard beforeUID > 1 else { return [] }
        let range = MessageIdentifierRange<UID>(UID(rawValue: 1)...UID(rawValue: beforeUID - 1))
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(range)) else { return [] }
        return try await search(mailbox: name, key: .uid(.set(set)), limit: limit)
    }

    func search(mailbox name: String, key: SearchKey, limit: Int) async throws -> [IMAPMessage] {
        _ = try await ensureSelected(name)
        let responses = try await send(.uidSearch(key: key))
        var uids: [UInt32] = []
        for r in responses {
            if case .untagged(.mailboxData(.search(let ids, _))) = r {
                uids.append(contentsOf: ids.map { $0.rawValue })
            }
        }
        guard !uids.isEmpty else { return [] }
        let chosen = Array(uids.sorted(by: >).prefix(limit))
        let ranges = chosen.map { MessageIdentifierRange<UID>(UID(rawValue: $0)...UID(rawValue: $0)) }
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges)) else { return [] }
        let responses2 = try await send(.uidFetch(.set(set), [.uid, .flags, .envelope, .internalDate], []))
        return parseMessages(responses2).sorted { $0.date > $1.date }
    }

    /// Drain new UIDs oldest-first, so a bounded page never skips arrivals.
    /// The cursor includes searched UIDs that disappeared before FETCH.
    func fetchNewAfter(mailbox name: String, afterUID: UInt32, limit: Int) async throws -> (messages: [IMAPMessage], through: UInt32, hasMore: Bool) {
        _ = try await ensureSelected(name)
        guard afterUID < UInt32.max else { return ([], afterUID, false) }
        let range = MessageIdentifierRange<UID>(UID(rawValue: afterUID + 1)...UID.max)
        guard let query = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(range)) else { return ([], afterUID, false) }
        let responses = try await send(.uidSearch(key: .uid(.set(query))))
        var uids = Set<UInt32>()
        for response in responses {
            if case .untagged(.mailboxData(.search(let ids, _))) = response {
                uids.formUnion(ids.map(\.rawValue).filter { $0 > afterUID })
            }
        }
        let chosen = Array(uids.sorted().prefix(limit))
        guard let highest = chosen.last else { return ([], afterUID, false) }
        let ranges = chosen.map { MessageIdentifierRange<UID>(UID(rawValue: $0)...UID(rawValue: $0)) }
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges)) else { return ([], afterUID, false) }
        let fetched = try await send(.uidFetch(.set(set), [.uid, .flags, .envelope, .internalDate], []))
        let allowed = Set(chosen)
        return (parseMessages(fetched).filter { allowed.contains($0.uid) }, highest, uids.count > chosen.count)
    }

    func searchText(mailbox name: String, query: String, limit: Int) async throws -> [IMAPMessage] {
        try await search(mailbox: name, key: .text(ByteBuffer(string: query)), limit: limit)
    }

    func searchFlagged(mailbox name: String, limit: Int) async throws -> [IMAPMessage] {
        try await search(mailbox: name, key: .flagged, limit: limit)
    }

    func searchAdvanced(mailbox name: String, criteria c: MailSearchCriteria, limit: Int) async throws -> [IMAPMessage] {
        var keys: [SearchKey] = []
        if !c.text.isEmpty { keys.append(.text(ByteBuffer(string: c.text))) }
        if !c.from.isEmpty { keys.append(.from(ByteBuffer(string: c.from))) }
        if !c.to.isEmpty { keys.append(.to(ByteBuffer(string: c.to))) }
        if !c.subject.isEmpty { keys.append(.subject(ByteBuffer(string: c.subject))) }
        if let since = c.since, let day = IMAPService.imapDay(since) { keys.append(.since(day)) }
        if let before = c.before, let day = IMAPService.imapDay(before) { keys.append(.before(day)) }
        if c.unseenOnly { keys.append(.unseen) }
        if c.flaggedOnly { keys.append(.flagged) }
        let key: SearchKey = keys.isEmpty ? .all : (keys.count == 1 ? keys[0] : .and(keys))
        return try await search(mailbox: name, key: key, limit: limit)
    }

    private static func imapDay(_ date: Date) -> IMAPCalendarDay? {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        return IMAPCalendarDay(year: y, month: m, day: d)
    }

    /// Fetch the raw RFC822 message bytes. `byteLimit` caps the download (the
    /// text parts come first in MIME order); pass nil for the complete message.
    func fetchMessageData(mailbox name: String, uid: UInt32, byteLimit: Int?) async throws -> Data {
        _ = try await ensureSelected(name)
        let range = MessageIdentifierRange<UID>(UID(rawValue: uid)...UID(rawValue: uid))
        let section: FetchAttribute = byteLimit.map { .bodySection(peek: true, .complete, 0...UInt32($0 - 1)) }
            ?? .bodySection(peek: true, .complete, nil)
        let responses = try await send(.uidFetch(.range(range), [section], []))
        var raw = ByteBuffer()
        for r in responses {
            if case .fetch(.streamingBytes(var chunk)) = r { raw.writeBuffer(&chunk) }
        }
        return Data(raw.readableBytesView)
    }

    /// Batched body fetch — pulls bytes for many UIDs in a single FETCH command
    /// instead of one round-trip per message. Returns `[uid: data]`; uids that
    /// the server didn't return are absent from the map.
    func fetchMessageDatas(mailbox name: String, uids: [UInt32], byteLimit: Int?) async throws -> [UInt32: Data] {
        guard !uids.isEmpty else { return [:] }
        _ = try await ensureSelected(name)
        let ranges = uids.map { MessageIdentifierRange<UID>(UID(rawValue: $0)...UID(rawValue: $0)) }
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges)) else { return [:] }
        let section: FetchAttribute = byteLimit.map { .bodySection(peek: true, .complete, 0...UInt32($0 - 1)) }
            ?? .bodySection(peek: true, .complete, nil)
        let responses = try await send(.uidFetch(.set(set), [.uid, section], []))
        var out: [UInt32: Data] = [:]
        var currentUID: UInt32 = 0
        var buf = ByteBuffer()
        for r in responses {
            guard case .fetch(let fr) = r else { continue }
            switch fr {
            case .start, .startUID:
                currentUID = 0
                buf.clear()
            case .simpleAttribute(let attr):
                if case .uid(let u) = attr { currentUID = u.rawValue }
            case .streamingBytes(var chunk):
                buf.writeBuffer(&chunk)
            case .finish:
                if currentUID > 0, buf.readableBytes > 0 {
                    out[currentUID] = Data(buf.readableBytesView)
                }
                currentUID = 0
                buf.clear()
            default:
                break
            }
        }
        return out
    }

    func existingUIDs(mailbox name: String, uids: [UInt32]) async throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        _ = try await ensureSelected(name)
        let ranges = uids.map { MessageIdentifierRange<UID>(UID(rawValue: $0)...UID(rawValue: $0)) }
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges)) else { throw MailError.noResult }
        return Set(parseFlags(try await send(.uidFetch(.set(set), [.uid, .flags], []))).keys)
    }
    func store(mailbox name: String, uid: UInt32, _ kind: MailFlagKind, add: Bool) async throws {
        _ = try await ensureSelected(name)
        let flag: Flag = kind == .seen ? .seen : (kind == .flagged ? .flagged : .deleted)
        let range = MessageIdentifierRange<UID>(UID(rawValue: uid)...UID(rawValue: uid))
        let storeFlags: StoreFlags = add ? .add(silent: true, list: [flag]) : .remove(silent: true, list: [flag])
        _ = try await send(.uidStore(.range(range), [], .flags(storeFlags)))
    }

    func move(uid: UInt32, from: String, to: String) async throws {
        _ = try await ensureSelected(from)
        let range = MessageIdentifierRange<UID>(UID(rawValue: uid)...UID(rawValue: uid))
        _ = try await send(.uidMove(.range(range), mailbox(to)))
    }

    /// Add or remove a custom keyword (label) on a message.
    func storeKeyword(mailbox name: String, uid: UInt32, keyword: String, add: Bool) async throws {
        _ = try await ensureSelected(name)
        let range = MessageIdentifierRange<UID>(UID(rawValue: uid)...UID(rawValue: uid))
        let flag = Flag(keyword)
        let store: StoreFlags = add ? .add(silent: true, list: [flag]) : .remove(silent: true, list: [flag])
        _ = try await send(.uidStore(.range(range), [], .flags(store)))
    }

    /// APPEND a raw RFC822 message into a mailbox (used to save Sent/Drafts copies).
    func append(mailbox name: String, rawMessage: String, seen: Bool, draft: Bool) async throws {
        try Task.checkCancellation()
        guard let channel = self.channel, channel.isActive else { throw MailError.notConnected }
        var flags: [Flag] = []
        if seen { flags.append(.seen) }
        if draft { flags.append(.draft) }
        let bytes = ByteBuffer(string: rawMessage)
        let tag = nextTag()
        try Task.checkCancellation()
        let appendFlags = flags
        let promise = try await channel.eventLoop.submit { [collector] in
            try self.lifetime.dispatch {
                guard channel.isActive else { throw MailError.notConnected }
                let promise = channel.eventLoop.makePromise(of: [Response].self)
                collector.enqueue(tag: tag, promise: promise)
                let message = AppendMessage(options: AppendOptions(flagList: appendFlags), data: AppendData(byteCount: bytes.readableBytes))
                let parts: [AppendCommand] = [
                    .start(tag: tag, appendingTo: self.mailbox(name)), .beginMessage(message: message), .messageBytes(bytes), .endMessage, .finish
                ]
                for part in parts { channel.write(IMAPClientHandler.Message.part(.append(part)), promise: nil) }
                channel.flush()
                return promise
            }
        }.get()

        let deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise:nil) }
        defer { deadline.cancel() }
        let responses = try await promise.futureResult.get()
        if let last = responses.last, case .tagged(let t) = last, case .ok = t.state { return }
        throw MailError.commandFailed("APPEND rejected")
    }

    static func classify(name: String, attributes: [MailboxInfo.Attribute]) -> MailboxKind {
        if name.uppercased() == "INBOX" { return .inbox }
        if attributes.contains(MailboxInfo.Attribute("\\Sent")) { return .sent }
        if attributes.contains(MailboxInfo.Attribute("\\Drafts")) { return .drafts }
        if attributes.contains(MailboxInfo.Attribute("\\Trash")) { return .trash }
        if attributes.contains(MailboxInfo.Attribute("\\Junk")) { return .junk }
        if attributes.contains(MailboxInfo.Attribute("\\Archive")) { return .archive }
        switch name.lowercased() {
        case "sent", "sent items", "sent mail", "sent messages": return .sent
        case "drafts", "draft": return .drafts
        case "trash", "deleted", "deleted items", "deleted messages", "bin": return .trash
        case "junk", "spam", "junk e-mail", "junk email": return .junk
        case "archive", "archives", "all mail": return .archive
        default: return .other
        }
    }

    // MARK: Plumbing

    private func send(_ command: NIOIMAPCore.Command) async throws -> [Response] {
        try Task.checkCancellation()
        guard let channel = self.channel else { throw MailError.notConnected }
        let tag = nextTag()
        let admission = MailCommandDispatch()
        let responses = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let promise = try await channel.eventLoop.submit { [collector] in
                try admission.dispatch { try self.lifetime.dispatch {
                    guard channel.isActive else { throw MailError.notConnected }
                    let promise = channel.eventLoop.makePromise(of: [Response].self)
                    collector.enqueue(tag: tag, promise: promise)
                    let message = IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: command)))
                    channel.writeAndFlush(message, promise: nil)
                    return promise
                } }
            }.get()
            let deadline = channel.eventLoop.scheduleTask(in: .seconds(30)) { channel.close(promise:nil) }
            defer { deadline.cancel() }
            // After dispatch, keep the actual outcome; cancellation cannot authorize replay.
            return try await promise.futureResult.get()
        } onCancel: { admission.cancel() }
        if let last = responses.last, case .tagged(let tagged) = last {
            if case .ok = tagged.state { return responses }
            throw MailError.commandFailed("\(tagged.state)")
        }
        throw MailError.noResult
    }

    private func parseMessages(_ responses: [Response]) -> [IMAPMessage] {
        var out: [IMAPMessage] = []
        var uid: UInt32 = 0
        var subject = ""
        var fromName = ""
        var fromEmail = ""
        var toName = ""
        var toEmail = ""
        var ccEmail = "", bccEmail = ""
        var date = Date()
        var seen = false
        var flagged = false
        var messageID = ""
        var inReplyTo = ""
        var keywords: [String] = []

        func reset() {
            uid = 0; subject = ""; fromName = ""; fromEmail = ""; toName = ""; toEmail = ""; date = Date()
            seen = false; flagged = false; messageID = ""; inReplyTo = ""; keywords = []; ccEmail = ""; bccEmail = ""
        }

        for r in responses {
            guard case .fetch(let fr) = r else { continue }
            switch fr {
            case .start, .startUID:
                reset()
            case .simpleAttribute(let attr):
                switch attr {
                case .uid(let u):
                    uid = u.rawValue
                case .flags(let flags):
                    seen = flags.contains(.seen)
                    flagged = flags.contains(.flagged)
                    keywords = flags.map { String($0) }.filter { !$0.hasPrefix("\\") }
                case .envelope(let env):
                    if let s = env.subject { subject = MIME.decodeHeader(String(buffer: s)) }
                    if let first = env.from.first, case .singleAddress(let addr) = first {
                        if let pn = addr.personName { fromName = MIME.decodeHeader(String(buffer: pn)) }
                        let mailbox = addr.mailbox.map { String(buffer: $0) } ?? ""
                        let hostPart = addr.host.map { String(buffer: $0) } ?? ""
                        if !mailbox.isEmpty { fromEmail = hostPart.isEmpty ? mailbox : "\(mailbox)@\(hostPart)" }
                    }
                    toEmail = Self.addresses(env.to).joined(separator: ", ")
                    ccEmail = Self.addresses(env.cc).joined(separator: ", ")
                    bccEmail = Self.addresses(env.bcc).joined(separator: ", ")
                    if let d = env.date, let parsed = Self.parseRFC2822(String(d)) { date = parsed }
                    if let mid = env.messageID { messageID = String(mid) }
                    if let irt = env.inReplyTo { inReplyTo = String(irt) }
                case .internalDate(let serverDate):
                    if let built = Self.dateFrom(serverDate.components) { date = built }
                default:
                    break
                }
            case .finish:
                if uid > 0 {
                    out.append(IMAPMessage(uid: uid, subject: subject, fromName: fromName,
                                           fromEmail: fromEmail, toName: toName, toEmail: toEmail, ccEmail: ccEmail, bccEmail: bccEmail,
                                           date: date, seen: seen, flagged: flagged,
                                           messageID: messageID, inReplyTo: inReplyTo, keywords: keywords))
                }
            default:
                break
            }
        }
        return out
    }

    private static func addresses(_ values: [EmailAddressListElement], depth: Int = 0) -> [String] {
        guard depth < 32 else { return [] }
        return values.flatMap { value in
            switch value {
            case .singleAddress(let address):
                guard let mailbox = address.mailbox, let host = address.host else { return [String]() }
                return [String(buffer: mailbox) + "@" + String(buffer: host)]
            case .group(let group): return addresses(group.children, depth: depth + 1)
            }
        }
    }
    private func parseFlags(_ responses: [Response]) -> [UInt32: IMAPFlagState] {
        var map: [UInt32: IMAPFlagState] = [:]
        var uid: UInt32 = 0, seen = false, flagged = false
        var keywords: [String] = []
        func reset() { uid = 0; seen = false; flagged = false; keywords = [] }
        for r in responses {
            guard case .fetch(let fr) = r else { continue }
            switch fr {
            case .start, .startUID:
                reset()
            case .simpleAttribute(let attr):
                switch attr {
                case .uid(let u): uid = u.rawValue
                case .flags(let flags):
                    seen = flags.contains(.seen)
                    flagged = flags.contains(.flagged)
                    keywords = flags.map { String($0) }.filter { !$0.hasPrefix("\\") }
                default: break
                }
            case .finish:
                if uid > 0 { map[uid] = IMAPFlagState(seen: seen, flagged: flagged, keywords: keywords) }
            default:
                break
            }
        }
        return map
    }

    private static func parseRFC2822(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                    "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    private static func dateFrom(_ c: ServerMessageDate.Components) -> Date? {
        var comps = DateComponents()
        comps.year = c.year; comps.month = c.month; comps.day = c.day
        comps.hour = c.hour; comps.minute = c.minute; comps.second = c.second
        comps.timeZone = TimeZone(secondsFromGMT: c.zoneMinutes * 60)
        return Calendar(identifier: .gregorian).date(from: comps)
    }
}
