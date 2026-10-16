import Foundation

extension WhatsAppWorker {
  public func startGroupCall(accountID: UUID, groupJID: String, participants: [String], video: Bool)
    async throws -> WhatsAppOutgoing
  {
    try await startGroupCall(
      accountID: accountID, groupJID: groupJID, participants: participants, video: video,
      callContext: nil)
  }
  public func startGroupCall(
    accountID: UUID, groupJID: String, participants: [String], video: Bool, callContext: UUID?
  ) async throws -> WhatsAppOutgoing {
    try WhatsAppGroupCallTargets.validateGroup(groupJID)
    let targets = try WhatsAppGroupCallTargets.validate(participants)
    var action = WhatsAppAction(.callGroupStart, on: video)
    action.options = targets
    action.callContext = callContext
    return try await perform(accountID: accountID, chat: groupJID, action: action)
  }
  public func inviteCallParticipant(
    accountID: UUID, callID: String, epoch: UInt64, jid: String, ringOnly: Bool
  ) async throws -> WhatsAppOutgoing {
    guard !callID.isEmpty, callID.utf8.count <= 2048, epoch > 0,
      WhatsAppGroupCallTargets.isUser(jid), let session = sessions[accountID], !synthetic
    else { throw WhatsAppFailure.invalid }
    let generation = revisions[accountID]
    let callRevision = callRevisions[accountID] ?? 0
    let status = try await session.status()
    guard status.linked, revisions[accountID] == generation,
      (callRevisions[accountID] ?? 0) == callRevision,
      let call = status.call, !call.ended, call.id.utf8.elementsEqual(callID.utf8),
      call.epoch == epoch
    else { throw WhatsAppFailure.closed }
    if let group = call.group {
      try group.validate()
      let present = group.participants.contains { $0.jid.utf8.elementsEqual(jid.utf8) }
      guard ringOnly ? present : (!present && group.participants.count < 32) else {
        throw WhatsAppFailure.invalid
      }
    } else if ringOnly {
      throw WhatsAppFailure.invalid
    }
    var action = WhatsAppAction(ringOnly ? .callRing : .callInvite, target: callID, to: jid)
    action.callEpoch = epoch
    return try await perform(accountID: accountID, chat: call.peer, action: action)
  }
}

extension WhatsAppServing {
  public func cancelAcceptedCall(accountID: UUID, outgoingID: UUID) async throws {
    throw WhatsAppFailure.unavailable
  }
}
extension WhatsAppWorker {
  public func cancelAcceptedCall(accountID: UUID, outgoingID: UUID) async throws {
    guard !synthetic, let witness = acceptedCalls[accountID], witness.id == outgoingID,
      revisions[accountID] == witness.generation, let session = sessions[accountID], let repository
    else { throw WhatsAppFailure.closed }
    let receipt = try await repository.outgoing(id: outgoingID, accountID: accountID)
    guard receipt.accountID == accountID, receipt.state == .sent,
      let operation = receipt.content.action?.op,
      [.callStart, .callGroupStart, .callAccept].contains(operation), let id = receipt.stanza,
      !id.isEmpty, let epoch = receipt.callEpoch, epoch > 0
    else { throw WhatsAppFailure.invalid }
    let status = try await session.status()
    guard revisions[accountID] == witness.generation, acceptedCalls[accountID]?.id == outgoingID,
      let call = status.call, call.id.utf8.elementsEqual(id.utf8), call.epoch == epoch,
      call.peer.utf8.elementsEqual(receipt.chat.utf8), !call.ended
    else { throw WhatsAppFailure.closed }
    var end = WhatsAppAction(.callEnd, target: id)
    end.callEpoch = epoch
    _ = try await perform(accountID: accountID, chat: receipt.chat, action: end)
  }
}
