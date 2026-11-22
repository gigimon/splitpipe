import XCTest

/// Ключи VPN: стабильные для неизвестных клиентов и опознание из снимка расширения.
final class VPNKeysTests: XCTestCase {
    private func state(_ vpns: [String: VPNInfo], indexes: [String: UInt32]) -> NetworkState {
        var s = NetworkState()
        s.addresses = Dictionary(uniqueKeysWithValues: indexes.keys.map { ($0, "10.0.0.1") })
        s.indexes = indexes
        s.vpns = vpns
        return s
    }

    func testUnknownProcessKey() {
        let info = VPNCatalog.info(forUnknownProcess: "tailscaled")
        XCTAssertEqual(info.key, "proc:tailscaled")
        XCTAssertEqual(RouteID.defaultName(forVPN: info.key), "tailscaled")
        XCTAssertEqual(RouteID.defaultName(forVPN: "utun7"), "VPN utun7")
    }

    func testAdoptFillsUnidentifiedTunnel() {
        var app = state([:], indexes: ["utun4": 20])
        let ext = state(["utun4": VPNCatalog.info(forUnknownProcess: "tailscaled")], indexes: ["utun4": 20])
        app.adoptVPNs(from: ext)
        XCTAssertEqual(app.vpnKey(forTunnel: "utun4"), "proc:tailscaled")
    }

    func testAdoptSkipsRecreatedInterface() {
        var app = state([:], indexes: ["utun4": 21])
        let ext = state(["utun4": VPNCatalog.info(forUnknownProcess: "tailscaled")], indexes: ["utun4": 20])
        app.adoptVPNs(from: ext)
        XCTAssertEqual(app.vpnKey(forTunnel: "utun4"), "utun4")
    }

    func testAdoptPrefersExtensionOverProcessGuess() {
        let guess = VPNCatalog.info(forProcess: "amneziawg-go", source: .process)!
        var app = state(["utun4": guess], indexes: ["utun4": 20])
        let ext = state(["utun4": VPNCatalog.info(forUnknownProcess: "tailscaled")], indexes: ["utun4": 20])
        app.adoptVPNs(from: ext)
        XCTAssertEqual(app.vpnKey(forTunnel: "utun4"), "proc:tailscaled")
    }

    func testAdoptKeepsOwnReliableDetection() {
        let own = VPNInfo(key: "ne:ABC", name: "Work", client: "com.example.vpn", source: .service)
        var app = state(["utun4": own], indexes: ["utun4": 20])
        let ext = state(["utun4": VPNCatalog.info(forUnknownProcess: "other")], indexes: ["utun4": 20])
        app.adoptVPNs(from: ext)
        XCTAssertEqual(app.vpnKey(forTunnel: "utun4"), "ne:ABC")
    }
}
