import Darwin
import Foundation

/// Сброс соединений, открытых до SplitPipe (или до того, как приложение попало под правило): такие сокеты идут
/// мимо расширения, и новое правило к ним не применяется, пока приложение само их не закроет.
///
/// На каждое соединение ставится `block return out quick … from <локальный> to <удалённый>` в своём якоре:
/// на следующем же пакете приложение получает RST (по UDP — ICMP unreachable) и переподключается — уже через
/// расширение. Соединения через расширение pf не видит: их пакеты уходят в расширение, а не в сеть.
/// Правило снимается, когда сокет закрылся или (у TCP) на правило пришёлся первый пакет — RST уже отправлен, —
/// но не позже чем через `maxAge`.
///
/// Работает, только пока у соединения нет записи в таблице состояний pf: состояние проверяется раньше правил,
/// и `block return` такие пакеты не увидит. У Amnezia все правила `no state`, а с VPN-клиентом или файрволом,
/// который держит `keep state`, сброс молча не сработает — помощник пишет это в журнал (REVIEW2).
final class ConnectionResetter: @unchecked Sendable {
    static let anchor = "com.apple/splitpipe-reset"
    private let queue = DispatchQueue(label: "dev.splitpipe.helper.reset")
    /// IMAP IDLE и долгие keep-alive молчат до ~29 мин: RST придёт, только когда приложение что-то отправит.
    private let maxAge: TimeInterval = 1800
    private var blocked: [Connection: Blocked] = [:]

