//
//  RelayView.swift
//  bluesteal
//

import SwiftUI
import AppKit

struct RelayView: View {
    @Environment(AdvertRelay.self) private var advertRelay
    @Environment(RebroadcastService.self) private var rebroadcast
    @Environment(TunnelTransport.self) private var tunnel

    @State private var joinCode: String = ""
    @State private var showJoinField: Bool = false

    private var state: RelayState { tunnel.state }

    private var tunnelOpen: Bool {
        if case .open = tunnel.state { return true } else { return false }
    }

    var body: some View {
        HStack(spacing: 12) {
            statusBadge

            Divider().frame(height: 16)

            switch state {
            case .idle, .closed:
                idleControls
            case .hosting(let code):
                hostingControls(code: code)
            case .joining, .negotiating:
                ProgressView().controlSize(.small)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { cancelOrDisconnect() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            case .open:
                openControls
            }

            Spacer()

            openLogsLink
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        // Drive the rebroadcast pipeline from the tunnel's Open state — the
        // tunnel is the only transport, so this is what gates the sweep.
        .onChange(of: tunnelOpen, initial: true) { _, open in
            rebroadcast.externalOpen = open
        }
    }

    private var openLogsLink: some View {
        Button("Open logs") {
            let dir = RelayTracer.standardLogDirectory
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
        .controlSize(.small)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.caption)
    }

    // MARK: - Sections

    private var idleControls: some View {
        HStack(spacing: 8) {
            Button("Host", action: startTunnelHost)
                .controlSize(.small)

            if showJoinField {
                // Auto-formats as you type (uppercase, strip non-alphanumeric,
                // cap at 11, auto-insert "-" at position 5) while PRESERVING the
                // caret — matching the Windows/Android join fields. A plain
                // SwiftUI reformatting binding snaps the caret to the end.
                TokenTextField(
                    text: $joinCode,
                    placeholder: "token (e.g. ABCDE-123456)",
                    onSubmit: submitJoin
                )
                .frame(width: 180)
                Button("Connect", action: submitJoin)
                    .controlSize(.small)
                    .disabled(!joinInputValid)
                Button("Cancel") { showJoinField = false; joinCode = "" }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            } else {
                Button("Join…") { showJoinField = true }
                    .controlSize(.small)
            }
        }
    }

    private func hostingControls(code: String) -> some View {
        let displayValue = tunnel.token ?? "waiting…"
        let ready = tunnel.token != nil
        return HStack(spacing: 10) {
            Text("Token")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(displayValue)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(displayValue, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .disabled(!ready)
            .help("Copy token")
            Text("waiting for peer…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .destructive) { cancelOrDisconnect() }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            Text("sent \(tunnel.messagesSent) · recv \(tunnel.messagesReceived)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text("hbt \(tunnel.heartbeatCount)")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            if tunnel.hopNumber > 0 {
                Text("hop \(tunnel.hopNumber)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.18))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
            rebroadcastChip
            Button("Disconnect") { cancelOrDisconnect() }
                .controlSize(.small)
        }
    }

    private var rebroadcastChip: some View {
        let hasError = rebroadcast.lastError != nil
        let color: Color = hasError ? .red : (rebroadcast.isActive ? .green : .secondary)
        let label: String = {
            if let err = rebroadcast.lastError { return "Rebroadcast: \(err)" }
            return "Rebroadcasting \(rebroadcast.activeCount)"
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help(hasError ? "BLE peripheral error" : "Adverts re-broadcast over local BLE")
    }

    // MARK: - Helpers

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Relay · " + stateLabel).font(.caption).monospacedDigit()
        }
    }

    private var statusColor: Color {
        switch state {
        case .idle, .closed:                           return .secondary
        case .hosting, .joining, .negotiating:         return .orange
        case .open:                                    return .green
        }
    }

    private var stateLabel: String {
        switch state {
        case .idle:                                    return "idle"
        case .hosting:                                 return "tunnel hosting"
        case .joining(let c):                          return "tunnel joining \(c)"
        case .negotiating:                             return "tunnel negotiating"
        case .open:                                    return "tunnel open"
        case .closed(let r):                           return "closed (\(r))"
        }
    }

    private var joinInputValid: Bool {
        TunnelKeyDerivation.isTunnelToken(joinCode.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func submitJoin() {
        let raw = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TunnelKeyDerivation.isTunnelToken(raw) else { return }
        startTunnelJoin(token: raw.uppercased())
        showJoinField = false
        joinCode = ""
    }

    // MARK: - Tunnel transport actions

    private func wireTunnelSend() {
        advertRelay.tunnelSend = { data in
            Task { await tunnel.send([UInt8](data)) }
        }
    }

    private func startTunnelHost() {
        let code = PairingCode.make()
        wireTunnelSend()
        Task { try? await tunnel.host(code: code) }
    }

    private func startTunnelJoin(token: String) {
        wireTunnelSend()
        Task { try? await tunnel.join(token: token) }
    }

    private func cancelOrDisconnect() {
        advertRelay.tunnelSend = nil
        tunnel.disconnect()
    }

    /// Strip non-alphanumeric, uppercase, cap at 11 raw chars (5-char code + 6
    /// hex routing). Auto-insert the "-" separator at position 5 so the user
    /// never has to type it.
    static func formatTokenInput(_ raw: String) -> String {
        let clean = String(raw.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(11))
        if clean.count < 5 { return clean }
        let splitIdx = clean.index(clean.startIndex, offsetBy: 5)
        return String(clean[..<splitIdx]) + "-" + String(clean[splitIdx...])
    }
}

/// An `NSTextField` that auto-formats a tunnel token as you type while keeping
/// the caret where it belongs. SwiftUI's `TextField` with a reformatting
/// `Binding` snaps the insertion point to the end after every keystroke, which
/// makes mid-string edits and backspaces jump. The Windows (`SelectionStart`)
/// and Android (`TextFieldValue`) join fields both preserve the caret; this is
/// the AppKit equivalent. Tokens are ASCII (`A–Z`, `0–9`, `-`), so UTF-16
/// offsets and Character offsets coincide.
struct TokenTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = context.coordinator
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Only push external changes; avoid clobbering the caret during edits.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: TokenTextField
        init(_ parent: TokenTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            let editor = field.currentEditor()
            let raw = field.stringValue

            // Logical caret = count of alphanumerics before the insertion point.
            let selLoc = editor?.selectedRange.location ?? (raw as NSString).length
            let prefixEnd = min(selLoc, (raw as NSString).length)
            let logicalPos = (raw as NSString).substring(to: prefixEnd)
                .filter { $0.isLetter || $0.isNumber }.count

            let formatted = RelayView.formatTokenInput(raw)
            if formatted != raw {
                field.stringValue = formatted
                // Re-place the caret at the logical position, skipping past the
                // auto-inserted "-" at index 5.
                let caret = (logicalPos >= 5 && formatted.count > 5)
                    ? min(logicalPos + 1, formatted.count)
                    : min(logicalPos, formatted.count)
                editor?.selectedRange = NSRange(location: caret, length: 0)
            }
            parent.text = formatted
        }

        func control(_ control: NSControl,
                     textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
