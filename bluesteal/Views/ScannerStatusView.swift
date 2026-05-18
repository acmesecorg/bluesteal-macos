//
//  ScannerStatusView.swift
//  bluesteal
//

import SwiftUI
import CoreBluetooth

struct ScannerStatusView: View {
    let state: CBManagerState
    let isScanning: Bool
    let totalDetections: Int
    let uniqueCount: Int
    @Binding var mode: ScanMode
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            statusBadge
            Divider().frame(height: 16)

            Picker("Mode", selection: $mode) {
                ForEach(ScanMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Divider().frame(height: 16)

            Text("\(uniqueCount) unique  ·  \(totalDetections) total")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            Button("Clear", action: onClear)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch state {
            case .poweredOn:    return (isScanning ? "Scanning" : "Idle", .green)
            case .poweredOff:   return ("Bluetooth Off", .orange)
            case .unauthorized: return ("Unauthorized", .red)
            case .unsupported:  return ("Unsupported", .red)
            case .resetting:    return ("Resetting", .orange)
            case .unknown:      return ("Unknown", .secondary)
            @unknown default:   return ("Unknown", .secondary)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).monospacedDigit()
        }
    }
}
