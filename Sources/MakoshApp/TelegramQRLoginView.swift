import SwiftUI
import CoreImage.CIFilterBuiltins
import MakoshTelegram

func telegramLoginQRImage(_ value: String) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8); filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: .init(scaleX: 8, y: 8))
    return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(scaled, from: scaled.extent)
}
struct TelegramQRLoginView: View {
    @ObservedObject var controller: TelegramQRLoginController
    var body: some View {
        VStack(spacing: 20) {
            Text("Вход в Telegram по QR-коду").font(.title2.weight(.semibold))
            if let value = controller.displayURL, let qr = telegramLoginQRImage(value) {
                Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 240, height: 240).padding(16).background(.white)
                    .accessibilityLabel("QR-код входа в Telegram").accessibilityIdentifier("telegram.qr.image")
            } else if controller.phase == .failed {
                ContentUnavailableView("QR-код недоступен", systemImage: "qrcode", description: Text("Не удалось получить действующий код. Повторите попытку или войдите по номеру."))
                    .accessibilityIdentifier("telegram.qr.failure")
                Button("Повторить") { controller.start() }.accessibilityIdentifier("telegram.qr.retry")
            } else { ProgressView("Получение QR-кода…").frame(width: 272, height: 272) }
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Откройте Telegram на телефоне.")
                Text("2. Настройки → Устройства → Подключить устройство.")
                Text("3. Наведите камеру телефона на этот код.")
            }.font(.callout)
            Button("Войти по номеру телефона") { controller.cancel() }.accessibilityIdentifier("telegram.qr.phone")
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDisappear { controller.cancel() }
    }
}
