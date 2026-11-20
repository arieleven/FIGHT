import Foundation
import CoreBluetooth
import SwiftUI

struct DiscoveredHRDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral

    static func == (lhs: DiscoveredHRDevice, rhs: DiscoveredHRDevice) -> Bool {
        lhs.id == rhs.id && lhs.rssi == rhs.rssi && lhs.name == rhs.name
    }
}

@MainActor
final class BLEHeartRateManager: NSObject, ObservableObject {
    @Published var isBluetoothPoweredOn = false
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var connectedDeviceName: String = "CooSpo HRM"
    @Published var statusMessage: String = "Ready to scan for CooSpo strap"
    @Published var currentBPM: Int = 0
    @Published var batteryLevel: Int?
    @Published var sensorContactDetected: Bool?
    @Published var discoveredDevices: [DiscoveredHRDevice] = []

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var latestRRBuffer: [Double] = []
    private let lastDeviceUUIDKey = "coospo_last_device_uuid_v1"

    // Standard Bluetooth SIG Heart Rate & Battery UUIDs
    nonisolated private let hrServiceUUID = CBUUID(string: "180D")
	nonisolated private let hrMeasurementUUID = CBUUID(string: "2A37")
	nonisolated private let batteryServiceUUID = CBUUID(string: "180F")
	nonisolated private let batteryLevelUUID = CBUUID(string: "2A19")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: "com.shon.coospotracker.blecentral"
        ])
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Turn on Bluetooth in iOS Settings"
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        statusMessage = "Scanning for Heart Rate Monitors..."

        // Also check already-connected system HR peripherals
        let connected = centralManager.retrieveConnectedPeripherals(withServices: [hrServiceUUID])
        for p in connected {
            addOrUpdateDevice(peripheral: p, rssi: -50)
        }

        centralManager.scanForPeripherals(withServices: [hrServiceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        if !isConnected {
            statusMessage = discoveredDevices.isEmpty ? "Tap Scan to find CooSpo" : "Select your CooSpo strap"
        }
    }

    func connect(to device: DiscoveredHRDevice) {
        stopScanning()
        statusMessage = "Connecting to \(device.name)..."
        connectedPeripheral = device.peripheral
        connectedPeripheral?.delegate = self
        UserDefaults.standard.set(device.id.uuidString, forKey: lastDeviceUUIDKey)
        centralManager.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        UserDefaults.standard.removeObject(forKey: lastDeviceUUIDKey)
        cleanupConnection(message: "Disconnected")
    }

    func consumeLatestRRIntervals() -> [Double] {
        let copy = latestRRBuffer
        latestRRBuffer.removeAll()
        return copy
    }

    private func addOrUpdateDevice(peripheral: CBPeripheral, rssi: Int) {
        let name = peripheral.name ?? "BLE Heart Rate Monitor"
        let item = DiscoveredHRDevice(id: peripheral.identifier, name: name, rssi: rssi, peripheral: peripheral)
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx] = item
        } else {
            discoveredDevices.append(item)
        }
    }

    private func cleanupConnection(message: String) {
        isConnected = false
        currentBPM = 0
        batteryLevel = nil
        sensorContactDetected = nil
        statusMessage = message
    }

    private func parseHeartRatePacket(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return }

        let flags = bytes[0]
        let is16BitBPM = (flags & 0x01) != 0
        let contactSupported = (flags & 0x04) != 0
        let contactDetected = (flags & 0x02) != 0
        let energyExpendedPresent = (flags & 0x08) != 0
        let rrIntervalsPresent = (flags & 0x10) != 0

        if contactSupported {
            sensorContactDetected = contactDetected
        }

        var offset = 1
        let bpm: Int
        if is16BitBPM {
            guard bytes.count >= offset + 2 else { return }
            bpm = Int(UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
            offset += 2
        } else {
            bpm = Int(bytes[offset])
            offset += 1
        }

        if bpm > 25 && bpm < 250 {
            currentBPM = bpm
        }

        if energyExpendedPresent {
            offset += 2
        }

        if rrIntervalsPresent {
            while offset + 1 < bytes.count {
                let rawRR = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
                let rrMs = (Double(rawRR) / 1024.0) * 1000.0
                if rrMs >= 280 && rrMs <= 2000 {
                    latestRRBuffer.append(rrMs)
                }
                offset += 2
            }
            // Nothing drains the buffer while idle, so keep only the last ~5 minutes.
            if latestRRBuffer.count > 600 {
                latestRRBuffer.removeFirst(latestRRBuffer.count - 600)
            }
        }
    }
}

