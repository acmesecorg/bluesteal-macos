//
//  QRCodeView.swift
//  bluesteal
//
//  Renders a string as a QR code and the slide-up modal that displays a QR the
//  peer shared. macOS is receive/display only (no camera scanning).
//

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

/// Renders an arbitrary string as a scannable QR image (CoreImage).
struct QRCodeView: View {
    let uri: String

    var body: some View {
        if let img = Self.make(uri) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable().scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    static func make(_ string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
                .transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// The modal shown when the peer shares a QR: rendered for the user to scan.
struct ReceivedQRView: View {
    let uri: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("QR from peer")
                .font(.headline)
            Text("Scan this with your phone")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            QRCodeView(uri: uri)
                .frame(width: 260, height: 260)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(minWidth: 320)
    }
}
