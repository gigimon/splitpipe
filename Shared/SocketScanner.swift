import Darwin
import Foundation

/// Соединение процесса по 4-tuple: что сбрасывает помощник и что видит сторож правил в приложении.
struct SocketConnection: Hashable {
    var udp: Bool
    var local: String
    var localPort: UInt16
    var remote: String
    var remotePort: UInt16

    var display: String { "\(remote):\(remotePort)" }
}

/// Сокеты процессов через `proc_pidinfo`: помощнику (root) видны все процессы, приложению — процессы пользователя.
/// У приложения, которое идёт через расширение, собственные TCP-сокеты в состоянии `CLOSED` — настоящее соединение
/// держит расширение; `ESTABLISHED` в процессе приложения — значит, мимо SplitPipe (проверено 2026-10-23 на Opera).
enum SocketScanner {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFn.self) }

    static func allPids() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(n, 0)))).filter { $0 > 0 }
    }

    /// Процесс, ответственный за `pid` (приложение у helper-процессов и WebKit); nil — функции нет.
    static func responsible(for pid: pid_t) -> pid_t? { responsibleFn.map { $0(pid) } }

    /// `roots` и все процессы, за которые они отвечают.
    static func processes(responsibleFor roots: Set<pid_t>) -> [pid_t] {
        guard let fn = responsibleFn else { return Array(roots) }
        return allPids().filter { roots.contains($0) || roots.contains(fn($0)) }
    }

    /// Установленные TCP и (если `udp`) подключённые UDP по IPv4 в интернет; локальная сеть и DNS — нет.
    static func connections(of pid: pid_t, udp includeUDP: Bool = true) -> [SocketConnection] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard read > 0 else { return [] }
        var out: [SocketConnection] = []
        for fd in fds.prefix(Int(read) / stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0
            else { continue }
            let ini: in_sockinfo
            let udp: Bool
            if info.psi.soi_kind == Int32(SOCKINFO_TCP) {
                guard info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) else { continue }
                ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                udp = false
            } else if includeUDP, info.psi.soi_kind == Int32(SOCKINFO_IN), info.psi.soi_protocol == IPPROTO_UDP {
                ini = info.psi.soi_proto.pri_in
                udp = true
            } else {
                continue
            }
            guard ini.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }
            let remotePort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let remoteAddr = ini.insi_faddr.ina_46.i46a_addr4
            guard remotePort != 0, remotePort != 53, !isPrivate(remoteAddr) else { continue }
            out.append(SocketConnection(udp: udp, local: format(ini.insi_laddr.ina_46.i46a_addr4), localPort: localPort,
                                        remote: format(remoteAddr), remotePort: remotePort))
        }
        return out
    }

    private static func format(_ addr: in_addr) -> String {
        var a = addr
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    /// Локальная сеть, link-local, loopback, CGNAT (`100.64/10`: Tailscale) и неподключённый сокет.
    static func isPrivate(_ addr: in_addr) -> Bool {
        let a = UInt32(bigEndian: addr.s_addr)
        let b0 = a >> 24, b1 = (a >> 16) & 0xff
        return a == 0 || b0 == 127 || b0 == 10 || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168)
            || (b0 == 169 && b1 == 254) || (b0 == 100 && b1 & 0xc0 == 64)
    }
}
