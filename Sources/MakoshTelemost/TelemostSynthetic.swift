#if DEBUG
import Foundation
import MakoshCore

/// No URLSession, OS credentials or external browser exists behind this fixture.
private actor TelemostSyntheticHTTP: TelemostHTTPTransport {
    var counter = 0
    var waiting: [String: String] = [:]
    func response(to request: URLRequest) async throws -> TelemostHTTPResponse {
        guard request.url?.host == "cloud-api.yandex.net", request.url?.path.hasPrefix("/v1/telemost-api/conferences") == true else { throw TelemostFailure.forbidden }
        if request.url?.lastPathComponent == "cohosts" { return try result(["cohosts": [["email": "guest2@example.test"]]]) }
        let id: String
        if request.httpMethod == "POST" { counter += 1; id = "qa-created-" + UUID().uuidString }
        else { id = request.url!.lastPathComponent }
        if let data = request.httpBody, let body = try JSONSerialization.jsonObject(with: data) as? [String: String], let value = body["waiting_room_level"] { waiting[id] = value }
        return try result(["id": id, "join_url": "https://telemost.yandex.ru/j/" + id, "waiting_room_level": waiting[id] ?? "ADMINS"], status: request.httpMethod == "POST" ? 201 : 200)
    }
    private func result(_ value: [String: Any], status: Int = 200) throws -> TelemostHTTPResponse {
        .init(status: status, headers: [:], body: try JSONSerialization.data(withJSONObject: value))
    }
}
private actor TelemostSyntheticVault: TelemostTokenStoring {
    var values: [UUID: TelemostToken]
    init(_ accounts: [TelemostAccount]) {
        values = Dictionary(uniqueKeysWithValues: accounts.compactMap { account in account.principal.map { principal in
            (account.id, TelemostToken(accessToken: "synthetic-public-fixture", refreshToken: nil, expiresAt: Date().addingTimeInterval(86400), capabilities: account.capabilities, principal: principal))
        } })
    }
    func load(accountID: UUID) -> TelemostToken? { values[accountID] }
    func save(_ value: TelemostToken, accountID: UUID) { values[accountID] = value }
    func remove(accountID: UUID) { values[accountID] = nil }
}
extension TelemostWorker {
    public static func synthetic(configuration: ContactWorkspaceConfiguration, arguments: [String], contacts: ContactWorkspaceWorker) async throws -> TelemostWorker {
        try TelemostQAIsolation.validate(configuration: configuration, arguments: arguments)
        let repository = TelemostRepository(keyProvider: { _, _ in Data(repeating: 0x74, count: 32) })
        try await repository.open(configuration: configuration)
        var accounts = try await repository.accounts()
        if accounts.isEmpty {
            for index in 1...2 {
                let client = String(repeating: index == 1 ? "a" : "b", count: 32)
                let account = TelemostAccount(id: UUID(uuidString: "10000000-0000-4000-8000-00000000000\(index)")!, name: index == 1 ? "Проектная команда · QA" : "Второй аккаунт · QA", clientID: client,
                    callbackURL: URL(string: "org.makosh.desktop.telemost://oauth/callback")!, principal: .init(userID: "qa-user-\(index)", clientID: client, login: "qa\(index)@example.test"), capabilities: [.read, .create, .update])
                try await repository.saveAccount(account); accounts.append(account)
                let count = index == 1 ? 65 : 3
                for number in 1...count {
                    let url = try TelemostMeetingURL("https://telemost.yandex.ru/j/qa-\(index)-\(number)")
                    let id = try await repository.addLink(url, accountID: account.id)
                    var meeting = try await repository.meeting(id: id)
                    meeting.localTitle = "Планирование проекта · \(number)"; meeting.notes = "Синтетическая встреча. Постоянная история и поиск; Яндекс не подключён."
                    meeting.starred = number == count; try await repository.saveLocal(meeting)
                    let body = try JSONSerialization.data(withJSONObject: ["id": url.conferenceID, "join_url": url.url.absoluteString, "waiting_room_level": number == 1 ? "FUTURE_VALUE" : "ADMINS"])
                    let scope = TelemostScope(accountID: account.id, conferenceID: url.conferenceID)
                    try await repository.retain(.init(scope: scope, joinURL: url, waitingRoomRaw: number == 1 ? "FUTURE_VALUE" : "ADMINS", retainedJSON: body))
                    if number == count { try await repository.retainCohostPage(.init(scope: scope, offset: 0, limit: 50, emails: ["guest1@example.test"], complete: false), staged: []) }
                }
            }
            _ = try await repository.addLink(.init("https://telemost.yandex.ru/j/qa-local"), accountID: nil)
            if let account = accounts.first {
                let outcomes: [TelemostOperationOutcome] = [.rejected(403), .unknown]
                for outcome in outcomes {
                    let operation = TelemostOperation(accountID: account.id, payload: .create(.init(waitingRoom: .admins)))
                    let lease = try await repository.acquireLease(accountID: account.id, operationID: operation.id, kind: .dispatch)
                    do {
                        try await repository.prepare(operation)
                        _ = try await repository.begin(operationID: operation.id, attemptID: operation.attemptID)
                        try await repository.settle(operationID: operation.id, attemptID: operation.attemptID, outcome: outcome)
                        try await repository.releaseLease(lease)
                    } catch { try? await repository.releaseLease(lease); throw error }
                }
            }
        }
        let http = TelemostSyntheticHTTP()
        let worker = TelemostWorker(repository: repository, api: TelemostAPI(transport: http), oauth: TelemostOAuth(transport: http), vault: TelemostSyntheticVault(accounts), contacts: contacts)
        await worker.markSynthetic()
        for account in accounts { try await worker.connect(accountID: account.id) }
        return worker
    }
    private func markSynthetic() { syntheticEvidence = true }
}
#endif
