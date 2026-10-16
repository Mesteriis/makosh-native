import Foundation

extension TelemostRepository {
    public func cohostProgress(scope: TelemostScope) throws -> (offset: Int, values: [String]) {
        guard let local = try matchingMeeting(accountID: scope.accountID, url: .init("https://telemost.yandex.ru/j/" + scope.conferenceID)) else { throw TelemostFailure.missing }
        if local.cohostsComplete { return (0, []) }
        return (local.cohostsNextOffset, local.cohostsPending)
    }
    public func retainCohostPage(_ page: TelemostCohostPage, staged: [String]) throws {
        let db = try db()
        guard let local = try matchingMeeting(accountID: page.scope.accountID, url: .init("https://telemost.yandex.ru/j/" + page.scope.conferenceID)),
              page.offset == staged.count, page.emails.count <= page.limit else { throw TelemostFailure.conflict }
        try db.transaction {
            var value = try meeting(id: local.id)
            let all = staged + page.emails
            let duplicate = Set(all.map { Data($0.utf8) }).count != all.count
            value.lastCohostPage = page
            if duplicate {
                var seen = Set(value.cohosts.map { Data($0.utf8) })
                value.cohosts.append(contentsOf: all.filter { seen.insert(Data($0.utf8)).inserted })
                value.cohostsComplete = false; value.cohostsNextOffset = 0; value.cohostsPending = []
            } else if page.complete {
                value.cohosts = all; value.cohostsComplete = true; value.cohostsNextOffset = 0; value.cohostsPending = []
            } else {
                var seen = Set(value.cohosts.map { Data($0.utf8) })
                value.cohosts.append(contentsOf: all.filter { seen.insert(Data($0.utf8)).inserted })
                value.cohostsComplete = false; value.cohostsPending = all; value.cohostsNextOffset = page.offset + page.emails.count
            }
            value.updatedAt = Date()
            try put(value, kind: "local", key: value.id.uuidString, owner: owner(value.accountID))
        }
        if Set((staged + page.emails).map { Data($0.utf8) }).count != staged.count + page.emails.count { throw TelemostFailure.invalidResponse }
    }
}
