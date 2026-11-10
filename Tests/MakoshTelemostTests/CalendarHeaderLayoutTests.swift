import AppKit
import SwiftUI
import XCTest
@testable import MakoshApp

@MainActor final class CalendarHeaderLayoutTests: XCTestCase {
    func testDayAndWeekHeadersDoNotTakeTheScrollableGridsHeight() async throws {
        for dayCount in [1, 7] {
            for height in [CGFloat(320), CGFloat(960)] {
                let probe = HeaderHeightProbe()
                let calendar = Calendar(identifier: .gregorian)
                let start = Date(timeIntervalSince1970: 1_794_312_000)
                let days = (0..<dayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
                let content = VStack(spacing: 0) {
                    CalendarDayHeaders(days: days, calendar: calendar)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            probe.height = $0
                        }
                    ScrollView { Color.clear.frame(height: 1200) }
                }.frame(width: 800, height: height)
                let window = NSWindow(
                    contentRect: .init(x: 0, y: 0, width: 800, height: height),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: content)
                window.contentView = host
                window.orderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                }
                for _ in 0..<6 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let actual = try XCTUnwrap(probe.height)
                print("calendar-header-layout days=\(dayCount) parentHeight=\(height) measuredHeight=\(actual)")
                XCTAssertGreaterThan(actual, 20, "Day labels need a readable row")
                XCTAssertLessThan(actual, 45, "The header must not grow with the parent or consume grid space")
            }
        }
    }
}

@MainActor private final class HeaderHeightProbe {
    var height: CGFloat?
}

@MainActor final class WorkspaceFormLayoutTests: XCTestCase {
    func testCompoundRowsRemainAlignedInsideTheirFormAtNarrowAndWideSizes() async throws {
        for width in [CGFloat(640), CGFloat(1000)] {
            let probe = FormBoundsProbe()
            let content = Form {
                Section("Модели по ролям") {
                    ForEach(0..<3) { index in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(index == 0 ? "Беседа" : "Распознавание речи").frame(width: 170, alignment: .leading)
                                MakoshPicker("Подключение", selection: .constant("synthetic"), fillsWidth: true) {
                                    Text("Синтетический сервер с длинным названием").tag("synthetic")
                                }.labelsHidden().frame(width: 170)
                                TextField("Модель", text: .constant("synthetic-model"))
                            }
                            if index == 0 {
                                HStack {
                                    Text("Контекст модели, токенов").frame(width: 170, alignment: .leading)
                                    TextField("Контекст", text: .constant("128000")).frame(width: 120)
                                    Text("Бюджет беседы · Enter сохраняет").font(.caption)
                                }
                            }
                        }
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .named("formBounds"))
                        } action: {
                            probe.rows[index] = $0
                        }
                    }
                }
            }
            .formStyle(WorkspaceFormStyle()).textFieldStyle(WorkspaceTextFieldStyle())
            .frame(width: width, height: 540).coordinateSpace(name: "formBounds")
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: width, height: 540),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: content)
            window.contentView = host
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            for _ in 0..<6 {
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(probe.rows.count, 3)
            let first = try XCTUnwrap(probe.rows[0])
            for rect in probe.rows.values {
                XCTAssertGreaterThanOrEqual(rect.minX, 0, "A form row must not spill over its sidebar")
                XCTAssertLessThanOrEqual(rect.maxX, width + 1, "A form row must remain inside the viewport")
                XCTAssertEqual(rect.minX, first.minX, accuracy: 1, "Compound rows share a leading column")
                XCTAssertEqual(rect.width, first.width, accuracy: 1, "Compound rows share the same available width")
            }
        }
    }
}

@MainActor private final class FormBoundsProbe {
    var rows: [Int: CGRect] = [:]
}

@MainActor final class WorkspaceSettingsPageLayoutTests: XCTestCase {
    func testSparseSettingsKeepFieldsAndActionsTogetherAtTheTopLeft() async throws {
        for width in [CGFloat(640), CGFloat(1200)] {
            for height in [CGFloat(320), CGFloat(960)] {
                let probe = FormBoundsProbe()
                let content = WorkspaceSettingsContent {
                    Form {
                        Section("Синтетическая настройка") {
                            TextField("Название", text: .constant("QA"))
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named("settingsViewport"))
                                } action: {
                                    probe.rows[0] = $0
                                }
                            HStack {
                                Spacer()
                                Button("Сохранить") {}
                            }
                            .onGeometryChange(for: CGRect.self) {
                                $0.frame(in: .named("settingsViewport"))
                            } action: {
                                probe.rows[1] = $0
                            }
                        }
                    }.formStyle(WorkspaceFormStyle())
                }.frame(width: width, height: height).coordinateSpace(name: "settingsViewport")
                let window = NSWindow(
                    contentRect: .init(x: 0, y: 0, width: width, height: height),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let host = NSHostingView(rootView: content)
                window.contentView = host
                window.orderFront(nil)
                defer {
                    window.orderOut(nil)
                    window.contentView = nil
                    window.close()
                }
                for _ in 0..<6 {
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(20))
                }
                let field = try XCTUnwrap(probe.rows[0]), action = try XCTUnwrap(probe.rows[1])
                XCTAssertLessThan(field.minX, 80, "A sparse page must stay beside its category, not at the horizontal center")
                XCTAssertLessThan(field.minY, 120, "Window height must not move a field into the middle of the page")
                XCTAssertLessThanOrEqual(field.width, 700, "A wide window must leave spare space outside the form")
                XCTAssertGreaterThan(field.width, 450, "The editable area must remain usable at the narrower size")
                XCTAssertLessThan(action.minY - field.maxY, 40, "Save belongs next to the fields, not at the window bottom")
                XCTAssertEqual(action.minX, field.minX, accuracy: 1)
                XCTAssertEqual(action.width, field.width, accuracy: 1)
            }
        }
    }
}
