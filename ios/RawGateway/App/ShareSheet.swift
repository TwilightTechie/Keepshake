import SwiftUI
import UIKit

/// Presents native iOS UIActivityViewController for direct file sharing (AirDrop, Files, Mail, etc.)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Identifiable wrapper for presenting share sheet with file URLs in SwiftUI `.sheet(item:)`
struct ShareableReport: Identifiable {
    let id = UUID()
    let fileURL: URL
    let previewTitle: String
}
