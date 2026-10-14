import SwiftUI
import CoreAudio
import MakoshTelegram

private struct TelegramAudioDevice: Identifiable {
    let id: String, name: String
    let input: Bool, output: Bool
}

private enum TelegramAudioInventory {
    enum Failure: Error { case unavailable }
    static func read() throws -> [TelegramAudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size % 4 == 0, size <= 256 * 4 else { throw Failure.unavailable }
        if size == 0 { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size / 4))
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, Int(size) == ids.count * 4 else { throw Failure.unavailable }
        var devices: [TelegramAudioDevice] = []
        for id in ids {
            let uid = try string(id, selector: kAudioDevicePropertyDeviceUID)
            let name = try string(id, selector: kAudioObjectPropertyName)
            guard !uid.isEmpty, TelegramCallAudioSelection(inputUID: uid).isValid,
                  !name.isEmpty, name.utf16.count <= 512, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !devices.contains(where: { $0.id == uid }) else { throw Failure.unavailable }
            let input = try hasStreams(id, scope: kAudioDevicePropertyScopeInput)
            let output = try hasStreams(id, scope: kAudioDevicePropertyScopeOutput)
            if input || output { devices.append(.init(id: uid, name: name, input: input, output: output)) }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private static func string(_ id: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { throw Failure.unavailable }
        return value.takeRetainedValue() as String
    }
    private static func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size <= 65_536 else { throw Failure.unavailable }
        return size > 0
    }
    static let synthetic: [TelegramAudioDevice] = [
        .init(id: "qa-input", name: "Синтетический микрофон", input: true, output: false),
        .init(id: "qa-output", name: "Синтетические наушники", input: false, output: true)
    ]
}

struct TelegramCallAudioSettingsView: View {
    let synthetic: Bool
    @AppStorage(TelegramCallAudioSelection.preferenceKey) private var raw = ""
    @State private var expected: String?
    @State private var draft = TelegramCallAudioSelection()
    @State private var devices: [TelegramAudioDevice] = []
    @State private var error: String?
    @State private var inventoryReady = false
    @State private var saved = false
    private var available: Bool {
        draft.isValid && ((draft.inputUID.isEmpty && draft.outputUID.isEmpty) ||
            (inventoryReady && (draft.inputUID.isEmpty || devices.contains { $0.id == draft.inputUID && $0.input })
             && (draft.outputUID.isEmpty || devices.contains { $0.id == draft.outputUID && $0.output })))
    }
    var body: some View {
        Form {
            Section("Аудиоустройства") {
                picker("Микрофон", input: true)
                picker("Выход звука", input: false)
                Button("Обновить устройства", action: refresh).accessibilityIdentifier("telegram.call.audio.refresh")
                Text("Выбор применяется к следующему звонку. Если выбранное устройство исчезнет, звонок завершится с ошибкой. Системное устройство используется только при выборе «Системное по умолчанию».")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Открытие этих настроек не включает микрофон и не воспроизводит звук.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Сохранить") {
                    guard raw == expected, available, let encoded = try? draft.encoded() else { error = "Настройки изменились. Откройте страницу заново."; return }
                    raw = encoded; expected = encoded; saved = true; error = nil
                }.disabled(!available || expected != raw).accessibilityIdentifier("telegram.call.audio.save")
                Button("Системные устройства по умолчанию") { draft = .init(); saved = false }
                    .accessibilityIdentifier("telegram.call.audio.defaults")
                if let error { Text(error).foregroundStyle(.orange) }
                if saved { Text("Сохранено для следующего звонка.").accessibilityIdentifier("telegram.call.audio.saved") }
                if expected != nil, expected != raw { Text("Настройки изменены в другом окне. Откройте страницу заново.").foregroundStyle(.orange) }
            }
            if synthetic { Text("Синтетический список. Физические устройства не запрашиваются.").font(.caption) }
        }.formStyle(.grouped).onAppear {
            guard expected == nil else { return }; expected = raw
            do { draft = try .decode(raw) } catch { self.error = "Настройки аудио повреждены. Явно выберите системные устройства и сохраните." }
            refresh()
        }
    }
    private func picker(_ title: String, input: Bool) -> some View {
        let binding = Binding<String>(get: { input ? draft.inputUID : draft.outputUID }, set: { value in
            if input { draft.inputUID = value } else { draft.outputUID = value }; saved = false
        })
        return Picker(title, selection: binding) {
            Text("Системное по умолчанию").tag("")
            ForEach(devices.filter { input ? $0.input : $0.output }) { Text($0.name).tag($0.id) }
            if !binding.wrappedValue.isEmpty, !devices.contains(where: { $0.id == binding.wrappedValue && (input ? $0.input : $0.output) }) {
                Text("Выбранное устройство недоступно").tag(binding.wrappedValue)
            }
        }.accessibilityIdentifier(input ? "telegram.call.audio.input" : "telegram.call.audio.output")
    }
    private func refresh() {
        do { devices = synthetic ? TelegramAudioInventory.synthetic : try TelegramAudioInventory.read(); inventoryReady = true }
        catch { devices = []; inventoryReady = false; self.error = "Не удалось прочитать аудиоустройства. Повторите обновление." }
    }
}
