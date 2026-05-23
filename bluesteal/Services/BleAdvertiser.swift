//
//  BleAdvertiser.swift
//  bluesteal
//
//  Thin wrapper around `CBPeripheralManager` that broadcasts a single BLE
//  advertisement at a time. macOS imposes a hard limitation here: third-party
//  apps may only set `CBAdvertisementDataLocalNameKey` and
//  `CBAdvertisementDataServiceUUIDsKey` — raw service-data and manufacturer-
//  data sections cannot be emitted from the peripheral role. The caller
//  (`RebroadcastService`) is responsible for encoding the EID payload into a
//  128-bit service UUID before calling `start(uuid:)`.
//

import Foundation
import CoreBluetooth

@MainActor
@Observable
final class BleAdvertiser: NSObject {
    private(set) var isAdvertising: Bool = false
    private(set) var isPoweredOn: Bool = false
    private(set) var lastError: String?

    /// Fires after every state transition with the current `(isAdvertising,
    /// lastError)` tuple. `RebroadcastService` uses this to surface errors on
    /// the relay status chip.
    var onStatusChanged: ((Bool, String?) -> Void)?

    private let tracer: RelayTracer
    private var peripheralManager: CBPeripheralManager!
    private var pendingUUID: CBUUID?

    init(tracer: RelayTracer) {
        self.tracer = tracer
        super.init()
        // CBPeripheralManager init *immediately* triggers a system permission
        // prompt on first use. Defer until the user actually pairs by holding
        // off creation until `start(uuid:)` is first called — but we still
        // need the delegate to fire so the prompt resolves. Eager init is
        // simpler and matches the scanner's CBCentralManager lifecycle.
        peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
    }

    func start(uuid: CBUUID) {
        pendingUUID = uuid
        guard isPoweredOn else {
            tracer.log("ble.pub", "ble.pub.deferred",
                       ["uuid": uuid.uuidString,
                        "state": "\(peripheralManager.state.rawValue)"])
            return
        }
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }
        let data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [uuid]
        ]
        peripheralManager.startAdvertising(data)
        tracer.log("ble.pub", "ble.pub.start", ["uuid": uuid.uuidString])
    }

    func stop() {
        pendingUUID = nil
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
            tracer.log("ble.pub", "ble.pub.stop", [:])
        }
        if isAdvertising {
            isAdvertising = false
            onStatusChanged?(false, lastError)
        }
    }
}

extension BleAdvertiser: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        Task { @MainActor in
            self.isPoweredOn = (state == .poweredOn)
            self.tracer.log("ble.pub", "ble.pub.state",
                            ["state": "\(state.rawValue)",
                             "poweredOn": state == .poweredOn])
            // If a start was deferred until power-on, replay it now.
            if state == .poweredOn, let uuid = self.pendingUUID,
               !peripheral.isAdvertising {
                let data: [String: Any] = [CBAdvertisementDataServiceUUIDsKey: [uuid]]
                peripheral.startAdvertising(data)
                self.tracer.log("ble.pub", "ble.pub.start.deferred",
                                ["uuid": uuid.uuidString])
            }
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                                         error: Error?) {
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            if let errorDescription {
                self.isAdvertising = false
                self.lastError = errorDescription
                self.tracer.log("ble.pub", "ble.pub.error",
                                ["error": errorDescription])
            } else {
                self.isAdvertising = true
                self.lastError = nil
                self.tracer.log("ble.pub", "ble.pub.started", [:])
            }
            self.onStatusChanged?(self.isAdvertising, self.lastError)
        }
    }
}
