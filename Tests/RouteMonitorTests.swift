import Darwin
import XCTest

/// Разбор сообщений routing socket (`RouteMonitor.parse`) на собранных вручную сообщениях — без сети и root.
final class RouteMonitorTests: XCTestCase {
    private let monitor = RouteMonitor()
    /// У loopback индекс есть всегда: по нему `RouteMessage` находит имя интерфейса.
    private let lo = if_nametoindex("lo0")

    private func sockaddrIn(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> [UInt8] {
        [16, UInt8(AF_INET), 0, 0, a, b, c, d] + [UInt8](repeating: 0, count: 8)
    }

    private func sockaddrIn6() -> [UInt8] {
        [28, UInt8(AF_INET6)] + [UInt8](repeating: 0, count: 6) + [0x20, 0x01] + [UInt8](repeating: 0, count: 14) + [0, 0, 0, 0]
    }

    /// `rt_msghdr` и адреса за ним: `addrs` — по порядку `RTAX_*`, `nil` — адреса нет.
    private func routeMessage(type: Int32, flags: Int32, errno: Int32 = 0, addrs: [[UInt8]?]) -> [UInt8] {
        var h = rt_msghdr()
        h.rtm_version = UInt8(RTM_VERSION)
        h.rtm_type = UInt8(type)
        h.rtm_index = UInt16(lo)
        h.rtm_flags = flags
        h.rtm_pid = 42
        h.rtm_errno = errno
        var body: [UInt8] = []
        for (i, a) in addrs.enumerated() {
            guard let a else { continue }
            h.rtm_addrs |= 1 << i
            body += a
        }
        h.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + body.count)
        return withUnsafeBytes(of: h) { Array($0) } + body
    }

    private func addressMessage(type: Int32, ifa: [UInt8]) -> [UInt8] {
        var h = ifa_msghdr()
        h.ifam_version = UInt8(RTM_VERSION)
        h.ifam_type = UInt8(type)
        h.ifam_index = UInt16(lo)
        h.ifam_addrs = (1 << RTAX_NETMASK) | (1 << RTAX_IFA)
        let body = sockaddrIn(255, 0, 0, 0) + ifa
        h.ifam_msglen = UInt16(MemoryLayout<ifa_msghdr>.size + body.count)
        return withUnsafeBytes(of: h) { Array($0) } + body
    }

    private func parse(_ bytes: [UInt8]) -> RouteMonitor.Parsed {
        bytes.withUnsafeBytes { monitor.parse($0) }
    }

    func testSplitRouteIsDefaultChange() throws {
        let m = routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC,
                             addrs: [sockaddrIn(0, 0, 0, 0), sockaddrIn(192, 168, 1, 1), sockaddrIn(128, 0, 0, 0)])
        guard case .route(let change) = parse(m) else { return XCTFail("expected route") }
        XCTAssertEqual(change.type, RTM_ADD)
        XCTAssertEqual(change.pid, 42)
        XCTAssertEqual(change.route.prefix, 1)
        XCTAssertEqual(change.route.cidr, "0.0.0.0/1")
        XCTAssertEqual(change.route.gateway, "192.168.1.1")
        XCTAssertEqual(change.route.interface, "lo0")
        XCTAssertEqual(change.route.index, lo)
        XCTAssertTrue(change.isDefault)
    }

    /// Host-маршрут к серверу VPN через шлюз — важен; клонированный или без `RTF_STATIC` (ARP, кэш) — нет.
    func testHostRoutes() {
        let host = [sockaddrIn(135, 136, 177, 118), sockaddrIn(192, 168, 1, 1)]
        guard case .route(let c) = parse(routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_HOST,
                                                      addrs: host)) else { return XCTFail("expected route") }
        XCTAssertEqual(c.route.prefix, 32)
        XCTAssertFalse(c.isDefault)
        guard case .ignored = parse(routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_HOST, addrs: host))
        else { return XCTFail("non-static host route must be ignored") }
        guard case .ignored = parse(routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_HOST | RTF_WASCLONED,
                                                 addrs: host))
        else { return XCTFail("cloned route must be ignored") }
    }

    func testNarrowRouteAndFailedRequestIgnored() {
        let net24 = [sockaddrIn(10, 0, 0, 0), sockaddrIn(10, 0, 0, 1), sockaddrIn(255, 255, 255, 0)]
        guard case .ignored = parse(routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, addrs: net24))
        else { return XCTFail("/24 must be ignored") }
        let def = [sockaddrIn(0, 0, 0, 0), sockaddrIn(192, 168, 1, 1), sockaddrIn(0, 0, 0, 0)]
        guard case .ignored = parse(routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC, errno: EEXIST, addrs: def))
        else { return XCTFail("failed request must be ignored") }
    }

    func testScopedDefault() {
        let def = [sockaddrIn(0, 0, 0, 0), sockaddrIn(192, 168, 1, 1), sockaddrIn(0, 0, 0, 0)]
        guard case .route(let c) = parse(routeMessage(type: RTM_DELETE, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC | RTF_IFSCOPE,
                                                      addrs: def)) else { return XCTFail("expected route") }
        XCTAssertEqual(c.route.cidr, "default")
        XCTAssertTrue(c.route.scoped)
    }

    /// `RTM_NEWADDR` с IPv4 — «адрес назначен заново», с IPv6 — просто «интерфейсы поменялись».
    func testNewAddress() {
        guard case .address(let iface) = parse(addressMessage(type: RTM_NEWADDR, ifa: sockaddrIn(127, 0, 0, 1)))
        else { return XCTFail("expected address") }
        XCTAssertEqual(iface, "lo0")
        guard case .interfaces = parse(addressMessage(type: RTM_NEWADDR, ifa: sockaddrIn6()))
        else { return XCTFail("IPv6 address must not count") }
        guard case .link(let link) = parse(addressMessage(type: RTM_DELADDR, ifa: sockaddrIn(127, 0, 0, 1)))
        else { return XCTFail("expected link") }
        XCTAssertFalse(link.up)
        XCTAssertFalse(link.detached)
    }

    /// Обрезанные сообщения не должны ронять разбор.
    func testTruncatedMessages() {
        let m = routeMessage(type: RTM_ADD, flags: RTF_UP | RTF_GATEWAY | RTF_STATIC,
                             addrs: [sockaddrIn(0, 0, 0, 0), sockaddrIn(192, 168, 1, 1), sockaddrIn(128, 0, 0, 0)])
        for n in [4, 20, MemoryLayout<rt_msghdr>.size, MemoryLayout<rt_msghdr>.size + 10, m.count - 1] {
            _ = parse(Array(m.prefix(n)))
        }
        let a = addressMessage(type: RTM_NEWADDR, ifa: sockaddrIn(127, 0, 0, 1))
        for n in [4, MemoryLayout<ifa_msghdr>.size, MemoryLayout<ifa_msghdr>.size + 17, a.count - 1] {
            _ = parse(Array(a.prefix(n)))
        }
    }
}

