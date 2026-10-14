import Foundation
import TelegramCore
import TelegramApi
import Postbox
import SwiftSignalKit

struct TelegramAppearanceResource {
    let resource: CloudDocumentMediaResource
    let reference: MediaResourceReference
    let size: Int64
    let palette: Bool
}
struct TelegramAppearanceCatalogMapping {
    let snapshot: TelegramAppearanceCatalogSnapshot
    let resources: [String:TelegramAppearanceResource]
}
func telegramAppearanceCatalog(themes: Api.account.Themes, wallpapers: Api.account.WallPapers, accountID: Int64) -> TelegramAppearanceCatalogMapping? {
    guard case let .themes(_, themes) = themes, case let .wallPapers(_, wallpapers) = wallpapers,
          themes.count <= 512, wallpapers.count <= 1024 else { return nil }
    var choices: [TelegramCloudAppearanceChoice] = [], resources: [String:TelegramAppearanceResource] = [:]
    func document(_ value: Api.Document, palette: Bool, slug: String?) -> TelegramAppearanceResource? {
        guard case let .document(_,id,hash,reference,_,mime,size,_,_,dc,_) = value,
              id != 0, (1...1000).contains(dc), size > 0, size <= (palette ? 1_048_576 : 32 * 1024 * 1024),
              reference.size <= 65536,
              palette || ["image/jpeg","image/png","image/webp","image/heic"].contains(mime) else { return nil }
        let resource = CloudDocumentMediaResource(datacenterId:Int(dc),fileId:id,accessHash:hash,size:size,fileReference:reference.makeData(),fileName:nil)
        let mediaReference: MediaResourceReference = slug.map { .wallpaper(wallpaper:.slug($0),resource:resource) } ?? .standalone(resource:resource)
        return .init(resource:resource,reference:mediaReference,size:size,palette:palette)
    }
    func colors(_ settings: Api.WallPaperSettings?) -> [UInt32] {
        guard let settings, case let .wallPaperSettings(_,a,b,c,d,_,_,_) = settings else { return [] }
        return [a,b,c,d].compactMap { $0 }.map { UInt32(bitPattern:$0) & 0xffffff }
    }
    for theme in themes {
        guard case let .theme(_,id,_,_,title,file,settings,_,_) = theme, id != 0 else { return nil }
        if let settings, !settings.isEmpty {
            guard settings.count <= 8 else { return nil }
            for setting in settings {
                guard case let .themeSettings(_,base,accent,_,outgoing,wallpaper) = setting else { return nil }
                let name: String, dark: Bool
                switch base {
                case .baseThemeClassic: name = "classic"; dark = false
                case .baseThemeDay: name = "day"; dark = false
                case .baseThemeArctic: name = "arctic"; dark = false
                case .baseThemeNight: name = "night"; dark = true
                case .baseThemeTinted: name = "tinted"; dark = true
                }
                var background: UInt32?
                if case let .wallPaperNoFile(_,_,settings) = wallpaper, let first = colors(settings).first { background = first }
                let palette = TelegramCloudPalette(name:title,isDark:dark,accent:UInt32(bitPattern:accent) & 0xffffff,background:background,text:nil,incoming:nil,outgoing:(outgoing ?? []).map { UInt32(bitPattern:$0) & 0xffffff })
                choices.append(.init(id:"theme:\(id):\(name)",title:title + (dark ? " · Ночная" : " · Дневная"),kind:.theme(palette)))
            }
        } else {
            let key = "theme:\(id)"
            if let file, let resource = document(file,palette:true,slug:nil) { resources[key] = resource; choices.append(.init(id:key,title:title,kind:.downloadTheme)) }
            else { choices.append(.init(id:key,title:title,kind:.unavailable("Нет поддерживаемого файла настольной темы"))) }
        }
    }
    for wallpaper in wallpapers {
        switch wallpaper {
        case let .wallPaperNoFile(id,_,settings):
            let values = colors(settings), kind: TelegramCloudAppearanceKind
            if values.count == 1 { kind = .wallpaper(.solid(values[0])) }
            else if values.count == 2 { kind = .wallpaper(.gradient(values[0],values[1])) }
            else { kind = .unavailable("Этот вариант цветного фона недоступен") }
            choices.append(.init(id:"wallpaper:\(id)",title:"Цветной фон · \(id)",kind:kind))
        case let .wallPaper(id,flags,_,slug,file,_):
            let key = "wallpaper:\(id)", kind: TelegramCloudAppearanceKind
            if flags & (1 << 3) != 0 { kind = .unavailable("Узор с наложением цветов недоступен") }
            else if slug.utf8.count <= 256, let resource = document(file,palette:false,slug:slug) { resources[key] = resource; kind = .downloadWallpaper }
            else { kind = .unavailable("Формат или размер изображения не поддерживается") }
            choices.append(.init(id:key,title:"Изображение · \(id)",kind:kind))
        }
    }
    let snapshot = TelegramAppearanceCatalogSnapshot(accountID:accountID,choices:choices)
    guard snapshot.isValid else { return nil }; return .init(snapshot:snapshot,resources:resources)
}

