import SwiftUI
import MakoshTelegram

struct TelegramProfilePhotosView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var gallery: TelegramProfilePhotosController
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("telegram.profilePhotos.close")
            }.padding(16)
            ZStack {
                Color.black.opacity(0.9)
                switch gallery.state {
                case .idle: Text("Откройте фотографии заново.").foregroundStyle(.white)
                case .loading: ProgressView("Загрузка фотографий…").tint(.white).foregroundStyle(.white)
                case .unavailable:
                    VStack(spacing: 16) {
                        Text("Фотографии пока недоступны.").font(.headline)
                        Text("Возможно, доступных снимков нет или их не удалось получить.")
                            .multilineTextAlignment(.center)
                        Button("Повторить", action: gallery.retry).accessibilityIdentifier("telegram.profilePhotos.retry")
                    }.foregroundStyle(.white).padding(24)
                case .ready:
                    if let image = gallery.image {
                        Image(image.image, scale: 1, label: Text("Фотография профиля \(gallery.selectedIndex + 1)"))
                            .resizable().scaledToFit().padding(16)
                            .accessibilityIdentifier("telegram.profilePhotos.image")
                    } else if gallery.imageLoading {
                        ProgressView("Загрузка фотографии…").tint(.white).foregroundStyle(.white)
                    } else if let error = gallery.imageError {
                        VStack(spacing: 16) {
                            Text(error).multilineTextAlignment(.center)
                            Button("Повторить", action: gallery.retryImage)
                                .accessibilityIdentifier("telegram.profilePhotos.retryImage")
                        }.foregroundStyle(.white).padding(24)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if gallery.state == .ready, let photo = gallery.selectedPhoto {
                HStack(spacing: 20) {
                    Button { gallery.move(by: -1) } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut(.leftArrow, modifiers: []).disabled(!gallery.canGoBack)
                        .accessibilityLabel("Предыдущая фотография").accessibilityIdentifier("telegram.profilePhotos.previous")
                    VStack(spacing: 4) {
                        Text("\(gallery.selectedIndex + 1) из \(gallery.photos.count)")
                            .accessibilityIdentifier("telegram.profilePhotos.position")
                        if photo.date > 0 {
                            Text(Date(timeIntervalSince1970: Double(photo.date)).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if photo.totalCount > gallery.photos.count {
                            Text("Доступно \(gallery.photos.count) из \(photo.totalCount) фотографий")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if photo.hasVideo {
                            Text("Фотокадр видеоаватара").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                    Button { gallery.move(by: 1) } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut(.rightArrow, modifiers: []).disabled(!gallery.canGoForward)
                        .accessibilityLabel("Следующая фотография").accessibilityIdentifier("telegram.profilePhotos.next")
                }.padding(16)
            }
        }.frame(width: 800, height: 620)
            .onDisappear { gallery.close() }
    }
}
