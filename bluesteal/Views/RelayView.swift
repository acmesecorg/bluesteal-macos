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
    @Environment(TunnelTransport.self) private var tunnel

    enum TransportKind: String, CaseIterable { case webRTC = "WebRTC", tunnel = "Tunnel" }

    @State private var joinCode: String = ""
    @State private var showJoinField: Bool = false
    @State private var transport: TransportKind = .tunnel

    /// The tunnel transport "owns" the UI whenever it is past idle/closed;
    /// otherwise the WebRTC RelayClient drives it.
    private var tunnelActive: Bool {
        switch tunnel.state {
        case .idle, .closed: return false
        default:             return true
        }
    }

    private var effectiveState: RelayClient.State { tunnelActive ? tunnel.state : relay.state }

    var body: some View {
        HStack(spacing: 12) {
            statusBadge

            Divider().frame(height: 16)

            switch effectiveState {
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
            Picker("", selection: $transport) {
                ForEach(TransportKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 104)
            .controlSize(.small)

            Button("Host", action: startHost)
                .controlSize(.small)

            if showJoinField {
                TextField("code or token", text: $joinCode)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
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
        let isTunnel = tunnelActive
        let ready = !isTunnel || tunnel.token != nil
        let displayValue = isTunnel ? (tunnel.token ?? "waiting…") : code
        let label = isTunnel ? "Token" : "Code"
        return HStack(spacing: 10) {
            Text(label)
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
            .help("Copy \(label.lowercased())")
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
            if tunnelActive {
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
            } else {
                Text(relay.messagesSent > 0 ? "sent \(relay.messagesSent)" : "recv \(relay.messagesReceived)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Text("hbt \(relay.heartbeatCount)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if relay.isUsingTURN {
                    Text("TURN").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
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
        switch effectiveState {
        case .idle, .closed:                           return .secondary
        case .hosting, .joining, .negotiating:         return .orange
        case .open:                                    return .green
        }
    }

    private var stateLabel: String {
        let prefix = tunnelActive ? "tunnel " : ""
        switch effectiveState {
        case .idle:                                    return "idle"
        case .hosting:                                 return "\(prefix)hosting"
        case .joining(let c):                          return "\(prefix)joining \(c)"
        case .negotiating:                             return "\(prefix)negotiating"
        case .open:                                    return "\(prefix)open"
        case .closed(let r):                           return "closed (\(r))"
        }
    }

    /// Uppercased + filtered to the alphabet — strips spaces, ambiguous
    /// I/L/O, and any digits the user might paste from a stale code.
    private var normalisedJoinCode: String {
        let allowed = Set(SignalingClient.codeAlphabet)
        return joinCode.uppercased().filter { allowed.contains($0) }
    }

    private var joinInputValid: Bool {
        TunnelKeyDerivation.isTunnelToken(joinCode) ||
            normalisedJoinCode.count == SignalingClient.codeLength
    }

    private func submitJoin() {
        let raw = joinCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if TunnelKeyDerivation.isTunnelToken(raw) {
            startTunnelJoin(token: raw.uppercased())
        } else {
            let code = normalisedJoinCode
            guard code.count == SignalingClient.codeLength else { return }
            relay.join(code: code)
        }
        showJoinField = false
        joinCode = ""
    }

    // MARK: - Tunnel transport actions

    private func startHost() {
        switch transport {
        case .webRTC: _ = relay.host()
        case .tunnel: startTunnelHost()
        }
    }

    private func wireTunnelSend() {
        advertRelay.tunnelSend = { data in
            Task { await tunnel.send([UInt8](data)) }
        }
    }

    private func startTunnelHost() {
        let code = SignalingClient.makeCode()
        wireTunnelSend()
        Task { try? await tunnel.host(code: code) }
    }

    private func startTunnelJoin(token: String) {
        wireTunnelSend()
        Task { try? await tunnel.join(token: token) }
    }

    private func cancelOrDisconnect() {
        if tunnelActive {
            advertRelay.tunnelSend = nil
            tunnel.disconnect()
        } else {
            relay.disconnect(reason: "user")
        }
    }
}
