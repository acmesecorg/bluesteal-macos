//
//  RelayView.swift
//  bluesteal
//

import SwiftUI
import AppKit

struct RelayView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(AdvertRelay.self) private var advertRelay

    @State private var joinCode: String = ""
    @State private var showJoinField: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            statusBadge

            Divider().frame(height: 16)

            switch relay.state {
            case .idle, .closed:
                idleControls
            case .hosting(let code):
                hostingControls(code: code)
            case .joining, .negotiating:
                ProgressView().controlSize(.small)
                Text(stateLabel).font(.caption).foregroundStyle(.secondary)
                Button("Cancel") { relay.disconnect(reason: "cancelled") }
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
            Button("Host", action: { _ = relay.host() })
                .controlSize(.small)

            if showJoinField {
                TextField("8-char code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submitJoin() }
                Button("Connect", action: submitJoin)
                    .controlSize(.small)
                    .disabled(joinCode.count != 8)
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
        HStack(spacing: 10) {
            Text("Code")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("waiting for peer…")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel", role: .destructive) { relay.disconnect(reason: "cancelled") }
                .controlSize(.small)
                .buttonStyle(.borderless)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            Text(relay.messagesSent > 0 ? "sent \(relay.messagesSent)" : "recv \(relay.messagesReceived)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if relay.isUsingTURN {
                Text("TURN").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.18))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            Button("Disconnect") { relay.disconnect() }
                .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
            Text("Relay · " + stateLabel).font(.caption).monospacedDigit()
        }
    }

    private var statusColor: Color {
        switch relay.state {
        case .idle, .closed:                           return .secondary
        case .hosting, .joining, .negotiating:         return .orange
        case .open:                                    return .green
        }
    }

    private var stateLabel: String {
        switch relay.state {
        case .idle:                                    return "idle"
        case .hosting:                                 return "hosting"
        case .joining(let c):                          return "joining \(c)"
        case .negotiating:                             return "negotiating"
        case .open:                                    return "open"
        case .closed(let r):                           return "closed (\(r))"
        }
    }

    private func submitJoin() {
        let code = joinCode.uppercased().filter { $0.isLetter || $0.isNumber }
        guard code.count == 8 else { return }
        relay.join(code: code)
        showJoinField = false
    }
}
