import MakoshWhatsApp
// Layout adapted from WhatsApp Zen MainView.swift / Components.swift (MIT).
// See LICENSES/WhatsApp-Zen-MIT.txt and docs/reference-interface.md.
import SwiftUI

struct WhatsAppPairingView: View {
    @ObservedObject var model: WhatsAppWorkspaceModel
    private var steps: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Связать с WhatsApp").font(.largeTitle.bold())
            step(1, "Откройте WhatsApp на телефоне")
            step(2, "Настройки → Связанные устройства → Привязка устройства")
            step(3, "Наведите телефон на QR-код")
            if model.isSynthetic {
                Text("Тестовый QR · не привязывает аккаунт").font(.callout).foregroundStyle(.secondary)
            }
            if model.status.state == "expired" {
                Text("Код истёк. Подключитесь снова, чтобы получить новый.").foregroundStyle(.secondary)
            }
            Button("Отменить привязку") { Task { await model.disconnect() } }.accessibilityIdentifier(
                "whatsapp.pair.cancel")
        }.frame(maxWidth: 340, alignment: .leading)
    }
    private var code: some View {
        Group {
            if let data = model.qrImage, let image = NSImage(data: data) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(14).background(
                    .white, in: RoundedRectangle(cornerRadius: 22))
            } else if model.status.state == "expired" {
                Image(systemName: "qrcode").font(.system(size: 90)).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.large)
            }
        }.frame(width: 250, height: 250).padding(14).glassEffect(
            .regular, in: RoundedRectangle(cornerRadius: 34)
        ).accessibilityLabel(model.isSynthetic ? "Тестовый QR-код" : "QR-код привязки WhatsApp")
    }
    var body: some View {
        GeometryReader { size in
            ScrollView {
                Group {
                    if size.size.width >= 700 {
                        HStack(spacing: 44) {
                            steps
                            code
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            steps
                            code
                        }
                    }
                }.padding(32).frame(maxWidth: .infinity, minHeight: size.size.height)
            }
        }.background(
            LinearGradient(
                colors: [WorkspaceStyle.accent.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
    }
    private func step(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.callout.bold()).foregroundStyle(.white).frame(width: 24, height: 24)
                .background(WorkspaceStyle.accent, in: Circle())
            Text(title).font(.title3)
        }
    }
}
