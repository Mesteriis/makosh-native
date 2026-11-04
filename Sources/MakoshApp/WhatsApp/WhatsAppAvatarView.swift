import AppKit
import ImageIO
import MakoshCore
import MakoshWhatsApp
import SwiftUI

struct WhatsAppAvatarView: View {
    private struct Request: Equatable {
        let scope: WhatsAppAvatarScope
        let revision: UInt64, epoch: UInt64, manual: UInt64
    }
    let name: String, group: Bool
    let scope: WhatsAppAvatarScope?
    let revision: UInt64, epoch: UInt64
    @State private var manual: UInt64 = 0
    @State private var loaded: Request?
    @StateObject private var model: WhatsAppAvatarModel
    init(
        name: String, group: Bool, scope: WhatsAppAvatarScope?, revision: UInt64 = 0, epoch: UInt64 = 0,
        worker: any WhatsAppServing, cache: WhatsAppAvatarWindowCache
    ) {
        self.name = name
        self.group = group
        self.scope = scope
        self.revision = revision
        self.epoch = epoch
        _model = StateObject(wrappedValue: .init(worker: worker, cache: cache))
    }
    private var request: Request? {
        scope.map { .init(scope: $0, revision: revision, epoch: epoch, manual: manual) }
    }
    var body: some View {
        Group {
            if loaded == request, model.scope == scope, let image = model.image {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 44, height: 44).clipShape(
                    Circle())
            } else {
                WhatsAppAvatar(name: name, group: group)
            }
        }
        .help(
            model.unavailable ? "Фотография недоступна. Можно обновить через контекстное меню." : name
        )
        .contextMenu { Button("Обновить фотографию") { manual &+= 1 }.disabled(scope == nil) }
        .task(id: request) {
            guard let request else { return }
            await model.load(scope: request.scope, refresh: request.manual > 0)
            guard !Task.isCancelled else { return }
            loaded = request
        }
    }
}
