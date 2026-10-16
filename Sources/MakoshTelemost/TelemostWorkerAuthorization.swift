import Foundation

extension TelemostWorker {
    public func authorize(accountID: UUID, mode: TelemostAuthorizationMode) async throws -> TelemostAuthorizationRequest {
        try admitWork(); defer { finishWork() }
        let generation = generation(accountID), account = try await repository.account(id: accountID)
        let lease = try await repository.acquireLease(accountID: accountID, operationID: UUID(), kind: .auth)
        do {
            try requireCurrent(accountID, generation)
            let request = try await oauth.begin(account: account, mode: mode)
            do { try requireCurrent(accountID, generation) }
            catch { await oauth.cancel(id: request.id); throw error }
            authTickets[request.id] = AuthTicket(lease: lease, generation: generation, request: request)
            connections[accountID] = .authorizing
            return request
        } catch { try? await repository.releaseLease(lease); throw error }
    }
    public func completeAuthorization(id: UUID, callback: URL) async throws -> TelemostGrantResult {
        try admitWork(); defer { finishWork() }
        guard let ticket = authTickets[id] else { throw TelemostFailure.conflict }
        do {
            try requireCurrent(ticket.request.accountID, ticket.generation)
            let grant = try await oauth.complete(id: id, callback: callback)
            try requireCurrent(ticket.request.accountID, ticket.generation)
            connections[ticket.request.accountID] = .confirmation; return grant
        } catch {
            publishFailure(error, accountID: ticket.request.accountID, generation: ticket.generation)
            await cancelAuthorization(id: id); throw error
        }
    }
    public func completeAuthorization(id: UUID, code: String) async throws -> TelemostGrantResult {
        try admitWork(); defer { finishWork() }
        guard let ticket = authTickets[id] else { throw TelemostFailure.conflict }
        do {
            try requireCurrent(ticket.request.accountID, ticket.generation)
            let grant = try await oauth.complete(id: id, code: code)
            try requireCurrent(ticket.request.accountID, ticket.generation)
            connections[ticket.request.accountID] = .confirmation; return grant
        } catch {
            publishFailure(error, accountID: ticket.request.accountID, generation: ticket.generation)
            await cancelAuthorization(id: id); throw error
        }
    }
    public func confirmGrant(_ grant: TelemostGrantResult, accountID: UUID) async throws {
        try admitWork(); defer { finishWork() }
        guard let ticket = authTickets[grant.id], ticket.request.accountID == accountID else { throw TelemostFailure.conflict }
        guard authInstallations.insert(grant.id).inserted else { throw TelemostFailure.busy }
        defer { authInstallations.remove(grant.id) }
        do {
            try requireCurrent(accountID, ticket.generation)
            let verified = try await oauth.consumeGrant(id: grant.id, accountID: accountID)
            guard verified == grant, verified.token.expiresAt > now() else { throw TelemostFailure.conflict }
            var account = try await repository.account(id: accountID)
            try requireCurrent(accountID, ticket.generation)
            guard account.clientID.utf8.elementsEqual(verified.principal.clientID.utf8),
                  account.principal.map({ $0.sameSource(as: verified.principal) }) ?? true else { throw TelemostFailure.conflict }
            account.principal = verified.principal
            // Source binding commits first. Keychain failure cannot rebind an old session to a new principal.
            try await repository.saveAccount(account)
            try requireCurrent(accountID, ticket.generation)
            try await vault.save(verified.token, accountID: accountID)
            try requireCurrent(accountID, ticket.generation)
            try await repository.confirmCredential(accountID: accountID, epoch: grant.id, lease: ticket.lease)
            try requireCurrent(accountID, ticket.generation)
            tokens[accountID] = verified.token; credentialEpochs[accountID] = grant.id; generations[accountID, default: 0] += 1
            connections[accountID] = .authorized
            authTickets[grant.id] = nil; try await repository.releaseLease(ticket.lease)
        } catch {
            publishFailure(error, accountID: accountID, generation: ticket.generation)
            authTickets[grant.id] = nil; await oauth.cancel(id: grant.id)
            try? await repository.releaseLease(ticket.lease); throw error
        }
    }
    public func cancelAuthorization(id: UUID) async {
        await oauth.cancel(id: id)
        if authInstallations.contains(id), let ticket = authTickets[id] {
            generations[ticket.request.accountID, default: 0] += 1
            connections[ticket.request.accountID] = tokens[ticket.request.accountID] == nil ? .disconnected : .authorized
            // The confirming task owns release until the checked vault write has drained.
            return
        }
        if let ticket = authTickets.removeValue(forKey: id) {
            do { try await repository.releaseLease(ticket.lease) }
            catch { publishFailure(error, accountID: ticket.request.accountID, generation: ticket.generation) }
            if !closing, generation(ticket.request.accountID) == ticket.generation,
               connections[ticket.request.accountID] == .authorizing || connections[ticket.request.accountID] == .confirmation {
                connections[ticket.request.accountID] = tokens[ticket.request.accountID] == nil ? .disconnected : .authorized
            }
        }
    }
    public func connect(accountID: UUID) async throws {
        try admitWork(); defer { finishWork() }
        let generation = generation(accountID), account = try await repository.account(id: accountID)
        let lease = try await repository.acquireLease(accountID: accountID, operationID: UUID(), kind: .auth)
        do {
            let gate = try await repository.credentialGate(accountID: accountID)
            guard !gate.requiresLogin else { throw TelemostFailure.expired }
            guard let token = try await vault.load(accountID: accountID) else { throw TelemostFailure.unauthorized }
            try requireCurrent(accountID, generation); try token.validate()
            guard account.principal?.sameSource(as: token.principal) == true else { throw TelemostFailure.conflict }
            guard token.expiresAt > now() else { throw TelemostFailure.expired }
            tokens[accountID] = token; credentialEpochs[accountID] = gate.epoch; connections[accountID] = .authorized
            try await repository.releaseLease(lease)
        } catch {
            publishFailure(error, accountID: accountID, generation: generation)
            try? await repository.releaseLease(lease); throw error
        }
    }
    public func disconnect(accountID: UUID) async {
        generations[accountID, default: 0] += 1; tokens[accountID] = nil; connections[accountID] = .disconnected
        let ids = authTickets.filter { $0.value.request.accountID == accountID }.map(\.key)
        for id in ids { await cancelAuthorization(id: id) }
        await oauth.cancel(accountID: accountID)
    }
}
