import SwiftUI
import AppKit

struct MeetingsView: View {
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Яндекс Телемост", systemImage: "video").font(.largeTitle.weight(.semibold))
            Text("Встреча по вашей ссылке").font(.title3)
            Text("Вставьте HTTPS-ссылку telemost.yandex.ru. Встреча откроется в браузере; Макош не получает доступ к микрофону, камере или аккаунту.").foregroundStyle(.secondary)
            TextField("https://telemost.yandex.ru/…", text: $address).textFieldStyle(.roundedBorder).accessibilityIdentifier("meeting.url")
            Button("Открыть встречу") {
                guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host?.lowercased() == "telemost.yandex.ru", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { error = "Укажите HTTPS-ссылку на telemost.yandex.ru."; return }
                if !NSWorkspace.shared.open(url) { error = "Не удалось открыть браузер." }
            }.buttonStyle(.borderedProminent).disabled(address.isEmpty).accessibilityIdentifier("meeting.open")
            Divider()
            Label("API аккаунта не подключён", systemImage: "circle.dashed").font(.headline)
            Text("REST API Телемоста предназначен для Яндекс 360 для бизнеса с аккаунтами на домене организации. Создание встреч и календарь здесь пока не реализованы.").foregroundStyle(.secondary)
            Spacer()
        }.padding(36).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Проверьте ссылку", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Понятно") { error = nil } } message: { Text(error ?? "") }
    }
}
