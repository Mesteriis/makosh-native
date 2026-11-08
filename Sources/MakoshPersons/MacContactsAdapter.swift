import Contacts
import Foundation
import MakoshCore

/// `CNContact` ↔ cards. The display name is composed here, not by the system formatter, so it
/// does not depend on the user's locale.
public enum MacContactsMapping {
    public static var keys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey, CNContactTypeKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactMiddleNameKey,
            CNContactOrganizationNameKey, CNContactJobTitleKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
        ] as [CNKeyDescriptor]
    }

    public static func card(_ contact: CNContact) -> (ImportedPerson, PersonKind) {
        let kind: PersonKind = contact.contactType == .organization ? .organization : .person
        let personal = [contact.givenName, contact.middleName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let display = kind == .organization ? contact.organizationName : (personal.isEmpty ? contact.organizationName : personal)
        let imported = ImportedPerson(
            externalID: contact.identifier, displayName: display.isEmpty ? "Без имени" : display,
            kind: kind == .organization ? .organization : nil,
            givenName: contact.givenName.isEmpty ? nil : contact.givenName,
            familyName: contact.familyName.isEmpty ? nil : contact.familyName,
            middleName: contact.middleName.isEmpty ? nil : contact.middleName,
            organization: kind == .person && !contact.organizationName.isEmpty ? contact.organizationName : nil,
            jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle, phones: contact.phoneNumbers.map { $0.value.stringValue },
            emails: contact.emailAddresses.map { $0.value as String })
        return (imported, kind)
    }

    /// Replaces the fields Makosh owns; lists are replaced, not appended.
    public static func apply(_ card: PersonCard, to contact: CNMutableContact) {
        if card.kind == .organization {
            contact.contactType = .organization
            contact.organizationName = card.displayName
            contact.givenName = ""
            contact.familyName = ""
            contact.middleName = ""
            contact.jobTitle = ""
        } else {
            contact.contactType = .person
            contact.givenName = card.givenName.isEmpty ? card.displayName : card.givenName
            contact.familyName = card.familyName
            contact.middleName = card.middleName
            contact.organizationName = card.organization
            contact.jobTitle = card.jobTitle
        }
        contact.phoneNumbers = card.phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        contact.emailAddresses = card.emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
    }
}

/// The macOS Contacts book through `CNContactStore`, used only after the user enabled it and
/// the system granted access. Cards carry no mark: Makosh knows its cards by their identifiers.
/// `CNContactStore` is documented thread-safe; the actor keeps every call on one executor anyway.
public actor MacContactsAdapter: PersonBookAdapter {
    private let store: CNContactStore

    public init(store: CNContactStore = CNContactStore()) { self.store = store }

    public static var authorizationStatus: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    /// Shows the system prompt once; a refusal is final until the user changes System Settings.
    public static func requestAccess(store: CNContactStore = CNContactStore()) async -> Bool {
        if authorizationStatus == .authorized { return true }
        return (try? await store.requestAccess(for: .contacts)) ?? false
    }

    public var capabilities: PersonBookCapabilities {
        PersonBookCapabilities(acceptsOrganizations: true, requiresPhoneOrPeer: false, supportsMarker: false)
    }

    private func failure(_ error: Error) -> PersonsFailure {
        let code = (error as NSError).code
        if (error as NSError).domain == CNErrorDomain, code == CNError.authorizationDenied.rawValue { return .noAccess }
        if (error as NSError).domain == CNErrorDomain, code == CNError.recordDoesNotExist.rawValue { return .notFound }
        return .rejected(code: code, stage: "contacts")
    }

    public func changes(cursor: Data?) async throws -> RemoteCardChanges {
        guard Self.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
        var cards: [RemoteCard] = []
        let request = CNContactFetchRequest(keysToFetch: MacContactsMapping.keys)
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let (imported, kind) = MacContactsMapping.card(contact)
                cards.append(RemoteCard(externalID: contact.identifier, etag: nil, makoshID: nil, imported: imported, kind: kind))
            }
        } catch { throw failure(error) }
        return RemoteCardChanges(cards: cards, cursor: nil, full: true)
    }

    public func create(_ card: PersonCard) async throws -> RemoteCardRef {
        guard Self.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
        let contact = CNMutableContact()
        MacContactsMapping.apply(card, to: contact)
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do { try store.execute(request) } catch { throw failure(error) }
        return RemoteCardRef(externalID: contact.identifier, etag: nil)
    }

    public func update(externalID: String, etag: String?, card: PersonCard) async throws -> RemoteCardRef {
        guard Self.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
        do {
            let existing = try store.unifiedContact(withIdentifier: externalID, keysToFetch: MacContactsMapping.keys)
            guard let contact = existing.mutableCopy() as? CNMutableContact else { throw PersonsFailure.notFound }
            MacContactsMapping.apply(card, to: contact)
            let request = CNSaveRequest()
            request.update(contact)
            try store.execute(request)
        } catch let known as PersonsFailure {
            throw known
        } catch { throw failure(error) }
        return RemoteCardRef(externalID: externalID, etag: nil)
    }

    public func delete(externalID: String, etag: String?) async throws {
        guard Self.authorizationStatus == .authorized else { throw PersonsFailure.noAccess }
        do {
            let existing = try store.unifiedContact(withIdentifier: externalID, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
            guard let contact = existing.mutableCopy() as? CNMutableContact else { throw PersonsFailure.notFound }
            let request = CNSaveRequest()
            request.delete(contact)
            try store.execute(request)
        } catch let known as PersonsFailure {
            throw known
        } catch {
            let mapped = failure(error)
            if mapped != .notFound { throw mapped }
        }
    }

    public func find(makoshID: UUID) async throws -> RemoteCardRef? { nil }
}