private final class AppearanceCatalogBackend {
    let account: Account
    let sources = Atomic<[String:TelegramAppearanceResource]>(value:[:])
    init(account: Account) { self.account = account }
    func load() -> Signal<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError> {
        let themes = account.network.request(Api.functions.account.getThemes(format:"macos",hash:0),automaticFloodWait:false) |> mapError { _ in TelegramAppearanceError.invalid }
        let wallpapers = account.network.request(Api.functions.account.getWallPapers(hash:0),automaticFloodWait:false) |> mapError { _ in TelegramAppearanceError.invalid }
        return combineLatest(themes,wallpapers) |> take(1) |> mapToSignal { [self] themes,wallpapers in
            guard let mapped = telegramAppearanceCatalog(themes:themes,wallpapers:wallpapers,accountID:account.peerId.toInt64()) else { return .fail(.invalid) }
            _ = sources.swap(mapped.resources); return .single(mapped.snapshot)
        }
    }
    func prepare(_ choice: TelegramCloudAppearanceChoice) -> Signal<TelegramCloudAppearanceKind,TelegramAppearanceError> {
        guard let source = sources.with({ $0[choice.id] }),
              source.palette ? choice.kind == .downloadTheme : choice.kind == .downloadWallpaper else { return .fail(.invalid) }
        return Signal { [account] subscriber in
            let keep = MetaDisposable(), data = MetaDisposable(), fetch = MetaDisposable()
            let received = Atomic(value:false), cancelled = Atomic(value:false)
            keep.set(account.postbox.mediaBox.keepResource(id:source.resource.id).start())
            data.set(account.postbox.mediaBox.resourceData(source.resource,pathExtension:nil,option:.complete(waitUntilFetchStatus:false)).start(next: { value in
                guard value.complete, !received.swap(true) else { return }
                guard value.offset == 0, value.size == source.size else { subscriber.putError(.image); return }
                data.dispose(); fetch.dispose()
                Queue.concurrentDefaultQueue().async {
                    defer { keep.dispose() }
                    guard !cancelled.with({ $0 }) else { return }
                    do {
                        let bytes = try TelegramWallpaperFiles.readSelection(URL(fileURLWithPath:value.path))
                        guard bytes.count == source.size else { throw TelegramAppearanceError.image }
                        let result: TelegramCloudAppearanceKind = source.palette ? .theme(try TelegramCloudPalette.parse(bytes)) : .image(try TelegramWallpaperImage.prepare(bytes))
                        guard !cancelled.with({ $0 }) else { return }; subscriber.putNext(result); subscriber.putCompletion()
                    } catch { if !cancelled.with({ $0 }) { subscriber.putError(.image) } }
                }
            }))
            if !received.with({ $0 }) {
                fetch.set(fetchedMediaResource(mediaBox:account.postbox.mediaBox,userLocation:.other,userContentType:source.palette ? .file : .image,reference:source.reference,continueInBackground:false).start(error:{ _ in
                    guard !received.swap(true), !cancelled.with({ $0 }) else { return }; data.dispose(); keep.dispose(); subscriber.putError(.image)
                }))
            }
            return ActionDisposable { _ = cancelled.swap(true); data.dispose(); fetch.dispose(); keep.dispose() }
        }
    }
}
@MainActor final class TelegramEngineAppearanceCatalogProvider: TelegramAppearanceCatalogProvider {
    let accountID: Int64
    private let backend: AppearanceCatalogBackend
    init(account: Account) { accountID = account.peerId.toInt64(); backend = .init(account:account) }
    func load(receive: @escaping @MainActor (Result<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest {
        let request = Request()
        request.disposable.set((backend.load() |> deliverOnMainQueue).start(next:{ value in MainActor.assumeIsolated { receive(.success(value)) } },error:{ error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    func prepare(_ choice: TelegramCloudAppearanceChoice, receive: @escaping @MainActor (Result<TelegramCloudAppearanceKind,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest {
        let request = Request()
        request.disposable.set((backend.prepare(choice) |> deliverOnMainQueue).start(next:{ value in MainActor.assumeIsolated { receive(.success(value)) } },error:{ error in MainActor.assumeIsolated { receive(.failure(error)) } }))
        return request
    }
    private final class Request: TelegramSessionsRequest {
        let disposable = MetaDisposable()
        func cancel() { disposable.dispose() }
        isolated deinit { disposable.dispose() }
    }
}
