//
//  CableScanner.swift
//  bluesteal
//

import Foundation
import CoreBluetooth
import Observation

/// One raw discovery event surfaced from CoreBluetooth. The scanner emits these
/// for every advert that carries caBLE service data; the store handles dedup
/// and classification.
struct RawAdvertEvent {
    let timestamp: Date
    let peripheralID: UUID
    let serviceData: [CBUUID: Data]
    let advertisedServiceUUIDs: [CBUUID]
    let localName: String?
    let manufacturerData: Data?
    let txPowerLevel: Int?
    let isConnectable: Bool?
    let rssi: Int
}

enum ScanMode: String, CaseIterable, Identifiable {
    case promiscuous   // serviceUUIDs: nil — catches every variant
    case filtered      // serviceUUIDs: [FFF9, FDE2] — lower CPU
    /// Promiscuous + dump every advert's full `advertisementData` dictionary
    /// to a separate JSONL for offline inspection. Used to characterise the
    /// wire format of external authenticators (e.g. native iOS) — see
    /// `docs/IOS_AUTHENTICATOR_CAPTURE.md`.
    case diagnostic

    var id: String { rawValue }
    var label: String {
        switch self {
        case .promiscuous: return "Promiscuous"
        case .filtered: return "Filtered (FFF9/FDE2)"
        case .diagnostic: return "Diagnostic"
        }
    }
}

/// Owns the `CBCentralManager`. Filters every discovery callback for service
/// data under either caBLE UUID and forwards the rest to `onEvent`.
@Observable
final class CableScanner: NSObject, CBCentralManagerDelegate {
    private(set) var state: CBManagerState = .unknown
    private(set) var isScanning: Bool = false
    var mode: ScanMode = .promiscuous {
        didSet { if isScanning { restart() } }
    }

    var onEvent: ((RawAdvertEvent) -> Void)?

    /// Optional sink for the Diagnostic mode. When non-nil and `mode ==
    /// .diagnostic`, every advert (caBLE-matching or not) is dumped via this
    /// logger. Injected from the app shell.
    var diagnosticLogger: DiagnosticLogger?

    private var central: CBCentralManager!

    init(previewMode: Bool = false) {
        super.init()
        guard !previewMode else { return }
        // No queue arg → main queue; matches @MainActor isolation in this project.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func start() {
        guard state == .poweredOn else { return }
        // Filtered mode narrows the OS-level service-UUID filter; promiscuous
        // and diagnostic both scan with no filter so 128-bit UUIDs and
        // manufacturer-data adverts are all visible.
        let services: [CBUUID]? = (mode == .filtered) ? AdvertClassifier.cableUUIDs : nil
        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ]
        central.scanForPeripherals(withServices: services, options: options)
        isScanning = true
    }

    func stop() {
        central.stopScan()
        isScanning = false
    }

    private func restart() {
        stop()
        start()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if state == .poweredOn {
            start()
        } else {
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // Diagnostic mode: dump *every* advert before the cable filter, so
        // we can identify non-cable encodings (e.g. EID-as-128-bit-UUID from
        // a native iOS authenticator) that the normal pipeline would drop.
        // The dedicated logger handles dedup so the file stays readable.
        if mode == .diagnostic {
            diagnosticLogger?.log(peripheralID: peripheral.identifier,
                                  rssi: RSSI.intValue,
                                  advertisementData: advertisementData)
        }

        let serviceData = (advertisementData[CBAdvertisementDataServiceDataKey]
                           as? [CBUUID: Data]) ?? [:]
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        // Forward adverts carrying caBLE service data (FFF9 / FDE2) OR a
        // Google manufacturer-data v1 caBLE blob (company ID 0x00E0). Either
        // gate is enough; the store routes each path independently.
        let hasCableServiceData = serviceData.keys.contains(where: AdvertClassifier.isCableUUID)
        let hasCableMfgData = manufacturerData.flatMap(AdvertClassifier.classifyManufacturerData) != nil
        guard hasCableServiceData || hasCableMfgData else { return }

        let event = RawAdvertEvent(
            timestamp: Date(),
            peripheralID: peripheral.identifier,
            serviceData: serviceData,
            advertisedServiceUUIDs: (advertisementData[CBAdvertisementDataServiceUUIDsKey]
                                     as? [CBUUID]) ?? [],
            localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            manufacturerData: manufacturerData,
            txPowerLevel: (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            rssi: RSSI.intValue
        )
        onEvent?(event)
    }
}
