import Darwin
import Foundation

/// Правило списка IP-подсетей: «адреса из списка — по такому-то маршруту». Действует как правило приложения, но только
/// для приложений без своего правила (при «Управлять всеми приложениями»); первый подходящий список по порядку.
/// Сами подсети — отдельно (`CompiledIPList`): их бывают сотни тысяч, в конфигурацию прокси они не годятся.
struct IPListRule: Codable, Hashable {
    var id: String
    var name: String
    var rule: AppRule
}

/// Подсети списка в упакованном виде: отсортированные непересекающиеся диапазоны, IPv4 — пары `UInt32`,
/// IPv6 — пары `UInt128` (little-endian). `hash` — от содержимого: расширение возвращает его в статусе, и приложение
/// досылает список, если там другой.
struct CompiledIPList: Codable, Hashable {
    var id: String
    var hash: String
    var v4: Data
    var v6: Data
}

/// Разобранный текстовый список: подсети по одной на строку (IPv4 и IPv6, CIDR или адрес), комментарии `#` и `;`.
struct ParsedIPList {
    var v4: [ClosedRange<UInt32>] = []
    var v6: [ClosedRange<UInt128>] = []
    /// Строки, которые не разобрались: не ошибка всего списка, только счётчик для интерфейса.
    var invalid = 0

    var count: Int { v4.count + v6.count }

    static func parse(_ text: String) -> ParsedIPList {
        var out = ParsedIPList()
        var v4: [ClosedRange<UInt32>] = []
        var v6: [ClosedRange<UInt128>] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = Substring(rawLine)
            if let c = line.firstIndex(where: { $0 == "#" || $0 == ";" }) { line = line[..<c] }
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }) {
                if let r = range4(token) { v4.append(r) } else if let r = range6(token) { v6.append(r) } else { out.invalid += 1 }
            }
        }
        out.v4 = merge(v4)
        out.v6 = merge(v6)
        return out
    }

    private static func split(_ token: Substring) -> (String, Int?)? {
        let parts = token.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let p = Int(parts[1]) else { return nil }
            return (String(parts[0]), p)
        }
        return (String(parts[0]), nil)
    }

    static func range4(_ token: Substring) -> ClosedRange<UInt32>? {
        guard let (addr, prefix) = split(token) else { return nil }
        var a = in_addr()
        guard inet_pton(AF_INET, addr, &a) == 1 else { return nil }
        let p = prefix ?? 32
        guard (0...32).contains(p) else { return nil }
        let ip = UInt32(bigEndian: a.s_addr)
        let mask: UInt32 = p == 0 ? 0 : ~UInt32(0) << UInt32(32 - p)
        return (ip & mask)...(ip | ~mask)
    }

    static func range6(_ token: Substring) -> ClosedRange<UInt128>? {
        guard let (addr, prefix) = split(token), addr.contains(":") else { return nil }
        var a = in6_addr()
        guard inet_pton(AF_INET6, addr, &a) == 1 else { return nil }
        let p = prefix ?? 128
        guard (0...128).contains(p) else { return nil }
        let ip = withUnsafeBytes(of: a) { $0.reduce(UInt128(0)) { $0 << 8 | UInt128($1) } }
        let mask: UInt128 = p == 0 ? 0 : ~UInt128(0) << UInt128(128 - p)
        return (ip & mask)...(ip | ~mask)
    }

    /// Сортирует и сливает пересекающиеся и соседние диапазоны.
    static func merge<T: FixedWidthInteger & UnsignedInteger>(_ ranges: [ClosedRange<T>]) -> [ClosedRange<T>] {
        var out: [ClosedRange<T>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, last.upperBound == T.max || r.lowerBound <= last.upperBound + 1 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    func compiled(id: String, hash: String) -> CompiledIPList {
        CompiledIPList(id: id, hash: hash, v4: Self.pack(v4), v6: Self.pack(v6))
    }

    static func pack<T: FixedWidthInteger>(_ ranges: [ClosedRange<T>]) -> Data {
        var data = Data(capacity: ranges.count * MemoryLayout<T>.size * 2)
        for r in ranges {
            withUnsafeBytes(of: r.lowerBound.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.upperBound.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack<T: FixedWidthInteger>(_ data: Data, as: T.Type) -> [ClosedRange<T>] {
        let size = MemoryLayout<T>.size
        guard data.count % (size * 2) == 0 else { return [] }
        return data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: size * 2).compactMap { off in
                let lo = T(littleEndian: raw.loadUnaligned(fromByteOffset: off, as: T.self))
                let hi = T(littleEndian: raw.loadUnaligned(fromByteOffset: off + size, as: T.self))
                return lo <= hi ? lo...hi : nil
            }
        }
    }
}

/// Поиск адреса в списках расширения: по каждому списку — бинарный поиск по отсортированным диапазонам.
struct IPListSet {
    private struct Ranges {
        var v4: [ClosedRange<UInt32>]
        var v6: [ClosedRange<UInt128>]
    }

    private var byID: [String: Ranges] = [:]
    private(set) var hashes: [String: String] = [:]

    var isEmpty: Bool { byID.isEmpty }

    init(_ lists: [CompiledIPList] = []) {
        for l in lists { upsert(l) }
    }

    mutating func upsert(_ list: CompiledIPList) {
        byID[list.id] = Ranges(v4: ParsedIPList.unpack(list.v4, as: UInt32.self), v6: ParsedIPList.unpack(list.v6, as: UInt128.self))
        hashes[list.id] = list.hash
    }

    mutating func keepOnly(_ ids: Set<String>) {
        byID = byID.filter { ids.contains($0.key) }
        hashes = hashes.filter { ids.contains($0.key) }
    }

    /// Первое правило из `rules` (по порядку), чей список содержит адрес.
    func firstMatch(_ rules: [IPListRule], v4 address: UInt32) -> IPListRule? {
        rules.first { byID[$0.id].map { Self.contains($0.v4, address) } ?? false }
    }

    func firstMatch(_ rules: [IPListRule], v6 address: UInt128) -> IPListRule? {
        rules.first { byID[$0.id].map { Self.contains($0.v6, address) } ?? false }
    }

    static func contains<T: Comparable>(_ ranges: [ClosedRange<T>], _ x: T) -> Bool {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ranges[mid].upperBound < x { lo = mid + 1 } else { hi = mid }
        }
        return lo < ranges.count && ranges[lo].contains(x)
    }
}
