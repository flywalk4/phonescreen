import Network

public extension TransportKind {
    /// Classifies a ready TCP connection by the interface it runs over:
    /// loopback = tunnelled by usbmuxd (USB), `awdl*` / `llw*` = peer-to-peer Wi-Fi, anything else = LAN.
    static func detect(_ connection: NWConnection) -> TransportKind {
        guard let path = connection.currentPath else { return .lan }
        if path.usesInterfaceType(.loopback) { return .usb }
        if let name = path.availableInterfaces.first?.name, name.hasPrefix("awdl") || name.hasPrefix("llw") {
            return .peerToPeer
        }
        return .lan
    }
}
