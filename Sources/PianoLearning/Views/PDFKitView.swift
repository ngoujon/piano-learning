import PDFKit
import SwiftUI

/// Displays a PDF score (local file or remote URL).
struct PDFKitView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        load(into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if context.coordinator.loadedURL != url { load(into: view, coordinator: context.coordinator) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var loadedURL: URL? }

    private func load(into view: PDFView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        if url.isFileURL {
            view.document = PDFDocument(url: url)
        } else {
            view.document = nil
            let target = url
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: target) else { return }
                await MainActor.run {
                    if coordinator.loadedURL == target { view.document = PDFDocument(data: data) }
                }
            }
        }
    }
}
