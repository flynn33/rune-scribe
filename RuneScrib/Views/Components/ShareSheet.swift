// RuneScrib/Views/Components/ShareSheet.swift
//
// iOS export uses the system share sheet (there is no NSOpenPanel). The exported
// key files are written to a temporary folder, then handed to UIActivityViewController
// so the user can Save to Files, AirDrop, etc.

#if os(iOS)
import SwiftUI
import UIKit

/// Identifiable payload that drives the share sheet's `.sheet(item:)`.
struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// SwiftUI wrapper around `UIActivityViewController`.
struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
