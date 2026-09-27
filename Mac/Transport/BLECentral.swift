import CoreBluetooth
import Foundation
import PhoneScreenKit

/// The Mac's Bluetooth LE side: finds the phone's service, reads the L2CAP PSM and opens the channel.
/// Kept connected in the background as a standby, so losing the cable and Wi-Fi switches over instantly.
final class BLECentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "phonescreen.ble")
    private var manager: CBCentralManager?
    /// Peripherals we're connecting / connected to (CoreBluetooth needs strong references).
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var channelOpen: Set<UUID> = []
    private let onChannel: @Sendable (ByteChannel) -> Void

    private static let service = CBUUID(string: Protocol.bleService)
    private static let psmCharacteristic = CBUUID(string: Protocol.blePSMCharacteristic)

    init(onChannel: @escaping @Sendable (ByteChannel) -> Void) {
        self.onChannel = onChannel
    }

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            manager = CBCentralManager(delegate: self, queue: queue)
        }
    }

    // MARK: - Central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { scan() }
    }

    private func scan() {
        guard let manager, manager.state == .poweredOn, !manager.isScanning else { return }
        manager.scanForPeripherals(withServices: [Self.service])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] == nil else { return }
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        forget(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        forget(peripheral)
    }

    private func forget(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = nil
        channelOpen.remove(peripheral.identifier)
        // Scanning with a service filter only reports new advertisements; restart to find the phone again.
        manager?.stopScan()
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.scan() }
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return disconnect(peripheral)
        }
        peripheral.discoverCharacteristics([Self.psmCharacteristic], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.psmCharacteristic }) else {
            return disconnect(peripheral)
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, data.count >= 2 else { return disconnect(peripheral) }
        let psm = CBL2CAPPSM(data[data.startIndex]) | CBL2CAPPSM(data[data.startIndex + 1]) << 8
        peripheral.openL2CAPChannel(psm)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return disconnect(peripheral) }
        channelOpen.insert(peripheral.identifier)
        let id = peripheral.identifier
        let bytes = StreamByteChannel(input: channel.inputStream, output: channel.outputStream,
                                      transport: .bluetooth, owner: channel)
        onChannel(ClosingObserver(bytes) { [weak self] in
            // Channel ended (phone app closed, out of range): drop the link and look for the phone again.
            self?.queue.async {
                guard let self, let p = self.peripherals[id] else { return }
                self.disconnect(p)
            }
        })
    }

    private func disconnect(_ peripheral: CBPeripheral) {
        manager?.cancelPeripheralConnection(peripheral)
        forget(peripheral)
    }
}
