#if DEBUG
import SwiftUI
import MakoshTelegram

struct TelegramS3SyntheticPreview: View {
    @StateObject private var archive = TelegramArchiveController()
    @State private var failure: String?
    @State private var started = false
    private struct Configuration: Decodable {
        let connectionString: String
        let schema: String
        let storageConfiguration: String
        let spoolDirectory: String
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 20) {
            Text("СИНТЕТИЧЕСКАЯ ПРОВЕРКА S3").font(.title2.bold())
            Text("Тестовый файл захвачен до удаления кеша; личные аккаунты и Связка ключей не используются.")
            TelegramArchiveBar(archive: archive)
            if let failure { Text(failure).foregroundStyle(.red) }
            Spacer()
        }.padding(24).task {
            guard !started else { return }; started = true
            do {
                let args = CommandLine.arguments
                guard let index = args.firstIndex(of: "--telegram-s3-synthetic-preview"), args.indices.contains(index+1) else { throw CocoaError(.fileReadUnknown) }
                let url = URL(fileURLWithPath: args[index+1])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16384 else { throw CocoaError(.fileReadUnknown) }
                let config = try JSONDecoder().decode(Configuration.self,from: Data(contentsOf: url))
                try archive.configureSyntheticS3(connectionString: config.connectionString,schema: config.schema,
                    configurationFile: URL(fileURLWithPath: config.storageConfiguration),spoolDirectory: URL(fileURLWithPath: config.spoolDirectory))
            } catch { failure = "Не удалось открыть изолированную синтетическую конфигурацию S3." }
        }
    }
}
#endif
