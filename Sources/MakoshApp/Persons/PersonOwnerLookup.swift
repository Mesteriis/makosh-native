import Foundation
import MakoshCore

/// `.task(id:)` key for an owner lookup: re-runs when the identity or the loaded persons change.
struct PersonOwnerLookupKey: Hashable {
    let identity: ServiceIdentity
    let count: Int
    let revisions: Int

    init(identity: ServiceIdentity, persons: [Person]) {
        self.identity = identity
        count = persons.count
        revisions = persons.reduce(0) { $0 &+ $1.revision }
    }
}
