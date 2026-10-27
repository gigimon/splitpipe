import XCTest

/// Разбор текстовых списков подсетей, слияние диапазонов, упаковка для расширения и поиск адреса по спискам.
final class IPListsTests: XCTestCase {
    private func v4(_ s: String) -> UInt32 {
        s.split(separator: ".").reduce(0) { $0 << 8 | UInt32($1)! }
    }

    private func v6(_ s: String) -> UInt128 {
        ParsedIPList.range6(Substring(s))!.lowerBound
    }

    // MARK: - Разбор

    func testParseFormats() {
        let text = """
        # страна
        1.2.3.0/24
        5.6.7.8
        2a00:1450::/32 ; google
        9.9.9.0/24 # inline
        10.0.0.0/8, 11.0.0.0/8\t12.0.0.0/8
        """
        let p = ParsedIPList.parse(text)
        XCTAssertEqual(p.invalid, 0)
        XCTAssertEqual(p.v6.count, 1)
        XCTAssertEqual(p.v4, [v4("1.2.3.0")...v4("1.2.3.255"), v4("5.6.7.8")...v4("5.6.7.8"), v4("9.9.9.0")...v4("9.9.9.255"),
                              v4("10.0.0.0")...v4("12.255.255.255")])
        XCTAssertEqual(p.count, 5)
    }

    func testInvalidLinesAreCountedNotFatal() {
        let p = ParsedIPList.parse("hello\n1.2.3.0/33\n1.2.3.4/x\n300.1.1.1\n::1/129\n1.2.3.0/24\n\n   \n")
        XCTAssertEqual(p.invalid, 5)
        XCTAssertEqual(p.v4, [v4("1.2.3.0")...v4("1.2.3.255")])
    }

    func testHostBitsAreMaskedOff() {
        XCTAssertEqual(ParsedIPList.range4("1.2.3.77/24"), v4("1.2.3.0")...v4("1.2.3.255"))
        XCTAssertEqual(ParsedIPList.range4("0.0.0.0/0"), 0...UInt32.max)
        XCTAssertEqual(ParsedIPList.range6("::/0"), 0...UInt128.max)
        XCTAssertEqual(ParsedIPList.range6("2001:db8::1/128"), v6("2001:db8::1")...v6("2001:db8::1"))
    }

    func testIPv4NotParsedAsIPv6() {
        XCTAssertNil(ParsedIPList.range6("1.2.3.4"))
        XCTAssertNil(ParsedIPList.range4("2a00::1"))
    }

    // MARK: - Слияние

    func testMergeOverlappingAdjacentAndContained() {
        let p = ParsedIPList.parse("1.2.4.0/24\n1.2.3.0/24\n1.2.3.128/25\n1.2.6.0/24\n1.2.6.10\n")
        XCTAssertEqual(p.v4, [v4("1.2.3.0")...v4("1.2.4.255"), v4("1.2.6.0")...v4("1.2.6.255")])
    }

    func testMergeFullRangeDoesNotOverflow() {
        let merged = ParsedIPList.merge([0...UInt32.max, 5...10, v4("1.0.0.0")...v4("1.0.0.255")])
        XCTAssertEqual(merged, [0...UInt32.max])
    }

    // MARK: - Упаковка

    func testPackRoundTrip() {
        let p = ParsedIPList.parse("1.2.3.0/24\n8.8.8.8\n2a00:1450::/32\n2001:db8::1\n")
        let c = p.compiled(id: "x", hash: "h")
        XCTAssertEqual(c.v4.count, 2 * 2 * 4)
        XCTAssertEqual(c.v6.count, 2 * 2 * 16)
        XCTAssertEqual(ParsedIPList.unpack(c.v4, as: UInt32.self), p.v4)
        XCTAssertEqual(ParsedIPList.unpack(c.v6, as: UInt128.self), p.v6)
    }

    func testUnpackRejectsDamagedData() {
        XCTAssertEqual(ParsedIPList.unpack(Data([1, 2, 3]), as: UInt32.self), [])
        // Обратный диапазон (начало больше конца) отбрасывается.
        XCTAssertEqual(ParsedIPList.unpack(ParsedIPList.pack([UInt32(1)...UInt32(2)]) + Data([9, 0, 0, 0, 1, 0, 0, 0]),
                                           as: UInt32.self), [1...2])
    }

