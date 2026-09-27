import CoreBluetooth
import Foundation
import PhoneScreenKit

/// The phone's Bluetooth LE side: publishes an L2CAP channel (a byte stream, much faster than GATT writes),
/// advertises a service whose characteristic tells the Mac the channel's PSM, and hands every opened channel
/// to the pool. It's the fallback when there is no cable and no Wi-Fi.
final class BLEPeripheral: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "phonescreen.ble")
    private var manager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    private let name: String
    private let onChannel: @Sendable (ByteChannel) -> Void

    init(name: String, onChannel: @escaping @Sendable (ByteChannel) -> Void) {
        self.name = name
        self.onChannel = onChannel
    }

    func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        // Unencrypted at the Bluetooth level: encryption there would pop system pairing dialogs on both devices.
        peripheral.publishL2CAPChannel(withEncryption: false)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard error == nil else { return }
        psm = PSM
        var le = PSM.littleEndian
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: Protocol.blePSMCharacteristic),
                                                     properties: [.read], value: Data(bytes: &le, count: 2),
                                                     permissions: [.readable])
        let service = CBMutableService(type: CBUUID(string: Protocol.bleService), primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard error == nil else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: Protocol.bleService)],
            CBAdvertisementDataLocalNameKey: name,
        ])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard let channel, error == nil else { return }
        onChannel(StreamByteChannel(input: channel.inputStream, output: channel.outputStream,
                                    transport: .bluetooth, owner: channel))
    }
}
