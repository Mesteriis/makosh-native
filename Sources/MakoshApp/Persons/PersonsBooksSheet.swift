import Foundation
import MakoshPersons
import SwiftUI

/// Connection state and open attempts of every book, from the sidebar's «Книги» button.
struct PersonsBooksSheet: View {
    @ObservedObject var model: PersonsWorkspaceModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Книги").font(.title2.bold())
                Spacer()
                Button("Обновить") { Task { await model.readAll() } }.accessibilityIdentifier("persons.books.refresh")
                Button("Готово") { dismiss() }
            }
            PersonsBooksStatusList(model: model)
        }.padding(26).frame(width: 640, height: 520)
    }
}

struct PersonsBooksStatusList: View {
    @ObservedObject var model: PersonsWorkspaceModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let books = model.snapshot?.books ?? []
                if books.isEmpty { Text("Учётные записи не подключены. Добавьте их в Настройках → Персоны.").foregroundStyle(.secondary) }
                ForEach(books) { book in
                    GroupBox {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.name).font(.headline)
                                Text(PersonsBookText.kind(book.kind) + " · " + PersonsBookText.state(book.state)).font(.caption)
                                    .foregroundStyle(.secondary)
                                if let failure = book.lastError {
                                    Text(PersonsWorkspaceModel.describe(failure)).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if book.state == .needsSignIn || book.state == .unreachable {
                                Button("Повторить") { Task { await model.reconnect(bookID: book.id) } }
                            }
                        }.padding(4)
                    }
                }
                let attempts = model.snapshot?.openAttempts ?? []
                if !attempts.isEmpty {
                    Text("Открытые попытки · \(attempts.count)").font(.headline)
                    ForEach(attempts) { attempt in
                        HStack {
                            Text(PersonsBookText.attempt(attempt)).font(.callout)
                            Spacer()
                            if attempt.state == .unknown {
                                Button("Проверить") { Task { await model.settle(bookID: attempt.bookID) } }
                                Button("Отказаться") { Task { await model.dismiss(attemptID: attempt.id) } }
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum PersonsBookText {
    static func kind(_ kind: PersonBookKind) -> String {
        switch kind {
        case .telegram: "Telegram"
        case .carddav: "CardDAV"
        case .googleContacts: "Google Contacts"
        case .macContacts: "Контакты macOS"
        case .synthetic: "Синтетическая книга"
        case .mail: "Почта"
        case .whatsapp: "WhatsApp"
        case .teams: "Teams"
        }
    }
    static func state(_ state: PersonBookState) -> String {
        switch state {
        case .connected: "подключена"
        case .needsSignIn: "нужен повторный вход"
        case .noAccess: "нет доступа"
        case .unreachable: "недоступна"
        case .disabled: "отключена"
        }
    }
    static func attempt(_ attempt: PersonAttempt) -> String {
        let kind =
            switch attempt.kind {
            case .create: "создание"
            case .update: "обновление"
            case .delete: "удаление"
            }
        let state =
            switch attempt.state {
            case .queued: "в очереди"
            case .sent: "отправляется"
            case .unknown: "неизвестно"
            case .confirmed: "принято"
            case .rejected: "отклонено"
            }
        return "\(kind) · \(state) · \(attempt.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }
}
