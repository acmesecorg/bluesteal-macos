//
//  AdvertRowView.swift
//  bluesteal
//

import SwiftUI
import CoreBluetooth

enum AdvertSource {
    case local        // observed by our own CoreBluetooth scanner
    case relay        // received over the WebRTC data channel from a paired peer

    var symbol: String {
        switch self {
        case .local: return "dot.radiowaves.left.and.right"
        case .relay: return "arrow.down.forward.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .local: return .secondary
        case .relay: return .purple
        }
    }
}

struct AdvertRowView: View {
    let advert: CableAdvert
    var source: AdvertSource = .local
    @State private var expanded = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                detailRow("Peripheral", advert.peripheralID.uuidString)
                if let uuid = advert.serviceUUID {
                    detailRow("UUID", uuid.uuidString)
                }
                detailRow("Payload (\(advert.payload.count) B)", advert.payloadHex)
                if let name = advert.localName {
                    detailRow("Local Name", name)
                }
                if let manuf = advert.manufacturerHex {
                    detailRow("Manufacturer", manuf)
                }
                if !advert.advertisedServiceUUIDs.isEmpty {
                    detailRow("Advertised UUIDs",
                              advert.advertisedServiceUUIDs.map { $0.uuidString }.joined(separator: ", "))
                }
                if let tx = advert.txPowerLevel {
                    detailRow("Tx Power", "\(tx) dBm")
                }
                if let conn = advert.isConnectable {
                    detailRow("Connectable", conn ? "yes" : "no")
                }
                detailRow("First Seen", Self.timeFormatter.string(from: advert.firstSeen))
                detailRow("Last Seen", Self.timeFormatter.string(from: advert.lastSeen))
            }
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(.top, 4)
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: source.symbol)
                    .font(.caption)
                    .foregroundStyle(source.tint)
                    .frame(width: 16, alignment: .center)
                    .help(source == .relay ? "Received from paired peer" : "Locally scanned")

                Text(Self.timeFormatter.string(from: advert.lastSeen))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 92, alignment: .leading)

                variantBadge

                Text("\(advert.rssi) dBm")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)

                Text("×\(advert.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Text(shortHex(advert.payloadHex))
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(source == .relay ? Color.purple.opacity(0.06) : Color.clear)
    }

    private var variantBadge: some View {
        let color: Color = {
            switch advert.variant {
            case .fidoV2: return .blue
            case .googleV1: return .purple
            case .googleV2: return .indigo
            case .googleMfgV1: return .pink
            case .unknown: return .orange
            }
        }()
        return Text(advert.variant.badge)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .frame(width: 84, alignment: .leading)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func shortHex(_ hex: String) -> String {
        guard hex.count > 24 else { return hex }
        let start = hex.prefix(12)
        let end = hex.suffix(8)
        return "\(start)…\(end)"
    }
}