    private struct Blocked {
        var since: Date
        /// Процессы, у которых нашлось соединение: живо ли оно, проверяем только у них, а не у всех процессов системы.
        /// Сокет, переданный другому процессу, тогда сочтётся закрытым — его просто не сбросит.
        var pids: Set<pid_t>
    }
    /// Токен `pfctl -E`, если pf был выключен и его включили мы: вернуть как было, когда правил не останется.
    /// Он же на диске: помощник, перезапущенный или убитый с правилами сброса, иначе оставил бы pf включённым нами
    /// навсегда — вместе с чужим kill switch (REVIEW3, 5).
    private var pfToken: String? {
        didSet {
            if let pfToken {
                try? FileManager.default.createDirectory(at: Self.tokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(pfToken.utf8).write(to: Self.tokenURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: Self.tokenURL)
            }
        }
    }
    private static let tokenURL = URL(fileURLWithPath: "/Library/Application Support/SplitPipe/pf-token")
    private var timer: DispatchSourceTimer?

    typealias Connection = SocketConnection

    func start() {
        // Хвосты прошлого запуска помощника: его правила и сокеты уже неизвестны, а pf, включённый им, — отпускаем.
        queue.sync {
            _ = Guardian.run("/sbin/pfctl", ["-a", Self.anchor, "-F", "rules"])
            if let data = try? Data(contentsOf: Self.tokenURL) {
                let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    log.notice("releasing pf reference \(token, privacy: .public) left by previous helper")
                    Guardian.run("/sbin/pfctl", ["-X", token])
                }
                try? FileManager.default.removeItem(at: Self.tokenURL)
            }
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
        t.setEventHandler { [weak self] in self?.cleanup() }
        t.resume()
        timer = t
    }

    /// Перед завершением помощника: правила сброса и включённый нами pf не должны его пережить.
    func shutdown() {
        queue.sync {
            blocked.removeAll()
            apply()
        }
    }

    /// Сбрасывает интернет-соединения процессов `pids` и всех, за кого они отвечают (helper-процессы, WebKit).
    /// Возвращает число сброшенных соединений.
    func reset(pids: [pid_t]) -> Int {
        queue.sync {
            let targets = SocketScanner.processes(responsibleFor: Set(pids))
            // Один сокет бывает открыт в нескольких дескрипторах и процессах — считаем соединения, а не дескрипторы.
            var found: [Connection: Set<pid_t>] = [:]
            for pid in targets {
                for c in SocketScanner.connections(of: pid) where blocked[c] == nil { found[c, default: []].insert(pid) }
            }
            guard !found.isEmpty else { return 0 }
            let now = Date()
            for (c, owners) in found { blocked[c] = Blocked(since: now, pids: owners) }
            apply()
            log.notice("reset \(found.count) connections of pids \(targets.sorted(), privacy: .public)")
            warnAboutStates(Set(found.keys))
            return found.count
        }
    }

    /// Вызывать на `queue`. Снимает правила закрытых сокетов, сработавшие правила TCP и старые.
    private func cleanup() {
        guard !blocked.isEmpty else { return }
        let pids = Set(blocked.values.flatMap(\.pids))
        let alive = Set(pids.flatMap { SocketScanner.connections(of: $0) })
        let fired = firedTCP()
        let now = Date()
        let before = blocked.count
        blocked = blocked.filter { c, b in
            alive.contains(c) && !fired.contains(c) && now.timeIntervalSince(b.since) < maxAge
        }
        if blocked.count != before { apply() }
    }

    /// TCP-соединения, на чьё правило уже пришёлся пакет: RST ушёл, сокет сброшен. Правило снимаем сразу: новое
    /// соединение с тем же локальным портом к тому же адресу иначе попало бы под него до `maxAge`. UDP — нет:
    /// ICMP unreachable сокет не закрывает, приложение может слать дальше мимо расширения.
    private func firedTCP() -> Set<Connection> {
        var out: Set<Connection> = []
        var rule: Connection?
        for line in Guardian.run("/sbin/pfctl", ["-a", Self.anchor, "-vsr"]).split(separator: "\n") {
            if line.hasPrefix("block") {
                rule = Self.parseRule(line)
            } else if let r = rule, !r.udp, let packets = Self.counter("Packets:", in: line) {
                if packets > 0 { out.insert(r) }
                rule = nil
            }
        }
        return out
    }

    /// `block return out quick inet proto tcp from 192.168.1.5 port = 52144 to 17.57.146.20 port = 5223` — как
    /// pfctl печатает наше правило.
    static func parseRule(_ line: Substring) -> Connection? {
        let w = line.split(separator: " ")
        func value(after key: Substring) -> (word: Substring, index: Int)? {
            guard let i = w.firstIndex(of: key), i + 1 < w.count else { return nil }
            return (w[i + 1], i + 1)
        }
        func port(after i: Int) -> UInt16? {
            guard i + 2 < w.count, w[i + 1] == "port" else { return nil }
            let v = w[i + 2] == "=" && i + 3 < w.count ? w[i + 3] : w[i + 2]
            return UInt16(v)
        }
        guard let proto = value(after: "proto"), let from = value(after: "from"), let to = value(after: "to"),
              let localPort = port(after: from.index), let remotePort = port(after: to.index) else { return nil }
        return Connection(udp: proto.word == "udp", local: String(from.word), localPort: localPort,
                          remote: String(to.word), remotePort: remotePort)
    }

    /// Число после `key` в строке счётчиков `pfctl -v`: `[ Evaluations: 3  Packets: 1  Bytes: 52  States: 0 ]`.
    static func counter(_ key: String, in line: Substring) -> Int? {
        guard let r = line.range(of: key) else { return nil }
        return line[r.upperBound...].split(separator: " ").first.flatMap { Int($0) }
    }

    /// У соединения есть запись в таблице состояний pf — пакеты пойдут по ней, мимо нашего правила.
    private func warnAboutStates(_ connections: Set<Connection>) {
        let states = Guardian.run("/sbin/pfctl", ["-ss"])
        guard !states.isEmpty else { return }
        let stuck = connections.filter { c in
            states.contains("\(c.local):\(c.localPort) -> \(c.remote):\(c.remotePort)")
                || states.contains("\(c.remote):\(c.remotePort) <- \(c.local):\(c.localPort)")
        }
        guard !stuck.isEmpty else { return }
        log.error("\(stuck.count) of \(connections.count) connections have pf state and will not be reset: \(stuck.map(\.rule).sorted().joined(separator: "; "), privacy: .public)")
    }

    /// Загружает текущий набор правил в якорь; пустой набор — сброс якоря и возврат pf как было.
    private func apply() {
        if blocked.isEmpty {
            Guardian.run("/sbin/pfctl", ["-a", Self.anchor, "-F", "rules"])
            if let token = pfToken {
                Guardian.run("/sbin/pfctl", ["-X", token])
                pfToken = nil
            }
            return
        }
        if pfToken == nil, Guardian.run("/sbin/pfctl", ["-s", "info"]).contains("Status: Disabled") {
            // `-E` со счётчиком ссылок: не мешает тем, кто включал pf до нас.
            let out = Guardian.run("/sbin/pfctl", ["-E"])
            pfToken = out.split(separator: "\n").first { $0.hasPrefix("Token") }?
                .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let rules = blocked.keys.map(\.rule).sorted().joined(separator: "\n") + "\n"
        Guardian.run("/sbin/pfctl", ["-a", Self.anchor, "-f", "-"], input: rules)
        // Якорь сброса вызывается из `anchor "com.apple/*"` общего набора правил: если VPN-клиент перезагрузил pf
        // без него, правила лежат мёртвым грузом.
        let (effective, note) = Guardian.anchorEffect(info: Guardian.run("/sbin/pfctl", ["-s", "info"]),
                                                      main: Guardian.run("/sbin/pfctl", ["-sr"]))
        if !effective { log.error("reset rules will not work: \(note?.description ?? "", privacy: .public)") }
    }
}

extension SocketConnection {
    var rule: String {
        "block return out quick proto \(udp ? "udp" : "tcp") from \(local) port \(localPort) to \(remote) port \(remotePort)"
    }
}
