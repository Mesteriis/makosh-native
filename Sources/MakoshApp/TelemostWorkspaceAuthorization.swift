import Foundation
import MakoshTelemost

extension TelemostWorkspaceModel {
    func beginAuthorization(mode: TelemostAuthorizationMode) async {
        guard let account = selectedAccountID else { return }; let context = contextID
        await authorizationCommand {
            let request = try await service.authorize(accountID: account, mode: mode)
            guard context == contextID else { await service.cancelAuthorization(id: request.id); return }
            authorization = request
        }
    }
    func completeAuthorization(callback: URL? = nil, code: String? = nil) async {
        guard let request = authorization else { return }; let context = contextID
        await authorizationCommand {
            let result: TelemostGrantResult
            if let callback { result = try await service.completeAuthorization(id: request.id, callback: callback) }
            else if let code { result = try await service.completeAuthorization(id: request.id, code: code) }
            else { throw TelemostFailure.invalidConfiguration }
            guard context == contextID, authorization?.id == request.id else { await service.cancelAuthorization(id: request.id); return }
            grant = result
        }
    }
    func confirmAuthorization() async {
        guard let grant, grant.accountID == selectedAccountID else { return }; let context = contextID
        await authorizationCommand {
            try await service.confirmGrant(grant, accountID: grant.accountID)
            guard context == contextID else { return }; authorization = nil; self.grant = nil; await reload()
        }
    }
    func cancelAuthorization() async {
        let request = authorization; authorization = nil; grant = nil
        if let request { await service.cancelAuthorization(id: request.id) }
    }
    func connect() async {
        guard let id = selectedAccountID else { return }; let context = contextID
        await authorizationCommand { try await service.connect(accountID: id); guard context == contextID else { return }; await reload() }
    }
    func disconnect() async {
        guard let id = selectedAccountID else { return }
        invalidateAuthorizationContext(); await service.disconnect(accountID: id); await reload()
    }
}