    // MARK: - Поиск

    private func rule(_ id: String, _ route: String) -> IPListRule {
        IPListRule(id: id, name: id.uppercased(), rule: AppRule(route: route, fallback: Fallback.system))
    }

    func testContainsBoundaries() {
        let ranges: [ClosedRange<UInt32>] = [10...20, 30...40, 50...50]
        for (x, expected) in [(9, false), (10, true), (20, true), (21, false), (35, true), (50, true), (51, false), (0, false)] {
            XCTAssertEqual(IPListSet.contains(ranges, UInt32(x)), expected, "\(x)")
        }
        XCTAssertFalse(IPListSet.contains([ClosedRange<UInt32>](), 5))
    }

    func testFirstMatchingListWinsByOrder() {
        let ru = ParsedIPList.parse("1.2.0.0/16").compiled(id: "ru", hash: "a")
        let tg = ParsedIPList.parse("1.2.3.0/24\n2a00:1450::/32").compiled(id: "tg", hash: "b")
        let set = IPListSet([ru, tg])
        // Порядок правил решает, а не узость подсети.
        XCTAssertEqual(set.firstMatch([rule("ru", "direct"), rule("tg", "vpn:amnezia")], v4: v4("1.2.3.4"))?.id, "ru")
        XCTAssertEqual(set.firstMatch([rule("tg", "vpn:amnezia"), rule("ru", "direct")], v4: v4("1.2.3.4"))?.id, "tg")
        XCTAssertEqual(set.firstMatch([rule("tg", "vpn:amnezia"), rule("ru", "direct")], v4: v4("1.2.9.9"))?.id, "ru")
        XCTAssertNil(set.firstMatch([rule("ru", "direct")], v4: v4("8.8.8.8")))
        XCTAssertEqual(set.firstMatch([rule("ru", "direct"), rule("tg", "vpn:amnezia")], v6: v6("2a00:1450::5"))?.id, "tg")
    }

    func testRuleWithoutRangesIsSkipped() {
        let set = IPListSet([ParsedIPList.parse("1.2.3.0/24").compiled(id: "a", hash: "h")])
        XCTAssertEqual(set.firstMatch([rule("missing", "block"), rule("a", "direct")], v4: v4("1.2.3.1"))?.id, "a")
    }

    func testUpsertKeepOnlyAndHashes() {
        var set = IPListSet([ParsedIPList.parse("1.2.3.0/24").compiled(id: "a", hash: "h1"),
                             ParsedIPList.parse("5.0.0.0/8").compiled(id: "b", hash: "h2")])
        XCTAssertEqual(set.hashes, ["a": "h1", "b": "h2"])
        set.upsert(ParsedIPList.parse("9.9.9.0/24").compiled(id: "a", hash: "h3"))
        XCTAssertNil(set.firstMatch([rule("a", "direct")], v4: v4("1.2.3.1")))
        XCTAssertNotNil(set.firstMatch([rule("a", "direct")], v4: v4("9.9.9.9")))
        set.keepOnly(["a"])
        XCTAssertEqual(set.hashes, ["a": "h3"])
        XCTAssertNil(set.firstMatch([rule("b", "direct")], v4: v4("5.1.1.1")))
        set.keepOnly([])
        XCTAssertTrue(set.isEmpty)
    }

    func testLargeListLookup() {
        // Как ipdeny: тысячи непересекающихся /24.
        let text = (0..<5000).map { "10.\($0 / 256).\($0 % 256).0/24" }.joined(separator: "\n")
        let p = ParsedIPList.parse(text)
        XCTAssertEqual(p.v4.count, 1)  // соседние /24 слились в одну подсеть
        let sparse = (0..<5000).map { "10.\($0 / 128).\(($0 % 128) * 2).0/24" }.joined(separator: "\n")
        let set = IPListSet([ParsedIPList.parse(sparse).compiled(id: "s", hash: "h")])
        let r = [rule("s", "direct")]
        XCTAssertNotNil(set.firstMatch(r, v4: v4("10.3.4.200")))
        XCTAssertNil(set.firstMatch(r, v4: v4("10.3.5.200")))
    }
}
