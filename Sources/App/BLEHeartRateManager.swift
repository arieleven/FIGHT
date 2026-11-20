import Foundation
import CoreBluetooth
import Combine

enum BLEConnectionState: String {
    case bluetoothOff = "Bluetooth Off"
    case disconnected = "Disconnected"
    case scanning = "Scanning for HW9..."
    case connecting = "Connecting..."
    case reconnecting = "Out of Range — Reconnecting..."
    case connected = "Connected"
}

@MainActor
final class BLEHeartRateManager: NSObject, ObservableObject {
    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")
    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")

    @Published var connectionState: BLEConnectionState = .disconnected
    @Published var deviceName: String = "Coospo HW9"
    @Published var currentBPM: Int = 0
    @Published var batteryLevel: Int? = nil
    @Published var latestRRMs: Double? = nil
    @Published var rollingRMSSD: Double? = nil

    @Published var isHRVScanning = false
    @Published var hrvScanSecondsLeft: Int = 60
    @Published var lastMorningHRV: Double? = nil

    var onHeartRateSample: ((Int, Double?, Date) -> Void)?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var shouldAutoReconnect = false
    private let savedDeviceKey = "LastConnectedHRMonitorUUID"

    private var recentRRIntervals: [Double] = []
    private var hrvScanRRBuffer: [Double] = []
    private var hrvScanTimer: Timer?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            connectionState = .bluetoothOff
            return
        }
        connectionState = .scanning
        centralManager.scanForPeripherals(
            withServices: [heartRateServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        if connectionState == .scanning {
            connectionState = .disconnected
        }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        shouldAutoReconnect = true
        connectedPeripheral = peripheral
        peripheral.delegate = self
        deviceName = peripheral.name ?? "Coospo HW9"
        connectionState = .connecting
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedDeviceKey)
        if centralManager.state == .poweredOn {
            centralManager.connect(peripheral, options: nil)
        }
    }

    func disconnect() {
        shouldAutoReconnect = false
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        currentBPM = 0
        batteryLevel = nil
        latestRRMs = nil
        connectionState = .disconnected
    }

    func startMorningHRVScan(onComplete: @escaping (Double?) -> Void) {
        guard connectionState == .connected else { return }
        hrvScanRRBuffer.removeAll()
        hrvScanSecondsLeft = 60
        isHRVScanning = true

        hrvScanTimer?.invalidate()
        hrvScanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                if self.hrvScanSecondsLeft > 1 {
                    self.hrvScanSecondsLeft -= 1
                } else {
                    timer.invalidate()
                    self.isHRVScanning = false
                    let result = Self.computeRMSSD(from: self.hrvScanRRBuffer) ?? self.rollingRMSSD
                    self.lastMorningHRV = result
                    onComplete(result)
                }
            }
        }
    }

    func cancelMorningHRVScan() {
        hrvScanTimer?.invalidate()
        isHRVScanning = false
    }

    private func parseHeartRatePacket(from data: Data) -> (bpm: Int, rrIntervalsMs: [Double])? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }

        let flags = bytes[0]
        let isUInt16 = (flags & 0x01) != 0
        let energyExpendedPresent = (flags & 0x08) != 0
        let rrIntervalPresent = (flags & 0x10) != 0

        var offset = 1
        let bpm: Int

        if isUInt16 {
            guard bytes.count >= 3 else { return nil }
            bpm = Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
            offset = 3
        } else {
            guard bytes.count >= 2 else { return nil }
            bpm = Int(bytes[1])
            offset = 2
        }

        if energyExpendedPresent {
            offset += 2
        }

        var rrValues: [Double] = []
        if rrIntervalPresent {
            while offset + 1 < bytes.count {
                let rawRR = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let rrMs = (Double(rawRR) / 1024.0) * 1000.0
                if rrMs >= 250.0 && rrMs <= 2000.0 {
                    rrValues.append(rrMs)
                }
                offset += 2
            }
        }

        return (bpm, rrValues)
    }

    static func computeRMSSD(from rrIntervals: [Double]) -> Double? {
        guard rrIntervals.count >= 5 else { return nil }
        var sumSquaredDiffs = 0.0
        var count = 0
        for i in 1..<rrIntervals.count {
            let diff = rrIntervals[i] - rrIntervals[i - 1]
            if abs(diff) < 250.0 {
                sumSquaredDiffs += diff * diff
                count += 1
            }
        }
        guard count >= 4 else { return nil }
        return sqrt(sumSquaredDiffs / Double(count))
    }
}

extension BLEHeartRateManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if shouldAutoReconnect, let existing = connectedPeripheral {
                    connectionState = .reconnecting
                    central.connect(existing, options: nil)
                } else if let savedIDString = UserDefaults.standard.string(forKey: savedDeviceKey),
                          let uuid = UUID(uuidString: savedIDString),
                          let knownPeripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                    connect(to: knownPeripheral)
                } else {
                    startScanning()
                }
            case .poweredOff:
                connectionState = .bluetoothOff
                currentBPM = 0
            default:
                connectionState = .disconnected
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").uppercased()
            if name.contains("HW9") || name.contains("COOSPO") {
                connect(to: peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectionState = .connected
            deviceName = peripheral.name ?? "Coospo HW9"
            peripheral.discoverServices([heartRateServiceUUID, batteryServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            currentBPM = 0
            if shouldAutoReconnect && central.state == .poweredOn {
                connectionState = .reconnecting
                centralManager.connect(peripheral, options: nil)
            } else if shouldAutoReconnect {
                connectionState = .bluetoothOff
            } else {
                connectionState = .disconnected
            }
        }
    }
}

extension BLEHeartRateManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let services = peripheral.services else { return }
            for service in services {
                if service.uuid == heartRateServiceUUID {
                    peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: service)
                } else if service.uuid == batteryServiceUUID {
                    peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let characteristics = service.characteristics else { return }
            for characteristic in characteristics {
                if characteristic.uuid == heartRateMeasurementUUID {
                    peripheral.setNotifyValue(true, for: characteristic)
                } else if characteristic.uuid == batteryLevelUUID {
                    peripheral.readValue(for: characteristic)
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value else { return }

            if characteristic.uuid == heartRateMeasurementUUID,
               let parsed = parseHeartRatePacket(from: data),
               parsed.bpm >= 30 && parsed.bpm <= 240 {
                currentBPM = parsed.bpm

                if !parsed.rrIntervalsMs.isEmpty {
                    latestRRMs = parsed.rrIntervalsMs.last
                    recentRRIntervals.append(contentsOf: parsed.rrIntervalsMs)
                    if recentRRIntervals.count > 60 {
                        recentRRIntervals.removeFirst(recentRRIntervals.count - 60)
                    }
                    rollingRMSSD = Self.computeRMSSD(from: recentRRIntervals)
                    if isHRVScanning {
                        hrvScanRRBuffer.append(contentsOf: parsed.rrIntervalsMs)
                    }
                }

                onHeartRateSample?(parsed.bpm, parsed.rrIntervalsMs.last, Date())
            } else if characteristic.uuid == batteryLevelUUID,
                      let level = data.first {
                batteryLevel = Int(level)
            }
        }
    }
}