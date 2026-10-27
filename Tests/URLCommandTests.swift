import XCTest

/// Разбор ссылок `splitpipe://` и сроков временного маршрута.
final class URLCommandTests: XCTestCase {
    private func parse(_ s: String) throws -> URLCommand { try URLCommand.parse(URL(string: s)!) }

    func testSwitchCommands() throws {
        XCTAssertEqual(try parse("splitpipe://toggle").action, .setEnabled(nil))
        XCTAssertEqual(try parse("splitpipe://on").action, .setEnabled(true))
        XCTAssertEqual(try parse("splitpipe://off").action, .setEnabled(false))
        XCTAssertEqual(try parse("SPLITPIPE://ON").action, .setEnabled(true))
        XCTAssertNil(try parse("splitpipe://on").token)
    }

    func testRoute() throws {
        XCTAssertEqual(try parse("splitpipe://route?app=org.telegram.desktop&via=vpn:amnezia&for=1h").action,
                       .route(app: "org.telegram.desktop", via: "vpn:amnezia", duration: .hour))
        // Без приложения — активное, без срока — навсегда.
        XCTAssertEqual(try parse("splitpipe://route?via=direct").action, .route(app: nil, via: "direct", duration: nil))
        XCTAssertEqual(try parse("splitpipe://route?app=&via=direct&for=").action, .route(app: nil, via: "direct", duration: nil))
        // Имя с пробелом и кириллицей.
        XCTAssertEqual(try parse("splitpipe://route?app=Google%20Chrome&via=%D0%9D%D0%B0%D0%BF%D1%80%D1%8F%D0%BC%D1%83%D1%8E").action,
                       .route(app: "Google Chrome", via: "Напрямую", duration: nil))
        // Регистр имён параметров не важен.
        XCTAssertEqual(try parse("splitpipe://route?APP=a&Via=block&FOR=quit").action, .route(app: "a", via: "block", duration: .untilQuit))
    }

    func testRevert() throws {
        XCTAssertEqual(try parse("splitpipe://revert?app=com.tinyspeck.slackmacgap").action, .revert(app: "com.tinyspeck.slackmacgap"))
        XCTAssertEqual(try parse("splitpipe://revert").action, .revert(app: nil))
    }

    func testToken() throws {
        XCTAssertEqual(try parse("splitpipe://off?token=ABC").token, "ABC")
        XCTAssertNil(try parse("splitpipe://off?token=").token)
    }

    func testErrors() {
        XCTAssertThrowsError(try parse("splitpipe://route?app=a")) { error in
            guard case CommandError.routeNotFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parse("splitpipe://route?via=direct&for=2d")) { error in
            guard case CommandError.badDuration("2d") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parse("splitpipe://delete")) { error in
            guard case CommandError.unknownCommand("delete") = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try parse("https://example.com/on"))
        XCTAssertThrowsError(try parse("splitpipe://"))
    }

    // MARK: - Сроки

    func testDurationParse() throws {
        XCTAssertNil(try TemporaryDuration.parse(nil))
        XCTAssertNil(try TemporaryDuration.parse("  "))
        for (s, d) in [("15m", TemporaryDuration.minutes15), ("15", .minutes15), ("1h", .hour), ("60m", .hour), ("60", .hour),
                       ("quit", .untilQuit), ("QUIT", .untilQuit), (" vpn ", .untilVPNDisconnect)] {
            XCTAssertEqual(try TemporaryDuration.parse(s), d, s)
        }
        XCTAssertThrowsError(try TemporaryDuration.parse("30m"))
        XCTAssertThrowsError(try TemporaryDuration.parse("forever"))
    }

    func testDurationEnds() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(TemporaryDuration.minutes15.end(from: now), .at(now.addingTimeInterval(900)))
        XCTAssertEqual(TemporaryDuration.hour.end(from: now), .at(now.addingTimeInterval(3600)))
        XCTAssertEqual(TemporaryDuration.untilQuit.end(from: now), .appQuit)
        XCTAssertEqual(TemporaryDuration.untilVPNDisconnect.end(from: now), .vpnDisconnect)
    }

    func testTemporaryRouteRoundTrip() throws {
        let routes = [
            TemporaryRoute(route: "direct", end: .at(Date(timeIntervalSince1970: 1_800_000_000)),
                           previous: AppRule(route: "vpn:amnezia", fallback: "block")),
            TemporaryRoute(route: "block", end: .appQuit, previous: nil),
            TemporaryRoute(route: "vpn:amnezia", end: .vpnDisconnect, previous: nil, vpnDownSince: Date(timeIntervalSince1970: 1_800_000_100)),
        ]
        let data = try JSONEncoder().encode(routes)
        XCTAssertEqual(try JSONDecoder().decode([TemporaryRoute].self, from: data), routes)
    }
}
