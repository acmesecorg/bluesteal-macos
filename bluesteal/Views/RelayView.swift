//
//  RelayView.swift
//  bluesteal
//

import SwiftUI
import AppKit

struct RelayView: View {
    @Environment(RelayClient.self) private var relay
    @Environment(AdvertRelay.self) private var advertRelay
    @Environment(RebroadcastService.self) private var rebroadcast

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
                TextField("\(SignalingClient.codeLength)-letter code", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submitJoin() }
                Button("Connect", action: submitJoin)
                    .controlSize(.small)
                    .disabled(normalisedJoinCode.count != SignalingClient.codeLength)
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
            rebroadcastChip
            Button("Disconnect") { relay.disconnect() }
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

    /// Uppercased + filtered to the alphabet — strips spaces, ambiguous
    /// I/L/O, and any digits the user might paste from a stale code. The
    /// "Connect" button gates on this length, not the raw input length.
    private var normalisedJoinCode: String {
        let allowed = Set(SignalingClient.codeAlphabet)
        return joinCode.uppercased().filter { allowed.contains($0) }
    }

    private func submitJoin() {
        let code = normalisedJoinCode
        guard code.count == SignalingClient.codeLength else { return }
        relay.join(code: code)
        showJoinField = false
        joinCode = ""
    }
}