final class SharedLogicTests: XCTestCase {
    func testCovers2001() {
        XCTAssertTrue(NetworkState.covers2001(firstByte: 0x00, prefix: 0))   // ::/0
        XCTAssertTrue(NetworkState.covers2001(firstByte: 0x00, prefix: 1))   // ::/1
        XCTAssertFalse(NetworkState.covers2001(firstByte: 0x80, prefix: 1))  // 8000::/1
        XCTAssertTrue(NetworkState.covers2001(firstByte: 0x20, prefix: 3))   // 2000::/3
        XCTAssertFalse(NetworkState.covers2001(firstByte: 0x40, prefix: 2))  // 4000::/2
    }

    func testRuleMatchLongestPrefix() {
        let rules = ["com.google": 1, "com.google.Chrome": 2, "org.mozilla.firefox": 3]
        XCTAssertEqual(rules.match(signingID: "com.google.Chrome"), 2)
        XCTAssertEqual(rules.match(signingID: "com.google.Chrome.helper.Renderer"), 2)
        XCTAssertEqual(rules.match(signingID: "com.google.drivefs.fpext"), 1)
        XCTAssertNil(rules.match(signingID: "com.googlex"))
        XCTAssertNil(rules.match(signingID: "org.mozilla"))
        XCTAssertNil(rules.match(signingID: ""))
    }

    func testManagedApps() {
        XCTAssertTrue(ManagedApps.contains(path: "/Users/u/Downloads/Foo.app/Contents/MacOS/Foo", signingID: "com.foo"))
        XCTAssertTrue(ManagedApps.contains(path: "/System/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari",
                                           signingID: "com.apple.Safari"))
        XCTAssertFalse(ManagedApps.contains(path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                                            signingID: "com.apple.controlcenter"))
        XCTAssertFalse(ManagedApps.contains(path: "/usr/libexec/foo", signingID: "foo"))
        XCTAssertFalse(ManagedApps.contains(path: "/Applications/SplitPipe.app/Contents/MacOS/SplitPipe", signingID: "dev.splitpipe.app"))
    }

    func testSTUN() {
        let tx = [UInt8](repeating: 7, count: 12)
        // Binding Success, XOR-MAPPED-ADDRESS 203.0.113.5.
        let ip: [UInt8] = [203, 0, 113, 5]
        let xored = zip(ip, [0x21, 0x12, 0xA4, 0x42] as [UInt8]).map { $0 ^ $1 }
        let attr: [UInt8] = [0x00, 0x20, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00] + xored
        let msg: [UInt8] = [0x01, 0x01, 0x00, UInt8(attr.count), 0x21, 0x12, 0xA4, 0x42] + tx + attr
        XCTAssertEqual(Probe.parseSTUN(msg, transaction: tx), "203.0.113.5")
        XCTAssertNil(Probe.parseSTUN(msg, transaction: [UInt8](repeating: 8, count: 12)))
        XCTAssertNil(Probe.parseSTUN(Array(msg.prefix(19)), transaction: tx))
    }
}
