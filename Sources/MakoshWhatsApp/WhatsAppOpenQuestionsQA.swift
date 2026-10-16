#if DEBUG
  import CoreGraphics
  import Foundation
  import ImageIO
  import MakoshCore
  import UniformTypeIdentifiers

  private struct QAAvatarHTTP: WhatsAppAvatarFetching {
    let bytes: Data
    func fetch(_ url: URL, maximumBytes: Int, timeout: TimeInterval) async throws -> Data {
      try await Task.sleep(for: .milliseconds(25))
      return bytes
    }
  }
  extension WhatsAppWorker {
    public static func openQuestionsQA(
      configuration: ContactWorkspaceConfiguration, arguments: [String]
    ) async throws -> WhatsAppWorker {
      try WhatsAppQAIsolation.validate(configuration: configuration, arguments: arguments)
      let service = WhatsAppWorker(synthetic: true)
      try await service.configureOpenQuestionsQA(configuration: configuration, arguments: arguments)
      return service
    }
    private func configureOpenQuestionsQA(
      configuration: ContactWorkspaceConfiguration, arguments: [String]
    ) async throws {
      let root = try WhatsAppQAIsolation.root(arguments: arguments)
      let keys: @Sendable (UUID, Bool) throws -> Data = { _, _ in Data(repeating: 0x79, count: 32) }
      let repository = WhatsAppRepository(configuration: configuration, keyProvider: keys)
      self.repository = repository
      let storage = root.appendingPathComponent("storage.json")
      files = WhatsAppFiles(
        configuration: configuration, storageFile: storage,
        spool: root.appendingPathComponent("spool"), repository: repository, keyProvider: keys)
      let picture = try Self.qaPicture()
      let fixtures = root.appendingPathComponent("fixtures")
      try FileManager.default.createDirectory(
        at: fixtures, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      for n in 0..<10 {
        let path = fixtures.appendingPathComponent(n == 0 ? "photo.png" : "file-\(n).txt")
        if !FileManager.default.fileExists(atPath: path.path) {
          try (n == 0 ? picture : Data("Synthetic attachment \(n). No provider data.".utf8)).write(
            to: path, options: .atomic)
          try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
      }
      avatars = WhatsAppAvatars(
        root: root.appendingPathComponent("avatars"), http: QAAvatarHTTP(bytes: picture),
        keyProvider: { account in try await repository.avatarCacheKey(accountID: account) },
        descriptor: { scope in
          .init(
            pictureID: "qa-" + scope.accountID.uuidString + scope.jid,
            url: URL(string: "https://pps.whatsapp.net/synthetic-avatar")!)
        })
      qaRoot = root
      let accounts = try await load(configuration: configuration)
      guard let first = accounts.first else { throw WhatsAppFailure.storage }
      try await seedOpenQuestions(repository: repository, account: first.id)
    }
    private static func qaPicture() throws -> Data {
      guard
        let ctx = CGContext(
          data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 3840,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { throw WhatsAppFailure.invalid }
      for n in 0..<8 {
        ctx.setFillColor(
          CGColor(red: CGFloat(n) / 8, green: 0.55, blue: 1 - CGFloat(n) / 8, alpha: 1))
        ctx.fill(CGRect(x: n * 120, y: 0, width: 120, height: 640))
      }
      guard let image = ctx.makeImage() else { throw WhatsAppFailure.invalid }
      let bytes = NSMutableData()
      guard
        let dest = CGImageDestinationCreateWithData(
          bytes, UTType.png.identifier as CFString, 1, nil)
      else { throw WhatsAppFailure.invalid }
      CGImageDestinationAddImage(dest, image, nil)
      guard CGImageDestinationFinalize(dest) else { throw WhatsAppFailure.invalid }
      return bytes as Data
    }
    private func seedOpenQuestions(repository: WhatsAppRepository, account: UUID) async throws {
      var extra: [WhatsAppJournalEntry] = []
      let rich: [(String, String, String, WhatsAppMessageDetails)] = [
        {
          var d = WhatsAppMessageDetails()
          d.contactName = "Анна Тестовая"
          d.contactVcard =
            "BEGIN:VCARD\nVERSION:3.0\nFN:Анна Тестовая\nTEL;TYPE=CELL:+10000000001\nEMAIL:anna@example.test\nORG:Синтетическая команда\nURL:https://example.test\nEND:VCARD"
          return ("qa-contact", "contact", "Анна Тестовая", d)
        }(),
        {
          var d = WhatsAppMessageDetails()
          d.contactVcard = "BEGIN:VCARD\nTEL;ENCODING=broken:invalid\n"
          return ("qa-malformed", "contact", "Некорректная карточка", d)
        }(),
        {
          var d = WhatsAppMessageDetails()
          d.pollName = "Когда встречаемся?"
          d.pollOptions = ["Сегодня", "Сегодня", "Завтра"]
          return ("qa-poll", "poll", "Когда встречаемся?", d)
        }(),
        (
          "qa-location", "text",
          "Синтетическая проверка: сеть, доставка и устройства не используются.", .init()
        ),
      ]
      for (n, r) in rich.enumerated() {
        var message = WhatsAppMessage(
          chat: "test-alex@lid", id: r.0, stanza: r.0, sender: "test-alex@lid",
          timestamp: 1_792_100_000 + Int64(n), outgoing: false, text: r.2, kind: r.1, edited: false,
          deleted: false)
        message.details = r.3
        extra.append(
          .init(sequence: 66 + Int64(n), message: message, history: true, observed: 1_792_100_000))
      }
      let status = WhatsAppMessage(
        chat: "status@broadcast", id: "qa-status", stanza: "qa-status", sender: "test-alex@lid",
        timestamp: 1_792_100_005, outgoing: false, text: "Сохранённый синтетический статус",
        kind: "text", edited: false, deleted: false)
      extra.append(.init(sequence: 70, message: status, history: true, observed: 1_792_100_000))
      try await repository.ingest(extra, accountID: account)
      if let files, let root = qaRoot, try await repository.outgoing(accountID: account).isEmpty {
        var prepared: [UUID] = []
        for n in 1...3 {
          let p = try await files.prepare(
            file: root.appendingPathComponent("fixtures/file-\(n).txt"), accountID: account,
            chat: "test-team@g.us", kind: "document", mime: "text/plain")
          prepared.append(p.id)
        }
        let batch = try await repository.prepareOutgoingBatch(
          accountID: account, chat: "test-team@g.us",
          content: .init(
            text: "Подставной частичный результат · не доставка WhatsApp", files: prepared))
        let lease = try await repository.claimBatch(id: batch.batch.id, accountID: account)
        do {
          for (index, child) in batch.children.prefix(2).enumerated() {
            let claimed = try await repository.claimOutgoing(
              id: child.id, accountID: account, batchLease: lease)
            guard let attempt = claimed.attemptID else { throw WhatsAppFailure.invalid }
            try await repository.settleOutgoing(
              id: child.id, accountID: account, attemptID: attempt,
              outcome: index == 0 ? .sent : .unknown, stanza: index == 0 ? "synthetic-receipt" : nil
            )
          }
          try await repository.releaseBatch(lease)
        } catch {
          try? await repository.releaseBatch(lease)
          throw error
        }
      }
    }
    func qaInfo(accountID: UUID, chat: String, operation: WhatsAppAction.Operation) async throws
      -> WhatsAppPeerInfo?
    {
      guard qaRoot != nil, synthetic, let repository,
        try await repository.accounts().contains(where: { $0.id == accountID })
      else { return nil }
      var info = WhatsAppPeerInfo()
      info.jid = chat
      if operation == .groupInfo, chat == "test-team@g.us" {
        info.name = "Команда Макоша · синтетический состав"
        info.members = (0..<32).map { .init(jid: "qa\($0)@lid", admin: $0 == 0, me: $0 == 0) }
        return info
      }
      return nil
    }
  }
#endif
