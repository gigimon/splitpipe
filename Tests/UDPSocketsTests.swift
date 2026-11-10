import Darwin
import Network
import XCTest

/// `UDPSockets` на loopback: один порт на все адреса, приём от адреса, на который не слали.
final class UDPSocketsTests: XCTestCase {
    private let queue = DispatchQueue(label: "udp.tests")

    /// Сокет-получатель на `127.0.0.1`: порт и дескриптор.
    private func listener() -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(fd, $0, len), 0)
                getsockname(fd, $0, &len)
            }
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (fd, UInt16(bigEndian: sa.sin_port))
    }

    /// Порт отправителя датаграммы, пришедшей на `fd`.
    private func sourcePort(_ fd: Int32) -> UInt16? {
        var buf = [UInt8](repeating: 0, count: 64)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        return n > 0 ? UInt16(bigEndian: from.sin_port) : nil
    }

    func testAddressRoundTrip() {
        let v4 = UDPAddress(v4: [192, 168, 1, 77], port: 7125)
        XCTAssertEqual(v4.port, 7125)
        XCTAssertFalse(v4.isIPv6)
        XCTAssertEqual(UDPAddress(v4.endpoint), v4)
        let v6 = UDPAddress(v6: [0x20, 0x01] + [UInt8](repeating: 0, count: 13) + [1], port: 443)
        XCTAssertTrue(v6.isIPv6)
        XCTAssertEqual(UDPAddress(v6.endpoint), v6)
        XCTAssertNil(UDPAddress(.hostPort(host: .name("example.com", nil), port: 443)))
    }

    func testOnePortForAllDestinationsAndReplyFromStranger() {
        let a = listener(), b = listener(), stranger = listener()
        defer { [a.fd, b.fd, stranger.fd].forEach { close($0) } }
        let got = expectation(description: "datagram from an address never sent to")
        var from: UDPAddress?
        var sockets: UDPSockets!
        var ports: (UInt16?, UInt16?)
        queue.sync {
            sockets = UDPSockets(interfaceIndex: nil, queue: queue) { datagrams in
                from = datagrams.first?.1
                got.fulfill()
            }
            XCTAssertNil(sockets.send(Data("a".utf8), to: UDPAddress(v4: [127, 0, 0, 1], port: a.port), bound: true))
            XCTAssertNil(sockets.send(Data("b".utf8), to: UDPAddress(v4: [127, 0, 0, 1], port: b.port), bound: true))
        }
        ports = (sourcePort(a.fd), sourcePort(b.fd))
        XCTAssertNotNil(ports.0)
        XCTAssertEqual(ports.0, ports.1)
        XCTAssertEqual(queue.sync { sockets.localPort(ipv6: false, bound: false) }, ports.0)

        // Третий сокет, которому мы не слали, отвечает на наш порт.
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_addr.s_addr = inet_addr("127.0.0.1")
        to.sin_port = (ports.0 ?? 0).bigEndian
        _ = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(stranger.fd, "x", 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        wait(for: [got], timeout: 2)
        XCTAssertEqual(queue.sync { from }, UDPAddress(v4: [127, 0, 0, 1], port: stranger.port))
        queue.sync { sockets.close() }
        XCTAssertEqual(queue.sync { sockets.send(Data("c".utf8), to: UDPAddress(v4: [127, 0, 0, 1], port: a.port), bound: false) }, ECANCELED)
    }
}
