import XCTest
@testable import MakoshApp

@MainActor final class WorkspaceNavigationTests: XCTestCase {
    func testRepeatedSettingsCommandProducesANewRequestForTheSameCategory() {
        let navigation = WorkspaceNavigation()
        navigation.openSettings(.calendar)
        let first = navigation.settingsRequest
        navigation.openSettings(.calendar)
        XCTAssertEqual(navigation.settingsRequest?.category, .calendar)
        XCTAssertNotEqual(navigation.settingsRequest?.id, first?.id)
    }

    func testUnscopedCommandKeepsCategoryChoiceWithTheWorkspace() {
        let navigation = WorkspaceNavigation()
        navigation.openSettings()
        XCTAssertNotNil(navigation.settingsRequest)
        XCTAssertNil(navigation.settingsRequest?.category)
    }

    func testGuideCanReturnToItsExistingServiceWithoutOpeningAWindow() {
        let navigation = WorkspaceNavigation()
        navigation.openSettings(.tasks)
        navigation.showService(.tasks)
        XCTAssertEqual(navigation.destinationRequest, .tasks)
    }

    func testPersistedCategoryCannotEscapeSyntheticServiceScope() {
        XCTAssertEqual(WorkspaceSettingsCategory.resolve("persons", allowed: [.tasks]), .tasks)
        XCTAssertEqual(WorkspaceSettingsCategory.resolve("calendar", allowed: [.calendar, .tasks]), .calendar)
        XCTAssertEqual(WorkspaceSettingsCategory.resolve("removed-category", allowed: [.teams]), .teams)
        XCTAssertNil(WorkspaceSettingsCategory.resolve("telegram", allowed: []))
    }
}
