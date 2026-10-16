import AppKit
import Darwin
import QuickLookUI
import SwiftUI
import MakoshCore
import MakoshTeams

@MainActor enum TeamsFilePanels {
    static func fixtureDirectory() -> URL? {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--teams-qa-fixtures").flatMap { args.indices.contains($0 + 1) && !args[$0 + 1].hasPrefix("--") ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    }
    static func chooseFiles() async -> [URL] {
        if CommandLine.arguments.contains("--teams-synthetic-preview"), fixtureDirectory() == nil { return [] }
        let panel = NSOpenPanel(); panel.directoryURL = fixtureDirectory(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        return await withCheckedContinuation { continuation in panel.begin { result in continuation.resume(returning: result == .OK ? panel.urls : []) } }
    }
    static func save(_ lease: TeamsFileLease, name: String) async throws {
        if CommandLine.arguments.contains("--teams-synthetic-preview"), fixtureDirectory() == nil { throw TeamsFailure.invalidConfiguration }
        let panel = NSSavePanel(); panel.directoryURL = fixtureDirectory()?.deletingLastPathComponent().appendingPathComponent("exports"); panel.nameFieldStringValue = name
        let destination: URL? = await withCheckedContinuation { continuation in panel.begin { result in continuation.resume(returning: result == .OK ? panel.url : nil) } }
        guard let destination else { return }
        try await BackgroundWork.run {
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".makosh-save-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: lease.url, to: staging)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
            guard Darwin.rename(staging.path, destination.path) == 0 else { throw TeamsFailure.storage }
        }
    }
}
struct TeamsFilePreview: View {
    let lease: TeamsFileLease
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(name).font(.headline).lineLimit(1); Spacer(); Button("Сохранить…") { Task { do { try await TeamsFilePanels.save(lease, name: URL(fileURLWithPath: name).lastPathComponent) } catch { self.error = teamsFailureMessage(error) } } }; Button("Закрыть") { dismiss() } }.padding(12)
            if let error { Text(error).foregroundStyle(.orange).padding(8) }
            TeamsQuickLook(url: lease.url)
        }.frame(minWidth: 650, minHeight: 500)
    }
}
private struct TeamsQuickLook: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView { guard let view = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }; view.autostarts = true; return view }
    func updateNSView(_ view: NSView, context: Context) { (view as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? QLPreviewView)?.previewItem = nil; (view as? QLPreviewView)?.close() }
}
