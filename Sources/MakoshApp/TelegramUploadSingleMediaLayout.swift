import SwiftUI
import MakoshTelegram

struct TelegramUploadSingleMediaLayout: Layout {
    let file: TelegramUploadFile
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(16_384, max(16, proposal.width ?? 360))
        let height = TelegramSingleMediaPresentation.uploadSize(file, availableWidth: width)?.height ?? 200
        return CGSize(width: width, height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            view.place(at: bounds.origin, anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
