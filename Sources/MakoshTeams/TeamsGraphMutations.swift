import Foundation

extension TeamsGraphClient {
    public func postMessage(scope: TeamsScope, content: TeamsDraft, token: String) async throws -> TeamsMessage {
        guard content.fileIDs.isEmpty else { throw TeamsFailure.invalidResource }
        return try await postFileMessage(scope: scope, content: content, remotes: [], token: token)
    }
    func postFileMessage(scope: TeamsScope, content: TeamsDraft, remotes: [TeamsRemoteFile], token: String) async throws -> TeamsMessage {
        guard scope.accountID == context.accountID, Data(scope.tenantID.utf8) == Data(context.principal.tenantID.utf8),
              (!content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !remotes.isEmpty), content.text.utf8.count <= 1024 * 1024,
              content.fileIDs.count == remotes.count, remotes.count <= 10 else { throw TeamsFailure.invalidResource }
        let path = try TeamsGraphURL.path(TeamsCollection.Kind.messages(scope.resource).components)
        var components = URLComponents(); components.scheme = "https"; components.host = "graph.microsoft.com"; components.percentEncodedPath = path
        guard let url = components.url else { throw TeamsFailure.invalidResource }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["body": ["contentType": "text", "content": content.text]]
        if !remotes.isEmpty {
            let escaped = content.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            body["body"] = ["contentType": "html", "content": escaped + content.fileIDs.map { "<attachment id=\"" + $0.uuidString + "\"></attachment>" }.joined()]
            body["attachments"] = try zip(content.fileIDs, remotes).map { id, file -> [String: String] in
                guard let url = file.webURL, url.scheme == "https", url.user == nil, url.password == nil else { throw TeamsFailure.invalidResource }
                return ["id": id.uuidString, "contentType": "reference", "contentUrl": url.absoluteString, "name": file.name]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        let response = try await transport.response(to: request) // Mutations use no read-retry path.
        guard response.body.count <= 4 * 1024 * 1024 else { throw TeamsFailure.uncertainSubmission }
        guard response.status == 201 else { throw TeamsFailure.server(status: response.status) }
        guard let wire = try? JSONDecoder().decode(TeamsGraphMessage.self, from: response.body), !wire.id.isEmpty,
              wire.id.utf8.count <= 1024, wire.body?.content != nil else { throw TeamsFailure.uncertainSubmission }
        if case let .thread(_, _, rootID) = scope.resource, let reply = wire.replyToId, Data(reply.utf8) != Data(rootID.utf8) { throw TeamsFailure.uncertainSubmission }
        do { return try wire.message(scope: scope) } catch { throw TeamsFailure.uncertainSubmission }
    }
}
