#if DEBUG
import Foundation
@MainActor final class TelegramSyntheticAppearanceCatalogProvider: TelegramAppearanceCatalogProvider {
    let accountID: Int64 = -1
    private let choices: [TelegramCloudAppearanceChoice] = [
        .init(id:"theme:qa",title:"Синтетическая настольная тема",kind:.downloadTheme),
        .init(id:"wallpaper:qa",title:"Синтетический градиент",kind:.wallpaper(.gradient(0xdce8df,0xc6d5ed))),
        .init(id:"wallpaper:pattern",title:"Синтетический узор",kind:.unavailable("Узор с наложением цветов недоступен"))]
    func load(receive: @escaping @MainActor (Result<TelegramAppearanceCatalogSnapshot,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest {
        receive(.success(.init(accountID:accountID,choices:choices))); return Request()
    }
    func prepare(_ choice: TelegramCloudAppearanceChoice, receive: @escaping @MainActor (Result<TelegramCloudAppearanceKind,TelegramAppearanceError>) -> Void) -> any TelegramSessionsRequest {
        guard choices.contains(choice), choice.kind == .downloadTheme else { receive(.failure(.invalid)); return Request() }
        do { receive(.success(.theme(try TelegramCloudPalette.parse(Data("name = Синтетическая тема\nisDark = 0\naccent = #376dba\nbackground = #eef3f8\ntext = #17283a\nbubbleBackground_incoming = #ffffff\nbubbleBackground_outgoing = #d3e7ff,#b8d8ff\n".utf8))))) }
        catch { receive(.failure(.invalid)) }; return Request()
    }
    private final class Request: TelegramSessionsRequest { func cancel() {} }
}
#endif
