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
                TextField("token (e.g. ABCDE-123456)", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { submitJoin() }
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
}
