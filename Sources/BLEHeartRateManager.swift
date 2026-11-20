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

    var onHeartRateSample: ((Int, Date) -> Void)?

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var shouldAutoReconnect = false
    private let savedDeviceKey = "LastConnectedHRMonitorUUID"

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
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        shouldAutoReconnect = false
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        connectedPeripheral = nil
        currentBPM = 0
        batteryLevel = nil
        connectionState = .disconnected
    }

    private func parseHeartRate(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return nil }
        let isUInt16 = (bytes[0] & 0x01) != 0

        if isUInt16 {
            guard bytes.count >= 3 else { return nil }
            return Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        } else {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        }
    }
}

extension BLEHeartRateManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if let savedIDString = UserDefaults.standard.string(forKey: savedDeviceKey),
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
            if shouldAutoReconnect {
                connectionState = .reconnecting
                centralManager.connect(peripheral, options: nil)
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
               let bpm = parseHeartRate(from: data), bpm > 0 {
                currentBPM = bpm
                onHeartRateSample?(bpm, Date())
            } else if characteristic.uuid == batteryLevelUUID,
                      let level = data.first {
                batteryLevel = Int(level)
            }
        }
    }
}