extension BLEHeartRateManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            isBluetoothPoweredOn = (central.state == .poweredOn)
            if central.state == .poweredOn {
                statusMessage = "Bluetooth Ready"
                // Auto-reconnect to saved CooSpo strap if available
                if let savedStr = UserDefaults.standard.string(forKey: lastDeviceUUIDKey),
                   let savedUUID = UUID(uuidString: savedStr),
                   let known = central.retrievePeripherals(withIdentifiers: [savedUUID]).first {
                    connectedPeripheral = known
                    connectedPeripheral?.delegate = self
                    statusMessage = "Reconnecting to \(known.name ?? "CooSpo")..."
                    central.connect(known, options: nil)
                }
            } else {
                isScanning = false
                cleanupConnection(message: "Bluetooth is Off")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let first = peripherals.first {
            Task { @MainActor in
                self.connectedPeripheral = first
                self.connectedPeripheral?.delegate = self
                if first.state == .connected {
                    self.isConnected = true
                    self.connectedDeviceName = first.name ?? "CooSpo HRM"
                    self.statusMessage = "Connected (Restored)"
                    first.discoverServices([self.hrServiceUUID, self.batteryServiceUUID])
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssiVal = RSSI.intValue
        guard rssiVal != 127 else { return }
        Task { @MainActor in
            addOrUpdateDevice(peripheral: peripheral, rssi: rssiVal)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            isConnected = true
            connectedDeviceName = peripheral.name ?? "CooSpo HRM"
            statusMessage = "Connected • Streaming HR"
            peripheral.discoverServices([hrServiceUUID, batteryServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            cleanupConnection(message: "Couldn't connect — wake the strap (moisten pads) and tap Scan")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            cleanupConnection(message: "Signal lost — reconnecting...")
            // Automatic reconnect if strap briefly drops
            if UserDefaults.standard.string(forKey: lastDeviceUUIDKey) == peripheral.identifier.uuidString {
                centralManager.connect(peripheral, options: nil)
            }
        }
    }
}

extension BLEHeartRateManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == hrServiceUUID {
                peripheral.discoverCharacteristics([hrMeasurementUUID], for: service)
            } else if service.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            if ch.uuid == hrMeasurementUUID {
                peripheral.setNotifyValue(true, for: ch)
            } else if ch.uuid == batteryLevelUUID {
                peripheral.readValue(for: ch)
                peripheral.setNotifyValue(true, for: ch)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            if characteristic.uuid == hrMeasurementUUID {
                parseHeartRatePacket(data)
            } else if characteristic.uuid == batteryLevelUUID, let firstByte = data.first {
                batteryLevel = Int(firstByte)
            }
        }
    }
}

struct DeviceScannerSheet: View {
    @EnvironmentObject var bleManager: BLEHeartRateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if bleManager.isConnected {
                    Section("Connected Sensor") {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(bleManager.connectedDeviceName)
                                    .font(.headline)
                                Text(bleManager.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Disconnect", role: .destructive) {
                                bleManager.disconnect()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section("Available Heart Rate Monitors") {
                    if bleManager.discoveredDevices.isEmpty {
                        HStack {
                            ProgressView()
                                .padding(.trailing, 8)
                            Text("Searching for CooSpo H9Z / HW807...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(bleManager.discoveredDevices) { device in
                            Button {
                                bleManager.connect(to: device)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "heart.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.red)
                                    VStack(alignment: .leading) {
                                        Text(device.name)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Text("Signal: \(device.rssi) dBm")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("Connect")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("CooSpo Sensors")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(bleManager.isScanning ? "Stop" : "Scan") {
                        if bleManager.isScanning {
                            bleManager.stopScanning()
                        } else {
                            bleManager.startScanning()
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        bleManager.stopScanning()
                        dismiss()
                    }
                }
            }
            .onAppear {
                bleManager.startScanning()
            }
            .onDisappear {
                bleManager.stopScanning()
            }
        }
    }
}
